function Invoke-DeleteTempFiles {
    <#
    .SYNOPSIS
        Removes temporary files from the standard WinUtil temp directories.

    .DESCRIPTION
        Recursively removes temporary files from the current user's TEMP directory
        and Windows\Temp.

        Reference: https://winutil.christitus.com/dev/tweaks/essential-tweaks/deletetempfiles/
    #>

    try {
        Write-Log "Cleaning temporary files..." 'INFO'

        $tempPaths = @(
            $env:TEMP,
            (Join-Path $script:WindowsRoot 'Temp')
        )

        $totalRemoved = 0
        $totalFailed = 0

        foreach ($path in $tempPaths) {
            if (Test-Path $path) {
                try {
                    $itemCountEstimate = @(Get-ChildItem -Path $path -Recurse -Force -ErrorAction SilentlyContinue).Count
                    $items = @(Get-ChildItem -Path $path -Force -ErrorAction SilentlyContinue)
                    $removeErrors = @()
                    # Remove only top-level temp entries recursively. Piping every
                    # descendant back into Remove-Item causes noisy PathNotFound
                    # races once parent directories are removed first.
                    $items | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable +removeErrors

                    $meaningfulRemoveErrors = @(
                        $removeErrors | Where-Object {
                            [string]$_.FullyQualifiedErrorId -notlike 'PathNotFound,*'
                        }
                    )
                    $failed = @($meaningfulRemoveErrors).Count
                    $removed = [Math]::Max(0, $itemCountEstimate - $failed)

                    $totalRemoved += $removed
                    $totalFailed += $failed

                    if ($failed -gt 0) {
                        Write-Log "Temporary cleanup removed $removed items from $path and skipped $failed locked or inaccessible item(s)." 'INFO'
                    } else {
                        Write-Log "Cleaned $removed items from $path" 'INFO'
                    }
                } catch {
                    Write-Log "Best-effort temp cleanup skipped some items in $path : $_" 'INFO'
                }
            }
        }

        if ($totalFailed -gt 0) {
            Write-Log "Temporary file cleanup completed best-effort: $totalRemoved removed, $totalFailed skipped" 'INFO'
            return $true
        }

        Write-Log "Temporary file cleanup complete: $totalRemoved items removed" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error deleting temporary files: $_" 'ERROR'
        return $false
    }
}


function Invoke-RunDiskCleanup {
    <#
    .SYNOPSIS
        Runs the WinUtil disk cleanup sequence.

    .DESCRIPTION
        Mirrors the current WinUtil disk cleanup flow:
        - cleanmgr.exe /d C: /VERYLOWDISK
        - Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase

        Reference: https://winutil.christitus.com/dev/tweaks/essential-tweaks/diskcleanup/
    #>

    try {
        if ($script:IsHyperVGuest) {
            Write-Log 'Hyper-V guest detected, skipping Windows Disk Cleanup and DISM cleanup.' 'INFO'
            return (New-TaskSkipResult -Reason 'Disk cleanup is intentionally skipped on Hyper-V guests')
        }

        Write-Log "Running Windows Disk Cleanup using the WinUtil sequence..." 'INFO'

        $cleanMgrExitCode = Invoke-NativeCommandChecked -FilePath 'cleanmgr.exe' -ArgumentList @('/d', 'C:', '/VERYLOWDISK') -SuccessExitCodes @(0, 1)
        if ($cleanMgrExitCode -eq 1) {
            Write-Log 'Windows Disk Cleanup returned exit code 1; continuing because this is non-fatal on some systems.' 'INFO'
        }
        Invoke-NativeCommandChecked -FilePath 'Dism.exe' -ArgumentList @('/online', '/Cleanup-Image', '/StartComponentCleanup', '/ResetBase') | Out-Null

        Write-Log 'Windows Disk Cleanup sequence completed successfully.' 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error running Disk Cleanup: $_" 'ERROR'
        return $false
    }
}

