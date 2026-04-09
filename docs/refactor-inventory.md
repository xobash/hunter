# Hunter Refactor Inventory Baseline

This document records the current observable structure of `hunter.ps1` before any migration work begins. It is the Phase 1 baseline for later behavior-preserving refactors.

## Entry Surface

- Runtime file: `hunter.ps1`
- Execution requirement: `#Requires -RunAsAdministrator`
- Script-wide settings at startup:
  - `Set-StrictMode -Version Latest`
  - `$ErrorActionPreference = 'Stop'`
  - TLS 1.2 is enabled for .NET HTTP calls
- Supported wrapper arguments parsed from raw `$args`:
  - `-Mode Execute|Resume`
  - `-Strict`
  - `-LogPath <path>`
  - `-AutomationSafe`
- Main entrypoint:
  - `Invoke-Main -Mode $scriptMode -Strict:$scriptStrict -AutomationSafe:$scriptAutomationSafe`
- Default wrapper values:
  - `$scriptMode = 'Execute'`
  - `$scriptStrict = $false`
  - `$scriptLogPath = $null`
  - `$scriptAutomationSafe = $false`

## Top-Level Control Flow

`Invoke-Main` currently performs this sequence:

1. Start stopwatch and suppress web progress bars with local `$ProgressPreference = 'SilentlyContinue'`.
2. Ensure working directories exist under the Hunter root.
3. Detect automation mode from `-AutomationSafe`, `GITHUB_ACTIONS`, or `HUNTER_AUTOMATION_SAFE`.
4. Log banner, environment, admin status, and OS version.
5. Validate Windows version.
6. Detect Hyper-V guest state.
7. Load checkpoint state.
8. Build the ordered task list and store it in `$script:TaskList`.
9. Start progress tracking and the WPF progress window.
10. Register the `Hunter-Resume` scheduled task.
11. Execute tasks through `Invoke-TaskExecution`.
12. Unregister the resume task.
13. Compute summary statistics and persist checkpoint state.
14. Close the progress window.
15. Detect pending reboot and optionally reboot.
16. Return success/failure for the overall run.

## Task Catalog

Current task count in `Build-Tasks`: `65`

### Phase 1
- `preflight-internet`
- `preflight-restore-point`
- `preflight-predownload-v2`

### Phase 2
- `install-launch-packages-v2`
- `core-local-user-v2`
- `core-autologin-v2`
- `core-dark-mode`
- `core-ultimate-performance`

### Phase 3
- `startui-bing-search`
- `startui-start-recommendations-v4`
- `startui-search-box`
- `startui-task-view`
- `startui-widgets`
- `startui-end-task`
- `startui-notifications`
- `startui-new-outlook`
- `startui-settings-home`

### Phase 4
- `explorer-home-thispc`
- `explorer-remove-home-v2`
- `explorer-remove-gallery-v2`
- `explorer-remove-onedrive`
- `explorer-auto-discovery`

### Phase 5
- `cloud-edge-remove`
- `cloud-edge-pins`
- `cloud-onedrive-remove`
- `cloud-onedrive-backup`
- `cloud-copilot-remove`

### Phase 6
- `apps-consumer-features`
- `apps-nuke-block`
- `apps-inking-typing`
- `apps-delivery-opt`
- `apps-activity-history`

### Phase 7
- `tweaks-services`
- `tweaks-virtualization-security`
- `tweaks-telemetry`
- `tweaks-location`
- `tweaks-hibernation`
- `tweaks-background-apps`
- `tweaks-teredo`
- `tweaks-fso`
- `tweaks-graphics-scheduling`
- `tweaks-dwm-frame-interval`
- `tweaks-ui-desktop`
- `tweaks-razer`
- `tweaks-adobe`
- `tweaks-power-tuning`
- `tweaks-memory-disk`
- `tweaks-input-maintenance`
- `tweaks-timer-resolution`
- `tweaks-store-search`
- `tweaks-ipv6`

### Phase 8
- `external-wallpaper-v3`
- `external-tcp-optimizer`
- `external-oosu`
- `external-system-properties`
- `external-network-connections-shortcut`

### Phase 9
- `install-finalize-packages-v2`
- `cleanup-temp-files`
- `cleanup-retry-failed`
- `cleanup-disk-cleanup`
- `cleanup-explorer-restart`
- `cleanup-export-log`

## Shared State

The monolith depends heavily on script-scoped mutable state.

### Configuration and Paths
- `ProgramDataRoot`
- `ProgramFilesRoot`
- `WindowsRoot`
- `HunterRoot`
- `DownloadDir`
- `LogPath`
- `CheckpointPath`
- `ResumeScriptPath`
- `SecretsRoot`
- `LocalUserSecretPath`
- `AllUsersStartMenuProgramsPath`
- `HostsFilePath`

