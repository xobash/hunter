# Hunter Task Catalog

This reference mirrors the live task catalog in `src/Hunter/Private/Tasks/Catalog.ps1`.

Profile meanings:

- `Minimal`: debloat, privacy, and cleanup without the performance-heavy tuning pass
- `Balanced`: debloat, privacy, and safer gaming-oriented tweaks while skipping the most invasive tuning tasks
- `Aggressive`: full catalog
- `VMReset`: non-interactive aggressive run for disposable systems, with restore-point creation skipped and aggressive opt-ins forced on

Risk labels:

- `Safe`: low-risk preference or cleanup change
- `Moderate`: meaningful system behavior change that is still intended for broader use
- `Aggressive`: invasive change that can reduce compatibility, recovery surface, or feature coverage

| Phase | Task ID | Risk | Profiles | Description |
| --- | --- | --- | --- | --- |
| 1 | `preflight-driver-install-block` | Moderate | Minimal, Balanced, Aggressive, VMReset | Block Windows Update driver installs and automatic driver search |
| 1 | `preflight-internet` | Safe | Minimal, Balanced, Aggressive, VMReset | Verify internet connectivity |
| 1 | `preflight-edition-compatibility` | Moderate | Minimal, Balanced, Aggressive, VMReset | Validate supported Windows edition and set Store/AppX compatibility gates |
| 1 | `preflight-restore-point` | Moderate | Minimal, Balanced, Aggressive | Create Windows System Restore point |
| 1 | `preflight-winget-version` | Moderate | Minimal, Balanced, Aggressive, VMReset | Validate Hunter minimum winget version and refresh App Installer if needed |
| 1 | `preflight-app-downloads` | Safe | Minimal, Balanced, Aggressive, VMReset | Choose whether to skip app downloads and installs |
| 1 | `preflight-predownload-v2` | Safe | Minimal, Balanced, Aggressive, VMReset | Start background package downloads and installs |
| 2 | `install-launch-packages-v2` | Moderate | Minimal, Balanced, Aggressive, VMReset | Ensure package installers are running in parallel |
| 2 | `core-local-user-v2` | Moderate | Aggressive, VMReset | Ensure standard local user exists |
| 2 | `core-autologin-v2` | Aggressive | Aggressive, VMReset | Prompt and configure autologin for standard user |
| 2 | `core-dark-mode` | Safe | Balanced, Aggressive, VMReset | Enable Windows dark mode theme |
| 2 | `core-ultimate-performance` | Moderate | Balanced, Aggressive, VMReset | Activate Ultimate Performance power plan |
| 3 | `startui-bing-search` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable Bing search in Start Menu |
| 3 | `startui-start-recommendations-v4` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable Start Menu recommendations |
| 3 | `startui-search-box` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable taskbar search box |
| 3 | `startui-task-view` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable Task View button |
| 3 | `startui-widgets` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable Windows Widgets |
| 3 | `startui-end-task` | Safe | Minimal, Balanced, Aggressive, VMReset | Enable End Task option on taskbar |
| 3 | `startui-notifications` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable notifications, tray, and calendar |
| 3 | `startui-new-outlook` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable new Outlook and auto-migration |
| 3 | `startui-settings-home` | Safe | Minimal, Balanced, Aggressive, VMReset | Hide Settings home page |
| 4 | `explorer-home-thispc` | Safe | Minimal, Balanced, Aggressive, VMReset | Set Explorer home to This PC |
| 4 | `explorer-remove-home-v2` | Safe | Minimal, Balanced, Aggressive, VMReset | Remove Home tab from Explorer |
| 4 | `explorer-remove-gallery-v2` | Safe | Minimal, Balanced, Aggressive, VMReset | Remove Gallery tab from Explorer |
| 4 | `explorer-remove-onedrive` | Safe | Minimal, Balanced, Aggressive, VMReset | Remove OneDrive tab from Explorer |
| 4 | `explorer-auto-discovery` | Safe | Minimal, Balanced, Aggressive, VMReset | Disable Explorer automatic folder discovery |
| 5 | `cloud-edge-remove` | Aggressive | Minimal, Balanced, Aggressive, VMReset | Remove Microsoft Edge |
| 5 | `cloud-edge-pins` | Safe | Minimal, Balanced, Aggressive, VMReset | Remove Edge pins and shortcuts |
| 5 | `cloud-edge-update-block` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable Edge update tasks and services while preserving WebView2 |
| 5 | `cloud-onedrive-remove` | Aggressive | Minimal, Balanced, Aggressive, VMReset | Remove Microsoft OneDrive |
| 5 | `cloud-onedrive-backup` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable OneDrive folder backup |
| 5 | `cloud-copilot-remove` | Moderate | Minimal, Balanced, Aggressive, VMReset | Remove Copilot AI assistant |
| 6 | `apps-consumer-features` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable consumer experience features |
| 6 | `apps-nuke-block` | Aggressive | Minimal, Balanced, Aggressive, VMReset | Remove and block broad Microsoft bloatware (including Xbox/Game Bar) |
| 6 | `apps-inking-typing` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable Inking and Typing data collection |
| 6 | `apps-delivery-opt` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable Delivery Optimization |
| 6 | `apps-activity-history` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable activity history plus clipboard/cloud clipboard tracking |
| 7 | `tweaks-services` | Aggressive | Aggressive, VMReset | Apply Hunter aggressive service startup profile |
| 7 | `tweaks-virtualization-security` | Aggressive | Aggressive, VMReset | Disable HVCI, Hyper-V side features, Sandbox, and Application Guard |
| 7 | `tweaks-telemetry` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable telemetry plus Hunter privacy/web-content policies |
| 7 | `tweaks-location` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable location tracking |
| 7 | `tweaks-hibernation` | Moderate | Aggressive, VMReset | Disable hibernation mode |
| 7 | `tweaks-background-apps` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable background apps plus OneDrive, Widgets, and Edge background activity |
| 7 | `tweaks-teredo` | Moderate | Balanced, Aggressive, VMReset | Disable Teredo tunneling protocol |
| 7 | `tweaks-fso` | Moderate | Balanced, Aggressive, VMReset | Disable fullscreen optimizations |
| 7 | `tweaks-graphics-scheduling` | Aggressive | Balanced, Aggressive, VMReset | Apply HAGS, MPO, VRR, Game Bar, Auto HDR, and TDR graphics tweaks |
| 7 | `tweaks-gpu-interrupt-affinity` | Moderate | Balanced, Aggressive, VMReset | Pin GPU interrupts to a non-primary logical processor on supported single-group systems |
| 7 | `tweaks-rebar-audit` | Safe | Balanced, Aggressive, VMReset | Audit GPU family compatibility for Resizable BAR and document firmware-managed status |
| 7 | `tweaks-dwm-frame-interval` | Moderate | Balanced, Aggressive, VMReset | Set DWM frame interval to 15 |
| 7 | `tweaks-ui-desktop` | Moderate | Balanced, Aggressive, VMReset | Reduce transparency, animations, and desktop compositor overhead |
| 7 | `tweaks-razer` | Moderate | Balanced, Aggressive, VMReset | Block Razer software network access |
| 7 | `tweaks-adobe` | Moderate | Balanced, Aggressive, VMReset | Block Adobe software network traffic |
| 7 | `tweaks-power-tuning` | Aggressive | Aggressive, VMReset | Exhaustive power tuning (throttling, fast boot, core parking, device PM) |
| 7 | `tweaks-nic-power-management` | Moderate | Balanced, Aggressive, VMReset | Disable NIC power-management and wake policies on active physical adapters |
| 7 | `tweaks-memory-disk` | Aggressive | Aggressive, VMReset | Disable prefetch, RAM compression, Storage Sense, and NTFS last access updates |
| 7 | `tweaks-input-maintenance` | Aggressive | Aggressive, VMReset | Disable mouse acceleration, suppress the text input service, tune timer policy, and disable scheduled maintenance tasks |
| 7 | `tweaks-timer-resolution` | Aggressive | Aggressive, VMReset | Install 0.5ms timer resolution service |
| 7 | `tweaks-store-search` | Moderate | Minimal, Balanced, Aggressive, VMReset | Disable Microsoft Store search results |
| 7 | `tweaks-ipv6` | Moderate | Balanced, Aggressive, VMReset | Disable IPv6 on all adapters when explicitly requested |
| 8 | `external-wallpaper-v3` | Safe | Balanced, Aggressive, VMReset | Apply wallpaper to desktop |
| 8 | `external-tcp-optimizer` | Aggressive | Aggressive, VMReset | Apply TCP optimizations and verify with TCP Optimizer |
| 8 | `external-oosu` | Moderate | Minimal, Balanced, Aggressive, VMReset | Configure privacy with O&O ShutUp10 |
| 8 | `external-system-properties` | Safe | Aggressive | Open Advanced System Settings |
| 8 | `external-network-connections-shortcut` | Safe | Balanced, Aggressive, VMReset | Create Network Connections shortcut and pin to Start |
| 9 | `install-finalize-packages-v2` | Moderate | Minimal, Balanced, Aggressive, VMReset | Finalize background package installations |
| 9 | `cleanup-temp-files` | Safe | Minimal, Balanced, Aggressive, VMReset | Clean temporary files |
| 9 | `cleanup-retry-failed` | Safe | Minimal, Balanced, Aggressive, VMReset | Retry failed tasks and report anything still unresolved |
| 9 | `cleanup-autologin-secrets` | Moderate | Minimal, Balanced, Aggressive, VMReset | Remove autologin registry values and Hunter-managed secrets after setup completes |
| 9 | `cleanup-disk-cleanup` | Safe | Minimal, Balanced, Aggressive, VMReset | Run Windows Disk Cleanup |
| 9 | `cleanup-explorer-restart` | Safe | Minimal, Balanced, Aggressive, VMReset | Restart Explorer with pending changes |
| 9 | `cleanup-export-log` | Safe | Minimal, Balanced, Aggressive, VMReset | Export operation report to desktop |
| 10 | `validation-post-run-state` | Safe | Minimal, Balanced, Aggressive, VMReset | Validate critical registry, service, and power-plan changes after execution |
