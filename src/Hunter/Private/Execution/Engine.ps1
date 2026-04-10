function Load-Checkpoint {
    try {
        if (Test-Path $script:CheckpointPath) {
            $checkpointData = Get-Content -Path $script:CheckpointPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            $checkpointTaskIds = @()
            $legacyCheckpointFormat = $false

            if ($null -ne $checkpointData -and $checkpointData -is [System.Collections.IEnumerable] -and $checkpointData -isnot [string]) {
                $checkpointTaskIds = @($checkpointData)
                $legacyCheckpointFormat = $true
            } elseif ($null -ne $checkpointData) {
                $schemaVersion = $null
                if ($null -ne $checkpointData.PSObject.Properties['SchemaVersion']) {
                    $schemaVersion = [int]$checkpointData.SchemaVersion
                }

                if ($null -eq $schemaVersion) {
                    throw 'Checkpoint payload did not include SchemaVersion.'
                }

                if ($schemaVersion -ne [int]$script:CheckpointSchemaVersion) {
                    throw "Checkpoint schema version $schemaVersion is not supported by this Hunter build."
                }

                if ($null -eq $checkpointData.PSObject.Properties['CompletedTasks']) {
                    throw 'Checkpoint payload did not include CompletedTasks.'
                }

                $checkpointTaskIds = @($checkpointData.CompletedTasks)
            } else {
                throw 'Checkpoint content was empty.'
            }

            $normalizedCheckpointTasks = New-Object 'System.Collections.Generic.List[string]'
            foreach ($checkpointTaskId in @($checkpointTaskIds)) {
                $taskId = [string]$checkpointTaskId
                if ([string]::IsNullOrWhiteSpace($taskId)) {
                    continue
                }

                $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $taskId
                if (-not $normalizedCheckpointTasks.Contains($resolvedTaskId)) {
                    [void]$normalizedCheckpointTasks.Add($resolvedTaskId)
                }
            }

            $script:CompletedTasks = @($normalizedCheckpointTasks.ToArray())
            if ($legacyCheckpointFormat) {
                Write-Log "Legacy checkpoint format detected. Rewriting checkpoint using schema version $($script:CheckpointSchemaVersion)." 'WARN'
                Save-Checkpoint
            }

            Write-Log "Checkpoint loaded: $($script:CompletedTasks.Count) tasks completed"
            return
        } else {
            $script:CompletedTasks = @()
            Write-Log "No checkpoint found, starting fresh"
            return
        }
    } catch {
        $script:CompletedTasks = @()
        Add-RunInfrastructureIssue -Message "Failed to load checkpoint state; starting without resume data: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Save-Checkpoint {
    try {
        Initialize-HunterDirectory (Split-Path -Parent $script:CheckpointPath)
        $tmpCheckpointPath = '{0}.tmp' -f $script:CheckpointPath
        [ordered]@{
            SchemaVersion = [int]$script:CheckpointSchemaVersion
            SavedAt       = (Get-Date).ToString('o')
            CompletedTasks = @($script:CompletedTasks)
        } | ConvertTo-Json -Depth 3 | Set-Content -Path $tmpCheckpointPath -Encoding UTF8 -Force
        Move-Item -Path $tmpCheckpointPath -Destination $script:CheckpointPath -Force
        Write-Log "Checkpoint saved: $($script:CompletedTasks.Count) tasks"
    } catch {
        Add-RunInfrastructureIssue -Message "Failed to persist checkpoint state: $($_.Exception.Message)" -Level 'ERROR'
    }
}

function Resolve-TaskCheckpointId {
    param([string]$TaskId)

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return $TaskId
    }

    if ($script:CheckpointAliases.ContainsKey($TaskId)) {
        return $script:CheckpointAliases[$TaskId]
    }

    return $TaskId
}

function Test-TaskCompleted {
    param([string]$TaskId)

    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $TaskId
    return ($script:CompletedTasks -contains $resolvedTaskId)
}

function Add-CompletedTask {
    param([string]$TaskId)

    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $TaskId
    if (-not (Test-TaskCompleted -TaskId $resolvedTaskId)) {
        $script:CompletedTasks = @($script:CompletedTasks) + @($resolvedTaskId)
        Write-Log "Task marked completed: $resolvedTaskId"
    }
}

