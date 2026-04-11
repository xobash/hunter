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

                $retryResult = & $task.ApplyHandler
                if (Test-TaskHandlerReturnedFailure -TaskResult $retryResult) {
                    throw "Task handler returned failure for $taskId"
                }

                $retryStatus = Get-TaskHandlerCompletionStatus -TaskResult $retryResult

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
            }
        }

        Write-Log "Task retry complete: $(@($script:FailedTasks).Count) still failing" 'INFO'
        return (@($script:FailedTasks).Count -eq 0)

    } catch {
        Write-Log "Error retrying failed tasks: $_" 'ERROR'
        throw
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

        Write-Log "Desktop operation log export complete" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Error exporting operation log: $_" 'ERROR'
        return $false
    }
}
