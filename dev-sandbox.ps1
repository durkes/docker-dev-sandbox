<#
.SYNOPSIS
    Open a shell in a containerized dev environment for the current project.

.DESCRIPTION
    Starts (or reuses) a long-lived Docker container with the project directory
    bind-mounted at /workspace, then execs an interactive shell into it. Run the
    command again from another PowerShell window to get another prompt in the
    same container.

    The bind mount is the entire containment boundary: only the project directory
    and its subdirectories are visible. Nothing above it, no Docker socket, no
    --privileged.

.PARAMETER Path
    Project directory to mount. Defaults to the current directory.

.PARAMETER Port
    Host ports to publish. Accepts bare ports (3000) or remaps (8081:8080).
    Ports are fixed when the container is created -- use -Stop first to change them.

.PARAMETER Isolated
    Use a throwaway home volume, removed when the container is stopped. For
    sandboxing untrusted third-party code.

.PARAMETER SharedHome
    Share one home volume across all projects instead of a per-project one.
    Convenient for shared settings, but lets Claude Code read its own session
    transcripts from your other projects.

.PARAMETER SharedModules
    Do not shadow /workspace/node_modules with a container-only volume. Only use
    this if you never run npm from Windows for this project.

.PARAMETER Claude
    Launch Claude Code (--dangerously-skip-permissions) instead of a shell.

.PARAMETER Command
    Run this command instead of an interactive shell.

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

function ConvertTo-PortMapping($Spec) {
    if ($Spec -match '^\d+$') { return "$($Spec):$($Spec)" }
    if ($Spec -match '^\d+:\d+$') { return $Spec }
    Fail "invalid -Port value '$Spec'. Use 3000 or 8081:8080."
}

function Test-DockerReady {
    # No 2>&1 anywhere in this script: in PowerShell 5.1 that wraps a native
    # command's stderr in ErrorRecords, which $ErrorActionPreference = "Stop"
    # then turns into a terminating error even on success.
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

function Test-VolumeExists($Name) {
    $found = docker volume ls -q --filter "name=^$Name$"
    return (-not [string]::IsNullOrWhiteSpace(($found -join "")))
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
$forbidden = @($env:USERPROFILE, ($env:SystemDrive + "\"), "C:\Users") |
    Where-Object { $_ }

foreach ($bad in $forbidden) {
    if ($projectPath.TrimEnd('\') -ieq $bad.TrimEnd('\')) {
        Fail "refusing to mount '$projectPath' -- mount a single project directory, not a drive root or your user profile."
    }
}

$slug          = Get-Slug $projectPath
$image         = "dev-sandbox:node$NodeVersion"
$containerName = "dev-sandbox-$slug"
$modulesVolume = "dev-sandbox-modules-$slug"

if ($Isolated) {
    $homeVolume = "dev-sandbox-home-isolated-$slug"
    $homeLabel  = "isolated, discarded on -Stop"
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
    if (Test-ContainerExists $containerName) {
        docker rm -f $containerName | Out-Null
        Write-Host "dev-sandbox: stopped $containerName" -ForegroundColor Yellow
    } else {
        Write-Host "dev-sandbox: no container running for this project" -ForegroundColor Yellow
    }
    if ($Isolated -and (Test-VolumeExists $homeVolume)) {
        docker volume rm $homeVolume | Out-Null
        Write-Host "dev-sandbox: removed isolated volume $homeVolume" -ForegroundColor Yellow
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

    if (-not $SharedModules) {
        # Shadow the host's node_modules: a Windows npm install produces Windows
        # binaries and .cmd shims that break under Linux, and vice versa.
        $runArgs += @("-v", "$($modulesVolume):/workspace/node_modules")
    }

    foreach ($p in $Port) {
        $runArgs += @("-p", (ConvertTo-PortMapping $p))
    }

    # Auth is forwarded from the host environment and never written to disk, so
    # it works identically in every project and nothing secret can be committed.
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

    if (-not $SharedModules) {
        # A fresh named volume mounted at a path that does not exist in the image
        # is created root:root, so the unprivileged node user cannot npm install
        # into it. Hand it over once, at creation.
        docker exec -u root $containerName chown node:node /workspace/node_modules | Out-Null
        if ($LASTEXITCODE -ne 0) { Fail "failed to set ownership on /workspace/node_modules" }
    }
}

# --------------------------------------------------------------------------
# Banner, then hand over the shell
# --------------------------------------------------------------------------

if ($created) {
    $verb = "started"
    $portList = ($Port | ForEach-Object { ConvertTo-PortMapping $_ }) -join " "
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
    $requested = ($Port | ForEach-Object { ConvertTo-PortMapping $_ })
    $missing = $requested | Where-Object { $published -notcontains $_ }
    if ($missing) {
        $portList = "$portList  (-Port $($missing -join ',') needs 'dev-sandbox -Stop' first)"
    }
}
if ($env:ANTHROPIC_API_KEY) { $auth = "api key forwarded" } else { $auth = "no api key, claude will prompt to log in" }

Write-Host ""
Write-Host "dev-sandbox: $verb $containerName" -ForegroundColor Green
Write-Host "  image  $image" -ForegroundColor DarkGray
Write-Host "  mount  $projectPath -> /workspace" -ForegroundColor DarkGray
Write-Host "  ports  $portList" -ForegroundColor DarkGray
Write-Host "  home   $homeVolume ($homeLabel), $auth" -ForegroundColor DarkGray
Write-Host "  exiting leaves the container running; 'dev-sandbox -Stop' shuts it down." -ForegroundColor DarkGray
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
exit $LASTEXITCODE