function Invoke-RetryFailedTasks {
    <#
    .SYNOPSIS
        Retries execution of all tasks that previously failed.

    .DESCRIPTION
        Iterates through $script:FailedTasks, re-executes each task's ApplyHandler,
        and moves successfully completed tasks from FailedTasks to CompletedTasks.

    .PARAMETER Tasks
        The full task array to use as reference.
    #>

    param(
        [array]$Tasks = @($script:TaskList)
    )

    try {
        $script:FailedTasks = @($script:FailedTasks)
        $script:CompletedTasks = @($script:CompletedTasks)

        if (@($Tasks).Count -eq 0) {
            Write-Log 'No task list available for retry processing' 'WARN'
            return $false
        }

        if (@($script:FailedTasks).Count -eq 0) {
            Write-Log "No failed tasks to retry" 'INFO'
            return (New-TaskSkipResult -Reason 'No failed tasks required retry')
        }

        Write-Log "Retrying $(@($script:FailedTasks).Count) failed task(s)..." 'INFO'

        $failedTaskIds = @($script:FailedTasks)

        foreach ($taskId in $failedTaskIds) {
            $task = $Tasks | Where-Object { $_.TaskId -eq $taskId }

            if (-not $task) {
                Write-Log "Task $taskId not found in task list" 'WARN'
                continue
            }

            try {
                Write-Log "Retrying task: $taskId" 'INFO'

                $retryResult = $null
                Enable-HunterTaskIssueTracking
                try {
                    $retryResult = & $task.ApplyHandler
                } finally {
                    Disable-HunterTaskIssueTracking
                }

                if (Test-TaskHandlerReturnedFailure -TaskResult $retryResult -LoggedError:$script:CurrentTaskLoggedError) {
                    throw "Task handler returned failure for $taskId"
                }

                $retryStatus = Get-TaskHandlerCompletionStatus -TaskResult $retryResult -LoggedWarning:$script:CurrentTaskLoggedWarning

                $script:FailedTasks = @($script:FailedTasks | Where-Object { $_ -ne $taskId })
                if ($retryStatus -ne 'Skipped') {
                    Add-CompletedTask -TaskId $taskId
                }
                $task.Status = $retryStatus
                $task.Error = $null

                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = $retryStatus
                    Error  = $null
                }

                switch ($retryStatus) {
                    'CompletedWithWarnings' { Write-Log "Retry completed with warnings: $taskId" 'WARN' }
                    'Skipped' { Write-Log "Retry skipped: $taskId" 'INFO' }
                    default { Write-Log "Retry succeeded: $taskId" 'SUCCESS' }
                }

            } catch {
                Write-Log "Retry failed for $taskId : $_" 'ERROR'
                $task.Error = $_.Exception.Message
                if (-not $script:TaskResults) {
                    $script:TaskResults = @{}
                }
                $script:TaskResults[$task.TaskId] = @{
                    Status = 'Failed'
                    Error  = $task.Error
                }
                # Keep in FailedTasks
            } finally {
                Reset-HunterTaskIssueState
            }
        }

        $remainingFailedTaskCount = @($script:FailedTasks).Count
        Write-Log "Task retry complete: ${remainingFailedTaskCount} still failing" 'INFO'
        if ($remainingFailedTaskCount -gt 0) {
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = "$remainingFailedTaskCount task(s) still failed after retry"
            }
        }

        return $true

    } catch {
        Write-Log "Error retrying failed tasks: $_" 'ERROR'
        throw
    }
}

function Get-HunterActivePowerSchemeGuid {
    try {
        $activeSchemeOutput = [string]::Join(' ', @(powercfg /getactivescheme 2>$null))
        $guidMatch = [regex]::Match($activeSchemeOutput, '[0-9a-fA-F-]{36}')
        if ($guidMatch.Success) {
            return $guidMatch.Value.ToLowerInvariant()
        }
    } catch {
    }

    return ''
}

