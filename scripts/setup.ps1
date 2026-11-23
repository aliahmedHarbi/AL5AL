[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

foreach ($directory in @("config", "logs", "scripts")) {
    $path = Join-Path $root $directory
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path | Out-Null
    }
}

$shell = Get-Command "pwsh" -ErrorAction SilentlyContinue
if (-not $shell) {
    $shell = Get-Command "powershell" -ErrorAction SilentlyContinue
}

if (-not $shell) {
    throw "PowerShell was not found. Install PowerShell 7 or use Windows PowerShell."
}

Write-Host "Agent fleet ready."
Write-Host "Shell: $($shell.Source)"
Write-Host "Root: $root"
