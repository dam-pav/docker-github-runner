$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

Set-Location C:\actions-runner

$versionFile = '.release-hash'
$runnerProcess = $null
$runnerRegistered = $false
$cleanupRan = $false
$currentContainer = $null

foreach ($temporaryDirectory in $env:TEMP, $env:TMP) {
    if (-not [string]::IsNullOrWhiteSpace($temporaryDirectory)) {
        New-Item -ItemType Directory -Force $temporaryDirectory | Out-Null
    }
}

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "[entrypoint] $Message"
}

function Get-EnvironmentValue {
    param(
        [Parameter(Mandatory)][string] $Name,
        [AllowEmptyString()][string] $Default = ''
    )
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) { return $Default }
    return $value
}

function Get-ContainerLabel {
    param([Parameter(Mandatory)][string] $Name)

    if ($null -eq $script:currentContainer) {
        $containerIds = @(& docker.exe ps --no-trunc --quiet 2>$null)
        if ($LASTEXITCODE -ne 0 -or $containerIds.Count -eq 0) {
            throw 'Cannot list running containers through the Docker named pipe'
        }
        $inspectJson = & docker.exe inspect @containerIds 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw 'Cannot inspect running containers through the Docker named pipe'
        }
        $script:currentContainer = @($inspectJson | ConvertFrom-Json |
            Where-Object { $_.Config.Hostname -eq $env:COMPUTERNAME } |
            Select-Object -First 1)[0]
        if ($null -eq $script:currentContainer) {
            throw "Cannot find this container by hostname '$env:COMPUTERNAME'"
        }
    }
    $property = $script:currentContainer.Config.Labels.PSObject.Properties[$Name]
    if ($null -eq $property -or [string]::IsNullOrWhiteSpace([string]$property.Value)) {
        throw "Cannot read Docker Compose label '$Name'"
    }
    return [string]$property.Value
}

function Set-RunnerInstanceName {
    $instanceCount = Get-EnvironmentValue RUNNER_INSTANCES '1'
    if ($instanceCount -notmatch '^[1-9][0-9]*$') {
        throw 'RUNNER_INSTANCES must be a natural number (1 or greater)'
    }
    if ([int64]$instanceCount -eq 1) { return }

    $instanceId = Get-ContainerLabel 'com.docker.compose.container-number'
    if ($instanceId -notmatch '^[1-9][0-9]*$') {
        throw 'Cannot derive the runner instance ID from Docker Compose metadata'
    }
    $env:RUNNER_NAME = "$env:RUNNER_NAME`_$instanceId"
}

function Get-MaskedToken {
    param([AllowEmptyString()][string] $Token)
    if ([string]::IsNullOrEmpty($Token)) { return '' }
    return "{0}****" -f $Token.Substring(0, [Math]::Min(4, $Token.Length))
}

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        [switch] $Retry
    )

    $headers = @{
        Authorization          = "Bearer $env:GITHUB_TOKEN"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'docker-github-runner'
    }
    $attempts = if ($Retry) { [int](Get-EnvironmentValue GH_API_RETRIES '6') } else { 1 }
    $delay = [int](Get-EnvironmentValue GH_API_INITIAL_DELAY '1')
    $backoff = [int](Get-EnvironmentValue GH_API_BACKOFF_MULT '2')

    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
        }
        catch {
            if ($attempt -eq $attempts) { throw }
            Write-Log "GitHub API request failed (attempt $attempt/$attempts); retrying in $delay second(s)"
            Start-Sleep -Seconds $delay
            $delay *= $backoff
        }
    }
}

function Invoke-RunnerCommand {
    param(
        [Parameter(Mandatory)][string] $Command,
        [Parameter(Mandatory)][string[]] $Arguments,
        [switch] $IgnoreExitCode
    )

    & $Command @Arguments
    if (-not $IgnoreExitCode -and $LASTEXITCODE -ne 0) {
        throw "$Command exited with code $LASTEXITCODE"
    }
}

