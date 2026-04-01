# Hunter

Hunter is a single-script Windows 10/11 debloat and gaming-PC setup tool. It applies a fixed sequence of system cleanup, privacy, UI, service, storage, graphics, power, and package-install steps so a fresh machine can be brought to a known state quickly.

It exists to make repeatable Windows setup fast: run one elevated PowerShell command, let the checkpoint/resume engine handle the workflow, and review the exported report at the end.

## Features

- One-command execution from GitHub or local checkout
- Checkpoint and resume support across reboots
- Parallel package installs and background asset prefetch
- Broad Microsoft app removal plus privacy and UI cleanup
- Gaming-focused power, graphics, storage, and device-management tuning
- Desktop report and full log export at the end of the run

## Requirements

- Windows 10 22H2+ or Windows 11 23H2+
- Administrator privileges
- Internet connection
- `winget` available on the target machine

## Quick Start

Open PowerShell as Administrator and run:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

Local checkout:

```powershell
git clone https://github.com/xobash/hunter.git
cd hunter
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

## Usage

Default run:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

Strict mode:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -Strict
```

Automation-safe run:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -AutomationSafe
```

Custom log path:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1 -LogPath C:\Temp\hunter.log
```

## Flags

| Flag | Description |
|------|-------------|
| `-Strict` | Abort the run when a mandatory task fails |
| `-AutomationSafe` | Skip dialogs, UI-only launches, and reboot/sign-out actions for unattended runs |
| `-LogPath <path>` | Write the main log to a custom path |

## Environment Variables

| Variable | Description |
|----------|-------------|
| `HUNTER_LOCAL_USER_PASSWORD` | Overrides the generated/stored password for Hunter's managed local `user` account |
| `HUNTER_AUTOMATION_SAFE=1` | Forces automation-safe behavior without passing `-AutomationSafe` |

## What Hunter Does

Hunter currently runs 62 tasks across 9 phases. Re-running is safe: completed work is checkpointed and skipped where possible.

| Phase | Name | Behavior |
|------|------|----------|
| 1 | Preflight | Connectivity checks, optional restore point, start package/asset background jobs |
| 2 | Core Setup | Create or normalize local standard user, configure dark mode, activate Ultimate Performance |
| 3 | Start / UI | Disable Bing search, Start recommendations, Widgets, Task View, notification center, and Focus Assist |
| 4 | Explorer | Set This PC as Explorer home, remove Home/Gallery/OneDrive shell entries, disable folder auto-discovery |
| 5 | Microsoft Cloud | Remove Edge while preserving WebView2, remove OneDrive and Copilot, clean Edge pins and shortcuts |
| 6 | Remove Apps | Remove bundled Microsoft and consumer apps, disable consumer features and activity history |
| 7 | System Tweaks | Apply service profile, telemetry/privacy changes, storage tweaks, graphics tweaks, power tuning, timer resolution service, Adobe/Razer blocking |
| 8 | External Tools | Install packages and apply external tooling such as TCP Optimizer and O&O ShutUp10 |
| 9 | Cleanup | Finalize installs, retry failed tasks, cleanup temp data, restart Explorer, export report/logs |

## Tuning Highlights

- Storage: disables 8.3 short-name creation, disables NTFS last-access updates, and deletes the NTFS USN journal when present.
- Memory: applies a RAM-aware `LargeSystemCache` policy. Systems under 16 GiB get `1`; systems at or above 16 GiB get `0`.
- Graphics: disables HAGS, enables GPU MSI mode for detected PCI display adapters, and applies frame-pacing related registry changes.
- CPU / power: forces `PROCTHROTTLEMIN/MAX` to `100`, suppresses core parking with `CPMINCORES`, clears the `tscsyncpolicy` override, and applies broader device/power-plan tuning.
- Services: keeps `WlanSvc`, `iphlpsvc`, `Fax`, `AJRouter`, and `SNMP Trap` available while still applying the broader Hunter service profile.
- Notifications: disables toast notifications, notification center, and Focus Assist for the current and default user profiles.

## Packages and External Tools

Hunter currently installs these packages in parallel:

- PowerShell 7
- Brave
- Parsec
- Steam
- FFmpeg
- yt-dlp
- CrystalDiskMark
- Cinebench R23
- FurMark
- PeaZip
- Winaero Tweaker

It also applies:

- TCP Optimizer
- O&O ShutUp10 preset import
- Wallpaper setup
- Classic System Properties shortcut/open step
- Network Connections shortcut creation

## Architecture

`hunter.ps1` remains the stable entry script and compatibility surface. The migration work is moving shared logic into `src/Hunter` in small, behavior-preserving steps.

- `hunter.ps1`: live entrypoint, raw argument parsing, and remaining legacy orchestration
- `src/Hunter/Private`: extracted private layers for config, common helpers, execution helpers, and native-system wrappers
- `src/Hunter/Hunter.psd1` / `src/Hunter/Hunter.psm1`: root module scaffold for the ongoing monolith decomposition
- `tests/Smoke`: wrapper, task-catalog, and module-scaffold compatibility checks
- `scripts/verification`: baseline capture and comparison helpers for before/after refactors

## Outputs

Hunter writes its working state under `C:\ProgramData\Hunter\`.

| File | Purpose |
|------|---------|
| `hunter.log` | Main timestamped execution log |
| `checkpoint.json` | Completed-task tracking for resume |
| `Secrets\local-user.secret` | Machine-protected stored credential payload for the managed local user |

At the end of the run Hunter exports:

- A desktop summary report
- A copy of the full execution log

## Hyper-V Behavior

Hunter detects Hyper-V guests and changes behavior where the default desktop-oriented flow is not appropriate.

- Skips autologin configuration
- Preserves RDP-relevant behavior
- Skips disk cleanup
- Keeps Hyper-V-specific tuning branches in the power/virtualization logic

## Project Structure

```text
hunter.ps1
README.md
docs/
scripts/verification/
src/Hunter/
tests/Smoke/
tests/Fixtures/
```

## Development

Run locally:

```powershell
powershell -ExecutionPolicy Bypass -File .\hunter.ps1
```

Basic repo checks:

```bash
git diff --check
```

Run the smoke compatibility suite:

```powershell
Invoke-Pester .\tests\Smoke
```

If PowerShell is installed in your dev environment, syntax-check the script with:

```powershell
[void][System.Management.Automation.Language.Parser]::ParseFile('hunter.ps1',[ref]$null,[ref]$null)
```

Validate the module scaffold:

```powershell
Test-ModuleManifest .\src\Hunter\Hunter.psd1
```

## Scope Notes

- Hunter is opinionated. It is not a general-purpose Windows tuning framework.
- It borrows from WinUtil and similar tuning references, but it does not attempt strict one-to-one parity.
- The service profile, app removal pass, and privacy suppression are intentionally broader than a minimal debloat baseline.

## Acknowledgements

- [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil)
- [FR33THYFR33THY/WinSux-Windows-Optimization-Guide](https://github.com/FR33THYFR33THY/WinSux-Windows-Optimization-Guide)

---

## License

[GPL-3.0](LICENSE)
