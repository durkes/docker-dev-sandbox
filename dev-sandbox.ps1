<#
.SYNOPSIS
    Open a shell in a containerized dev environment for the current project.

.DESCRIPTION
    Starts (or reuses) a Docker container with the project directory bind-mounted
    at /workspace, then execs an interactive shell into it. Run it again from
    another window for another prompt in the same container; the container stops
    once no shell is left attached (see -Persist).

    The bind mount is the entire containment boundary: only the project directory
    and its subdirectories are visible. No Docker socket, no --privileged.

.PARAMETER Path
    Project directory to mount. Defaults to the current directory.

.PARAMETER Port
    Host ports to publish. Accepts bare ports (3000) or remaps (8081:8080).
    If a host port is already taken, it walks upward to the next free one.
    Ports are fixed when the container is created -- use -Stop first to change them.

.PARAMETER Isolated
    Use throwaway home and node_modules volumes, removed when the container is
    stopped, and separate from the ones a normal run uses. For sandboxing
    untrusted third-party code.

.PARAMETER SharedHome
    Share one home volume across all projects instead of a per-project one.
    Convenient for shared settings, but lets Claude Code read its own session
    transcripts from your other projects.

.PARAMETER SharedModules
    Do not shadow node_modules (root and nested package.json alike) with a
    container-only volume. Only safe if you never run npm from Windows here.

.PARAMETER Claude
    Launch Claude Code (--dangerously-skip-permissions) instead of a shell.

.PARAMETER Command
    Run this command instead of an interactive shell.

.PARAMETER ClaudeAuth
    Run the Claude Code long-lived token flow once, then save the token to your
    Windows user environment so every future sandbox starts already logged in.

.PARAMETER Persist
    Leave the container running after this shell exits, instead of stopping it
    once no other shell is attached.

.PARAMETER Stop
    Stop and remove this project's container (and its throwaway volume, if -Isolated).

.PARAMETER Fresh
    Recreate the container even if one is already running.

.PARAMETER Rebuild
    Force an image rebuild.

.PARAMETER NodeVersion
    Node major version to build/use. Defaults to 24 (current Active LTS).

.EXAMPLE
    dev-sandbox
    Mount the current directory and open a shell.

.EXAMPLE
    dev-sandbox -Port 5173 -Claude
    Publish Vite's port and drop straight into Claude Code.

.EXAMPLE
    dev-sandbox -ClaudeAuth
    Log in once, here, and never again in any project sandbox.
#>
[CmdletBinding()]
param(
    [string]   $Path = ".",
    [string[]] $Port = @("3000", "5173", "8080"),
    [switch]   $Isolated,
    [switch]   $SharedHome,
    [switch]   $SharedModules,
    [switch]   $Claude,
    [string]   $Command,
    [switch]   $ClaudeAuth,
    [switch]   $Persist,
    [switch]   $Stop,
    [switch]   $Fresh,
    [switch]   $Rebuild,
    [int]      $NodeVersion = 24
)

$ErrorActionPreference = "Stop"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

function Fail($Message) {
    Write-Host "dev-sandbox: $Message" -ForegroundColor Red
    exit 1
}

function Get-Slug($AbsolutePath) {
    # Folder name for readability + a hash of the full path, so two projects
    # sharing a folder name never share volumes.
    $leaf = (Split-Path $AbsolutePath -Leaf).ToLower()
    $leaf = $leaf -replace '[^a-z0-9]+', '-'
    $leaf = $leaf.Trim('-')
    if ([string]::IsNullOrEmpty($leaf)) { $leaf = "project" }
    if ($leaf.Length -gt 24) { $leaf = $leaf.Substring(0, 24).Trim('-') }

    $sha = [System.Security.Cryptography.SHA1]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($AbsolutePath.ToLower())
    $hash = [System.BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "").ToLower()
    $sha.Dispose()

    return "$leaf-$($hash.Substring(0, 6))"
}