function Invoke-ValidateAppliedConfiguration {
    try {
        Write-Log 'Running post-run validation checks...' 'INFO'
        Reset-HunterValidationResults

        $taskResults = if ($null -ne $script:TaskResults) { $script:TaskResults } else { @{} }
        $gpuContexts = @(Get-GpuPciDeviceContexts)
        $gpuDetectionIsReliable = ($gpuContexts.Count -gt 0)

        if ($taskResults.ContainsKey('tweaks-graphics-scheduling') -and $gpuDetectionIsReliable) {
            $expectedHwSchMode = if ($script:DisableHagsRequested) { 1 } else { 2 }
            $graphicsValidationPassed = (
                (Test-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrLevel' -ExpectedValue 3) -and
                (Test-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrDelay' -ExpectedValue 10) -and
                (Test-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'TdrDdiDelay' -ExpectedValue 10) -and
                (Test-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -ExpectedValue $expectedHwSchMode)
            )
            Add-HunterValidationResult -Name 'Graphics scheduling policy' -Passed:$graphicsValidationPassed -Detail ("Expected TdrLevel=3 and HwSchMode={0}" -f $expectedHwSchMode) | Out-Null
        } else {
            Add-HunterValidationResult -Name 'Graphics scheduling policy' -Passed:$true -Detail 'Skipped because no PCI display devices were detected or the task did not run.' -Skipped | Out-Null
        }

        if ($taskResults.ContainsKey('tweaks-telemetry')) {
            $telemetryValidationPassed = (
                (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -ExpectedValue 0) -and
                (Test-ServiceStartTypeMatch -Name 'DiagTrack' -ExpectedStartType 'Disabled')
            )
            Add-HunterValidationResult -Name 'Telemetry suppression' -Passed:$telemetryValidationPassed -Detail 'Expected AllowTelemetry=0 and DiagTrack disabled.' | Out-Null
        } else {
            Add-HunterValidationResult -Name 'Telemetry suppression' -Passed:$true -Detail 'Skipped because the telemetry task did not run.' -Skipped | Out-Null
        }

        if ($taskResults.ContainsKey('tweaks-services')) {
            $serviceProfilePassed = (
                (Test-ServiceStartTypeMatch -Name 'WSearch' -ExpectedStartType 'Disabled') -and
                (Test-ServiceStartTypeMatch -Name 'SysMain' -ExpectedStartType 'Disabled') -and
                (Test-ServiceStartTypeMatch -Name 'DiagTrack' -ExpectedStartType 'Disabled')
            )
            Add-HunterValidationResult -Name 'Service profile baseline' -Passed:$serviceProfilePassed -Detail 'Expected WSearch, SysMain, and DiagTrack to remain disabled.' | Out-Null
        } else {
            Add-HunterValidationResult -Name 'Service profile baseline' -Passed:$true -Detail 'Skipped because the aggressive service-profile task did not run.' -Skipped | Out-Null
        }

        if ($taskResults.ContainsKey('core-ultimate-performance') -or $taskResults.ContainsKey('tweaks-power-tuning')) {
            $activePowerSchemeGuid = Get-HunterActivePowerSchemeGuid
            $powerPlanPassed = ($activePowerSchemeGuid -in @(
                '88888888-8888-8888-8888-888888888888',
                'e9a42b02-d5df-448d-aa00-03f14749eb61',
                '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
            ))
            Add-HunterValidationResult -Name 'Power plan activation' -Passed:$powerPlanPassed -Detail ("Active scheme GUID: {0}" -f $(if ([string]::IsNullOrWhiteSpace($activePowerSchemeGuid)) { 'unknown' } else { $activePowerSchemeGuid })) | Out-Null
        } else {
            Add-HunterValidationResult -Name 'Power plan activation' -Passed:$true -Detail 'Skipped because no power-plan task ran.' -Skipped | Out-Null
        }

        if ($taskResults.ContainsKey('tweaks-input-maintenance') -and $script:ForceTextInputServiceRedirectRequested) {
            $textInputRedirectPassed = Test-RegistryValue `
                -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\TextInputManagementService\Parameters' `
                -Name 'ServiceDll' `
                -ExpectedValue '%SystemRoot%\System32\MSCTF.DLL'
            Add-HunterValidationResult -Name 'Text input ServiceDll redirect' -Passed:$textInputRedirectPassed -Detail 'Expected ServiceDll to point at MSCTF.DLL when the opt-in redirect is requested.' | Out-Null
        } else {
            Add-HunterValidationResult -Name 'Text input ServiceDll redirect' -Passed:$true -Detail 'Skipped because the advanced redirect is now opt-in.' -Skipped | Out-Null
        }

        $failedValidationCount = @($script:ValidationResults | Where-Object { $_.Status -eq 'Failed' }).Count
        if ($failedValidationCount -gt 0) {
            Write-Log "Post-run validation completed with $failedValidationCount failing check(s)." 'WARN'
            return (New-TaskWarningResult -Reason "$failedValidationCount post-run validation check(s) failed")
        }

        Write-Log 'Post-run validation checks completed successfully.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error validating applied configuration: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}


function Invoke-ExportDesktopOperationLog {
    <#
    .SYNOPSIS
        Exports a comprehensive operation report to the desktop.

    .DESCRIPTION
        Creates a timestamped report file on the user's desktop containing:
        - Operation summary (total, completed, failed)
        - List of completed tasks
        - List of failed tasks with error details
        - Reboot status
        - Also copies the full log file to the desktop
    #>

    try {
        Write-Log "Exporting operation report to desktop..." 'INFO'

        $desktopPath = [Environment]::GetFolderPath('Desktop')
        $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $reportPath = Join-Path $desktopPath "Hunter-Report-$timestamp.txt"
        $completedTasks = @()
        $warningTasks = @()
        $skippedTasks = @()
        $failedTasks = @()

        if ($script:TaskResults.Count -gt 0) {
            foreach ($entry in @($script:TaskResults.GetEnumerator() | Sort-Object Name)) {
                switch ([string]$entry.Value.Status) {
                    'Completed' { $completedTasks += $entry.Name }
                    'CompletedWithWarnings' { $warningTasks += $entry.Name }
                    'Skipped' { $skippedTasks += $entry.Name }
                    'Failed' { $failedTasks += $entry.Name }
                }
            }
        } else {
            $completedTasks = @($script:CompletedTasks)
            $failedTasks = @($script:FailedTasks)
        }

        # Gather statistics
        $totalTasks = $completedTasks.Count + $warningTasks.Count + $skippedTasks.Count + $failedTasks.Count
        $completedCount = $completedTasks.Count
        $warningCount = $warningTasks.Count
        $skippedCount = $skippedTasks.Count
        $failedCount = $failedTasks.Count

        # Check for pending reboot
        $rebootPending = Test-PendingReboot

        # Build report content
        $elapsedTime = if ($null -ne $script:RunStopwatch) { Format-ElapsedDuration $script:RunStopwatch.Elapsed } else { 'N/A' }
        $reportContent = @(
            "========================================",
            "        HUNTER OPERATION REPORT",
            "========================================",
            "",
            "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')",
            "Computer: $env:COMPUTERNAME",
            "User: $env:USERNAME",
            "",
            '---- SUMMARY ----',
            "Elapsed Time:     $elapsedTime",
            "Total Tasks:      $totalTasks",
            "Completed:        $completedCount",
            "Warnings:         $warningCount",
            "Skipped:          $skippedCount",
            "Failed:           $failedCount",
            "Success Rate:     $([math]::Round(($completedCount / [math]::Max($totalTasks, 1)) * 100, 1))%",
            "",
            "Pending Reboot:   $(if ($null -eq $rebootPending) { 'UNKNOWN (check failed)' } elseif ($rebootPending) { 'YES' } else { 'NO' })",
            ""
        )

        # Add completed tasks
        if ($completedTasks.Count -gt 0) {
            $reportContent += @(
                '---- COMPLETED TASKS ----'
            )
            $reportContent += $completedTasks | ForEach-Object { "  [+] $_" }
            $reportContent += @(
                ""
            )
        }

        if ($warningTasks.Count -gt 0) {
            $reportContent += @(
                '---- COMPLETED WITH WARNINGS ----'
            )

            foreach ($warningTaskId in $warningTasks) {
                $reportContent += "  [!] $warningTaskId"
                if ($script:TaskResults.ContainsKey($warningTaskId)) {
                    $result = $script:TaskResults[$warningTaskId]
                    if ($result.Error) {
                        $reportContent += "    Detail: $($result.Error)"
                    }
                }
            }

            $reportContent += ""
        }

        if ($skippedTasks.Count -gt 0) {
            $reportContent += @(
                '---- SKIPPED TASKS ----'
            )
            $reportContent += $skippedTasks | ForEach-Object { "  [-] $_" }
            $reportContent += @(
                ""
            )
        }

        # Add failed tasks
        if ($failedTasks.Count -gt 0) {
            $reportContent += @(
                '---- FAILED TASKS ----'
            )

            foreach ($failedTaskId in $failedTasks) {
                $reportContent += "  [X] $failedTaskId"

                if ($script:TaskResults.ContainsKey($failedTaskId)) {
                    $result = $script:TaskResults[$failedTaskId]
                    if ($result.Error) {
                        $reportContent += "    Error: $($result.Error)"
                    }
                }
            }

            $reportContent += ""
        }

        if (@($script:RunInfrastructureIssues).Count -gt 0) {
            $reportContent += @(
                '---- INFRASTRUCTURE ISSUES ----'
            )
            $reportContent += @($script:RunInfrastructureIssues | ForEach-Object { "  [!] $_" })
            $reportContent += @(
                ""
            )
        }

        if (@($script:ValidationResults).Count -gt 0) {
            $reportContent += @(
                '---- VALIDATION CHECKS ----'
            )
            foreach ($validationResult in @($script:ValidationResults)) {
                $statusLabel = switch ([string]$validationResult.Status) {
                    'Passed' { '[PASS]' }
                    'Failed' { '[FAIL]' }
                    default { '[SKIP]' }
                }
                $reportContent += "  ${statusLabel} $($validationResult.Name)"
                if (-not [string]::IsNullOrWhiteSpace([string]$validationResult.Detail)) {
                    $reportContent += "    Detail: $($validationResult.Detail)"
                }
            }
            $reportContent += @(
                ""
            )
        }

        $reportContent += @(
            "========================================",
            "Report generated by Hunter v2.0",
            "========================================",
            ""
        )

        # Write report
        $reportContent | Out-File -FilePath $reportPath -Encoding UTF8 -Force

        Write-Log "Report exported to: $reportPath" 'SUCCESS'

        # Copy main log file to desktop
        if (Test-Path $script:LogPath) {
            $logDesktopPath = Join-Path $desktopPath "Hunter-Full-Log-$timestamp.txt"
            Copy-Item -Path $script:LogPath -Destination $logDesktopPath -Force
            Write-Log "Full log copied to: $logDesktopPath" 'SUCCESS'
        }

        if (Test-Path $script:RollbackScriptPath) {
            $rollbackDesktopPath = Join-Path $desktopPath "Hunter-Restore-$timestamp.ps1"
            Copy-Item -Path $script:RollbackScriptPath -Destination $rollbackDesktopPath -Force
            Write-Log "Restore script copied to: $rollbackDesktopPath" 'SUCCESS'
        }

        if (Test-Path $script:RunConfigurationPath) {
            $runConfigDesktopPath = Join-Path $desktopPath "Hunter-Run-Configuration-$timestamp.json"
            Copy-Item -Path $script:RunConfigurationPath -Destination $runConfigDesktopPath -Force
            Write-Log "Run configuration copied to: $runConfigDesktopPath" 'SUCCESS'
        }

        Write-Log "Desktop operation log export complete" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error exporting operation log: $_" 'ERROR'
        return $false
    }
}
