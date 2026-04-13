# Hunter

Opinionated Windows 10/11 debloat and gaming-PC setup script. Hunter applies a repeatable multi-phase workflow for cleanup, app removal, privacy suppression, package installs, gaming-oriented tuning, and report export, with checkpoint/resume support across reboots.

## Quickstart

Recommended host on the target machine: elevated Windows PowerShell (`powershell.exe`).

Run directly from GitHub:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/stable/hunter.ps1 | iex
```

Run from a local checkout:

```powershell
git clone https://github.com/xobash/hunter.git
cd hunter
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

## Table of Contents

- [Features](#features)
- [When to Use Hunter](#when-to-use-hunter)
- [When Not to Use Hunter](#when-not-to-use-hunter)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Configuration](#configuration)
- [Surgical App Removal](#surgical-app-removal)
- [What Hunter Changes](#what-hunter-changes)
- [Outputs and Logs](#outputs-and-logs)
- [Project Structure](#project-structure)
- [Verification](#verification)
- [Contributing](#contributing)
- [FAQ](#faq)
- [Acknowledgements](#acknowledgements)
- [License](#license)

## Features

- One-command execution from GitHub or a local checkout.
- Explicit release channels for public `stable`, development `preview`, and exact versioned entrypoints.
- Checkpoint and resume support so long-running runs can survive reboots.
- Parallel package installs and background asset prefetch.
- Surgical app removal driven by `src/Hunter/Config/Apps.json`, with protected system apps excluded.
- Three-layer app removal strategy:
  - WinGet uninstall for modern packaged apps where available.
  - Custom handlers for awkward edge cases such as Edge and OneDrive.
  - Selective targeting through a user-supplied custom app list.
- Windows build-aware behavior for Win10 and Win11-specific registry and shell changes.
- Gaming-focused tuning across graphics, power, device management, networking, and storage.
- Rollback capture for shared registry, service, scheduled-task, and power-plan mutations.
- Desktop summary report plus full execution log, restore script, and run-configuration export at the end of the run.

## When to Use Hunter

- You want a fast, repeatable baseline for Windows gaming desktops or bare-metal installs.
- You prefer one broad, opinionated setup pass over manual point-and-click tuning.
- You want app removal, privacy cleanup, package install, and gaming tweaks in one workflow.
- You need resume/retry behavior for machines that reboot during setup.

## When Not to Use Hunter

- You want a minimal tweak tool that only changes one or two settings.
- You need to preserve most default Microsoft apps and inbox experiences.
- The machine is corporate-managed, policy-managed, or shared with other users.
- You are looking for a GUI-first tuning tool instead of a scripted workflow.

## Requirements

- Windows 10 or Windows 11.
- Best fit today: Windows 10 22H2+ and Windows 11 22H2+.
- Administrator privileges.
- Internet connection.
- `winget` available on the target machine if you want package installs and WinGet-backed app removal.

## Installation

Hunter does not need a traditional installer.

### Remote one-liner

Stable channel:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/stable/hunter.ps1 | iex
```

Exact version:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/v2.0.1/hunter.ps1 | iex
```

Preview channel (`main`, for development validation rather than public use):

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

### Local checkout

```powershell
git clone https://github.com/xobash/hunter.git
cd hunter
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

### Notes

- Hunter bootstraps `src/Hunter/Private/Bootstrap/Loader.ps1`, validates its SHA-256, then downloads any missing private assets from the loader manifest when you run `hunter.ps1` directly from GitHub.
- The wrapper now self-identifies its release channel and release version, while private bootstrap assets remain pinned to an immutable bootstrap revision for integrity and reproducibility.
- PowerShell 7 can launch Hunter, but Hunter still uses Windows PowerShell internally for some AppX operations because the desktop AppX tooling is not consistently available in `pwsh` on Windows clients.

## Usage

### Default run

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

### Strict mode

Abort the overall run when a mandatory task fails after retries.

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Strict
```

### Automation-safe mode

Skip UI-only launches and automatic reboot/sign-out behavior for unattended runs.

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -AutomationSafe
```

### Skip specific tasks

Useful for isolating a problem task or tailoring a run without editing code.

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -SkipTask tweaks-ipv6,tweaks-timer-resolution
```

### Use a custom app list

Override the default Phase 6 broad-removal selection.

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -CustomAppsListPath .\CustomAppsList.txt
```

### Write logs to a custom path

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -LogPath C:\Temp\hunter.log
```

### Opt-in legacy network and graphics toggles

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -DisableIPv6 -DisableTeredo -DisableHags
```

## Configuration

### Command-line flags

| Flag | Description |
|------|-------------|
| `-Strict` | Stop the run when a mandatory task fails after retries. |
| `-AutomationSafe` | Skip UI-only launches and automatic reboot/sign-out behavior. |
| `-SkipTask <id1,id2>` | Skip one or more task IDs for this run. |
| `-CustomAppsListPath <path>` | Use a text or JSON custom app selection file for Phase 6 app removal. |
| `-DisableIPv6` | Opt in to Hunter's legacy IPv6-disable task. |
| `-DisableTeredo` | Opt in to Hunter's Teredo-disable task. |
| `-DisableHags` | Opt out of Hunter's default HAGS-enable policy and apply the legacy disable override. |
| `-LogPath <path>` | Write the main log to a custom path. |
| `-Mode Resume` | Internal recovery mode used by the resume scheduled task. |

### Environment variables

| Variable | Description |
|----------|-------------|
| `HUNTER_LOCAL_USER_PASSWORD` | Overrides the generated/stored password for Hunter's managed local `user` account. |
| `HUNTER_AUTOMATION_SAFE=1` | Forces automation-safe behavior without passing `-AutomationSafe`. |
| `HUNTER_CUSTOM_APPS_LIST=<path>` | Provides a default custom app list path when `-CustomAppsListPath` is not passed. |
| `HUNTER_DISABLE_IPV6=1` | Opts in to Hunter's IPv6-disable task. |
| `HUNTER_DISABLE_TEREDO=1` | Opts in to Hunter's Teredo-disable task. |
| `HUNTER_DISABLE_HAGS=1` | Opts out of Hunter's default HAGS-enable policy and applies the legacy disable override. |

## Surgical App Removal

Hunter now uses a three-layer app removal model influenced by tools such as Win11Debloat, but adapted to Hunter's task engine.

### Layer 1: WinGet uninstall

Hunter uses WinGet when the target app has a reliable packaged uninstall path.

Examples:

- Edge
- OneDrive

### Layer 2: Custom edge-case handlers

Some apps still need dedicated logic instead of blind package removal.

Examples:

- Edge removal while checking that WebView2 survives.
- OneDrive cleanup and leftover folder handling.

### Layer 3: User-defined selective targeting

Hunter can narrow its broad app-removal pass with a custom apps list instead of using the default catalog selection.

Text format example:

```text
xbox
teams
clipchamp
```

JSON format example:

```json
{
  "Apps": [
    { "AppId": "xbox", "SelectedByDefault": true },
    { "AppId": "teams", "SelectedByDefault": true },
    { "AppId": "clipchamp", "SelectedByDefault": true }
  ]
}
```

Run with that list:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -CustomAppsListPath .\CustomAppsList.txt
```

### Catalog

`src/Hunter/Config/Apps.json` is the authoritative app-removal catalog.

It tracks:

- Protected system apps that Hunter must not target.
- Friendly names and app identifiers.
- Default-selection behavior.
- Build gates.
- Removal strategies per app.

Critical shell and security apps such as Windows Security, Shell Experience Host, Start Menu Experience Host, Settings, and Windows Store are explicitly preserved.

## What Hunter Changes

Hunter runs a fixed multi-phase workflow.

| Phase | Area | Examples |
|------|------|----------|
| 1 | Preflight | Connectivity checks, optional restore point, app-download prompt, package/asset prefetch startup |
| 2 | Core setup | Local user normalization, dark mode, Ultimate Performance activation |
| 3 | Start / UI | Search cleanup, Start recommendations, Widgets, notifications, taskbar options |
| 4 | Explorer | This PC as home, namespace cleanup, auto-discovery reset |
| 5 | Microsoft cloud | Edge, OneDrive, Copilot, Edge shortcut/pin cleanup |
| 6 | Broad app removal | Surgical catalog-driven app removal, consumer features, activity history |
| 7 | System tweaks | Services, telemetry, virtualization, graphics, MPO, GPU MSI, GPU interrupt affinity, ReBAR audit, power tuning, storage, input, IPv6 |
| 8 | External tools | Wallpaper, TCP Optimizer, O&O ShutUp10, classic system tools |
| 9 | Cleanup | Finalize installs, retry failed tasks, temp cleanup, Explorer restart, report export |

### Tuning highlights

- Graphics:
  - GPU MSI mode for detected PCI display adapters.
  - MPO disable via `OverlayTestMode=5`.
  - Windowed-game swap-effect upgrade.
  - GPU interrupt affinity pinning on supported single-group systems.
  - ReBAR audit instead of undocumented force-enablement.
- CPU and power:
  - Ultimate Performance activation.
  - Core parking suppression and processor minimum/maximum performance state changes.
  - Windows 11 SMT unpark policy tuning where that power setting exists.
  - Additional device and plan-level power tuning.
- Storage and memory:
  - RAM-aware `LargeSystemCache` policy.
  - Disable 8.3 short names and NTFS last-access updates.
  - Delete the NTFS USN journal when present.
  - Disk write-cache policy tuning where exposed.
- Shell and UX:
  - Start/taskbar cleanup.
  - Explorer namespace cleanup.
  - Notification and toast suppression.
  - No-sounds profile and desktop visual-effect trimming.

## Outputs and Logs

Hunter writes working state under `C:\ProgramData\Hunter\`.

| File | Purpose |
|------|---------|
| `hunter.log` | Main execution log |
| `checkpoint.json` | Completed-task tracking for resume/retry logic |
| `Rollback\rollback-manifest.json` | Captured rollback manifest for shared system mutations |
| `Rollback\Restore-HunterState.ps1` | Generated restore script for captured rollback entries |
| `Resume\hunter.ps1` | Resume-script copy used by the scheduled recovery task |
| `run-configuration.json` | Release metadata and run inputs for reproducibility |
| `Secrets\local-user.secret` | Machine-protected credential payload for Hunter's managed local user |
| `Temp\` | Temporary helper assets used during some operations |

At the end of the run Hunter exports:

- A desktop summary report.
- A desktop copy of the full execution log.
- A desktop copy of the generated restore script.
- A desktop copy of the run configuration used for the run.

## Project Structure

```text
hunter.ps1
README.md
LICENSE
docs/
scripts/
  verification/
src/
  Hunter/
    Config/
    Private/
tests/
  Fixtures/
  Smoke/
```

### Important paths

- `hunter.ps1`: stable entrypoint and compatibility surface.
- `src/Hunter/Config/Apps.json`: surgical app-removal catalog.
- `src/Hunter/Private/Bootstrap`: bootstrap configuration and runtime state.
- `src/Hunter/Private/Tasks/Catalog.ps1`: declarative task catalog.
- `src/Hunter/Private/Execution`: execution engine and resume logic.
- `src/Hunter/Private/Infrastructure`: native-system wrappers and low-level helpers.
- `tests/Smoke`: compatibility and task-catalog checks.
- `scripts/verification`: repo-local verification and before/after comparison helpers.
- `tests/Fixtures/Baseline/README.md`: manual baseline-capture workflow for refactor comparisons.

## Verification

Fast checks:

```powershell
git diff --check
python3 .\scripts\verification\audit_task_issue_compatibility.py
python3 .\scripts\verification\audit_bootstrap_hashes.py
```

Smoke tests:

```powershell
Invoke-Pester .\tests\Smoke
```

Module manifest validation:

```powershell
Test-ModuleManifest .\src\Hunter\Hunter.psd1
```

PowerShell syntax parse:

```powershell
[void][System.Management.Automation.Language.Parser]::ParseFile('hunter.ps1',[ref]$null,[ref]$null)
```

Manual before/after artifact capture:

See `tests/Fixtures/Baseline/README.md` for the `Capture-Baseline.ps1` and `Compare-Baseline.ps1` workflow.

## Contributing

Pull requests are welcome, but Hunter is intentionally opinionated. Keep changes practical and behavior-focused.

### Suggested workflow

1. Fork the repository.
2. Create a feature branch.
3. Make the smallest behaviorally coherent change you can.
4. Update tests or smoke coverage when behavior changes.
5. Update the README when flags, outputs, or runtime behavior change.
6. Open a pull request with before/after notes.

### Useful local checks

Use the verification commands above before opening a pull request.

## FAQ

### Is Hunter safe to re-run?

Usually yes. Hunter checkpoints completed tasks and skips work where possible. It is still a full-machine tuning script, so review changes before repeatedly running it on a daily-driver machine.

### Do I need `winget`?

You need `winget` for Hunter's package installs and WinGet-backed app removal paths. Core tuning tasks can still run even if package-install tasks are skipped.

### Can I remove only a few apps instead of the default bundle?

Yes. Pass `-CustomAppsListPath` or set `HUNTER_CUSTOM_APPS_LIST` and target only the app IDs you want from `src/Hunter/Config/Apps.json`.

### Does Hunter reboot the machine?

It can. If a pending reboot is detected at the end of a clean run, Hunter may reboot automatically unless automation-safe behavior is active or the run completed with issues.

### Does Hunter force-enable Resizable BAR?

No. Hunter audits likely support and logs what it finds, but does not use undocumented force-enable registry hacks. BAR sizing is negotiated by firmware and display drivers on supported hardware.

## Acknowledgements

Hunter is informed by and borrows ideas from:

- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)
- [Raphire/Win11Debloat](https://github.com/Raphire/Win11Debloat)
- [FR33THYFR33THY/WinSux-Windows-Optimization-Guide](https://github.com/FR33THYFR33THY/WinSux-Windows-Optimization-Guide)

## License

[GPL-3.0](LICENSE)
