# Hunter

<p align="center">
  <strong>Opinionated Windows 10/11 setup, debloat, tuning, reporting, and rollback capture in one PowerShell run.</strong>
</p>

<p align="center">
  <img alt="PowerShell" src="https://img.shields.io/badge/PowerShell-5.1+-5391FE?logo=powershell&logoColor=white">
  <img alt="Windows" src="https://img.shields.io/badge/Windows-10%20%7C%2011-0078D4?logo=windows&logoColor=white">
  <img alt="License" src="https://img.shields.io/badge/License-GPL--3.0-blue">
</p>

Hunter is a PowerShell-based baseline script for personal Windows installs. It runs a fixed, multi-phase task catalog covering preflight checks, app removal, privacy and UI changes, performance tuning, package installs, cleanup, reporting, and rollback capture.

> [!WARNING]
> Hunter runs as administrator and changes system settings. It is intended for personal machines and lab VMs, not managed enterprise devices, shared systems, or one-off single-setting tweaks.

## Safety

- Hunter captures rollback data for shared registry, service, scheduled task, and active power-plan changes.
- Interactive runs create a restore point before mutation continues unless the selected profile is `VMReset`.
- Hunter supports `-WhatIf` preview mode plus `Minimal`, `Balanced`, `Aggressive`, and `VMReset` execution profiles.
- Hunter validates critical registry, service, and power-plan outcomes after the main run completes.
- Hunter preserves prefetch and scheduled defrag defaults on rotational disks and blocks disk write-cache flushing changes on battery-backed systems.
- Hunter exports a report, full log, restore script, and run configuration on every run.

## Quick Start

Run from an elevated 64-bit Windows PowerShell session. Do not use `Windows PowerShell (x86)`.

```powershell
$ProgressPreference='SilentlyContinue'; irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

The quick-start command sets `$ProgressPreference` first so Windows PowerShell does not render the legacy blue download progress header while it fetches `hunter.ps1`.

Pinned release:

```powershell
$ProgressPreference='SilentlyContinue'; irm https://raw.githubusercontent.com/xobash/hunter/v2.0.3/hunter.ps1 | iex
```

Local checkout:

```powershell
git clone https://github.com/xobash/hunter.git
cd hunter
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

## Requirements

| Requirement | Notes |
| --- | --- |
| Windows | Windows 10 or Windows 11 |
| Shell | Elevated 64-bit Windows PowerShell, `powershell.exe` |
| Network | Internet access for bootstrap, package, and external-tool steps |
| Packages | `winget` is used for supported package installs and WinGet-backed removals |

## What It Does

- Builds a fixed task catalog and executes it with checkpoint and resume support.
- Logs a pre-run execution plan with per-task risk labels before mutation begins.
- Supports no-mutation `-WhatIf` previews for every execution profile.
- Applies Windows build-aware UI, privacy, Explorer, cloud, app, and hardware changes, including Recall suppression on supported Windows 11 24H2 builds.
- Removes supported apps from the catalog in `src/Hunter/Config/Apps.json`.
- Runs package and external-tool steps where configured.
- Re-checks critical settings after execution and records validation results in the final report.
- Exports a report, full log, restore script, and run configuration at the end of the run.

## Usage

```powershell
# Default local run
powershell -ExecutionPolicy Bypass -File .\hunter.ps1

# Fail the run if a mandatory task still fails after retry handling
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Strict

# Preview the selected run without mutating the system
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -WhatIf -Profile Balanced

# Avoid UI-only launches and automatic reboot/sign-out behavior
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -AutomationSafe

# Skip one or more task IDs
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -SkipTask tweaks-ipv6,tweaks-timer-resolution

# Use a custom app removal list
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -CustomAppsListPath .\CustomAppsList.txt

# Write the main log somewhere else
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -LogPath .\hunter.log
```

Profile presets:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Profile Minimal
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Profile Balanced
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Profile Aggressive
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Profile VMReset
```

Opt into legacy disable flags:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -DisableIPv6 -DisableTeredo -DisableHags
```

Opt into the aggressive storage and audio tweaks that are now disabled by default:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -ForceStorageOptimization -DisableAudioEnhancements -DisableSystemSounds -ForceTextInputServiceRedirect
```

Opt into third-party external-tool execution when you explicitly want TCP Optimizer or O&O ShutUp10 to run:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -RunTcpOptimizer -RunOOSU
```

## Configuration

### Flags

