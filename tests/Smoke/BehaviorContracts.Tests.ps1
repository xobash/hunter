Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Behavior contracts' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        . (Join-Path $repoRoot 'src/Hunter/Private/System/Detection.ps1')
        . (Join-Path $repoRoot 'src/Hunter/Private/Common/PathPolicy.ps1')
        . (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Catalog.ps1')
        $appRemovalSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Apps/AppRemoval.ps1') -Raw -ErrorAction Stop
        $commonSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Common/Common.ps1') -Raw -ErrorAction Stop
        $configSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Bootstrap/Config.ps1') -Raw -ErrorAction Stop
        $cleanupSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Cleanup.ps1') -Raw -ErrorAction Stop
        $copilotSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/OneDriveCopilot.ps1') -Raw -ErrorAction Stop
        $detectionSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/System/Detection.ps1') -Raw -ErrorAction Stop
        $engineSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Execution/Engine.ps1') -Raw -ErrorAction Stop
        $edgeSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Edge.ps1') -Raw -ErrorAction Stop
        $explorerSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Explorer.ps1') -Raw -ErrorAction Stop
        $featuresSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Features.ps1') -Raw -ErrorAction Stop
        $hardwareSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Hardware.ps1') -Raw -ErrorAction Stop
        $hunterSource = Get-Content -Path (Join-Path $repoRoot 'hunter.ps1') -Raw -ErrorAction Stop
        $interactionSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/System/Interaction.ps1') -Raw -ErrorAction Stop
        $nativeSystemSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Infrastructure/NativeSystem.ps1') -Raw -ErrorAction Stop
        $packageHelpersSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Packages/Helpers.ps1') -Raw -ErrorAction Stop
        $pathPolicySource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Common/PathPolicy.ps1') -Raw -ErrorAction Stop
        $privacySource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Privacy.ps1') -Raw -ErrorAction Stop
        $preflightSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Preflight.ps1') -Raw -ErrorAction Stop
        $readmeSource = Get-Content -Path (Join-Path $repoRoot 'README.md') -Raw -ErrorAction Stop
        $registryOpsSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Registry/Operations.ps1') -Raw -ErrorAction Stop
        $rollbackSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/State/Rollback.ps1') -Raw -ErrorAction Stop
        $serviceControlSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Services/ServiceControl.ps1') -Raw -ErrorAction Stop
        $taskbarOpsSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Shortcuts/TaskbarOps.ps1') -Raw -ErrorAction Stop
        $uiSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/UI.ps1') -Raw -ErrorAction Stop
        $userSetupSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Core/UserSetup.ps1') -Raw -ErrorAction Stop
    }

    BeforeEach {
        $script:WindowsBuildContext = [pscustomobject]@{
            CurrentBuild = 19045
            UBR = 0
            DisplayVersion = '22H2'
            ReleaseId = '22H2'
            ProductName = 'Windows 10'
            IsWindows11 = $false
            IsWindows10 = $true
        }
        $script:HunterRoot = 'C:\ProgramData\Hunter'
    }

    It 'treats Windows 10 22H2 as inside the Windows 10 build range' {
        Test-WindowsBuildInRange -MinBuild 10240 -MaxBuild 22000 | Should -BeTrue
    }

    It 'rejects a Windows 11 minimum build on Windows 10' {
        Test-WindowsBuildInRange -MinBuild 22000 | Should -BeFalse
    }

    It 'rejects ranges whose maximum build is below the current build' {
        Test-WindowsBuildInRange -MaxBuild 18363 | Should -BeFalse
    }

    It 'keeps retry cleanup as warning/reporting rather than a synthetic failed task' {
        $cleanupSource | Should -Match "Status\s*=\s*'CompletedWithWarnings'"
        $cleanupSource | Should -Not -Match 'return \(@\(\$script:FailedTasks\)\.Count -eq 0\)'
    }

    It 'allows optional MaxBuild keys in Copilot registry settings under strict mode' {
        $copilotSource | Should -Match "ContainsKey\('MaxBuild'\)"
        $copilotSource | Should -Not -Match '-MaxBuild \$setting\.MaxBuild'
    }

    It 'returns a single wallpaper asset path string without leaking Ensure-Directory output' {
        $wallpaperPath = Get-WallpaperAssetPath -WallpaperUrl 'https://example.com/wallpaper.png'

        $wallpaperPath | Should -BeOfType ([string])
        $wallpaperPath | Should -BeExactly 'C:\ProgramData\Hunter\Assets\hunter-wallpaper.png'
    }

    It 'blocks Windows Update driver installation before package downloads begin' {
        $taskIds = @((Get-HunterTaskCatalog).Id)

        [array]::IndexOf($taskIds, 'preflight-driver-install-block') | Should -BeGreaterThan -1
        [array]::IndexOf($taskIds, 'preflight-driver-install-block') | Should -BeLessThan ([array]::IndexOf($taskIds, 'preflight-predownload-v2'))
        $hardwareSource | Should -Match 'ExcludeWUDriversInQualityUpdate'
        $hardwareSource | Should -Match 'PreventDeviceMetadataFromNetwork'
        $hardwareSource | Should -Match 'SearchOrderConfig'
        $hardwareSource | Should -Match "Stop-ServiceIfPresent -Name 'wuauserv'"
        $hardwareSource | Should -Match "Set-ServiceStartType -Name 'wuauserv' -StartType 'Disabled'"
    }

    It 'avoids blocking DISM PowerShell cmdlets for edition and optional-feature handling' {
        $detectionSource | Should -Not -Match 'Get-WindowsEdition\s+-Online'
        $nativeSystemSource | Should -Not -Match 'Get-WindowsOptionalFeature\s+-Online'
        $nativeSystemSource | Should -Not -Match 'Disable-WindowsOptionalFeature\s+-Online'
        $nativeSystemSource | Should -Match 'dism\.exe'
        $nativeSystemSource | Should -Match 'Invoke-NativeCommandWithTimeout'
    }

    It 'temporarily restores Windows Modules Installer before optional-feature servicing' {
        $nativeSystemSource | Should -Match 'function Invoke-WithOptionalFeatureServicingPrerequisites'
        $nativeSystemSource | Should -Match "TrustedInstaller"
        $hardwareSource | Should -Match 'Invoke-WithOptionalFeatureServicingPrerequisites'
    }

    It 'keeps the speculative-execution override opt-in and the latency/network overrides aligned' {
        $hardwareSource | Should -Match 'FeatureSettingsOverride'
        $hardwareSource | Should -Match 'FeatureSettingsOverrideMask'
        $hardwareSource | Should -Match 'Resolve-DisableCpuMitigationsPreference'
        $hardwareSource | Should -Match 'Disable-NetAdapterRsc'
        $hardwareSource | Should -Match "SystemResponsiveness' -Value 0"
        $hardwareSource | Should -Match "tscsyncpolicy', 'Enhanced'"
    }

    It 'uses a recovery-enabled TDR default and pushes risky storage or audio tweaks behind explicit opt-ins' {
        $hardwareSource | Should -Match "TdrLevel' -Value 3"
        $hardwareSource | Should -Match 'Resolve-ForceStorageOptimizationPreference'
        $hardwareSource | Should -Match 'Resolve-DisableAudioEnhancementsPreference'
        $hardwareSource | Should -Match 'Resolve-DisableSystemSoundsPreference'
        $hardwareSource | Should -Match 'Get-HunterStorageMediaContext'
        $hardwareSource | Should -Match 'Skipping prefetch and SysMain policy changes because rotational storage was detected'
        $interactionSource | Should -Match 'HUNTER_FORCE_STORAGE_OPTIMIZATION=1'
        $interactionSource | Should -Match 'HUNTER_DISABLE_AUDIO_ENHANCEMENTS=1'
        $interactionSource | Should -Match 'HUNTER_DISABLE_SYSTEM_SOUNDS=1'
    }

    It 'runs O&O ShutUp10 quiet imports without restore-point prompts and keeps the preset beside the executable' {
        $hardwareSource | Should -Match '/nosrp'
        $hardwareSource | Should -Match 'WorkingDirectory \$oosuWorkingDirectory'
        $pathPolicySource | Should -Match "Join-Path \\$script:DownloadDir 'ooshutup10_winutil_settings\.cfg'"
    }

    It 'skips third-party external tool execution by default unless explicitly requested' {
        $interactionSource | Should -Match 'HUNTER_RUN_TCP_OPTIMIZER=1'
        $interactionSource | Should -Match 'HUNTER_RUN_OOSU=1'
        $hardwareSource | Should -Match 'Resolve-RunTcpOptimizerPreference'
        $hardwareSource | Should -Match 'Resolve-RunOOSUPreference'
        $hardwareSource | Should -Match 'third-party verification utility was skipped by default'
        $hunterSource | Should -Match '\.PARAMETER RunTcpOptimizer'
        $hunterSource | Should -Match '\.PARAMETER RunOOSU'
        $hunterSource | Should -Match '\[switch\]\$RunTcpOptimizer'
        $hunterSource | Should -Match '\[switch\]\$RunOOSU'
    }

    It 'sets the TCP Optimizer WinINet connection caps to 10 for current and default users' {
        $hardwareSource | Should -Match "MaxConnectionsPer1_0Server'; Value = 10"
        $hardwareSource | Should -Match "MaxConnectionsPerServer'; Value = 10"
        $hardwareSource | Should -Match 'Set-DwordBatchForAllUsers'
    }

    It 'suppresses the text input service and preserves REG_EXPAND_SZ verification for the advanced redirect' {
        $hardwareSource | Should -Match 'InputServiceEnabled'
        $hardwareSource | Should -Match 'InputServiceEnabledForCCI'
        $hardwareSource | Should -Match 'TextInputManagementService\\Parameters'
        $hardwareSource | Should -Match 'TabSvc\.dll'
        $hardwareSource | Should -Match 'MSCTF\.DLL'
        $hardwareSource | Should -Match 'Resolve-ForceTextInputServiceRedirectPreference'
        $interactionSource | Should -Match 'HUNTER_FORCE_TEXT_INPUT_SERVICE_REDIRECT=1'
        $registryOpsSource | Should -Match 'DoNotExpandEnvironmentNames'
        $registryOpsSource | Should -Match 'RegistryValueKind\]::ExpandString'
    }

    It 'adds WinUtil-aligned WPBT, Explorer visibility, and diagnostic preference coverage' {
        $uiSource | Should -Match 'IsBatteryPercentageEnabled'
        $uiSource | Should -Match 'Get-HunterPowerPlatformContext'
        $explorerSource | Should -Match "HideFileExt' -Value 0"
        $explorerSource | Should -Match "Hidden' -Value 1"
        $featuresSource | Should -Match 'DisableWpbtExecution'
        $featuresSource | Should -Match 'DisplayParameters'
        $featuresSource | Should -Match 'DisableEmoticon'
        $featuresSource | Should -Match 'VerboseStatus'
        $featuresSource | Should -Match 'InitialKeyboardIndicators'
        $registryOpsSource | Should -Match 'HKEY_USERS'
    }

    It 'adds Windows Recall suppression for supported 24H2 builds' {
        $privacySource | Should -Match 'Test-WindowsBuildInRange -MinBuild 26100'
        $privacySource | Should -Match "AllowRecallEnablement' -Value 0"
        $privacySource | Should -Match "DisableAIDataAnalysis' -Value 1"
        $privacySource | Should -Match "Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Recall'"
    }

    It 'requires explicit user consent for standard user creation and autologin' {
        $configSource | Should -Match '\$script:ConfigureAutologin = \$null'
        $interactionSource | Should -Match 'function Resolve-CreateLocalUserPreference'
        $interactionSource | Should -Match 'function Initialize-HunterInteractivePreferences'
        $interactionSource | Should -Match 'Capturing standard-user setup consent before the progress overlay starts'
        $interactionSource | Should -Match 'Standard user consent was requested after the progress overlay started'
        $interactionSource | Should -Match "-Title 'Hunter Standard User'"
        $interactionSource | Should -Match 'Skipping this account also skips autologin'
        $interactionSource | Should -Match 'Skipping standard user creation in automation-safe mode because Hunter requires explicit user consent for this step'
        $interactionSource | Should -Not -Match '\$script:CreateLocalUser = \$true'
        $interactionSource | Should -Match 'function Resolve-ConfigureAutologinPreference'
        $interactionSource | Should -Match 'Autologin consent was requested after the progress overlay started'
        $interactionSource | Should -Match "-Title 'Hunter Autologin'"
        $interactionSource | Should -Match 'Configure automatic sign-in'
        $interactionSource | Should -Match 'Skipping autologin in automation-safe mode because Hunter requires explicit user consent for this step'
        $interactionSource | Should -Not -Match '\$script:ConfigureAutologin = \$true'
        $userSetupSource | Should -Match 'Resolve-ConfigureAutologinPreference'
        $userSetupSource | Should -Match 'Autologin declined by user'
        $userSetupSource | Should -Match "Get-NativeSystemExecutablePath -FileName 'net\.exe'"
        $userSetupSource | Should -Match 'Invoke-NativeCommandWithTimeout'
        $hunterSource | Should -Match 'Initialize-HunterInteractivePreferences -Tasks \$tasks -Context \$context'
        $hunterSource.IndexOf('Initialize-HunterInteractivePreferences -Tasks $tasks -Context $context') | Should -BeLessThan $hunterSource.IndexOf('Start-ProgressWindow')
    }

    It 'creates restore points automatically in interactive runs and logs a full execution plan with profile-aware risk levels' {
        $preflightSource | Should -Not -Match 'Show-YesNoDialog'
        $preflightSource | Should -Match 'Interactive run detected; creating a restore point before Hunter continues.'
        $preflightSource | Should -Match "Get-HunterRegistryValueSnapshot -Path \\$systemRestorePath -Name 'SystemRestorePointCreationFrequency'"
        $preflightSource | Should -Not -Match "Get-ItemProperty -Path \\$systemRestorePath -Name 'SystemRestorePointCreationFrequency'"
        $hunterSource | Should -Match 'function Write-HunterExecutionPlan'
        $hunterSource | Should -Match 'PLANNED EXECUTION SUMMARY:'
        $hunterSource | Should -Match 'Dry-run preview complete\. Re-run without -WhatIf to execute the selected profile\.'
        $hunterSource | Should -Match 'Preview Only:'
        $hunterSource | Should -Match 'Profile:\s+\$\(\$script:SelectedProfile\)'
        $hunterSource | Should -Match "'Aggressive', 'Moderate', 'Safe'"
        $hunterSource | Should -Match '\[\{0\}\] \{1\} - \{2\}'
        $engineSource | Should -Match 'return \[pscustomobject\]@{'
    }

    It 'publishes a no-progress bootstrap command and bounds cloud app removal waits' {
        $readmeSource | Should -Match '\$ProgressPreference=''SilentlyContinue''; irm https://raw\.githubusercontent\.com/xobash/hunter/main/hunter\.ps1 \| iex'
        $appRemovalSource | Should -Match 'Starting WinGet uninstall'
        $appRemovalSource | Should -Match 'ExecutionTimeoutSeconds \$wingetUninstallTimeoutSeconds'
        $copilotSource | Should -Match 'Invoke-NativeCommandWithTimeout'
        $edgeSource | Should -Match 'Invoke-NativeCommandWithTimeout'
        $edgeSource | Should -Match 'edgeUninstallTimeoutSeconds'
        $packageHelpersSource | Should -Match "Invoke-WithNamedSemaphore -Name 'Global\\HunterWingetInstall'"
        $packageHelpersSource | Should -Not -Match '(?m)^\s*\}\)\s*$'
    }

    It 'captures storage and power-platform context for hardware-aware guardrails and exposes a validation phase' {
        $commonSource | Should -Match '\$\{prefix\} \$\{Name\}: \$Detail'
        $detectionSource | Should -Match 'function Get-HunterStorageMediaContext'
        $detectionSource | Should -Match 'Get-PhysicalDisk'
        $detectionSource | Should -Match 'Win32_DiskDrive'
        $detectionSource | Should -Match 'function Get-HunterPowerPlatformContext'
        $detectionSource | Should -Match 'Win32_Battery'
        $detectionSource | Should -Match 'Win32_ComputerSystem'
        $hardwareSource | Should -Match 'Get-HunterPowerPlatformContext'
        $cleanupSource | Should -Match 'function Invoke-ValidateAppliedConfiguration'
        $cleanupSource | Should -Match '\[VERIFY\] PASS'
        $cleanupSource | Should -Match 'VALIDATION CHECKS'
    }

    It 'keeps only safe UI and Explorer phases parallelized and defers rollback persistence to the main thread' {
        $engineSource | Should -Match "\$script:ParallelPhases = @\('3', '4'\)"
        $engineSource | Should -Match 'function Get-HunterTaskRunspaceMaxConcurrency'
        $engineSource | Should -Match 'HUNTER_TASK_MAX_CONCURRENCY'
        $engineSource | Should -Match '\$script:DeferRollbackPersistence = \$true'
        $rollbackSource | Should -Match 'function Save-HunterRollbackArtifacts'
        $rollbackSource | Should -Match 'Save-HunterRollbackArtifacts'
        $serviceControlSource | Should -Match 'function Get-HunterScheduledTaskState'
        $serviceControlSource | Should -Match 'schtasks\.exe'
        $taskbarOpsSource | Should -Match "Hunter-TaskbarPolicyCleanup"
        $taskbarOpsSource | Should -Not -Match "Get-ScheduledTask -TaskName 'Hunter-TaskbarPolicyCleanup'"
    }
}
