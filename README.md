# Hunter

Hunter is a PowerShell-based Windows setup script for personal Windows 10 and Windows 11 systems. It applies a single multi-phase pass that handles debloat, privacy changes, app removal, package install, performance tuning, cleanup, reporting, and rollback capture.

## Scope

- Supported target: personal Windows 10 and Windows 11 installs
- Recommended host: elevated Windows PowerShell (`powershell.exe`)
- Primary use case: fresh installs, rebuilds, and repeatable baseline setup
- Exclusions: managed enterprise machines, shared systems, and minimal one-setting tweak workflows

## Safety

- Hunter runs as administrator and changes system settings.
- The `stable` channel is the public release channel. `main` is the preview channel.
- Hunter captures rollback data for shared registry, service, scheduled task, and active power-plan changes.
- Interactive runs now create a restore point before execution continues.
- Hunter exports a report, full log, restore script, and run configuration on every run.
- App removals and third-party tool imports are documented and accompanied by explicit restore guidance.
- Use `stable` for production baselines and `main` only to validate upcoming changes.

## Quick Start

Stable:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/stable/hunter.ps1 | iex
```

Preview:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

Exact version:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/v2.0.1/hunter.ps1 | iex
```

Local checkout:

```powershell
git clone https://github.com/xobash/hunter.git
cd hunter
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

## Requirements

- Windows 10 or Windows 11
- Administrator privileges
- Internet access
- `winget` for package installs and WinGet-backed app removal

## What Hunter Does

- Builds a fixed task catalog and executes it with checkpoint and resume support
- Logs a pre-run execution plan with per-task risk labels before mutation begins
- Applies Windows build-aware UI, privacy, explorer, cloud, app, and hardware changes
- Removes supported apps from the catalog in `src/Hunter/Config/Apps.json`
- Runs package and external-tool steps where configured
- Exports a report, full log, restore script, and run configuration at the end of the run

## Usage

Default run:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

Strict mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Strict
```

Automation-safe mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -AutomationSafe
```

Skip specific tasks:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -SkipTask tweaks-ipv6,tweaks-timer-resolution
```

Use a custom app list:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -CustomAppsListPath .\CustomAppsList.txt
```

Opt into legacy disable flags:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -DisableIPv6 -DisableTeredo -DisableHags
```

Opt into the aggressive storage and audio tweaks that are now disabled by default:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -ForceStorageOptimization -DisableAudioEnhancements -DisableSystemSounds
```

Write the log to a custom path:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -LogPath .\hunter.log
```

## Configuration

### Flags

| Flag | Purpose |
| --- | --- |
| `-Strict` | Fail the overall run if a mandatory task still fails after retry handling. |
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
| `-PagefileDrive <drive>` | Move the fixed pagefile target to a specific drive letter. |
| `-LogPath <path>` | Write the main log to a custom path. |
| `-Mode Resume` | Internal recovery mode used by the scheduled resume task. |

### Environment Variables

| Variable | Purpose |
| --- | --- |
| `HUNTER_AUTOMATION_SAFE=1` | Force automation-safe behavior without passing `-AutomationSafe`. |
| `HUNTER_CUSTOM_APPS_LIST=<path>` | Provide a default custom apps list path. |
| `HUNTER_DISABLE_IPV6=1` | Opt in to IPv6 disable. |
| `HUNTER_DISABLE_TEREDO=1` | Opt in to Teredo disable. |
| `HUNTER_DISABLE_CPU_MITIGATIONS=1` | Opt in to disabling speculative-execution mitigations. |
| `HUNTER_DISABLE_HAGS=1` | Opt out of default HAGS enablement. |
| `HUNTER_FORCE_STORAGE_OPTIMIZATION=1` | Opt in to the aggressive storage tweaks Hunter now preserves by default. |
| `HUNTER_DISABLE_AUDIO_ENHANCEMENTS=1` | Opt in to disabling Windows audio enhancements. |
| `HUNTER_DISABLE_SYSTEM_SOUNDS=1` | Opt in to Hunter's silent system sound-scheme change. |
| `HUNTER_LOCAL_USER_PASSWORD=<value>` | Override the managed local-user password if that path is used. |

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

Protected apps are enforced by the catalog and will be skipped.

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

## Release Channels

| Channel | Ref | Intended use |
| --- | --- | --- |
| `stable` | `stable` | Public one-liner |
| `preview` | `main` | Pre-release validation |
| versioned | `v<semver>` | Exact reproducible release |

The wrapper logs its release channel and version at startup. Private bootstrap assets are pinned to an immutable bootstrap revision for integrity and reproducibility.

## Development

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
