$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$runnerPath = Join-Path $root "scripts\run-fleet.ps1"
$configPath = Join-Path ([System.IO.Path]::GetTempPath()) "fleet-regression-$([Guid]::NewGuid().ToString('N')).json"
$shell = Get-Command "pwsh.exe" -ErrorAction SilentlyContinue
if (-not $shell) {
    $shell = Get-Command "powershell.exe" -ErrorAction SilentlyContinue
}
if (-not $shell) {
    throw "PowerShell was not found."
}

function Invoke-FleetRegressionRun {
    param(
        [string]$Task,
        [string]$ConfigPath
    )

    $output = @(& $shell.Source -NoProfile -ExecutionPolicy Bypass -File $runnerPath -Task $Task -ConfigPath $ConfigPath 2>&1)
    $runnerExitCode = $LASTEXITCODE
    $reportLine = $output |
        ForEach-Object { [string]$_ } |
        Where-Object { $_ -like "Fleet report: *" } |
        Select-Object -Last 1
    if (-not $reportLine) {
        throw "Fleet runner did not report its output file. Output: $($output -join [Environment]::NewLine)"
    }

    $reportPath = $reportLine.Substring("Fleet report: ".Length)
    $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
    Remove-Item -LiteralPath $reportPath -Force

    [PSCustomObject]@{
        ExitCode = $runnerExitCode
        Report = $report
    }
}

try {
    $nativeConfig = [PSCustomObject]@{
        agents = @(
            [PSCustomObject]@{
                name = "native-exit"
                role = "regression"
                enabled = $true
                timeoutSeconds = 10
                command = "Write-Output 'starting native commands'; & `$env:ComSpec /c exit 7; & `$env:ComSpec /c exit 0"
            }
        )
    }
    $nativeConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $nativeResult = Invoke-FleetRegressionRun -Task "native exit regression" -ConfigPath $configPath
    $nativeRecord = @($nativeResult.Report)[0]
    if ($nativeResult.ExitCode -eq 0 -or $nativeRecord.exitCode -ne 7) {
        throw "A failed native command was not propagated: runner=$($nativeResult.ExitCode), agent=$($nativeRecord.exitCode)."
    }

    $timeoutConfig = [PSCustomObject]@{
        agents = @(
            [PSCustomObject]@{
                name = "first-timeout"
                role = "regression"
                enabled = $true
                timeoutSeconds = 1
                command = "Start-Sleep -Milliseconds 3000"
            },
            [PSCustomObject]@{
                name = "second-timeout"
                role = "regression"
                enabled = $true
                timeoutSeconds = 2
                command = "Start-Sleep -Milliseconds 2500"
            }
        )
    }
    $timeoutConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configPath -Encoding UTF8
    $timeoutResult = Invoke-FleetRegressionRun -Task "per-job timeout regression" -ConfigPath $configPath
    $secondRecord = @($timeoutResult.Report | Where-Object { $_.name -eq "second-timeout" })[0]
    if (-not $secondRecord -or -not $secondRecord.timedOut -or $secondRecord.exitCode -ne 124) {
        throw "The second job was not timed out from its launch deadline."
    }

    Write-Output "PASS: native failures survive later native successes."
    Write-Output "PASS: each job timeout is measured from its own launch."
}
finally {
    if (Test-Path -LiteralPath $configPath) {
        Remove-Item -LiteralPath $configPath -Force
    }
}
