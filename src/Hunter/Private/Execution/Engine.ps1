function Load-Checkpoint {
    param([object]$Context = $null)

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

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
                Sync-HunterContextFromScriptState -Context $Context
                Save-Checkpoint -Context $Context
            }

            Write-Log "Checkpoint loaded: $($script:CompletedTasks.Count) tasks completed"
            Sync-HunterContextFromScriptState -Context $Context
            return
        } else {
            $script:CompletedTasks = @()
            Write-Log "No checkpoint found, starting fresh"
            Sync-HunterContextFromScriptState -Context $Context
            return
        }
    } catch {
        $script:CompletedTasks = @()
        Add-RunInfrastructureIssue -Message "Failed to load checkpoint state; starting without resume data: $($_.Exception.Message)" -Level 'ERROR'
        Sync-HunterContextFromScriptState -Context $Context
    }
}

function Save-Checkpoint {
    param([object]$Context = $null)

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

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
    } finally {
        Sync-HunterContextFromScriptState -Context $Context
    }
}

function Resolve-TaskCheckpointId {
    param(
        [string]$TaskId,
        [object]$Context = $null
    )

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    }

    if ([string]::IsNullOrWhiteSpace($TaskId)) {
        return $TaskId
    }

    if ($script:CheckpointAliases.ContainsKey($TaskId)) {
        return $script:CheckpointAliases[$TaskId]
    }

    return $TaskId
}

function Test-TaskCompleted {
    param(
        [string]$TaskId,
        [object]$Context = $null
    )

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    }

    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $TaskId -Context $Context
    return ($script:CompletedTasks -contains $resolvedTaskId)
}

function Add-CompletedTask {
    param(
        [string]$TaskId,
        [object]$Context = $null
    )

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

    $resolvedTaskId = Resolve-TaskCheckpointId -TaskId $TaskId -Context $Context
    if (-not (Test-TaskCompleted -TaskId $resolvedTaskId -Context $Context)) {
        $script:CompletedTasks = @($script:CompletedTasks) + @($resolvedTaskId)
        Write-Log "Task marked completed: $resolvedTaskId"
        Sync-HunterContextFromScriptState -Context $Context
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
        [string[]]$SkipTask = @(),
        [object]$Context = $null
    )

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

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
                if (Test-TaskCompleted -TaskId $task.TaskId -Context $Context) {
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
                    Sync-HunterContextFromScriptState -Context $Context
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
                    Sync-HunterContextFromScriptState -Context $Context
                    continue
                }

                # Update status and progress
                $task.Status = 'Running'
                Update-ProgressState -Tasks $Tasks

                Write-Log "Executing task: $($task.TaskId) [Phase $($task.Phase)]" 'INFO'

                $taskResult = $null
                Enable-HunterTaskIssueTracking
                try {
                    $taskResult = & $task.ApplyHandler
                } finally {
                    Disable-HunterTaskIssueTracking
                }

                if (Test-TaskHandlerReturnedFailure -TaskResult $taskResult -LoggedError:$script:CurrentTaskLoggedError) {
                    throw "Task handler returned failure for $($task.TaskId)"
                }

                $taskStatus = Get-TaskHandlerCompletionStatus -TaskResult $taskResult -LoggedWarning:$script:CurrentTaskLoggedWarning
                $task.Status = $taskStatus
                $task.Error = $null
                if ($taskStatus -ne 'Skipped') {
                    Add-CompletedTask -TaskId $task.TaskId -Context $Context
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
                Sync-HunterContextFromScriptState -Context $Context

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
                Sync-HunterContextFromScriptState -Context $Context

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
                    Save-Checkpoint -Context $Context
                }
                Reset-HunterTaskIssueState
                Sync-HunterContextFromScriptState -Context $Context
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

    param([object]$Context = $null)

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

    $tasks = @(
        foreach ($taskDefinition in @(Get-HunterTaskCatalog)) {
            New-Task `
                -TaskId ([string]$taskDefinition.Id) `
                -Phase ([string]$taskDefinition.Phase) `
                -ApplyHandler $taskDefinition.Handler `
                -Description ([string]$taskDefinition.Description)
        }
    )

    $script:TaskList = @($tasks)
    Sync-HunterContextFromScriptState -Context $Context
    return @($tasks)
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