| Flag | Purpose |
| --- | --- |
| `-Strict` | Fail the overall run if a mandatory task still fails after retry handling. |
| `-WhatIf` | Print the selected execution plan and exit before Hunter mutates the system. |
| `-Profile <name>` | Select `Minimal`, `Balanced`, `Aggressive`, or `VMReset`. |
| `-AutomationSafe` | Skip UI-only launches and automatic reboot or sign-out behavior. |
| `-SkipTask <id1,id2>` | Skip one or more task IDs for the current run. |
| `-CustomAppsListPath <path>` | Override the default broad app-removal selection. |
| `-DisableIPv6` | Opt in to Hunter's IPv6-disable task. |
| `-DisableTeredo` | Opt in to Hunter's Teredo-disable task. |
| `-DisableCpuMitigations` | Opt in to disabling speculative-execution mitigations. |
| `-DisableHags` | Opt out of Hunter's default HAGS-enable policy. |
| `-ForceStorageOptimization` | Opt in to NTFS USN journal deletion and disk write-cache buffer-flushing disable. |
| `-DisableAudioEnhancements` | Opt in to disabling Windows audio enhancements. |
| `-DisableSystemSounds` | Opt in to Hunter's silent system sound-scheme change. |
| `-ForceTextInputServiceRedirect` | Opt in to the advanced `TextInputManagementService` `ServiceDll` redirect. |
| `-PagefileDrive <drive>` | Move the fixed pagefile target to a specific drive letter. |
| `-LogPath <path>` | Write the main log to a custom path. |
| `-Mode Resume` | Internal recovery mode used by the scheduled resume task. |

### Environment Variables

| Variable | Purpose |
| --- | --- |
| `HUNTER_AUTOMATION_SAFE=1` | Force automation-safe behavior without passing `-AutomationSafe`. |
| `HUNTER_WHATIF=1` | Force dry-run preview behavior without passing `-WhatIf`. |
| `HUNTER_CUSTOM_APPS_LIST=<path>` | Provide a default custom apps list path. |
| `HUNTER_DISABLE_IPV6=1` | Opt in to IPv6 disable. |
| `HUNTER_DISABLE_TEREDO=1` | Opt in to Teredo disable. |
| `HUNTER_DISABLE_CPU_MITIGATIONS=1` | Opt in to disabling speculative-execution mitigations. |
| `HUNTER_DISABLE_HAGS=1` | Opt out of default HAGS enablement. |
| `HUNTER_FORCE_STORAGE_OPTIMIZATION=1` | Opt in to the aggressive storage tweaks Hunter now preserves by default. |
| `HUNTER_DISABLE_AUDIO_ENHANCEMENTS=1` | Opt in to disabling Windows audio enhancements. |
| `HUNTER_DISABLE_SYSTEM_SOUNDS=1` | Opt in to Hunter's silent system sound-scheme change. |
| `HUNTER_FORCE_TEXT_INPUT_SERVICE_REDIRECT=1` | Opt in to the advanced text-input service redirect. |
| `HUNTER_TASK_MAX_CONCURRENCY=<n>` | Override Hunter's task runspace-pool ceiling when you want more or less parallelism. |
| `HUNTER_LOCAL_USER_PASSWORD=<value>` | Override the managed local-user password if that path is used. |

### Profiles

| Profile | Intent |
| --- | --- |
| `Minimal` | Debloat, privacy, and cleanup without the performance and system-overhead tuning pass. |
| `Balanced` | Debloat, privacy, and safer gaming-oriented tweaks while skipping the most invasive tuning tasks. |
| `Aggressive` | Full Hunter task catalog with the new opt-in-only aggressive exceptions still preserved by default. |
| `VMReset` | Non-interactive aggressive run intended for disposable systems, with restore-point creation skipped and aggressive opt-ins forced on. |

## Custom App Lists

Hunter reads app targets from `src/Hunter/Config/Apps.json`. A custom app list narrows the broad app-removal phase to only the entries you specify.

Text example:

```text
xbox
clipchamp
teams
```

JSON example:

```json
{
  "Apps": [
    { "AppId": "xbox", "SelectedByDefault": true },
    { "AppId": "clipchamp", "SelectedByDefault": true },
    { "AppId": "teams", "SelectedByDefault": true }
  ]
}
```

Protected apps are enforced by the catalog and skipped automatically.

## Outputs

Hunter stores working state under `%ProgramData%\Hunter`.

Important runtime artifacts:

- `hunter.log`
- `checkpoint.json`
- `run-configuration.json`
- `Rollback\rollback-manifest.json`
- `Rollback\Restore-HunterState.ps1`
- `Resume\hunter.ps1`

Desktop exports at the end of a run:

- operation report
- full log copy
- restore script copy
- run-configuration copy

## Bootstrap Source

Hunter uses `main` as its single branch bootstrap source:

```powershell
$ProgressPreference='SilentlyContinue'; irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

If you create version tags, you can still use those as pinned snapshots. The wrapper logs its release channel and version at startup, and the bootstrap loader still verifies the private asset hashes it downloads.

## Development

Reference docs:

- `ARCHITECTURE.md`
- `CONTRIBUTING.md`
- `CHANGELOG.md`
- `docs/task-catalog.md`

Key files:

- `hunter.ps1`
- `src/Hunter/Config/Apps.json`
- `src/Hunter/Private/Bootstrap/Loader.ps1`
- `src/Hunter/Private/Tasks/Catalog.ps1`
- `src/Hunter/Private/State/Rollback.ps1`
- `tests/Smoke`

Recommended checks:

```powershell
git diff --check
python3 .\scripts\verification\audit_bootstrap_hashes.py
python3 .\scripts\verification\audit_task_issue_compatibility.py
Invoke-Pester .\tests\Smoke
```

## License

GPL-3.0. See `LICENSE`.
