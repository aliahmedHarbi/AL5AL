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

    $launchedAtUtc = [DateTime]::UtcNow
    $job = Start-Job -Name "fleet-$($agent.name)-$runId" -ArgumentList `
        $root, $Task, $agent.command -ScriptBlock {
        param($Root, $Task, $Command)

        Set-Location $Root
        $env:FLEET_TASK = $Task
        $started = Get-Date
        $exitCode = 0
        $output = ""
        $global:FleetNativeExitCode = 0

        try {
            $PSNativeCommandUseErrorActionPreference = $false
            $tokens = $null
            $parseErrors = $null
            $commandAst = [System.Management.Automation.Language.Parser]::ParseInput(
                $Command,
                [ref]$tokens,
                [ref]$parseErrors
            )
            if ($parseErrors.Count -gt 0) {
                throw "Invalid agent command: $($parseErrors[0].Message)"
            }

            $guard = "`nif (`$null -ne `$LASTEXITCODE -and `$LASTEXITCODE -ne 0) { `$global:FleetNativeExitCode = [int]`$LASTEXITCODE; throw `"Native command exited with code `$LASTEXITCODE.`" }`n"
            $guardOffsets = @(
                $commandAst.FindAll({
                    param($node)
                    $node -is [System.Management.Automation.Language.StatementBlockAst] -or
                        $node -is [System.Management.Automation.Language.NamedBlockAst]
                }, $true) |
                    ForEach-Object { $_.Statements } |
                    Where-Object { $_ -is [System.Management.Automation.Language.PipelineAst] } |
                    ForEach-Object { $_.Extent.EndOffset } |
                    Sort-Object -Descending -Unique
            )

            $guardedCommand = $Command
            foreach ($offset in $guardOffsets) {
                $guardedCommand = $guardedCommand.Insert($offset, $guard)
            }

            $output = (& ([scriptblock]::Create($guardedCommand)) 2>&1 | Out-String).Trim()
            if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                $global:FleetNativeExitCode = [int]$LASTEXITCODE
                throw "Native command exited with code $LASTEXITCODE."
            }
        }
        catch {
            if ($global:FleetNativeExitCode -eq 0 -and $null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
                $global:FleetNativeExitCode = [int]$LASTEXITCODE
            }
            $exitCode = if ($global:FleetNativeExitCode -ne 0) {
                [int]$global:FleetNativeExitCode
            }
            else {
                1
            }
            $output = $_.Exception.Message
        }

        $completedAtUtc = [DateTime]::UtcNow
        [PSCustomObject]@{
            ExitCode = $exitCode
            TimedOut = $false
            Output = $output
            DurationSeconds = [Math]::Round(((Get-Date) - $started).TotalSeconds, 2)
            CompletedAtUtc = $completedAtUtc.ToString("o")
        }
    }

    $jobs += [PSCustomObject]@{
        Agent = $agent
        Job = $job
        StartedAtUtc = $launchedAtUtc
        TimeoutSeconds = $timeoutSeconds
    }
}

if ($DryRun) {
    return
}

foreach ($entry in $jobs) {
    $timeoutSeconds = [int]$entry.TimeoutSeconds
    $deadlineUtc = $entry.StartedAtUtc.AddSeconds($timeoutSeconds)
    while ($entry.Job.State -in @("NotStarted", "Running")) {
        $remainingMilliseconds = ($deadlineUtc - [DateTime]::UtcNow).TotalMilliseconds
        if ($remainingMilliseconds -le 0) {
            break
        }
        Start-Sleep -Milliseconds ([int][Math]::Max(1, [Math]::Min(100, [Math]::Ceiling($remainingMilliseconds))))
    }

    $jobStillRunning = $entry.Job.State -in @("NotStarted", "Running")
    if ($jobStillRunning) {
        Stop-Job -Job $entry.Job
    }
    $payload = if ($jobStillRunning) { $null } else { Receive-Job -Job $entry.Job -Keep }
    $timedOut = $jobStillRunning
    if ($payload -and $payload.CompletedAtUtc) {
        $completedAtUtc = [DateTime]::Parse($payload.CompletedAtUtc).ToUniversalTime()
        $timedOut = $timedOut -or $completedAtUtc -gt $deadlineUtc
    }
    Remove-Job -Job $entry.Job

    $exitCode = if ($timedOut) { 124 } elseif ($payload) { [int]$payload.ExitCode } else { 1 }
    $duration = if ($payload) {
        [double]$payload.DurationSeconds
    }
    else {
        [Math]::Round(([DateTime]::UtcNow - $entry.StartedAtUtc).TotalSeconds, 2)
    }
    $output = if ($timedOut) {
        "Agent exceeded $timeoutSeconds seconds."
    }
    elseif ($payload) {
        [string]$payload.Output
    }
    else {
        "No result payload."
    }

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