function New-Task {
    <#
    .SYNOPSIS
        Creates a new task object for the Hunter execution engine.

    .PARAMETER TaskId
        Unique identifier for the task (e.g., 'core-dark-mode')

    .PARAMETER Phase
        Phase number indicating execution order

    .PARAMETER ApplyHandler
        ScriptBlock that executes the task's main logic

    .PARAMETER Description
        Human-readable description of what the task does
    #>

    param(
        [string]$TaskId,
        [string]$Phase,
        [scriptblock]$ApplyHandler,
        [string]$Description = ''
    )

    return @{
        TaskId       = $TaskId
        Phase        = $Phase
        ApplyHandler = $ApplyHandler
        Description  = $Description
        Status       = 'Pending'
        Error        = $null
    }
}


function Invoke-TaskExecution {
    <#
    .SYNOPSIS
        Executes all tasks in order, with checkpoint recovery.

    .DESCRIPTION
        Iterates through each task, checking if already completed (via checkpoint),
        then executing the ApplyHandler. Handles success/failure logging and progress
        updates. Maintains task results for reporting.

    .PARAMETER Tasks
        Array of task objects created by Build-Tasks
    #>

    param(
        [array]$Tasks,
        [string[]]$SkipTask = @()
    )

    try {
        Write-Log "Starting task execution engine..." 'INFO'
        $requestedSkipTaskIds = @(
            $SkipTask |
                ForEach-Object { [string]$_ } |
                ForEach-Object { $_.Split(',') } |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )

        foreach ($task in $Tasks) {
            $completedCountBeforeTask = @($script:CompletedTasks).Count
            try {
                # Check if already completed
                if (Test-TaskCompleted -TaskId $task.TaskId) {
                    Write-Log "Task already completed (checkpoint): $($task.TaskId)" 'INFO'
                    $task.Status = 'Completed'
                    if (-not $script:TaskResults) {
                        $script:TaskResults = @{}
                    }
                    $script:TaskResults[$task.TaskId] = @{
                        Status = 'Completed'
                        Error  = $null
                    }
                    Update-ProgressState -Tasks $Tasks
                    continue
                }

                if ($requestedSkipTaskIds -contains [string]$task.TaskId) {
                    Write-Log "Task skipped by user request: $($task.TaskId)" 'INFO'
                    $task.Status = 'Skipped'
                    $task.Error = $null
                    if (-not $script:TaskResults) {
                        $script:TaskResults = @{}
                    }
                    $script:TaskResults[$task.TaskId] = @{
                        Status = 'Skipped'
                        Error  = $null
                    }
                    Update-ProgressState -Tasks $Tasks
                    continue
                }

                # Update status and progress
                $task.Status = 'Running'
                Update-ProgressState -Tasks $Tasks

                Write-Log "Executing task: $($task.TaskId) [Phase $($task.Phase)]" 'INFO'

                $script:CurrentTaskLoggedError = $false
                $script:CurrentTaskLoggedWarning = $false
                $taskResult = & $task.ApplyHandler
                if (Test-TaskHandlerReturnedFailure -TaskResult $taskResult -LoggedError:$script:CurrentTaskLoggedError) {
                    throw "Task handler returned failure for $($task.TaskId)"
                }

                $taskStatus = Get-TaskHandlerCompletionStatus -TaskResult $taskResult -LoggedWarning:$script:CurrentTaskLoggedWarning
                $task.Status = $taskStatus
                $task.Error = $null
                if ($taskStatus -ne 'Skipped') {
                    Add-CompletedTask -TaskId $task.TaskId
                }

                switch ($taskStatus) {
                    'CompletedWithWarnings' { Write-Log "Task completed with warnings: $($task.TaskId)" 'WARN' }
                    'Skipped' { Write-Log "Task skipped: $($task.TaskId)" 'INFO' }
                    default { Write-Log "Task completed: $($task.TaskId)" 'SUCCESS' }
                }

                # Store result
                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = $taskStatus
                    Error  = $null
                }

            } catch {
                # Failure
                $task.Status = 'Failed'
                $task.Error = $_.Exception.Message

                if (-not $script:FailedTasks) {
                    $script:FailedTasks = @()
                }
                if ($script:FailedTasks -notcontains $task.TaskId) {
                    $script:FailedTasks = @($script:FailedTasks) + @($task.TaskId)
                }

                Write-Log "Task failed: $($task.TaskId) - $($task.Error)" 'ERROR'

                # Store result
                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = 'Failed'
                    Error  = $task.Error
                }

                # Strict mode: abort on any task failure
                if ($script:StrictMode) {
                    Write-Log "STRICT MODE: Aborting run due to task failure: $($task.TaskId)" 'ERROR'
                    throw "Strict mode abort: task '$($task.TaskId)' failed - $($task.Error)"
                }
            } finally {
                Invoke-CollectCompletedParallelInstallJobs
                Invoke-CollectCompletedExternalAssetPrefetchJobs
                # Always update progress
                Update-ProgressState -Tasks $Tasks
                if (@($script:CompletedTasks).Count -ne $completedCountBeforeTask) {
                    Save-Checkpoint
                }
            }
        }

        if (@($script:FailedTasks).Count -gt 0) {
            Write-Log "Task execution engine complete with $(@($script:FailedTasks).Count) failed task(s)" 'WARN'
        } else {
            Write-Log "Task execution engine complete" 'SUCCESS'
        }

    } catch {
        Write-Log "Critical error in task execution engine: $_" 'ERROR'
        throw
    }
}