function Find-NestedWorkspaceDirs($Root, $MaxDepth) {
    # Never descends into node_modules or .git rather than filtering them out
    # afterward -- walking a real node_modules means thousands of package.json
    # files. Depth is capped so a deep tree can't make the scan slow either.
    $results = @()
    $queue = New-Object System.Collections.Generic.Queue[object]
    $queue.Enqueue(@{ Path = $Root; Depth = 0 })

    while ($queue.Count -gt 0) {
        $current = $queue.Dequeue()
        $subdirs = Get-ChildItem -LiteralPath $current.Path -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne 'node_modules' -and $_.Name -ne '.git' }

        foreach ($sub in $subdirs) {
            if (Test-Path -LiteralPath (Join-Path $sub.FullName "package.json") -PathType Leaf) {
                $results += $sub.FullName
            }
            if ($current.Depth -lt $MaxDepth) {
                $queue.Enqueue(@{ Path = $sub.FullName; Depth = $current.Depth + 1 })
            }
        }
    }

    return $results
}

function Get-ModuleMounts($ProjectPath, $Slug, $IsIsolated) {
    # One named volume per package.json found (root plus nested workspaces), so a
    # Linux npm install never lands on the real Windows filesystem. Keyed off the
    # full path, so it is stable across restarts and never collides with another
    # project's.
    #
    # -Isolated gets its own namespace for these, not just for the home: sharing
    # would hand whatever an untrusted `npm install` fetched to the next ordinary
    # run, and would make the volumes unsafe to delete on -Stop.
    #
    # Only called when a container is about to be created, since the mounts are
    # fixed at that point -- which is also why a workspace added later needs
    # -Fresh to pick it up.
    $prefix = if ($IsIsolated) { "dev-sandbox-modules-isolated-" } else { "dev-sandbox-modules-" }

    $mounts = @()
    $mounts += [pscustomobject]@{
        ContainerPath = "/workspace/node_modules"
        Volume        = "$prefix$Slug"
    }

    # 4 levels covers every realistic monorepo layout (packages/scope/name)
    # without risking a slow scan on a huge tree.
    foreach ($dir in (Find-NestedWorkspaceDirs -Root $ProjectPath -MaxDepth 4)) {
        $relPath = $dir.Substring($ProjectPath.Length).TrimStart('\') -replace '\\', '/'
        $mounts += [pscustomobject]@{
            ContainerPath = "/workspace/$relPath/node_modules"
            Volume        = "$prefix$(Get-Slug $dir)"
        }
    }

    # Comma operator: a single mount would otherwise come back as a bare object
    # rather than an array.
    return ,$mounts
}

function Test-PortNumber($Value) {
    # The digit bound comes first on purpose: [int] throws on a long enough run
    # of digits, so an unbounded '^\d+$' would blow up before the range check.
    if ($Value -notmatch '^\d{1,5}$') { return $false }
    $n = [int]$Value
    return ($n -ge 1 -and $n -le 65535)
}

function ConvertTo-PortMapping($Spec) {
    # Validated, not merely shaped: an out-of-range port reaching
    # Test-HostPortFree throws ArgumentOutOfRange, which its catch swallows and
    # surfaces 20 tries later as a misleading "no free host port".
    $parts = @($Spec -split ':')
    if ($parts.Count -eq 1) { $parts = @($parts[0], $parts[0]) }
    if ($parts.Count -ne 2 -or -not (Test-PortNumber $parts[0]) -or -not (Test-PortNumber $parts[1])) {
        Fail "invalid -Port value '$Spec'. Use 3000 or 8081:8080, with each port in 1-65535."
    }
    # Cast back through [int] so 0080 and 80 cannot name the same port twice.
    return "$([int]$parts[0]):$([int]$parts[1])"
}

function Get-DockerPublishedHostPorts {
    # Docker Desktop's WSL2 backend publishes container ports without binding a
    # plain Windows socket, so a TcpListener probe cannot see another
    # container's published port and `docker run -p` then fails with "port is
    # already allocated". Ask Docker separately.
    $ports = New-Object System.Collections.Generic.HashSet[int]
    docker ps --format '{{.Ports}}' | ForEach-Object {
        foreach ($m in [regex]::Matches($_, ':(\d+)->')) {
            [void]$ports.Add([int]$m.Groups[1].Value)
        }
    }
    # Comma operator: without it PowerShell enumerates the HashSet onto the
    # output stream, leaving an [int] or an [object[]] with no .Contains().
    return ,$ports
}

function Test-HostPortFree([int]$HostPort, $DockerPorts) {
    if ($DockerPorts.Contains($HostPort)) { return $false }
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Any, $HostPort)
        $listener.Start()
        $listener.Stop()
        return $true
    } catch {
        return $false
    }
}

