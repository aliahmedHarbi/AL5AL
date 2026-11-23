[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Task,

    [string]$ConfigPath,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $ConfigPath) {
    $ConfigPath = Join-Path $root "config\fleet.json"
}
elseif (-not [System.IO.Path]::IsPathRooted($ConfigPath)) {
    $ConfigPath = Join-Path (Get-Location) $ConfigPath
}

if (-not (Test-Path $ConfigPath)) {
    throw "Fleet configuration not found: $ConfigPath"
}

$shellCommand = Get-Command "pwsh" -ErrorAction SilentlyContinue
if (-not $shellCommand) {
    $shellCommand = Get-Command "powershell" -ErrorAction SilentlyContinue
}
if (-not $shellCommand) {
    throw "PowerShell was not found."
}

$fleet = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not $fleet.agents) {
    throw "Configuration must contain an 'agents' array."
}

$runId = Get-Date -Format "yyyyMMdd-HHmmss"
$logDirectory = Join-Path $root "logs"
New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null

$jobs = @()
$results = @()

foreach ($agent in @($fleet.agents)) {
    if ($agent.PSObject.Properties["enabled"] -and -not [bool]$agent.enabled) {
        continue
    }
    if (-not $agent.name -or -not $agent.command) {
        throw "Every enabled agent requires 'name' and 'command'."
    }

    Write-Host "[$($agent.name)] $($agent.role)" -ForegroundColor Cyan
    if ($DryRun) {
        Write-Host "  Command: $($agent.command)"
        continue
    }

    $timeoutSeconds = 300
    if ($agent.PSObject.Properties["timeoutSeconds"]) {
        $timeoutSeconds = [Math]::Max(1, [int]$agent.timeoutSeconds)
    }

    $job = Start-Job -Name "fleet-$($agent.name)-$runId" -ArgumentList `
        $root, $Task, $agent.command, $timeoutSeconds -ScriptBlock {
        param($Root, $Task, $Command, $TimeoutSeconds)

        Set-Location $Root
        $env:FLEET_TASK = $Task
        $started = Get-Date
        $exitCode = 0
        $output = ""

        try {
            $output = (& ([scriptblock]::Create($Command)) 2>&1 | Out-String).Trim()
        }
        catch {
            $exitCode = 1
            $output = $_.Exception.Message
        }

        [PSCustomObject]@{
            ExitCode = $exitCode
            TimedOut = $false
            Output = $output
            DurationSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
        }
    }

    $jobs += [PSCustomObject]@{
        Agent = $agent
        Job = $job
    }
}

if ($DryRun) {
    return
}

foreach ($entry in $jobs) {
    $timeoutSeconds = [int]$entry.Agent.timeoutSeconds
    if ($timeoutSeconds -le 0) {
        $timeoutSeconds = 300
    }
    Wait-Job -Job $entry.Job -Timeout $timeoutSeconds | Out-Null

    $timedOut = $entry.Job.State -eq "Running"
    if ($timedOut) {
        Stop-Job -Job $entry.Job
    }
    $payload = if ($timedOut) { $null } else { Receive-Job -Job $entry.Job -Keep }
    Remove-Job -Job $entry.Job

    $exitCode = if ($payload) { [int]$payload.ExitCode } elseif ($timedOut) { 124 } else { 1 }
    $duration = if ($payload) { [double]$payload.DurationSeconds } else { 0 }
    $output = if ($payload) { [string]$payload.Output } elseif ($timedOut) { "Agent exceeded $timeoutSeconds seconds." } else { "No result payload." }

    $record = [PSCustomObject]@{
        name = [string]$entry.Agent.name
        role = [string]$entry.Agent.role
        task = $Task
        exitCode = $exitCode
        timedOut = $timedOut
        durationSeconds = $duration
        output = $output
        completedAt = (Get-Date).ToString("o")
    }
    $results += $record

    $statusColor = if ($exitCode -eq 0) { "Green" } else { "Red" }
    Write-Host "[$($record.name)] completed in $($record.durationSeconds)s (exit $exitCode)" -ForegroundColor $statusColor
    if ($output) {
        Write-Host $output
    }
}

$jsonPath = Join-Path $logDirectory "fleet-$runId.json"
$results | ConvertTo-Json -Depth 5 | Set-Content -Path $jsonPath -Encoding UTF8
Write-Host "Fleet report: $jsonPath"

$failed = @($results | Where-Object { $_.exitCode -ne 0 })
if ($failed.Count -gt 0) {
    exit 1
}