function Test-NestedDockerMounts {
    param([Parameter(Mandatory)][string] $WorkDirectory)

    $workPath = [IO.Path]::GetFullPath((Join-Path 'C:\actions-runner' $WorkDirectory))
    $helperPath = 'C:\ProgramData\BcContainerHelper'
    New-Item -ItemType Directory -Force $workPath, $helperPath | Out-Null

    $probeName = ".mount-probe-$PID-$([Guid]::NewGuid().ToString('N'))"
    $workProbe = Join-Path $workPath $probeName
    $helperProbe = Join-Path $helperPath $probeName
    Set-Content -LiteralPath $workProbe, $helperProbe -Value 'same-path mount probe' -NoNewline

    $runnerImage = Get-EnvironmentValue RUNNER_IMAGE 'ghcr.io/dam-pav/github-runner:windows-ltsc2022-latest'
    $probeScript = "if (-not ((Test-Path -LiteralPath 'C:\runner-work\$probeName') -and (Test-Path -LiteralPath 'C:\bc-helper\$probeName'))) { exit 42 }"
    $probeContainer = "runner-mount-probe-$PID-$([Guid]::NewGuid().ToString('N'))"

    Write-Log 'Validating same-path workspace and BcContainerHelper mounts through the host Docker daemon'
    try {
        $containerId = & docker.exe run --detach --name $probeContainer `
            --mount "type=bind,source=$workPath,target=C:\runner-work" `
            --mount "type=bind,source=$helperPath,target=C:\bc-helper" `
            --entrypoint C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe `
            $runnerImage -NoLogo -NoProfile -Command $probeScript
        if ($LASTEXITCODE -ne 0) {
            throw "Could not start nested Docker mount probe (docker exit code $LASTEXITCODE)"
        }

        $probeExitCode = & docker.exe wait $containerId
        if ($LASTEXITCODE -ne 0 -or [int]$probeExitCode -ne 0) {
            & docker.exe logs $containerId
            throw "Nested Docker mount validation failed with container exit code $probeExitCode. The host and runner paths must be identical."
        }
        Write-Log 'Nested Docker mount validation succeeded'
    }
    finally {
        & docker.exe rm --force $probeContainer *> $null
        Remove-Item -LiteralPath $workProbe, $helperProbe -Force -ErrorAction SilentlyContinue
    }
}

function Remove-RunnerRegistration {
    if ($script:cleanupRan) { return }
    $script:cleanupRan = $true

    if ($null -ne $script:runnerProcess -and -not $script:runnerProcess.HasExited) {
        Write-Log "Stopping runner process (pid=$($script:runnerProcess.Id))"
        & taskkill.exe /PID $script:runnerProcess.Id /T /F 2>$null | Out-Null
    }

    if (-not $script:runnerRegistered) { return }

    Write-Log "Attempting runner unregister via API (name=$env:RUNNER_NAME)"
    $runnerIds = @()
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $runnerList = Invoke-GitHubApi -Method GET -Uri $script:apiListUrl
            $runnerIds = @($runnerList.runners | Where-Object name -EQ $env:RUNNER_NAME | ForEach-Object id)
            if ($runnerIds.Count -gt 0) { break }
        }
        catch {
            Write-Log "Could not list runners during cleanup: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds 2
    }

    foreach ($runnerId in $runnerIds) {
        try {
            Invoke-GitHubApi -Method DELETE -Uri "$script:apiDeletePrefix/$runnerId" | Out-Null
            Write-Log "Unregistered runner id $runnerId"
        }
        catch {
            Write-Log "Failed to unregister runner id ${runnerId}: $($_.Exception.Message)"
        }
    }
}