function Resolve-PortMapping($Spec, $DockerPorts) {
    # Ports are fixed at container creation, so a conflict only needs dodging
    # once: walk upward until a free host port is found.
    $mapping = ConvertTo-PortMapping $Spec
    $hostPort, $containerPort = $mapping -split ':'
    $hostPort = [int]$hostPort
    $original = $hostPort

    $maxTries = 20
    while (-not (Test-HostPortFree $hostPort $DockerPorts)) {
        $hostPort++
        if ($hostPort -gt 65535) {
            Fail "no free host port found at or above $original before the end of the port range."
        }
        if ($hostPort - $original -ge $maxTries) {
            Fail "no free host port found near $original after $maxTries tries."
        }
    }
    if ($hostPort -ne $original) {
        Write-Host "dev-sandbox: port $original is in use, using $hostPort instead" -ForegroundColor Yellow
    }
    return "$($hostPort):$($containerPort)"
}

function Test-DockerReady {
    # No stderr redirection on native commands anywhere in this script -- neither
    # 2>&1 nor 2>$null. PowerShell 5.1 wraps redirected stderr in ErrorRecords,
    # which $ErrorActionPreference = "Stop" turns into a terminating error
    # whatever the exit code; unredirected, stderr is harmless. Hence the pattern
    # throughout: check quietly first (docker ps --filter), then run the command
    # that would complain.
    #
    # A missing executable is a different failure: PowerShell raises
    # CommandNotFoundException before the process runs, so $LASTEXITCODE never
    # gets a say and the friendly message below would become a stack trace.
    if (-not (Get-Command docker -CommandType Application -ErrorAction SilentlyContinue)) {
        Fail "docker not found on PATH. Is Docker Desktop installed?"
    }
    docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "cannot reach the Docker daemon. Is Docker Desktop running?"
    }
}

function Test-ContainerRunning($Name) {
    # ps --filter rather than inspect: inspect writes to stderr when the
    # container is absent, which is normal here, not an error.
    $found = docker ps -q --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
}

function Test-ContainerExists($Name) {
    $found = docker ps -aq --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
}

function Get-TokenFromPaste {
    # `claude setup-token` prints the token inside a block of prose, and a narrow
    # terminal wraps it across lines. Wrapping only inserts whitespace, which is
    # never token content -- so reassembly is: find the fragment starting the
    # token, strip whitespace, and keep appending while lines are nothing but
    # token characters. Anything else is prose again, and ends the token.
    $token  = ""
    $blanks = 0

    while ($true) {
        $line = Read-Host

        if ([string]::IsNullOrWhiteSpace($line)) {
            if ($token) { return $token }
            # A blank line inside the pasted block is normal. Two in a row with
            # nothing found means there was no token in it.
            $blanks++
            if ($blanks -ge 2) { return $null }
            continue
        }
        $blanks = 0
        $line = $line -replace '\s', ''

        if ($line -match 'sk-ant-oat[A-Za-z0-9_\-]*') {
            # Drops any prefix ("export CLAUDE_CODE_OAUTH_TOKEN=") and any
            # non-token suffix.
            $token = $matches[0]
        } elseif ($token) {
            if ($line -match '^[A-Za-z0-9_\-]+$') {
                $token += $line          # a wrapped continuation
            } else {
                return $token            # prose again: the token ended
            }
        }
    }
}

function Clear-PastedInput {
    # Whatever followed the token is still queued as keystrokes. Drop it so it
    # does not land on the prompt after this script exits.
    if ([Console]::IsInputRedirected) { return }
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
}

function Test-VolumeExists($Name) {
    $found = docker volume ls -q --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
}

function Test-ContainerHasOtherShell($Name) {
    # Anything running besides the "tail -f /dev/null" sentinel, its init
    # wrapper, and this ps itself means another window's shell is still attached.
    #
    # The existence check keeps docker exec off its stderr path: another window
    # can have removed the container between this shell exiting and this call,
    # and "Error: No such container" would be fatal (see Test-DockerReady).
    if (-not (Test-ContainerRunning $Name)) { return $false }
    $lines = docker exec $Name ps -eo args=
    if ($LASTEXITCODE -ne 0) { return $false }
    foreach ($line in $lines) {
        $line = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match 'docker-init\b') { continue }
        if ($line -eq "tail -f /dev/null") { continue }
        if ($line -match '^ps -eo args=$') { continue }
        return $true
    }
    return $false
}

