# Hunter

Automated Windows 10/11 debloat and gaming PC setup. One command, no manual steps. Removes bloatware, kills telemetry, installs your apps, tunes performance — done.

## Run It

Open PowerShell **as Administrator** and paste:

```powershell
irm https://raw.githubusercontent.com/xobash/hunter/main/hunter.ps1 | iex
```

That's it. No cloning, no downloading, no setup. The script runs directly from GitHub.

> Requires admin. If you forget, it'll tell you.

## What It Does

53 tasks across 9 phases. Everything is idempotent — re-running skips completed tasks. If a reboot is needed, Hunter registers a scheduled task to auto-resume on next login.

| Phase | Name | What Happens |
|-------|------|-------------|
| 1 | Preflight | System restore point, background app downloads start |
| 2 | Core Setup | Local standard user, dark mode, Ultimate Performance power plan |
| 3 | Start / UI | Kill Bing search, Start recommendations, Widgets, Task View, notifications |
| 4 | Explorer | This PC as home, remove Home/Gallery/OneDrive tabs, disable auto folder discovery |
| 5 | Microsoft Cloud | Remove Edge (keeps WebView2), OneDrive, Copilot; block Edge reinstall via Group Policy |
| 6 | Remove Apps | Nuke ~20 bloatware apps (Outlook, Xbox, Teams, Clipchamp, Solitaire, etc.), block consumer features |
| 7 | System Tweaks | Service profiles (winutil-based), disable telemetry/location/hibernation, block Razer/Adobe traffic, exhaustive power tuning (throttling, core parking, device power management across USB/HID/PCI/NIC buses), 0.5ms timer resolution service |
| 8 | External Tools | Install 11 apps in parallel (Brave, Steam, Parsec, PowerShell 7, FFmpeg, yt-dlp, CrystalDiskMark, Cinebench R23, FurMark, PeaZip, Winaero Tweaker), TCP Optimizer, O&O ShutUp10++ |
| 9 | Cleanup | Retry failed tasks, disk cleanup, Explorer restart, desktop report |

A real-time progress overlay with animated liquid glass UI tracks everything as it runs. A summary report lands on your desktop when done.

## Requirements

- Windows 10 22H2+ or Windows 11 23H2+
- Administrator privileges
- Internet connection
- winget (pre-installed on modern Windows)

## Options

| Flag | What it does |
|------|-------------|
| `-Strict` | Abort if any task fails |
| `-LogPath <path>` | Custom log location |
| `-AutomationSafe` | Unattended mode — skips dialogs and manual review steps |

## How It Works

Hunter is a single PowerShell script (~9,700 lines). It uses a checkpoint/resume engine so reboots don't lose progress. Heavyweight operations (service config, power tuning, app installs) run in parallel where possible. The progress UI runs inline via WPF — no separate window.

State files live in `C:\ProgramData\Hunter\`:

| File | Purpose |
|------|---------|
| `hunter.log` | Timestamped log of every action |
| `checkpoint.json` | Completed task tracking (for resume) |
| `progress.json` | UI state |

## Hyper-V

Hunter detects Hyper-V VMs and adjusts: skips autologin (RDP handles it), skips disk cleanup, tunes DWM for Enhanced Session.

## Acknowledgements

Service profiles and tweak implementations based on [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil). Power tuning patterns from [FR33THYFR33THY/WinSux](https://github.com/FR33THYFR33THY/WinSux-Windows-Optimization-Guide).

---

If Hunter saved you time, consider giving it a **star** — a lot of work went into building and testing this. It helps others find it too.