#=============================================================================
# BUILD-TASKS
#=============================================================================

function Build-Tasks {
    <#
    .SYNOPSIS
        Builds and returns the complete ordered task list for Hunter execution.

    .DESCRIPTION
        Constructs all tasks across 9 phases in proper execution order.
        Each task references an Invoke-* function from Parts A, B, or C.
        Tasks are organized by phase for logical dependency management.

    .OUTPUTS
        [array] Ordered task array suitable for Invoke-TaskExecution
    #>

    $tasks = @()

    # -------------------------------------------------------------------------
    # PHASE 1: PREFLIGHT
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'preflight-internet' `
        -Phase '1' `
        -ApplyHandler { Invoke-VerifyInternetConnectivity } `
        -Description 'Verify internet connectivity'

    $tasks += New-Task `
        -TaskId 'preflight-edition-compatibility' `
        -Phase '1' `
        -ApplyHandler { Invoke-ValidateSupportedWindowsEdition } `
        -Description 'Validate supported Windows edition and set Store/AppX compatibility gates'

    $tasks += New-Task `
        -TaskId 'preflight-restore-point' `
        -Phase '1' `
        -ApplyHandler { Invoke-CreateRestorePoint } `
        -Description 'Create Windows System Restore point'

    $tasks += New-Task `
        -TaskId 'preflight-winget-version' `
        -Phase '1' `
        -ApplyHandler { Invoke-EnsureWingetMinVersion } `
        -Description 'Validate Hunter minimum winget version and refresh App Installer if needed'

    $tasks += New-Task `
        -TaskId 'preflight-app-downloads' `
        -Phase '1' `
        -ApplyHandler { Invoke-ConfirmAppDownloads } `
        -Description 'Choose whether to skip app downloads and installs'

    $tasks += New-Task `
        -TaskId 'preflight-predownload-v2' `
        -Phase '1' `
        -ApplyHandler { Invoke-PreDownloadInstallers } `
        -Description 'Start background package downloads and installs'

    $tasks += New-Task `
        -TaskId 'install-launch-packages-v2' `
        -Phase '2' `
        -ApplyHandler { Invoke-ParallelInstalls -LaunchOnly } `
        -Description 'Ensure package installers are running in parallel'

    # -------------------------------------------------------------------------
    # PHASE 2: CORE
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'core-local-user-v2' `
        -Phase '2' `
        -ApplyHandler { Invoke-EnsureLocalStandardUser } `
        -Description 'Ensure standard local user exists'

    $tasks += New-Task `
        -TaskId 'core-autologin-v2' `
        -Phase '2' `
        -ApplyHandler { Invoke-ConfigureAutologin } `
        -Description 'Configure autologin for standard user'

    $tasks += New-Task `
        -TaskId 'core-dark-mode' `
        -Phase '2' `
        -ApplyHandler { Invoke-EnableDarkMode } `
        -Description 'Enable Windows dark mode theme'

    $tasks += New-Task `
        -TaskId 'core-ultimate-performance' `
        -Phase '2' `
        -ApplyHandler { Invoke-ActivateUltimatePerformance } `
        -Description 'Activate Ultimate Performance power plan'

    # -------------------------------------------------------------------------
    # PHASE 3: START/UI
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'startui-bing-search' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableBingStartSearch } `
        -Description 'Disable Bing search in Start Menu'

    $tasks += New-Task `
        -TaskId 'startui-start-recommendations-v4' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableStartRecommendations } `
        -Description 'Disable Start Menu recommendations'

    $tasks += New-Task `
        -TaskId 'startui-search-box' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableTaskbarSearchBox } `
        -Description 'Disable taskbar search box'

    $tasks += New-Task `
        -TaskId 'startui-task-view' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableTaskViewButton } `
        -Description 'Disable Task View button'

    $tasks += New-Task `
        -TaskId 'startui-widgets' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableWidgets } `
        -Description 'Disable Windows Widgets'

    $tasks += New-Task `
        -TaskId 'startui-end-task' `
        -Phase '3' `
        -ApplyHandler { Invoke-EnableEndTaskOnTaskbar } `
        -Description 'Enable End Task option on taskbar'

    $tasks += New-Task `
        -TaskId 'startui-notifications' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableNotificationsTrayCalendar } `
        -Description 'Disable notifications, tray, and calendar'

    $tasks += New-Task `
        -TaskId 'startui-new-outlook' `
        -Phase '3' `
        -ApplyHandler { Invoke-DisableNewOutlook } `
        -Description 'Disable new Outlook and auto-migration'

    $tasks += New-Task `
        -TaskId 'startui-settings-home' `
        -Phase '3' `
        -ApplyHandler { Invoke-HideSettingsHome } `
        -Description 'Hide Settings home page'

    # -------------------------------------------------------------------------
    # PHASE 4: EXPLORER
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'explorer-home-thispc' `
        -Phase '4' `
        -ApplyHandler { Invoke-SetExplorerHomeThisPC } `
        -Description 'Set Explorer home to This PC'

    $tasks += New-Task `
        -TaskId 'explorer-remove-home-v2' `
        -Phase '4' `
        -ApplyHandler { Invoke-RemoveExplorerHomeTab } `
        -Description 'Remove Home tab from Explorer'

    $tasks += New-Task `
        -TaskId 'explorer-remove-gallery-v2' `
        -Phase '4' `
        -ApplyHandler { Invoke-RemoveExplorerGalleryTab } `
        -Description 'Remove Gallery tab from Explorer'

    $tasks += New-Task `
        -TaskId 'explorer-remove-onedrive' `
        -Phase '4' `
        -ApplyHandler { Invoke-RemoveExplorerOneDriveTab } `
        -Description 'Remove OneDrive tab from Explorer'

    $tasks += New-Task `
        -TaskId 'explorer-auto-discovery' `
        -Phase '4' `
        -ApplyHandler { Invoke-DisableExplorerAutoFolderDiscovery } `
        -Description 'Disable Explorer automatic folder discovery'

    # -------------------------------------------------------------------------
    # PHASE 5: MICROSOFT CLOUD
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'cloud-edge-remove' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveEdgeKeepWebView2 } `
        -Description 'Remove Microsoft Edge'

    $tasks += New-Task `
        -TaskId 'cloud-edge-pins' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveEdgePinsAndShortcuts } `
        -Description 'Remove Edge pins and shortcuts'

    $tasks += New-Task `
        -TaskId 'cloud-edge-update-block' `
        -Phase '5' `
        -ApplyHandler { Invoke-DisableEdgeUpdateInfrastructure } `
        -Description 'Disable Edge update tasks and services while preserving WebView2'

    $tasks += New-Task `
        -TaskId 'cloud-onedrive-remove' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveOneDrive } `
        -Description 'Remove Microsoft OneDrive'

    $tasks += New-Task `
        -TaskId 'cloud-onedrive-backup' `
        -Phase '5' `
        -ApplyHandler { Invoke-DisableOneDriveFolderBackup } `
        -Description 'Disable OneDrive folder backup'

    $tasks += New-Task `
        -TaskId 'cloud-copilot-remove' `
        -Phase '5' `
        -ApplyHandler { Invoke-RemoveCopilot } `
        -Description 'Remove Copilot AI assistant'

    # -------------------------------------------------------------------------
    # PHASE 6: REMOVE APPS
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'apps-consumer-features' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableConsumerFeatures } `
        -Description 'Disable consumer experience features'

    $tasks += New-Task `
        -TaskId 'apps-nuke-block' `
        -Phase '6' `
        -ApplyHandler { Invoke-NukeBlockApps } `
        -Description 'Remove and block broad Microsoft bloatware (including Xbox/Game Bar)'

    $tasks += New-Task `
        -TaskId 'apps-inking-typing' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableInkingTyping } `
        -Description 'Disable Inking and Typing data collection'

    $tasks += New-Task `
        -TaskId 'apps-delivery-opt' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableDeliveryOptimization } `
        -Description 'Disable Delivery Optimization'

    $tasks += New-Task `
        -TaskId 'apps-activity-history' `
        -Phase '6' `
        -ApplyHandler { Invoke-DisableActivityHistory } `
        -Description 'Disable activity history plus clipboard/cloud clipboard tracking'

    # -------------------------------------------------------------------------
    # PHASE 7: TWEAKS
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'tweaks-services' `
        -Phase '7' `
        -ApplyHandler { Invoke-SetServiceProfileManual } `
        -Description 'Apply Hunter aggressive service startup profile'

    $tasks += New-Task `
        -TaskId 'tweaks-virtualization-security' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableVirtualizationSecurityOverhead } `
        -Description 'Disable HVCI, Hyper-V side features, Sandbox, and Application Guard'

    $tasks += New-Task `
        -TaskId 'tweaks-telemetry' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableTelemetry } `
        -Description 'Disable telemetry plus Hunter privacy/web-content policies'

    $tasks += New-Task `
        -TaskId 'tweaks-location' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableLocationTracking } `
        -Description 'Disable location tracking'

    $tasks += New-Task `
        -TaskId 'tweaks-hibernation' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableHibernation } `
        -Description 'Disable hibernation mode'

    $tasks += New-Task `
        -TaskId 'tweaks-background-apps' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableBackgroundApps } `
        -Description 'Disable background apps plus OneDrive, Widgets, and Edge background activity'

    $tasks += New-Task `
        -TaskId 'tweaks-teredo' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableTeredo } `
        -Description 'Disable Teredo tunneling protocol'

    $tasks += New-Task `
        -TaskId 'tweaks-fso' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableFullscreenOptimizations } `
        -Description 'Disable fullscreen optimizations'

    $tasks += New-Task `
        -TaskId 'tweaks-graphics-scheduling' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyGraphicsSchedulingTweaks } `
        -Description 'Apply HAGS, MPO, VRR, Game Bar, Auto HDR, and TDR graphics tweaks'

    $tasks += New-Task `
        -TaskId 'tweaks-gpu-interrupt-affinity' `
        -Phase '7' `
        -ApplyHandler { Invoke-ConfigureGpuInterruptAffinity } `
        -Description 'Pin GPU interrupts to a non-primary logical processor on supported single-group systems'

    $tasks += New-Task `
        -TaskId 'tweaks-rebar-audit' `
        -Phase '7' `
        -ApplyHandler { Invoke-AuditResizableBarSupport } `
        -Description 'Audit GPU family compatibility for Resizable BAR and document firmware-managed status'

    $tasks += New-Task `
        -TaskId 'tweaks-dwm-frame-interval' `
        -Phase '7' `
        -ApplyHandler { Invoke-SetDwmFrameInterval } `
        -Description 'Set DWM frame interval to 15'

    $tasks += New-Task `
        -TaskId 'tweaks-ui-desktop' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyUiDesktopPerformanceTweaks } `
        -Description 'Reduce transparency, animations, and desktop compositor overhead'

    $tasks += New-Task `
        -TaskId 'tweaks-razer' `
        -Phase '7' `
        -ApplyHandler { Invoke-BlockRazerSoftware } `
        -Description 'Block Razer software network access'

    $tasks += New-Task `
        -TaskId 'tweaks-adobe' `
        -Phase '7' `
        -ApplyHandler { Invoke-BlockAdobeNetworkTraffic } `
        -Description 'Block Adobe software network traffic'

    $tasks += New-Task `
        -TaskId 'tweaks-power-tuning' `
        -Phase '7' `
        -ApplyHandler { Invoke-ExhaustivePowerTuning } `
        -Description 'Exhaustive power tuning (throttling, fast boot, core parking, device PM)'

    $tasks += New-Task `
        -TaskId 'tweaks-nic-power-management' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableNicPowerManagement } `
        -Description 'Disable NIC power-management and wake policies on active physical adapters'

    $tasks += New-Task `
        -TaskId 'tweaks-memory-disk' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyMemoryDiskBehaviorTweaks } `
        -Description 'Disable prefetch, RAM compression, Storage Sense, and NTFS last access updates'

    $tasks += New-Task `
        -TaskId 'tweaks-input-maintenance' `
        -Phase '7' `
        -ApplyHandler { Invoke-ApplyInputAndMaintenanceTweaks } `
        -Description 'Disable mouse acceleration, tune timer policy, and defer maintenance tasks to 3am'

    $tasks += New-Task `
        -TaskId 'tweaks-timer-resolution' `
        -Phase '7' `
        -ApplyHandler { Invoke-InstallTimerResolutionService } `
        -Description 'Install 0.5ms timer resolution service'

    $tasks += New-Task `
        -TaskId 'tweaks-store-search' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableStoreSearch } `
        -Description 'Disable Microsoft Store search results'

    $tasks += New-Task `
        -TaskId 'tweaks-ipv6' `
        -Phase '7' `
        -ApplyHandler { Invoke-DisableIPv6 } `
        -Description 'Disable IPv6 on all adapters when explicitly requested'

    # -------------------------------------------------------------------------
    # PHASE 8: EXTERNAL TOOLS
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'external-wallpaper-v3' `
        -Phase '8' `
        -ApplyHandler { Invoke-ApplyWallpaperEverywhere } `
        -Description 'Apply wallpaper to desktop'

    $tasks += New-Task `
        -TaskId 'external-tcp-optimizer' `
        -Phase '8' `
        -ApplyHandler { Invoke-ApplyTcpOptimizerTutorialProfile } `
        -Description 'Apply TCP optimizations and verify with TCP Optimizer'

    $tasks += New-Task `
        -TaskId 'external-oosu' `
        -Phase '8' `
        -ApplyHandler { Invoke-ApplyOOSUSilentRecommendedPlusSomewhat } `
        -Description 'Configure privacy with O&O ShutUp10'

    $tasks += New-Task `
        -TaskId 'external-system-properties' `
        -Phase '8' `
        -ApplyHandler { Invoke-OpenAdvancedSystemSettings } `
        -Description 'Open Advanced System Settings'

    $tasks += New-Task `
        -TaskId 'external-network-connections-shortcut' `
        -Phase '8' `
        -ApplyHandler { Invoke-CreateNetworkConnectionsShortcut } `
        -Description 'Create Network Connections shortcut and pin to Start'

    # -------------------------------------------------------------------------
    # PHASE 9: CLEANUP
    # -------------------------------------------------------------------------

    $tasks += New-Task `
        -TaskId 'install-finalize-packages-v2' `
        -Phase '9' `
        -ApplyHandler { Invoke-ParallelInstalls } `
        -Description 'Finalize background package installations'

    $tasks += New-Task `
        -TaskId 'cleanup-temp-files' `
        -Phase '9' `
        -ApplyHandler { Invoke-DeleteTempFiles } `
        -Description 'Clean temporary files'

    $tasks += New-Task `
        -TaskId 'cleanup-retry-failed' `
        -Phase '9' `
        -ApplyHandler { Invoke-RetryFailedTasks } `
        -Description 'Retry any failed tasks'

    $tasks += New-Task `
        -TaskId 'cleanup-autologin-secrets' `
        -Phase '9' `
        -ApplyHandler { Invoke-ClearAutologinSecrets } `
        -Description 'Remove autologin registry values and Hunter-managed secrets after setup completes'

    $tasks += New-Task `
        -TaskId 'cleanup-disk-cleanup' `
        -Phase '9' `
        -ApplyHandler { Invoke-RunDiskCleanup } `
        -Description 'Run Windows Disk Cleanup'

    $tasks += New-Task `
        -TaskId 'cleanup-explorer-restart' `
        -Phase '9' `
        -ApplyHandler { Invoke-DeferredExplorerRestart } `
        -Description 'Restart Explorer with pending changes'

    $tasks += New-Task `
        -TaskId 'cleanup-export-log' `
        -Phase '9' `
        -ApplyHandler { Invoke-ExportDesktopOperationLog } `
        -Description 'Export operation report to desktop'

    return $tasks
}

function Test-PendingReboot {
    <#
    .SYNOPSIS
        Detects if Windows has a pending reboot.

    .DESCRIPTION
        Checks Windows registry for pending reboot indicators:
        - RebootPending in Component Based Servicing
        - RebootRequired in Windows Update

    .OUTPUTS
        [bool] $true if reboot is pending, $false otherwise
    #>

    try {
        $cbs = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
        $wuau = Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'

        return ($cbs -or $wuau)

    } catch {
        Add-RunInfrastructureIssue -Message "Failed to determine whether Windows is pending reboot: $($_.Exception.Message)" -Level 'WARN'
        return $null
    }
}