function Remove-IsolatedVolumes($Slug) {
    # Every volume an -Isolated run creates is labelled with this project's slug,
    # so the whole set can be found without knowing their names here.
    #
    # Labelling the volumes rather than the container matters twice: $Isolated
    # describes *this* invocation, not the one that created the container (so a
    # plain "dev-sandbox -Stop" still cleans up), and the labels outlive the
    # container, so a crash or reboot cannot strand a volume.
    $names = docker volume ls -q --filter "label=dev-sandbox.isolated-project=$Slug"
    foreach ($name in $names) {
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            docker volume rm $name | Out-Null
        }
    }

    # Belt and braces for a home volume created before those labels existed:
    # this name only ever belongs to an -Isolated run.
    $legacy = "dev-sandbox-home-isolated-$Slug"
    if (Test-VolumeExists $legacy) {
        docker volume rm $legacy | Out-Null
    }
}

function New-IsolatedVolume($Name, $Slug) {
    # Created up front purely to carry the label; docker run would otherwise
    # conjure it unlabelled, and it could never be found again.
    docker volume create --label "dev-sandbox.isolated-project=$Slug" $Name | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "failed to create volume $Name" }
}

function Remove-SandboxContainer($Name, $Slug) {
    if (Test-ContainerExists $Name) {
        docker rm -f $Name | Out-Null
    }
    # After the container is gone: a volume still mounted cannot be removed.
    Remove-IsolatedVolumes $Slug
}

# --------------------------------------------------------------------------
# Resolve the project path
# --------------------------------------------------------------------------

Test-DockerReady

if (-not (Test-Path -LiteralPath $Path)) {
    Fail "path not found: $Path"
}

$resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
    Fail "not a directory: $resolved"
}
$projectPath = $resolved.TrimEnd('\')

# The mount is the whole containment boundary, so a too-broad one silently
# defeats the point. Refuse the obvious mistakes.
$usersRoot = if ($env:SystemDrive) { "$env:SystemDrive\Users" } else { "C:\Users" }
$forbidden = @($env:USERPROFILE, $env:PUBLIC, $usersRoot) | Where-Object { $_ }

# The root of *any* drive, not just the system one. The trailing slash is
# already stripped, so "D:\" is "D:" by now -- exactly what -Qualifier returns.
# (It throws on a UNC path, which has no drive.)
try { $qualifier = Split-Path $projectPath -Qualifier } catch { $qualifier = $null }
if ($qualifier) { $forbidden += $qualifier }

foreach ($bad in $forbidden) {
    if ($projectPath.TrimEnd('\') -ieq $bad.TrimEnd('\')) {
        Fail "refusing to mount '$projectPath' -- mount a single project directory, not a drive root or a user profile."
    }
}

# Anything directly under C:\Users is somebody's whole profile.
$projectParent = Split-Path $projectPath -Parent
if ($projectParent -and ($projectParent.TrimEnd('\') -ieq $usersRoot.TrimEnd('\'))) {
    Fail "refusing to mount '$projectPath' -- that is a whole user profile, not a project directory."
}

$slug          = Get-Slug $projectPath
$image         = "dev-sandbox:node$NodeVersion"
$containerName = "dev-sandbox-$slug"

if ($Isolated) {
    $homeVolume = "dev-sandbox-home-isolated-$slug"
    $homeLabel  = "isolated, discarded with node_modules on -Stop"
} elseif ($SharedHome) {
    $homeVolume = "dev-sandbox-home-shared"
    $homeLabel  = "shared across all projects"
} else {
    $homeVolume = "dev-sandbox-home-$slug"
    $homeLabel  = "per-project"
}

# --------------------------------------------------------------------------
# -Stop
# --------------------------------------------------------------------------

if ($Stop) {
    $existed = Test-ContainerExists $containerName
    Remove-SandboxContainer $containerName $slug
    if ($existed) {
        Write-Host "dev-sandbox: stopped $containerName" -ForegroundColor Yellow
    } else {
        Write-Host "dev-sandbox: no container running for this project" -ForegroundColor Yellow
    }
    exit 0
}

# --------------------------------------------------------------------------
# Build the image if it is missing or stale
# --------------------------------------------------------------------------

$dockerfile = Join-Path $PSScriptRoot "Dockerfile"
if (-not (Test-Path -LiteralPath $dockerfile)) {
    Fail "Dockerfile not found next to this script ($dockerfile)"
}

$dfHash = (Get-FileHash -Path $dockerfile -Algorithm SHA256).Hash.Substring(0, 16).ToLower()
$needBuild = $false
$buildReason = ""

$imageId = docker images -q $image
if ([string]::IsNullOrWhiteSpace(($imageId -join ""))) {
    $needBuild = $true
    $buildReason = "image $image not found"
} else {
    # Read the label via JSON: PowerShell 5.1 mangles the double quotes an
    # '{{index .Config.Labels "..."}}' template would need.
    $builtHash = ""
    $labelJson = docker image inspect $image --format '{{json .Config.Labels}}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $labelJson) {
        $labels = $labelJson | ConvertFrom-Json
        if ($labels -and $labels.PSObject.Properties.Name -contains "dev-sandbox.dockerfile") {
            $builtHash = $labels."dev-sandbox.dockerfile"
        }
    }
    if ($builtHash -ne $dfHash) {
        $needBuild = $true
        $buildReason = "Dockerfile changed since this image was built"
    }
}

if ($Rebuild) {
    $needBuild = $true
    $buildReason = "-Rebuild requested"
}

if ($needBuild) {
    Write-Host "dev-sandbox: building $image ($buildReason)..." -ForegroundColor Cyan
    docker build `
        --build-arg "NODE_VERSION=$NodeVersion" `
        --label "dev-sandbox.dockerfile=$dfHash" `
        -t $image `
        $PSScriptRoot
    if ($LASTEXITCODE -ne 0) { Fail "image build failed" }

    # A rebuilt image means any existing container is running the old one.
    if (Test-ContainerExists $containerName) {
        docker rm -f $containerName | Out-Null
    }
}

# --------------------------------------------------------------------------
# -ClaudeAuth
# --------------------------------------------------------------------------

if ($ClaudeAuth) {
    Write-Host "dev-sandbox: starting the Claude Code long-lived token flow." -ForegroundColor Cyan
    Write-Host "  Approve in the browser, then paste what it prints back here." -ForegroundColor DarkGray
    Write-Host ""

    if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
        Fail "-ClaudeAuth needs an interactive console."
    }

    # Prefer the host install: already the account you use on Windows, and it
    # keeps the flow out of a container. Otherwise use a throwaway container with
    # its own config dir, so nothing is left behind.
    $hostClaude = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue
    if ($hostClaude) {
        & $hostClaude.Source setup-token
    } else {
        docker run --rm -i -t -e "CLAUDE_CONFIG_DIR=/tmp/claude-setup" $image claude setup-token
    }

    Write-Host ""
    Write-Host "Paste the token -- the surrounding output is fine, and it may wrap." -ForegroundColor Cyan
    Write-Host "Press Enter on an empty line when you are done." -ForegroundColor DarkGray
    $token = Get-TokenFromPaste
    Clear-PastedInput
    if (-not $token) {
        Fail "no sk-ant-oat... token found in what you pasted. Nothing was saved."
    }

    [Environment]::SetEnvironmentVariable("CLAUDE_CODE_OAUTH_TOKEN", $token, "User")
    $env:CLAUDE_CODE_OAUTH_TOKEN = $token

    Write-Host ""
    Write-Host "dev-sandbox: saved CLAUDE_CODE_OAUTH_TOKEN to your Windows user environment." -ForegroundColor Green
    Write-Host "  every sandbox from now on starts already logged in, in every project." -ForegroundColor DarkGray
    Write-Host "  already-open PowerShell windows need to be reopened to see it." -ForegroundColor DarkGray
    Write-Host "  containers created before now keep their old environment: 'dev-sandbox -Stop' to refresh one." -ForegroundColor DarkGray
    exit 0
}

# --------------------------------------------------------------------------
# Create the container if it is not already running
# --------------------------------------------------------------------------

if ($Fresh -and (Test-ContainerExists $containerName)) {
    docker rm -f $containerName | Out-Null
}

$created = $false

if (-not (Test-ContainerRunning $containerName)) {
    if (Test-ContainerExists $containerName) {
        docker rm -f $containerName | Out-Null
    }

    # Deferred to here: this walks the project tree, and nothing above needs it.
    $moduleMounts = @()
    if (-not $SharedModules) {
        $moduleMounts = Get-ModuleMounts $projectPath $slug $Isolated
    }

    # "Throwaway" has to mean it: volumes surviving a crash or reboot would
    # otherwise be mounted straight back into the new sandbox.
    if ($Isolated) {
        Remove-IsolatedVolumes $slug
        New-IsolatedVolume $homeVolume $slug
        foreach ($mount in $moduleMounts) { New-IsolatedVolume $mount.Volume $slug }
    }

    $runArgs = @(
        "run", "-d",
        "--name", $containerName,
        "--init",
        "--hostname", "sandbox",
        # Not a hardened boundary, but free hardening. Note what is absent: no
        # Docker socket mount, no --privileged, no extra capabilities.
        "--security-opt", "no-new-privileges",
        "-w", "/workspace",
        "-v", "$($projectPath):/workspace",
        "-v", "$($homeVolume):/home/node"
    )

    # Shadow the host's node_modules: a Windows npm install produces Windows
    # binaries and .cmd shims that break under Linux, and vice versa.
    foreach ($mount in $moduleMounts) {
        $runArgs += @("-v", "$($mount.Volume):$($mount.ContainerPath)")
    }

    $dockerPorts = Get-DockerPublishedHostPorts
    $resolvedPorts = @()
    foreach ($p in $Port) {
        $resolvedMapping = Resolve-PortMapping $p $dockerPorts
        $resolvedPorts += $resolvedMapping
        # Reserve it immediately, or two entries in the same -Port list could
        # both resolve to the same free port before either is published.
        $chosenHostPort = [int](($resolvedMapping -split ':')[0])
        [void]$dockerPorts.Add($chosenHostPort)
        $runArgs += @("-p", $resolvedMapping)
    }

    # Auth is forwarded from the host environment and never written to disk, so
    # nothing secret can be committed. Without it, the credentials Claude Code
    # writes on login land in the per-project home volume -- which is why a plain
    # login has to be repeated for every new project.
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        $runArgs += @("-e", "CLAUDE_CODE_OAUTH_TOKEN=$($env:CLAUDE_CODE_OAUTH_TOKEN)")
    }
    if ($env:ANTHROPIC_API_KEY) {
        $runArgs += @("-e", "ANTHROPIC_API_KEY=$($env:ANTHROPIC_API_KEY)")
    }

    # Identity only, no credentials. Commits and pushes happen on Windows.
    #
    # Guarded because host git is optional -- the container ships its own. Without
    # the guard, a host without git would not merely skip this:
    # CommandNotFoundException is terminating under "Stop", so the sandbox would
    # refuse to start.
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $gitName  = git config --global user.name
        $gitEmail = git config --global user.email
        if ($gitName)  { $runArgs += @("-e", "GIT_AUTHOR_NAME=$gitName",   "-e", "GIT_COMMITTER_NAME=$gitName") }
        if ($gitEmail) { $runArgs += @("-e", "GIT_AUTHOR_EMAIL=$gitEmail", "-e", "GIT_COMMITTER_EMAIL=$gitEmail") }
    }

    $runArgs += @($image, "tail", "-f", "/dev/null")

    docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "failed to start container" }
    $created = $true

    foreach ($mount in $moduleMounts) {
        # A fresh named volume mounted at a path absent from the image is created
        # root:root, so the unprivileged node user cannot npm install into it.
        # Hand it over once, at creation. The parent has to be made first -- the
        # volume only creates its own mount point.
        docker exec -u root $containerName mkdir -p (Split-Path $mount.ContainerPath -Parent).Replace('\', '/') | Out-Null
        docker exec -u root $containerName chown node:node $mount.ContainerPath | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "failed to set ownership on $($mount.ContainerPath)" }
    }

    # What stops -Claude from landing in a prompt on a brand new home volume is
    # Claude Code's three first-run questions (theme, folder trust, and the
    # bypass-permissions warning), not auth. All three are answered by
    # ~/.claude.json, so seed it -- with no credentials; auth still comes from the
    # forwarded environment only. Seeded only when absent, since the same file
    # holds real settings and history for a reused home volume.
    #
    # Base64 because PowerShell 5.1 strips embedded double quotes when passing an
    # argument to a native command, delivering unparseable JSON.
    $seedJson = '{"hasCompletedOnboarding":true,"theme":"dark","bypassPermissionsModeAccepted":true,' +
                '"projects":{"/workspace":{"hasTrustDialogAccepted":true,"hasCompletedProjectOnboarding":true}}}'
    $seedB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($seedJson))
    docker exec $containerName bash -c "if [ ! -e `$HOME/.claude.json ]; then echo $seedB64 | base64 -d > `$HOME/.claude.json; fi" | Out-Null
}

