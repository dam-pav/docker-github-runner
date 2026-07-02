$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
Set-StrictMode -Version Latest

$currentContainer = $null

function Write-Log {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "[cleanup-monitor] $Message"
}

function Get-ComposeLabel {
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

function Invoke-GitHubApi {
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Uri
    )
    $headers = @{
        Authorization          = "Bearer $env:GITHUB_TOKEN"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2022-11-28'
        'User-Agent'           = 'docker-github-runner-cleanup'
    }
    return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
}

function Remove-GitHubRunner {
    Write-Log "Stop requested for $env:RUNNER_NAME; removing its GitHub registration"
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        try {
            $runnerList = Invoke-GitHubApi GET "$script:apiBase`?per_page=100"
            $runnerIds = @($runnerList.runners | Where-Object name -EQ $env:RUNNER_NAME | ForEach-Object id)
            foreach ($runnerId in $runnerIds) {
                Invoke-GitHubApi DELETE "$script:apiBase/$runnerId" | Out-Null
                Write-Log "Unregistered runner id $runnerId"
            }
            return
        }
        catch {
            if ($attempt -eq 6) { throw }
            Start-Sleep -Seconds 1
        }
    }
}

$secretsFile = 'C:\run\secrets\credentials'
if (Test-Path -LiteralPath $secretsFile -PathType Leaf) {
    $tokenLine = Get-Content -LiteralPath $secretsFile |
        Where-Object { $_ -match '^\s*GITHUB_TOKEN\s*[:=]' } |
        Select-Object -Last 1
    if ($null -ne $tokenLine) {
        $env:GITHUB_TOKEN = ($tokenLine -replace '^\s*GITHUB_TOKEN\s*[:=]\s*', '').Trim()
    }
}

foreach ($requiredVariable in 'GITHUB_TOKEN', 'REPO_URL', 'RUNNER_NAME') {
    if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($requiredVariable))) {
        throw "$requiredVariable must be set"
    }
}

$instanceCount = if ([string]::IsNullOrWhiteSpace($env:RUNNER_INSTANCES)) { '1' } else { $env:RUNNER_INSTANCES }
if ($instanceCount -notmatch '^[1-9][0-9]*$') {
    throw 'RUNNER_INSTANCES must be a natural number (1 or greater)'
}
$composeProject = Get-ComposeLabel 'com.docker.compose.project'
$instanceId = Get-ComposeLabel 'com.docker.compose.container-number'
if ($instanceId -notmatch '^[1-9][0-9]*$') {
    throw 'Cannot derive the runner instance ID from Docker Compose metadata'
}
if ([int64]$instanceCount -gt 1) {
    $env:RUNNER_NAME = "$env:RUNNER_NAME`_$instanceId"
}

$repoUri = [Uri]$env:REPO_URL.TrimEnd('/')
if ($repoUri.Scheme -ne 'https' -or $repoUri.Host -ne 'github.com') {
    throw 'REPO_URL must be an https://github.com organization or repository URL'
}
$pathParts = @($repoUri.AbsolutePath.Trim('/') -split '/' | Where-Object { $_ })
if ($pathParts.Count -eq 0) { throw 'REPO_URL does not contain an organization' }
if ($pathParts.Count -ge 2 -and $pathParts[0] -ne 'orgs') {
    $script:apiBase = "https://api.github.com/repos/$($pathParts[0])/$($pathParts[1])/actions/runners"
}
else {
    if ($pathParts[0] -eq 'orgs' -and $pathParts.Count -lt 2) {
        throw 'REPO_URL does not contain an organization'
    }
    $organization = if ($pathParts[0] -eq 'orgs') { $pathParts[1] } else { $pathParts[0] }
    $script:apiBase = "https://api.github.com/orgs/$organization/actions/runners"
}

Write-Log "Watching Docker events for $env:RUNNER_NAME"
docker.exe events `
    --filter "label=com.docker.compose.project=$composeProject" `
    --filter 'label=com.docker.compose.service=github-runner' `
    --filter "label=com.docker.compose.container-number=$instanceId" `
    --filter 'event=kill' --format '{{.Action}}' |
    ForEach-Object {
        if ($_ -eq 'kill') {
            Remove-GitHubRunner
            break
        }
    }
