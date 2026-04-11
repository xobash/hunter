function Get-HunterTaskCatalog {
    return @(
        [pscustomobject]@{ Id = 'preflight-internet'; Phase = '1'; Handler = { Invoke-VerifyInternetConnectivity }; Description = 'Verify internet connectivity' }
        [pscustomobject]@{ Id = 'preflight-edition-compatibility'; Phase = '1'; Handler = { Invoke-ValidateSupportedWindowsEdition }; Description = 'Validate supported Windows edition and set Store/AppX compatibility gates' }
        [pscustomobject]@{ Id = 'preflight-restore-point'; Phase = '1'; Handler = { Invoke-CreateRestorePoint }; Description = 'Create Windows System Restore point' }
        [pscustomobject]@{ Id = 'preflight-winget-version'; Phase = '1'; Handler = { Invoke-EnsureWingetMinVersion }; Description = 'Validate Hunter minimum winget version and refresh App Installer if needed' }
        [pscustomobject]@{ Id = 'preflight-app-downloads'; Phase = '1'; Handler = { Invoke-ConfirmAppDownloads }; Description = 'Choose whether to skip app downloads and installs' }
        [pscustomobject]@{ Id = 'preflight-predownload-v2'; Phase = '1'; Handler = { Invoke-PreDownloadInstallers }; Description = 'Start background package downloads and installs' }
        [pscustomobject]@{ Id = 'install-launch-packages-v2'; Phase = '2'; Handler = { Invoke-ParallelInstalls -LaunchOnly }; Description = 'Ensure package installers are running in parallel' }
        [pscustomobject]@{ Id = 'core-local-user-v2'; Phase = '2'; Handler = { Invoke-EnsureLocalStandardUser }; Description = 'Ensure standard local user exists' }
        [pscustomobject]@{ Id = 'core-autologin-v2'; Phase = '2'; Handler = { Invoke-ConfigureAutologin }; Description = 'Configure autologin for standard user' }
        [pscustomobject]@{ Id = 'core-dark-mode'; Phase = '2'; Handler = { Invoke-EnableDarkMode }; Description = 'Enable Windows dark mode theme' }
        [pscustomobject]@{ Id = 'core-ultimate-performance'; Phase = '2'; Handler = { Invoke-ActivateUltimatePerformance }; Description = 'Activate Ultimate Performance power plan' }
        [pscustomobject]@{ Id = 'startui-bing-search'; Phase = '3'; Handler = { Invoke-DisableBingStartSearch }; Description = 'Disable Bing search in Start Menu' }
        [pscustomobject]@{ Id = 'startui-start-recommendations-v4'; Phase = '3'; Handler = { Invoke-DisableStartRecommendations }; Description = 'Disable Start Menu recommendations' }
        [pscustomobject]@{ Id = 'startui-search-box'; Phase = '3'; Handler = { Invoke-DisableTaskbarSearchBox }; Description = 'Disable taskbar search box' }
        [pscustomobject]@{ Id = 'startui-task-view'; Phase = '3'; Handler = { Invoke-DisableTaskViewButton }; Description = 'Disable Task View button' }
        [pscustomobject]@{ Id = 'startui-widgets'; Phase = '3'; Handler = { Invoke-DisableWidgets }; Description = 'Disable Windows Widgets' }
        [pscustomobject]@{ Id = 'startui-end-task'; Phase = '3'; Handler = { Invoke-EnableEndTaskOnTaskbar }; Description = 'Enable End Task option on taskbar' }
        [pscustomobject]@{ Id = 'startui-notifications'; Phase = '3'; Handler = { Invoke-DisableNotificationsTrayCalendar }; Description = 'Disable notifications, tray, and calendar' }
        [pscustomobject]@{ Id = 'startui-new-outlook'; Phase = '3'; Handler = { Invoke-DisableNewOutlook }; Description = 'Disable new Outlook and auto-migration' }
        [pscustomobject]@{ Id = 'startui-settings-home'; Phase = '3'; Handler = { Invoke-HideSettingsHome }; Description = 'Hide Settings home page' }
        [pscustomobject]@{ Id = 'explorer-home-thispc'; Phase = '4'; Handler = { Invoke-SetExplorerHomeThisPC }; Description = 'Set Explorer home to This PC' }
        [pscustomobject]@{ Id = 'explorer-remove-home-v2'; Phase = '4'; Handler = { Invoke-RemoveExplorerHomeTab }; Description = 'Remove Home tab from Explorer' }
        [pscustomobject]@{ Id = 'explorer-remove-gallery-v2'; Phase = '4'; Handler = { Invoke-RemoveExplorerGalleryTab }; Description = 'Remove Gallery tab from Explorer' }
        [pscustomobject]@{ Id = 'explorer-remove-onedrive'; Phase = '4'; Handler = { Invoke-RemoveExplorerOneDriveTab }; Description = 'Remove OneDrive tab from Explorer' }
        [pscustomobject]@{ Id = 'explorer-auto-discovery'; Phase = '4'; Handler = { Invoke-DisableExplorerAutoFolderDiscovery }; Description = 'Disable Explorer automatic folder discovery' }
        [pscustomobject]@{ Id = 'cloud-edge-remove'; Phase = '5'; Handler = { Invoke-RemoveEdgeKeepWebView2 }; Description = 'Remove Microsoft Edge' }
        [pscustomobject]@{ Id = 'cloud-edge-pins'; Phase = '5'; Handler = { Invoke-RemoveEdgePinsAndShortcuts }; Description = 'Remove Edge pins and shortcuts' }
        [pscustomobject]@{ Id = 'cloud-edge-update-block'; Phase = '5'; Handler = { Invoke-DisableEdgeUpdateInfrastructure }; Description = 'Disable Edge update tasks and services while preserving WebView2' }
        [pscustomobject]@{ Id = 'cloud-onedrive-remove'; Phase = '5'; Handler = { Invoke-RemoveOneDrive }; Description = 'Remove Microsoft OneDrive' }
        [pscustomobject]@{ Id = 'cloud-onedrive-backup'; Phase = '5'; Handler = { Invoke-DisableOneDriveFolderBackup }; Description = 'Disable OneDrive folder backup' }
        [pscustomobject]@{ Id = 'cloud-copilot-remove'; Phase = '5'; Handler = { Invoke-RemoveCopilot }; Description = 'Remove Copilot AI assistant' }
        [pscustomobject]@{ Id = 'apps-consumer-features'; Phase = '6'; Handler = { Invoke-DisableConsumerFeatures }; Description = 'Disable consumer experience features' }
        [pscustomobject]@{ Id = 'apps-nuke-block'; Phase = '6'; Handler = { Invoke-NukeBlockApps }; Description = 'Remove and block broad Microsoft bloatware (including Xbox/Game Bar)' }
        [pscustomobject]@{ Id = 'apps-inking-typing'; Phase = '6'; Handler = { Invoke-DisableInkingTyping }; Description = 'Disable Inking and Typing data collection' }
        [pscustomobject]@{ Id = 'apps-delivery-opt'; Phase = '6'; Handler = { Invoke-DisableDeliveryOptimization }; Description = 'Disable Delivery Optimization' }
        [pscustomobject]@{ Id = 'apps-activity-history'; Phase = '6'; Handler = { Invoke-DisableActivityHistory }; Description = 'Disable activity history plus clipboard/cloud clipboard tracking' }
        [pscustomobject]@{ Id = 'tweaks-services'; Phase = '7'; Handler = { Invoke-SetServiceProfileManual }; Description = 'Apply Hunter aggressive service startup profile' }
        [pscustomobject]@{ Id = 'tweaks-virtualization-security'; Phase = '7'; Handler = { Invoke-DisableVirtualizationSecurityOverhead }; Description = 'Disable HVCI, Hyper-V side features, Sandbox, and Application Guard' }
        [pscustomobject]@{ Id = 'tweaks-telemetry'; Phase = '7'; Handler = { Invoke-DisableTelemetry }; Description = 'Disable telemetry plus Hunter privacy/web-content policies' }
        [pscustomobject]@{ Id = 'tweaks-location'; Phase = '7'; Handler = { Invoke-DisableLocationTracking }; Description = 'Disable location tracking' }
        [pscustomobject]@{ Id = 'tweaks-hibernation'; Phase = '7'; Handler = { Invoke-DisableHibernation }; Description = 'Disable hibernation mode' }
        [pscustomobject]@{ Id = 'tweaks-background-apps'; Phase = '7'; Handler = { Invoke-DisableBackgroundApps }; Description = 'Disable background apps plus OneDrive, Widgets, and Edge background activity' }
        [pscustomobject]@{ Id = 'tweaks-teredo'; Phase = '7'; Handler = { Invoke-DisableTeredo }; Description = 'Disable Teredo tunneling protocol' }
        [pscustomobject]@{ Id = 'tweaks-fso'; Phase = '7'; Handler = { Invoke-DisableFullscreenOptimizations }; Description = 'Disable fullscreen optimizations' }
        [pscustomobject]@{ Id = 'tweaks-graphics-scheduling'; Phase = '7'; Handler = { Invoke-ApplyGraphicsSchedulingTweaks }; Description = 'Apply HAGS, MPO, VRR, Game Bar, Auto HDR, and TDR graphics tweaks' }
        [pscustomobject]@{ Id = 'tweaks-gpu-interrupt-affinity'; Phase = '7'; Handler = { Invoke-ConfigureGpuInterruptAffinity }; Description = 'Pin GPU interrupts to a non-primary logical processor on supported single-group systems' }
        [pscustomobject]@{ Id = 'tweaks-rebar-audit'; Phase = '7'; Handler = { Invoke-AuditResizableBarSupport }; Description = 'Audit GPU family compatibility for Resizable BAR and document firmware-managed status' }
        [pscustomobject]@{ Id = 'tweaks-dwm-frame-interval'; Phase = '7'; Handler = { Invoke-SetDwmFrameInterval }; Description = 'Set DWM frame interval to 15' }
        [pscustomobject]@{ Id = 'tweaks-ui-desktop'; Phase = '7'; Handler = { Invoke-ApplyUiDesktopPerformanceTweaks }; Description = 'Reduce transparency, animations, and desktop compositor overhead' }
        [pscustomobject]@{ Id = 'tweaks-razer'; Phase = '7'; Handler = { Invoke-BlockRazerSoftware }; Description = 'Block Razer software network access' }
        [pscustomobject]@{ Id = 'tweaks-adobe'; Phase = '7'; Handler = { Invoke-BlockAdobeNetworkTraffic }; Description = 'Block Adobe software network traffic' }
        [pscustomobject]@{ Id = 'tweaks-power-tuning'; Phase = '7'; Handler = { Invoke-ExhaustivePowerTuning }; Description = 'Exhaustive power tuning (throttling, fast boot, core parking, device PM)' }
        [pscustomobject]@{ Id = 'tweaks-nic-power-management'; Phase = '7'; Handler = { Invoke-DisableNicPowerManagement }; Description = 'Disable NIC power-management and wake policies on active physical adapters' }
        [pscustomobject]@{ Id = 'tweaks-memory-disk'; Phase = '7'; Handler = { Invoke-ApplyMemoryDiskBehaviorTweaks }; Description = 'Disable prefetch, RAM compression, Storage Sense, and NTFS last access updates' }
        [pscustomobject]@{ Id = 'tweaks-input-maintenance'; Phase = '7'; Handler = { Invoke-ApplyInputAndMaintenanceTweaks }; Description = 'Disable mouse acceleration, tune timer policy, and defer maintenance tasks to 3am' }
        [pscustomobject]@{ Id = 'tweaks-timer-resolution'; Phase = '7'; Handler = { Invoke-InstallTimerResolutionService }; Description = 'Install 0.5ms timer resolution service' }
        [pscustomobject]@{ Id = 'tweaks-store-search'; Phase = '7'; Handler = { Invoke-DisableStoreSearch }; Description = 'Disable Microsoft Store search results' }
        [pscustomobject]@{ Id = 'tweaks-ipv6'; Phase = '7'; Handler = { Invoke-DisableIPv6 }; Description = 'Disable IPv6 on all adapters when explicitly requested' }
        [pscustomobject]@{ Id = 'external-wallpaper-v3'; Phase = '8'; Handler = { Invoke-ApplyWallpaperEverywhere }; Description = 'Apply wallpaper to desktop' }
        [pscustomobject]@{ Id = 'external-tcp-optimizer'; Phase = '8'; Handler = { Invoke-ApplyTcpOptimizerTutorialProfile }; Description = 'Apply TCP optimizations and verify with TCP Optimizer' }
        [pscustomobject]@{ Id = 'external-oosu'; Phase = '8'; Handler = { Invoke-ApplyOOSUSilentRecommendedPlusSomewhat }; Description = 'Configure privacy with O&O ShutUp10' }
        [pscustomobject]@{ Id = 'external-system-properties'; Phase = '8'; Handler = { Invoke-OpenAdvancedSystemSettings }; Description = 'Open Advanced System Settings' }
        [pscustomobject]@{ Id = 'external-network-connections-shortcut'; Phase = '8'; Handler = { Invoke-CreateNetworkConnectionsShortcut }; Description = 'Create Network Connections shortcut and pin to Start' }
        [pscustomobject]@{ Id = 'install-finalize-packages-v2'; Phase = '9'; Handler = { Invoke-ParallelInstalls }; Description = 'Finalize background package installations' }
        [pscustomobject]@{ Id = 'cleanup-temp-files'; Phase = '9'; Handler = { Invoke-DeleteTempFiles }; Description = 'Clean temporary files' }
        [pscustomobject]@{ Id = 'cleanup-retry-failed'; Phase = '9'; Handler = { Invoke-RetryFailedTasks }; Description = 'Retry any failed tasks' }
        [pscustomobject]@{ Id = 'cleanup-autologin-secrets'; Phase = '9'; Handler = { Invoke-ClearAutologinSecrets }; Description = 'Remove autologin registry values and Hunter-managed secrets after setup completes' }
        [pscustomobject]@{ Id = 'cleanup-disk-cleanup'; Phase = '9'; Handler = { Invoke-RunDiskCleanup }; Description = 'Run Windows Disk Cleanup' }
        [pscustomobject]@{ Id = 'cleanup-explorer-restart'; Phase = '9'; Handler = { Invoke-DeferredExplorerRestart }; Description = 'Restart Explorer with pending changes' }
        [pscustomobject]@{ Id = 'cleanup-export-log'; Phase = '9'; Handler = { Invoke-ExportDesktopOperationLog }; Description = 'Export operation report to desktop' }
    )
}