### Execution Flags and Runtime Coordination
- `IsHyperVGuest`
- `IsAutomationRun`
- `ExplorerRestartPending`
- `StartSurfaceRestartPending`
- `TaskbarReconcilePending`
- `DefaultTaskbarPinsRemoved`
- `EdgeShortcutsRemoved`
- `CurrentTaskLoggedError`
- `CurrentTaskLoggedWarning`
- `ProgressUiIssueLogged`
- `StrictMode`

### Async and Cache State
- `ParallelInstallTargets`
- `ParallelInstallJobs`
- `ParallelInstallResults`
- `PrefetchedExternalAssets`
- `ExternalAssetPrefetchJobs`
- `AppShortcutSetCache`
- `ExecutableResolverCache`
- `ExecutableResolverNextAttemptAt`
- `PostInstallCompletion`

### Task Engine State
- `CompletedTasks`
- `FailedTasks`
- `TaskResults`
- `TaskList`
- `CheckpointAliases`
- `RunStopwatch`
- `RunInfrastructureIssues`

### UI State
- `UiSync`
- `UiRunspace`
- `UiPipeline`

## Helper Groups

The file is currently organized into these broad helper areas:

- logging and run issue tracking
- directory, secret, and native process helpers
- task result interpretation
- installer job helper bootstrap
- registry helpers
- service, scheduled task, feature, BCD, and power helpers
- AppX helpers
- download and external asset prefetch helpers
- install target catalog and executable resolution
- shortcut, taskbar, shell, and AppsFolder helpers
- host file, Hyper-V, memory, pagefile, audio, GPU, and storage helpers
- checkpoint, progress, and Explorer restart helpers
- phase-specific `Invoke-*` handlers
- task engine, resume handling, pending reboot detection, and main orchestration

## Side Effects

Current side effects performed by `hunter.ps1` include:

- writes under the Hunter working root
- log writes
- checkpoint writes
- secret file writes for managed local-user credentials
- downloads of installers and external tools
- desktop and Start Menu shortcut creation
- temp file deletion
- registry value creation, update, and deletion in HKLM, HKCU, and Default user hive
- service start-type changes and service stops
- scheduled task registration, deletion, and disablement
- AppX and provisioned package removal
- optional feature disablement
- hosts file edits
- BCD changes
- power configuration changes
- pagefile policy changes
- network DNS and adapter property changes
- timer resolution service installation
- Explorer and Start surface restarts
- optional reboot after completion

## External Dependencies

### PowerShell and Windows APIs
- CIM and WMI-backed classes such as `Win32_Service`, `Win32_ComputerSystem`, `Win32_PageFileSetting`, and `Win32_NetworkAdapterConfiguration`
- scheduled task cmdlets
- AppX cmdlets
- networking cmdlets
- Defender cmdlets
- restore point cmdlets

### COM and ADSI
- `WScript.Shell`
- `Shell.Application`
- ADSI `WinNT://`

### Native Executables
- `winget`
- `curl.exe`
- `powercfg.exe`
- `bcdedit.exe`
- `fsutil.exe`
- `reg.exe`
- `sc.exe`
- `net.exe`
- `netsh.exe`
- `cleanmgr.exe`
- `Dism.exe`
- `shutdown.exe`
- `msiexec.exe`
- `takeown`
- `icacls`
- `control.exe`
- `SystemPropertiesAdvanced.exe`

### UI and Managed Libraries
- WinForms
- WPF assemblies
- inline C# for wallpaper application
- inline C# compilation for the timer resolution service

### Network and Asset Sources
- GitHub release assets
- wallpaper source URL
- O&O ShutUp10 config URL
- vendor and package download endpoints

## Ordering Constraints

Current ordering is behaviorally significant:

- task IDs and order are part of checkpoint and resume compatibility
- predownload must happen before install finalization
- local-user creation must precede autologin
- deferred Explorer and Start changes depend on cleanup-phase restart
- background installer and asset job collection happens after each task
- resume task registration must happen before risky task execution
- resume task cleanup must happen after task execution completes
- pending reboot is evaluated after all cleanup and reporting

## Known Defects and Migration Watchpoints

- `tweaks-power-tuning` is currently capable of failing on unsupported `powercfg` settings.
- task completion semantics depend partly on `Write-Log` setting warning/error flags, so logging is also control flow.
- raw `$args` parsing is part of the wrapper contract and must be preserved unless a deliberate compatibility shim replaces it.
- the progress window runs in a separate runspace and should be treated as fragile during refactor.
- checkpoint compatibility depends on stable task IDs and alias normalization.

## Phase 1 Scope Boundary

Phase 1 adds only documentation and verification assets:

- `docs/refactor-inventory.md`
- `tests/Smoke/TaskCatalog.Tests.ps1`
- `tests/Smoke/CompatibilitySurface.Tests.ps1`
- `tests/Fixtures/Baseline/README.md`
- `scripts/verification/Capture-Baseline.ps1`
- `scripts/verification/Compare-Baseline.ps1`

No production function bodies should change in this phase.
