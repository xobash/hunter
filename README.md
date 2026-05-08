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
> Hunter runs as administrator and changes system settings. Use the `stable` channel for real machines and `main` only when validating preview changes. It is not intended for managed enterprise devices, shared systems, or one-off single-setting tweaks.

## Quick Start

Run from an elevated Windows PowerShell session:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/stable/hunter.ps1 | iex
````

Preview channel:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

Pinned release:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/v2.0.3/hunter.ps1 | iex
```

Local checkout:

```powershell
git clone https://github.com/xobash/hunter.git
cd hunter
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

## Requirements

| Requirement | Notes                                                                      |
| ----------- | -------------------------------------------------------------------------- |
| Windows     | Windows 10 or Windows 11                                                   |
| Shell       | Elevated Windows PowerShell, `powershell.exe`                              |
| Network     | Internet access for bootstrap, package, and external-tool steps            |
| Packages    | `winget` is used for supported package installs and WinGet-backed removals |

## What It Does

Hunter builds a task plan, labels task risk, resumes from checkpoints, and exports run artifacts under `%ProgramData%\Hunter`.

Core areas:

* preflight validation, restore point creation, and checkpoint setup
* Windows UI, Explorer, Start, privacy, cloud, and hardware policy changes
* catalog-driven app removal from `src/Hunter/Config/Apps.json`
* package and external-tool steps where configured
* final cleanup, report export, rollback manifest, and restore script generation

## Usage

```powershell
# Default local run
powershell -ExecutionPolicy Bypass -File .\hunter.ps1

# Fail the run if a mandatory task still fails after retry handling
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Strict

# Avoid UI-only launches and automatic reboot/sign-out behavior
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -AutomationSafe

# Skip one or more task IDs
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -SkipTask tweaks-ipv6,tweaks-timer-resolution

# Use a custom app removal list
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -CustomAppsListPath .\CustomAppsList.txt

# Write the main log somewhere else
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -LogPath .\hunter.log
```

<details>
<summary>Advanced and opt-in flags</summary>

| Flag                        | Purpose                                                    |
| --------------------------- | ---------------------------------------------------------- |
| `-DisableIPv6`              | Opt in to Hunter's IPv6-disable task.                      |
| `-DisableTeredo`            | Opt in to Hunter's Teredo-disable task.                    |
| `-DisableHags`              | Opt out of Hunter's default HAGS-enable policy.            |
| `-DisableCpuMitigations`    | Opt in to disabling speculative-execution mitigations.     |
| `-ForceStorageOptimization` | Opt in to aggressive NTFS and disk write-cache tweaks.     |
| `-DisableAudioEnhancements` | Opt in to disabling Windows audio enhancements.            |
| `-DisableSystemSounds`      | Opt in to Hunter's silent system sound scheme.             |
| `-PagefileDrive <drive>`    | Move the fixed pagefile target to a specific drive letter. |
| `-Mode Resume`              | Internal recovery mode used by the scheduled resume task.  |

Some advanced flags may appear first on `main` before they are available in `stable`.

</details>

<details>
<summary>Environment variables</summary>

| Variable                              | Purpose                                                        |
| ------------------------------------- | -------------------------------------------------------------- |
| `HUNTER_AUTOMATION_SAFE=1`            | Force automation-safe behavior.                                |
| `HUNTER_CUSTOM_APPS_LIST=<path>`      | Provide a default custom app list path.                        |
| `HUNTER_DISABLE_IPV6=1`               | Opt in to IPv6 disable.                                        |
| `HUNTER_DISABLE_TEREDO=1`             | Opt in to Teredo disable.                                      |
| `HUNTER_DISABLE_HAGS=1`               | Opt out of default HAGS enablement.                            |
| `HUNTER_DISABLE_CPU_MITIGATIONS=1`    | Opt in to disabling speculative-execution mitigations.         |
| `HUNTER_FORCE_STORAGE_OPTIMIZATION=1` | Opt in to aggressive storage tweaks.                           |
| `HUNTER_DISABLE_AUDIO_ENHANCEMENTS=1` | Opt in to disabling audio enhancements.                        |
| `HUNTER_DISABLE_SYSTEM_SOUNDS=1`      | Opt in to the silent sound scheme.                             |
| `HUNTER_LOCAL_USER_PASSWORD=<value>`  | Override the managed local-user password if that path is used. |

</details>

## Custom App Lists

Hunter reads app targets from `src/Hunter/Config/Apps.json`. A custom app list narrows the broad app-removal phase to only the app IDs you specify.

Text format:

```text
xbox
clipchamp
teams
```

JSON format:

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

Hunter stores runtime state in:

```text
%ProgramData%\Hunter
```

Important artifacts:

| Artifact                           | Purpose                   |
| ---------------------------------- | ------------------------- |
| `hunter.log`                       | Full run log              |
| `checkpoint.json`                  | Resume and recovery state |
| `run-configuration.json`           | Captured run options      |
| `Rollback\rollback-manifest.json`  | Rollback metadata         |
| `Rollback\Restore-HunterState.ps1` | Generated restore script  |
| `Resume\hunter.ps1`                | Scheduled resume copy     |

At the end of a run, Hunter also exports desktop copies of the operation report, full log, restore script, and run configuration.

## Release Channels

| Channel   | Ref         | Use                                       |
| --------- | ----------- | ----------------------------------------- |
| Stable    | `stable`    | Public one-liner and production baselines |
| Preview   | `main`      | Pre-release validation                    |
| Versioned | `v<semver>` | Exact reproducible release                |

The wrapper logs its release channel and version at startup. Bootstrap assets are pinned to immutable revisions for integrity and reproducibility.

## Development

Key paths:

```text
hunter.ps1
src/Hunter/Config/Apps.json
src/Hunter/Private/Bootstrap/Loader.ps1
src/Hunter/Private/Tasks/Catalog.ps1
src/Hunter/Private/State/Rollback.ps1
tests/Smoke
```

Recommended checks:

```powershell
git diff --check
python3 .\scripts\verification\audit_bootstrap_hashes.py
python3 .\scripts\verification\audit_task_issue_compatibility.py
Invoke-Pester .\tests\Smoke
```

## License

GPL-3.0. See `LICENSE`.

```
```
