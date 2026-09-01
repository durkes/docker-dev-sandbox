<#
.SYNOPSIS
    Open a shell in a containerized dev environment for the current project.

.DESCRIPTION
    Starts (or reuses) a Docker container with the project directory bind-mounted
    at /workspace, then execs an interactive shell into it. Run the command again
    from another PowerShell window to get another prompt in the same container.
    By default the container stops as soon as no shell is left attached to it
    (see -Persist); with two windows open side by side, closing one leaves it
    running for the other.

    The bind mount is the entire containment boundary: only the project directory
    and its subdirectories are visible. Nothing above it, no Docker socket, no
    --privileged.

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
    Do not shadow /workspace/node_modules (and any node_modules of a nested
    package.json, e.g. v1/node_modules) with a container-only volume. Only use
    this if you never run npm from Windows for this project.

.PARAMETER Claude
    Launch Claude Code (--dangerously-skip-permissions) instead of a shell.

.PARAMETER Command
    Run this command instead of an interactive shell.

.PARAMETER ClaudeAuth
    Run the Claude Code long-lived token flow once, then save the token to your
    Windows user environment so every future sandbox starts already logged in.

.PARAMETER Persist
    Leave the container running after this shell exits, instead of stopping it
    as soon as no other shell is attached. Use this to keep it warm across
    windows opened one after another rather than side by side.

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
    # Folder name for readability + a hash of the full path, so two projects that
    # happen to share a folder name never share volumes.
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
    # Breadth-first, and critically: never descends into node_modules (or
    # .git) at all, rather than filtering it out of the results afterward --
    # walking into a real node_modules can mean thousands of package.json
    # files. Depth is capped so a pathologically deep tree can't make this
    # scan slow either.
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

function ConvertTo-PortMapping($Spec) {
    if ($Spec -match '^\d+$') { return "$($Spec):$($Spec)" }
    if ($Spec -match '^\d+:\d+$') { return $Spec }
    Fail "invalid -Port value '$Spec'. Use 3000 or 8081:8080."
}

function Get-DockerPublishedHostPorts {
    # Docker Desktop's WSL2 backend publishes container ports without ever
    # binding a plain Windows socket for them, so a raw TcpListener probe
    # cannot see another container's published port -- it has to be asked
    # for separately. This lets `docker run -p` fail with "port is already
    # allocated" even though a Windows-side bind test claimed the port free.
    $ports = New-Object System.Collections.Generic.HashSet[int]
    docker ps --format '{{.Ports}}' | ForEach-Object {
        foreach ($m in [regex]::Matches($_, ':(\d+)->')) {
            [void]$ports.Add([int]$m.Groups[1].Value)
        }
    }
    # The comma operator stops PowerShell from enumerating the HashSet onto the
    # output stream -- without it, a 1-item set collapses to a bare [int] and a
    # multi-item set becomes an [object[]], either of which breaks .Contains().
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
    # Fixed at container creation, so a conflicting host port only needs to be
    # dodged once here -- walk upward until a free one is found.
    $mapping = ConvertTo-PortMapping $Spec
    $hostPort, $containerPort = $mapping -split ':'
    $hostPort = [int]$hostPort
    $original = $hostPort

    $maxTries = 20
    while (-not (Test-HostPortFree $hostPort $DockerPorts)) {
        $hostPort++
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
    # 2>&1 nor 2>$null. In PowerShell 5.1 either one wraps the command's stderr
    # in ErrorRecords, which $ErrorActionPreference = "Stop" turns into a
    # terminating error the moment anything is written there, whatever the exit
    # code. Left unredirected, stderr is harmless. So the pattern throughout is
    # to check first (docker ps --filter, which is quiet) and only then run the
    # command that would complain.
    docker info --format '{{.ServerVersion}}' | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Fail "cannot reach the Docker daemon. Is Docker Desktop running?"
    }
}

function Test-ContainerRunning($Name) {
    # ps --filter rather than inspect: inspect writes to stderr when the
    # container is absent, which is the normal case here, not an error.
    $found = docker ps -q --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
}

function Test-ContainerExists($Name) {
    $found = docker ps -aq --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
}