# --------------------------------------------------------------------------
# Banner, then hand over the shell
# --------------------------------------------------------------------------

if ($created) {
    $verb = "started"
    $portList = $resolvedPorts -join " "
} else {
    # Ports are fixed when the container is created, so report what it actually
    # publishes rather than what was asked for on this invocation.
    $verb = "attached to"
    $published = @()
    foreach ($line in (docker port $containerName)) {
        # "3000/tcp -> 0.0.0.0:3000"
        if ($line -match '^(\d+)/tcp\s+->\s+.*:(\d+)$') {
            $mapping = "$($matches[2]):$($matches[1])"
            if ($published -notcontains $mapping) { $published += $mapping }
        }
    }
    if ($published.Count -gt 0) {
        $portList = $published -join " "
    } else {
        $portList = "none"
    }
    # Compare on the container port alone: one walked upward at creation
    # (3000 busy -> 3001:3000) still serves what was asked for, so matching whole
    # "host:container" strings would send you to -Stop for a port you have.
    $publishedContainerPorts = @($published | ForEach-Object { ($_ -split ':')[1] })
    $missing = @()
    foreach ($p in $Port) {
        $containerPort = ((ConvertTo-PortMapping $p) -split ':')[1]
        if ($publishedContainerPorts -notcontains $containerPort) { $missing += $p }
    }
    if ($missing.Count -gt 0) {
        $portList = "$portList  (-Port $($missing -join ',') needs 'dev-sandbox -Stop' first)"
    }
}
if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
    $auth = "oauth token forwarded"
} elseif ($env:ANTHROPIC_API_KEY) {
    $auth = "api key forwarded"
} else {
    $auth = "no host auth, claude will prompt to log in (run 'dev-sandbox -ClaudeAuth' once to stop that)"
}