try {
    $secretsFile = 'C:\run\secrets\credentials'
    if (Test-Path -LiteralPath $secretsFile -PathType Leaf) {
        $tokenLine = Get-Content -LiteralPath $secretsFile |
            Where-Object { $_ -match '^\s*GITHUB_TOKEN\s*[:=]' } |
            Select-Object -Last 1
        if ($null -ne $tokenLine) {
            $env:GITHUB_TOKEN = ($tokenLine -replace '^\s*GITHUB_TOKEN\s*[:=]\s*', '').Trim()
            Write-Log "Using GITHUB_TOKEN from $secretsFile (masked: $(Get-MaskedToken $env:GITHUB_TOKEN))"
        }
    }
    else {
        Write-Log "No credentials file at $secretsFile; using the environment variable if provided"
    }

    foreach ($requiredVariable in 'GITHUB_TOKEN', 'REPO_URL', 'RUNNER_NAME') {
        if ([string]::IsNullOrWhiteSpace((Get-EnvironmentValue $requiredVariable))) {
            throw "$requiredVariable must be set"
        }
    }

    Set-RunnerInstanceName
    $env:RUNNER_WORKDIR = "_work\$env:RUNNER_NAME"
    $env:TEMP = "C:\actions-runner\_work\$env:RUNNER_NAME\_temp"
    $env:TMP = $env:TEMP
    New-Item -ItemType Directory -Force $env:TEMP | Out-Null

    $repoUri = [Uri]$env:REPO_URL.TrimEnd('/')
    if ($repoUri.Scheme -ne 'https' -or $repoUri.Host -ne 'github.com') {
        throw 'REPO_URL must be an https://github.com organization or repository URL'
    }

    $pathParts = @($repoUri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
    if ($pathParts.Count -eq 0) { throw 'REPO_URL does not contain an organization' }
    if ($pathParts.Count -ge 2 -and $pathParts[0] -ne 'orgs') {
        $runnerScope = 'repository'
        $apiBase = "https://api.github.com/repos/$($pathParts[0])/$($pathParts[1])/actions/runners"
    }
    else {
        $runnerScope = 'organization'
        if ($pathParts[0] -eq 'orgs' -and $pathParts.Count -lt 2) {
            throw 'REPO_URL does not contain an organization'
        }
        $organization = if ($pathParts[0] -eq 'orgs') { $pathParts[1] } else { $pathParts[0] }
        if ([string]::IsNullOrWhiteSpace($organization)) { throw 'REPO_URL does not contain an organization' }
        $apiBase = "https://api.github.com/orgs/$organization/actions/runners"
    }

    $runnerGroup = Get-EnvironmentValue RUNNER_GROUP
    if (-not [string]::IsNullOrWhiteSpace($runnerGroup) -and $runnerScope -ne 'organization') {
        throw 'RUNNER_GROUP can only be used with an organization REPO_URL'
    }

    $script:apiListUrl = "$apiBase`?per_page=100"
    $script:apiDeletePrefix = $apiBase
    $apiRegistrationUrl = "$apiBase/registration-token"

    $workDirectory = Get-EnvironmentValue RUNNER_WORKDIR "_work\$env:RUNNER_NAME"
    $normalizedWorkDirectory = $workDirectory.Replace('/', '\').TrimEnd('\')
    $expectedWorkDirectory = "_work\$env:RUNNER_NAME"
    if ($normalizedWorkDirectory -ne $expectedWorkDirectory) {
        throw "RUNNER_WORKDIR must be '$expectedWorkDirectory' for same-path workspace isolation"
    }

    Write-Log 'Determining runner asset (win x64) from GitHub Releases API'
    $release = Invoke-GitHubApi -Method GET -Uri 'https://api.github.com/repos/actions/runner/releases/latest' -Retry
    $runnerAsset = $release.assets |
        Where-Object name -Match '^actions-runner-win-x64-.*\.zip$' |
        Select-Object -First 1
    if ($null -eq $runnerAsset) { throw 'The latest runner release has no win-x64 asset' }

    $releaseRecord = [ordered]@{ tag = $release.tag_name; asset = $runnerAsset.name; url = $runnerAsset.browser_download_url }
    $releaseJson = $releaseRecord | ConvertTo-Json -Compress
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $releaseHash = [BitConverter]::ToString($sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($releaseJson))).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }

    $installedHash = if (Test-Path -LiteralPath $versionFile) { (Get-Content -LiteralPath $versionFile -Raw).Trim() } else { '' }
    if ($installedHash -ne $releaseHash) {
        Write-Log "Bootstrapping GitHub runner $($release.tag_name)"
        Get-ChildItem -Force | Where-Object Name -NE '_work' | Remove-Item -Recurse -Force
        $runnerArchive = Join-Path $PWD $runnerAsset.name
        Invoke-WebRequest -UseBasicParsing -Uri $runnerAsset.browser_download_url -OutFile $runnerArchive
        Expand-Archive -LiteralPath $runnerArchive -DestinationPath $PWD -Force
        Remove-Item -LiteralPath $runnerArchive
        Set-Content -LiteralPath $versionFile -Value $releaseHash -NoNewline
    }

    & docker.exe version *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Log 'Docker CLI can reach the host daemon through the named pipe'
        if ((Get-EnvironmentValue VALIDATE_NESTED_DOCKER_MOUNTS 'false') -eq 'true') {
            Test-NestedDockerMounts -WorkDirectory $workDirectory
        }
    }
    else {
        Write-Log 'Docker daemon is unavailable. Windows jobs can run, but Docker commands will fail; verify the named-pipe mount.'
        if ((Get-EnvironmentValue VALIDATE_NESTED_DOCKER_MOUNTS 'false') -eq 'true') {
            throw 'Docker is required when VALIDATE_NESTED_DOCKER_MOUNTS is true'
        }
    }

    Write-Log "Requesting registration token from GitHub API ($apiRegistrationUrl)"
    $registration = Invoke-GitHubApi -Method POST -Uri $apiRegistrationUrl -Retry
    if ([string]::IsNullOrWhiteSpace($registration.token)) { throw 'GitHub returned an empty registration token' }
    Write-Log "Obtained registration token (masked: $(Get-MaskedToken $registration.token)); expires at $($registration.expires_at)"

    $runnerList = Invoke-GitHubApi -Method GET -Uri $script:apiListUrl
    foreach ($staleRunner in @($runnerList.runners | Where-Object name -EQ $env:RUNNER_NAME)) {
        Write-Log "Removing stale runner id $($staleRunner.id)"
        Invoke-GitHubApi -Method DELETE -Uri "$script:apiDeletePrefix/$($staleRunner.id)" | Out-Null
    }

    $labels = 'self-hosted,windows,x64'
    $customLabels = Get-EnvironmentValue RUNNER_LABELS
    if (-not [string]::IsNullOrWhiteSpace($customLabels)) { $labels += ",$customLabels" }
    if (Test-Path -LiteralPath .runner) {
        Write-Log 'Local runner config detected; removing before reconfiguration'
        Invoke-RunnerCommand -Command .\config.cmd -Arguments @('remove', '--unattended', '--token', $registration.token) -IgnoreExitCode
    }

    Write-Log "Configuring runner for $env:REPO_URL as $env:RUNNER_NAME"
    $configArguments = @(
        '--unattended', '--url', $env:REPO_URL, '--token', $registration.token,
        '--name', $env:RUNNER_NAME, '--work', $workDirectory, '--labels', $labels, '--replace'
    )
    if (-not [string]::IsNullOrWhiteSpace($runnerGroup)) {
        $configArguments += @('--runnergroup', $runnerGroup)
    }
    Invoke-RunnerCommand -Command .\config.cmd -Arguments $configArguments
    $script:runnerRegistered = $true

    Write-Log 'Starting runner'
    $script:runnerProcess = Start-Process -FilePath .\run.cmd -NoNewWindow -PassThru
    $script:runnerProcess.WaitForExit()
    exit $script:runnerProcess.ExitCode
}
catch {
    Write-Error $_
    exit 1
}
finally {
    Remove-RunnerRegistration
}
