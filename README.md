# AL5AL

## Electronic Agent Fleet

This repository includes a small PowerShell-based agent fleet. Each agent runs as an
independent local shell job and can be configured with a role-specific command.

### Requirements

- Windows PowerShell 5.1 or PowerShell 7
- Git

### Setup

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\setup.ps1
```

### Run the fleet

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-fleet.ps1 -Task "Review the repository"
```

Use `-DryRun` to print resolved agent commands without executing them:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\run-fleet.ps1 -Task "Check readiness" -DryRun
```

Agent definitions live in `config/fleet.json`. Set `enabled` to `false` to disable
an agent, or replace `command` with a PowerShell command for that role.