Write-Host ""
Write-Host "dev-sandbox: $verb $containerName" -ForegroundColor Green
Write-Host "  image  $image" -ForegroundColor DarkGray
Write-Host "  mount  $projectPath -> /workspace" -ForegroundColor DarkGray
Write-Host "  ports  $portList" -ForegroundColor DarkGray
Write-Host "  home   $homeVolume ($homeLabel), $auth" -ForegroundColor DarkGray
if ($Persist) {
    Write-Host "  -Persist: exiting leaves the container running; 'dev-sandbox -Stop' shuts it down." -ForegroundColor DarkGray
} else {
    Write-Host "  stops automatically once no other shell is attached (-Persist to keep it running)." -ForegroundColor DarkGray
}
Write-Host ""

# Allocate a TTY only when there is one: -t with redirected stdin fails outright.
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    $ttyFlags = @("-i")
} else {
    $ttyFlags = @("-i", "-t")
}

$execArgs = @("exec") + $ttyFlags + @("-w", "/workspace", $containerName)

# Every way in is a login shell, so all three see the same environment. Plain
# `bash` would not: an interactive shell reads ~/.bashrc and skips the profile
# files, while `bash -c` reads neither. With -l both read the profile, and
# ~/.bashrc still applies to the interactive one.
#
# Claude Code goes through the same shell so its own bash tool calls inherit
# that environment -- a PATH set in ~/.profile has to reach them too.
if ($Command) {
    $execArgs += @("bash", "-lc", $Command)
} elseif ($Claude) {
    $execArgs += @("bash", "-lc", "claude --dangerously-skip-permissions")
} else {
    $execArgs += @("bash", "-l")
}

docker @execArgs
$exitCode = $LASTEXITCODE

if (-not $Persist) {
    if (-not (Test-ContainerHasOtherShell $containerName)) {
        Remove-SandboxContainer $containerName $slug
        Write-Host "dev-sandbox: last shell exited, stopped $containerName" -ForegroundColor Yellow
    }
}

exit $exitCode