function Get-TokenFromPaste {
    # `claude setup-token` prints the token inside a block of prose, and a narrow
    # terminal wraps the token itself across lines. So take the whole paste and
    # reassemble: find the fragment that starts the token, then keep appending
    # lines that are made purely of token characters. Prose lines always contain
    # a space or punctuation, so they cannot be mistaken for a fragment.
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
        $line = $line.Trim()

        if ($line -match 'sk-ant-oat[A-Za-z0-9_\-]*') {
            # Start here, dropping any prefix ("export CLAUDE_CODE_OAUTH_TOKEN=")
            # and any suffix that is not part of the token.
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
    # Whatever followed the token in the paste is still queued as keystrokes.
    # Drop it so it does not land on the prompt after this script exits.
    if ([Console]::IsInputRedirected) { return }
    while ([Console]::KeyAvailable) { [Console]::ReadKey($true) | Out-Null }
}

function Test-VolumeExists($Name) {
    $found = docker volume ls -q --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
}

function Test-ContainerHasOtherShell($Name) {
    # Anything still running inside the container besides the "tail -f /dev/null"
    # sentinel and its init wrapper means another window's shell (or something it
    # started) is still attached. ps itself shows up in its own snapshot, so that
    # line is filtered too.
    #
    # The existence check is what keeps docker exec off its stderr path: another
    # window can have removed the container between this shell exiting and this
    # call, and "Error: No such container" would then be fatal (again: 2>$null
    # does not help, see Test-DockerReady).
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
    # Every volume an -Isolated run creates -- the home and each node_modules
    # shadow, nested ones included -- is tagged with this project's slug when it
    # is created, so the whole set can be found and discarded without knowing
    # their names here.
    #
    # Labelling the volumes rather than the container is what makes this correct
    # in the two cases that matter: $Isolated describes *this* invocation, not
    # the one that created the container (so a plain "dev-sandbox -Stop", or
    # another window being the last one to exit, still cleans up), and the tags
    # outlive the container, so a crash or a reboot cannot strand a volume.
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
    # Created up front purely so it can carry the label; docker run would
    # otherwise conjure it unlabelled and it could never be found again.
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

# The mount is the whole containment boundary, so a too-broad mount silently
# defeats the point. Refuse the obvious mistakes.
$usersRoot = if ($env:SystemDrive) { "$env:SystemDrive\Users" } else { "C:\Users" }
$forbidden = @($env:USERPROFILE, $env:PUBLIC, $usersRoot) | Where-Object { $_ }

# The root of *any* drive, not just the system one. $projectPath has already had
# its trailing slash stripped, so "D:\" is "D:" by now -- which is exactly what
# Split-Path -Qualifier returns. (It throws on a UNC path, which has no drive.)
try { $qualifier = Split-Path $projectPath -Qualifier } catch { $qualifier = $null }
if ($qualifier) { $forbidden += $qualifier }

foreach ($bad in $forbidden) {
    if ($projectPath.TrimEnd('\') -ieq $bad.TrimEnd('\')) {
        Fail "refusing to mount '$projectPath' -- mount a single project directory, not a drive root or a user profile."
    }
}

# Anything sitting directly under C:\Users is somebody's whole profile, whichever
# account it happens to belong to.
$projectParent = Split-Path $projectPath -Parent
if ($projectParent -and ($projectParent.TrimEnd('\') -ieq $usersRoot.TrimEnd('\'))) {
    Fail "refusing to mount '$projectPath' -- that is a whole user profile, not a project directory."
}

$slug          = Get-Slug $projectPath
$image         = "dev-sandbox:node$NodeVersion"
$containerName = "dev-sandbox-$slug"

# An -Isolated run gets its own namespace for the node_modules shadows, not just
# for the home. Sharing them would hand whatever an untrusted `npm install`
# fetched straight to the next ordinary run of this project -- and would make the
# volumes unsafe to delete on -Stop, since they would be holding the real
# per-project node_modules too.
$modulesPrefix = if ($Isolated) { "dev-sandbox-modules-isolated-" } else { "dev-sandbox-modules-" }

# Shadow node_modules for the root package.json plus every nested workspace
# (e.g. v1/package.json) so a Linux npm install never lands on the real
# Windows filesystem. One named volume per package.json found, keyed off its
# own full path so it is stable across restarts and never collides with
# another project's. This scan happens once, at container creation -- a
# workspace added later needs -Fresh to pick it up.
$moduleMounts = @()
if (-not $SharedModules) {
    $moduleMounts += [pscustomobject]@{
        ContainerPath = "/workspace/node_modules"
        Volume        = "$modulesPrefix$slug"
    }

    # 4 levels deep covers every realistic monorepo layout (e.g.
    # packages/scope/name) without risking a slow scan on a huge tree.
    $nestedDirs = Find-NestedWorkspaceDirs -Root $projectPath -MaxDepth 4

    foreach ($dir in $nestedDirs) {
        $relPath = $dir.Substring($projectPath.Length).TrimStart('\') -replace '\\', '/'
        $nestedSlug = Get-Slug $dir
        $moduleMounts += [pscustomobject]@{
            ContainerPath = "/workspace/$relPath/node_modules"
            Volume        = "$modulesPrefix$nestedSlug"
        }
    }
}

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
    # Read the label via JSON: PowerShell 5.1 mangles the double quotes that a
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

    # Prefer the host install: it is already the account you use on Windows, and
    # it keeps the flow out of a container entirely. Otherwise run it in a
    # throwaway container with its own config dir, so nothing is left behind.
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

    # "Throwaway" has to mean it: volumes surviving a crash or a reboot would
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
        # Not a hardened boundary, but free hardening. Note what is absent:
        # no Docker socket mount, no --privileged, no extra capabilities.
        "--security-opt", "no-new-privileges",
        "-w", "/workspace",
        "-v", "$($projectPath):/workspace",
        "-v", "$($homeVolume):/home/node"
    )

    # Shadow the host's node_modules: a Windows npm install produces Windows
    # binaries and .cmd shims that break under Linux, and vice versa. Covers
    # the root and every nested workspace found above.
    foreach ($mount in $moduleMounts) {
        $runArgs += @("-v", "$($mount.Volume):$($mount.ContainerPath)")
    }

    $dockerPorts = Get-DockerPublishedHostPorts
    $resolvedPorts = @()
    foreach ($p in $Port) {
        $resolvedMapping = Resolve-PortMapping $p $dockerPorts
        $resolvedPorts += $resolvedMapping
        # Reserve it immediately so two bare ports in the same -Port list (or a
        # remap that lands on an earlier pick) don't both resolve to the same
        # free port before either is actually published.
        $chosenHostPort = [int](($resolvedMapping -split ':')[0])
        [void]$dockerPorts.Add($chosenHostPort)
        $runArgs += @("-p", $resolvedMapping)
    }

    # Auth is forwarded from the host environment and never written to disk, so
    # it works identically in every project and nothing secret can be committed.
    # Without this the credentials Claude Code writes on login land in the
    # per-project home volume, which is why a plain login has to be repeated for
    # every new project. Either variable removes that entirely; -ClaudeAuth
    # produces the OAuth one from a Claude subscription.
    if ($env:CLAUDE_CODE_OAUTH_TOKEN) {
        $runArgs += @("-e", "CLAUDE_CODE_OAUTH_TOKEN=$($env:CLAUDE_CODE_OAUTH_TOKEN)")
    }
    if ($env:ANTHROPIC_API_KEY) {
        $runArgs += @("-e", "ANTHROPIC_API_KEY=$($env:ANTHROPIC_API_KEY)")
    }

    # Identity only, no credentials. Commits and pushes happen on Windows.
    $gitName  = git config --global user.name 2>$null
    $gitEmail = git config --global user.email 2>$null
    if ($gitName)  { $runArgs += @("-e", "GIT_AUTHOR_NAME=$gitName",   "-e", "GIT_COMMITTER_NAME=$gitName") }
    if ($gitEmail) { $runArgs += @("-e", "GIT_AUTHOR_EMAIL=$gitEmail", "-e", "GIT_COMMITTER_EMAIL=$gitEmail") }

    $runArgs += @($image, "tail", "-f", "/dev/null")

    docker @runArgs | Out-Null
    if ($LASTEXITCODE -ne 0) { Fail "failed to start container" }
    $created = $true

    foreach ($mount in $moduleMounts) {
        # A fresh named volume mounted at a path that does not exist in the image
        # is created root:root, so the unprivileged node user cannot npm install
        # into it. Hand it over once, at creation. Nested paths need to exist
        # first -- the volume only creates its own mount point.
        docker exec -u root $containerName mkdir -p (Split-Path $mount.ContainerPath -Parent).Replace('\', '/') | Out-Null
        docker exec -u root $containerName chown node:node $mount.ContainerPath | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "failed to set ownership on $($mount.ContainerPath)" }
    }

    # CLAUDE_CODE_OAUTH_TOKEN is enough to authenticate the interactive REPL --
    # what actually stops -Claude from landing in a prompt on a brand new home
    # volume is Claude Code's three first-run questions (theme, "do you trust
    # this folder?", and the bypass-permissions warning). All three are answered
    # by ~/.claude.json, so seed it. No credentials go in this file; auth still
    # comes from the forwarded environment only.
    #
    # Seeded only when absent, since this same file also holds real settings and
    # history for a reused home volume.
    # Base64 because PowerShell 5.1 strips embedded double quotes when it hands
    # an argument to a native command, which would deliver unquoted, unparseable
    # JSON. The command below is deliberately free of them for the same reason.
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
    # Compare on the container port alone. A host port that was walked upward at
    # creation (3000 busy -> 3001:3000) still serves what was asked for, so
    # matching whole "host:container" strings would wrongly report it missing and
    # send you to -Stop for a port you already have.
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

# Allocate a TTY only when there actually is one. Passing -t with redirected
# stdin (a CI step, a piped invocation) fails outright.
if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) {
    $ttyFlags = @("-i")
} else {
    $ttyFlags = @("-i", "-t")
}

$execArgs = @("exec") + $ttyFlags + @("-w", "/workspace", $containerName)

if ($Command) {
    $execArgs += @("bash", "-lc", $Command)
} elseif ($Claude) {
    $execArgs += @("claude", "--dangerously-skip-permissions")
} else {
    $execArgs += @("bash")
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
