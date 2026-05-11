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

    .PARAMETER RiskLevel
        Relative risk label used for pre-run execution summaries
    #>

    param(
        [string]$TaskId,
        [string]$Phase,
        [scriptblock]$ApplyHandler,
        [string]$Description = '',
        [ValidateSet('Safe', 'Moderate', 'Aggressive')]
        [string]$RiskLevel = 'Safe',
        [string[]]$Profiles = @('Aggressive')
    )

    return @{
        TaskId       = $TaskId
        Phase        = $Phase
        ApplyHandler = $ApplyHandler
        Description  = $Description
        RiskLevel    = $RiskLevel
        Profiles     = @($Profiles)
        Status       = 'Pending'
        Error        = $null
    }
}

function Test-HunterTaskIncludedInProfile {
    param(
        [string[]]$Profiles,
        [string]$Profile = 'Aggressive'
    )

    $normalizedProfiles = @($Profiles | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($normalizedProfiles.Count -eq 0) {
        return $true
    }

    return ([string]$Profile) -in $normalizedProfiles
}


#=============================================================================
# PARALLEL EXECUTION INFRASTRUCTURE
#=============================================================================

# Phases whose tasks are independent and safe to run concurrently.
# Phase 3 = Start/UI tweaks, Phase 4 = Explorer tweaks, Phase 7 = system tweaks.
$script:ParallelPhases = @('3', '4', '7')

function Get-HunterScriptVariableSnapshot {
    <#
    .SYNOPSIS
    Captures all script-scoped variables into a hashtable for injection into
    parallel runspaces.  Variables that hold live runspace/pipeline references
    or WPF dispatchers are excluded because they cannot cross thread boundaries.
    #>
    $exclude = @(
        'UiRunspace', 'UiPipeline', 'UiSync',
        'ParallelInstallJobs', 'ExternalAssetPrefetchJobs',
        'HunterContext'
    )
    $snapshot = @{}
    foreach ($var in (Get-Variable -Scope Script -ErrorAction SilentlyContinue)) {
        if ($var.Name -in $exclude) { continue }
        if ($var.Options -band [System.Management.Automation.ScopedItemOptions]::ReadOnly) { continue }
        if ($var.Options -band [System.Management.Automation.ScopedItemOptions]::Constant) { continue }
        $snapshot[$var.Name] = $var.Value
    }
    return $snapshot
}

function New-HunterRunspacePool {
    <#
    .SYNOPSIS
    Creates a RunspacePool with all current session functions injected via
    InitialSessionState so that task handlers can call any helper (Write-Log,
    Set-RegistryValue, Set-DwordBatchForAllUsers, etc.) inside a parallel
    runspace without re-importing modules.
    #>
    param([int]$MaxConcurrency = 0)

    if ($MaxConcurrency -le 0) {
        $MaxConcurrency = [Math]::Min([Environment]::ProcessorCount, 8)
    }

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    foreach ($func in (Get-Command -CommandType Function -ErrorAction SilentlyContinue)) {
        if (-not $func.ScriptBlock) { continue }
        try {
            $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new(
                $func.Name, $func.ScriptBlock.ToString()
            )
            $iss.Commands.Add($entry)
        } catch {
            # Skip functions whose definitions cannot be serialized
        }
    }

    $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
        1, $MaxConcurrency, $iss, $Host
    )
    $pool.Open()
    Write-Log "Runspace pool opened (max concurrency: $MaxConcurrency)" 'INFO'
    return $pool
}

function Invoke-TaskPhaseParallel {
    <#
    .SYNOPSIS
    Runs all tasks in a single phase concurrently via a shared RunspacePool.
    Each task gets its own runspace with a full copy of script-scoped state.
    Results (status, rollback entries, log lines, shared flags) are collected
    after all tasks complete and merged back into the main thread's state.

    .DESCRIPTION
    Tasks that are already completed (checkpoint) or user-skipped are handled
    on the main thread before the parallel batch starts.  Only truly pending
    tasks are dispatched to the pool.
    #>
    param(
        [object[]]$PhaseTasks,
        [object[]]$AllTasks,
        [string[]]$SkipTaskIds,
        [object]$RunspacePool,
        [object]$Context
    )

    if (-not $script:TaskResults) { $script:TaskResults = @{} }

    # ── Pre-filter: checkpoint and skip checks on main thread ──
    $pendingTasks = [System.Collections.Generic.List[object]]::new()
    foreach ($task in $PhaseTasks) {
        if (Test-TaskCompleted -TaskId $task.TaskId -Context $Context) {
            Write-Log "Task already completed (checkpoint): $($task.TaskId)" 'INFO'
            $task.Status = 'Completed'
            $script:TaskResults[$task.TaskId] = @{ Status = 'Completed'; Error = $null }
            continue
        }
        if ($SkipTaskIds -contains [string]$task.TaskId) {
            Write-Log "Task skipped by user request: $($task.TaskId)" 'INFO'
            $task.Status = 'Skipped'
            $script:TaskResults[$task.TaskId] = @{ Status = 'Skipped'; Error = $null }
            continue
        }
        [void]$pendingTasks.Add($task)
    }

    if ($pendingTasks.Count -eq 0) { return }

    # ── Prepare shared state for runspaces ──
    $snapshot = Get-HunterScriptVariableSnapshot
    # Give each runspace an empty rollback buffer; the dedup index is shared
    # as a read-copy so tasks don't re-register entries from earlier phases.
    $rollbackIndexCopy = @{} + $script:RollbackEntryIndex
    $snapshot['RollbackEntries']    = @()
    $snapshot['RollbackEntryIndex'] = $rollbackIndexCopy

    $logBuffer = [System.Collections.Concurrent.ConcurrentQueue[string]]::new()
    $sharedFlags = [hashtable]::Synchronized(@{
        ExplorerRestartPending      = [bool]$script:ExplorerRestartPending
        StartSurfaceRestartPending  = [bool]$script:StartSurfaceRestartPending
        TaskbarReconcilePending     = [bool]$script:TaskbarReconcilePending
    })

    # ── Mark all pending tasks as Running for the progress UI ──
    foreach ($task in $pendingTasks) { $task.Status = 'Running' }
    Update-ProgressState -Tasks $AllTasks

    # ── Dispatch each task to the pool ──
    $jobs = [System.Collections.Generic.List[hashtable]]::new()

    # The scriptblock that runs inside each runspace.  It receives all
    # state as parameters, restores $script: variables, overrides Write-Log
    # and flag-setting functions, runs the handler, and returns a structured
    # result including any new rollback entries the handler registered.
    $workerScript = {
        param(
            [string]$HandlerBody,
            [string]$TaskId,
            [hashtable]$VarSnapshot,
            $LogBuffer,
            $SharedFlags
        )

        # Restore script-scoped variables from snapshot
        foreach ($kv in $VarSnapshot.GetEnumerator()) {
            try { Set-Variable -Scope Script -Name $kv.Key -Value $kv.Value -Force -ErrorAction SilentlyContinue } catch {}
        }

        # ── Override Write-Log to use the concurrent buffer ──
        function Write-Log {
            param(
                [string]$Message,
                [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
                [string]$Level = 'INFO'
            )
            $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
            $line = "[$ts] [$Level] $Message"
            $LogBuffer.Enqueue($line)
            try {
                switch ($Level) {
                    'ERROR'   { Write-Host $line -ForegroundColor Red }
                    'WARN'    { Write-Host $line -ForegroundColor Yellow }
                    'SUCCESS' { Write-Host $line -ForegroundColor Green }
                    default   { Write-Host $line }
                }
            } catch {}
            if ($script:TaskIssueTrackingEnabled) {
                switch ($Level) {
                    'ERROR' { $script:CurrentTaskLoggedError   = $true }
                    'WARN'  { $script:CurrentTaskLoggedWarning = $true }
                }
            }
        }

        # ── Override flag-setters to write into the synchronized hashtable ──
        function Request-ExplorerRestart      { $SharedFlags.ExplorerRestartPending     = $true }
        function Request-StartSurfaceRestart  { $SharedFlags.StartSurfaceRestartPending = $true }

        # ── Execute the handler ──
        $rollbackCountBefore = @($script:RollbackEntries).Count
        $script:CurrentTaskLoggedError   = $false
        $script:CurrentTaskLoggedWarning = $false
        $script:TaskIssueTrackingEnabled = $true

        $result = @{
            TaskId          = $TaskId
            Success         = $false
            HandlerResult   = $null
            Error           = $null
            LoggedError     = $false
            LoggedWarning   = $false
            NewRollbackEntries = @()
        }

        try {
            $handler = [scriptblock]::Create($HandlerBody)
            $handlerOutput = & $handler

            $result.Success       = $true
            $result.HandlerResult = $handlerOutput
            $result.LoggedError   = [bool]$script:CurrentTaskLoggedError
            $result.LoggedWarning = [bool]$script:CurrentTaskLoggedWarning
        } catch {
            $result.Error       = $_.Exception.Message
            $result.LoggedError = $true
        }

        $script:TaskIssueTrackingEnabled = $false

        # Collect rollback entries that this task added
        $allEntries = @($script:RollbackEntries)
        if ($allEntries.Count -gt $rollbackCountBefore) {
            $result.NewRollbackEntries = @($allEntries[$rollbackCountBefore..($allEntries.Count - 1)])
        }

        return $result
    }

    foreach ($task in $pendingTasks) {
        $handlerBody = $task.ApplyHandler.ToString().Trim()
        Write-Log "Dispatching parallel task: $($task.TaskId) [Phase $($task.Phase)]" 'INFO'

        $ps = [powershell]::Create()
        $ps.RunspacePool = $RunspacePool

        [void]$ps.AddScript($workerScript)
        [void]$ps.AddArgument($handlerBody)
        [void]$ps.AddArgument($task.TaskId)
        [void]$ps.AddArgument($snapshot)
        [void]$ps.AddArgument($logBuffer)
        [void]$ps.AddArgument($sharedFlags)

        $handle = $ps.BeginInvoke()
        [void]$jobs.Add(@{ PS = $ps; Handle = $handle; Task = $task })
    }

    # ── Collect results ──
    foreach ($job in $jobs) {
        try {
            $output = @($job.PS.EndInvoke($job.Handle))

            # Find the structured result hashtable in the output stream
            $taskResult = $null
            foreach ($item in $output) {
                if ($item -is [hashtable] -and $item.ContainsKey('TaskId')) {
                    $taskResult = $item
                    break
                }
            }

            if ($null -eq $taskResult) {
                # Fallback: no structured result returned
                if ($job.PS.HadErrors) {
                    $errorMsg = ($job.PS.Streams.Error | ForEach-Object { $_.Exception.Message }) -join '; '
                    $job.Task.Status = 'Failed'
                    $job.Task.Error  = if ([string]::IsNullOrWhiteSpace($errorMsg)) { 'Unknown error (no result returned)' } else { $errorMsg }
                } else {
                    $job.Task.Status = 'Completed'
                    $job.Task.Error  = $null
                    Add-CompletedTask -TaskId $job.Task.TaskId -Context $Context
                    Write-Log "Task completed: $($job.Task.TaskId)" 'SUCCESS'
                }
            } elseif ($taskResult.Success) {
                $handlerResult = $taskResult.HandlerResult

                if (Test-TaskHandlerReturnedFailure -TaskResult $handlerResult -LoggedError:$taskResult.LoggedError) {
                    $job.Task.Status = 'Failed'
                    $job.Task.Error  = "Task handler returned failure for $($job.Task.TaskId)"
                } else {
                    $taskStatus = Get-TaskHandlerCompletionStatus -TaskResult $handlerResult -LoggedWarning:$taskResult.LoggedWarning
                    $job.Task.Status = $taskStatus
                    $job.Task.Error  = $null
                    if ($taskStatus -ne 'Skipped') {
                        Add-CompletedTask -TaskId $job.Task.TaskId -Context $Context
                    }
                    switch ($taskStatus) {
                        'CompletedWithWarnings' { Write-Log "Task completed with warnings: $($job.Task.TaskId)" 'WARN' }
                        'Skipped'              { Write-Log "Task skipped: $($job.Task.TaskId)" 'INFO' }
                        default                { Write-Log "Task completed: $($job.Task.TaskId)" 'SUCCESS' }
                    }
                }
            } else {
                $job.Task.Status = 'Failed'
                $job.Task.Error  = $taskResult.Error
            }

            # Record failure bookkeeping
            if ($job.Task.Status -eq 'Failed') {
                if (-not $script:FailedTasks) { $script:FailedTasks = @() }
                if ($script:FailedTasks -notcontains $job.Task.TaskId) {
                    $script:FailedTasks = @($script:FailedTasks) + @($job.Task.TaskId)
                }
                Write-Log "Task failed: $($job.Task.TaskId) - $($job.Task.Error)" 'ERROR'
            }

            $script:TaskResults[$job.Task.TaskId] = @{
                Status = [string]$job.Task.Status
                Error  = $job.Task.Error
            }

            # Merge rollback entries from this task
            if ($null -ne $taskResult -and $taskResult.NewRollbackEntries.Count -gt 0) {
                foreach ($entry in $taskResult.NewRollbackEntries) {
                    $entryKey = if ($entry.PSObject.Properties['Key']) { [string]$entry.Key } else { $null }
                    if (-not [string]::IsNullOrWhiteSpace($entryKey) -and -not $script:RollbackEntryIndex.ContainsKey($entryKey)) {
                        $script:RollbackEntries += $entry
                        $script:RollbackEntryIndex[$entryKey] = $true
                    }
                }
            }
        } catch {
            $job.Task.Status = 'Failed'
            $job.Task.Error  = $_.Exception.Message
            if (-not $script:FailedTasks) { $script:FailedTasks = @() }
            if ($script:FailedTasks -notcontains $job.Task.TaskId) {
                $script:FailedTasks = @($script:FailedTasks) + @($job.Task.TaskId)
            }
            Write-Log "Task failed (collection error): $($job.Task.TaskId) - $($_.Exception.Message)" 'ERROR'
            $script:TaskResults[$job.Task.TaskId] = @{ Status = 'Failed'; Error = $job.Task.Error }
        } finally {
            $job.PS.Dispose()
        }
    }

    # ── Merge shared flags back to main-thread state ──
    if ($sharedFlags.ExplorerRestartPending)     { $script:ExplorerRestartPending     = $true }
    if ($sharedFlags.StartSurfaceRestartPending) { $script:StartSurfaceRestartPending = $true }
    if ($sharedFlags.TaskbarReconcilePending)    { $script:TaskbarReconcilePending    = $true }

    # ── Flush log buffer to the log file ──
    $logLine = $null
    while ($logBuffer.TryDequeue([ref]$logLine)) {
        try { Add-Content -Path $script:LogPath -Value $logLine -ErrorAction SilentlyContinue } catch {}
    }

    # ── Strict mode: abort if any task in this batch failed ──
    if ($script:StrictMode) {
        $failedInPhase = @($pendingTasks | Where-Object { $_.Status -eq 'Failed' })
        if ($failedInPhase.Count -gt 0) {
            Write-Log "STRICT MODE: Aborting run due to $($failedInPhase.Count) failed parallel task(s)" 'ERROR'
            throw "Strict mode abort: $($failedInPhase.Count) task(s) failed in parallel phase"
        }
    }
}

#=============================================================================
# TASK EXECUTION ENGINE
#=============================================================================

function Invoke-TaskExecution {
    <#
    .SYNOPSIS
        Executes all tasks grouped by phase, with parallel execution for
        independent registry phases and checkpoint recovery.

    .DESCRIPTION
        Groups tasks by phase number.  Phases listed in $script:ParallelPhases
        (3, 4, 7) run their tasks concurrently via a RunspacePool.  All other
        phases execute sequentially.  The Default-user registry hive is kept
        loaded for the duration of each phase so that per-task load/unload
        overhead is eliminated.  Checkpoints are saved once per phase rather
        than per task to reduce I/O.

    .PARAMETER Tasks
        Array of task objects created by Build-Tasks

    .PARAMETER SkipTask
        Task IDs to skip

    .PARAMETER Context
        Optional Hunter execution context
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
        Write-Log "Starting task execution engine (phase-parallel mode)..." 'INFO'
        $requestedSkipTaskIds = @(
            $SkipTask |
                ForEach-Object { [string]$_ } |
                ForEach-Object { $_.Split(',') } |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Select-Object -Unique
        )

        # ── Group tasks by phase ──
        $phaseGroups = [ordered]@{}
        foreach ($task in $Tasks) {
            $phase = [string]$task.Phase
            if (-not $phaseGroups.Contains($phase)) {
                $phaseGroups[$phase] = [System.Collections.Generic.List[object]]::new()
            }
            [void]$phaseGroups[$phase].Add($task)
        }

        # ── Create RunspacePool for parallel phases (created once, reused) ──
        $pool = $null
        $parallelPhaseKeys = @($phaseGroups.Keys | Where-Object { $_ -in $script:ParallelPhases })
        $hasWorkForPool = $false
        foreach ($pk in $parallelPhaseKeys) {
            $pending = @($phaseGroups[$pk] | Where-Object {
                -not (Test-TaskCompleted -TaskId $_.TaskId -Context $Context)
            })
            if ($pending.Count -gt 1) { $hasWorkForPool = $true; break }
        }
        if ($hasWorkForPool) {
            try {
                $pool = New-HunterRunspacePool
            } catch {
                Write-Log "Failed to create runspace pool; all phases will run sequentially: $($_.Exception.Message)" 'WARN'
                $pool = $null
            }
        }

        try {
            foreach ($phase in $phaseGroups.Keys) {
                $phaseTasks = @($phaseGroups[$phase])
                $phaseLabel = "Phase $phase"
                $completedCountBeforePhase = @($script:CompletedTasks).Count

                Write-Log "── $phaseLabel ($($phaseTasks.Count) task(s)) ──" 'INFO'

                # Open a Default-user hive session for the phase so that
                # individual tasks skip per-task reg load/unload.
                $hiveSessionOpened = $false
                try { $hiveSessionOpened = Open-DefaultUserHiveSession } catch {
                    Write-Log "Could not open hive session for $phaseLabel (non-fatal): $($_.Exception.Message)" 'WARN'
                }

                try {
                    $useParallel = (
                        $phase -in $script:ParallelPhases -and
                        $phaseTasks.Count -gt 1 -and
                        $null -ne $pool
                    )

                    if ($useParallel) {
                        # ── Parallel path ──
                        Write-Log "[$phaseLabel] Executing $($phaseTasks.Count) tasks in parallel..." 'INFO'
                        Invoke-TaskPhaseParallel `
                            -PhaseTasks $phaseTasks `
                            -AllTasks $Tasks `
                            -SkipTaskIds $requestedSkipTaskIds `
                            -RunspacePool $pool `
                            -Context $Context
                    } else {
                        # ── Sequential path (unchanged logic, batched checkpoint) ──
                        foreach ($task in $phaseTasks) {
                            try {
                                if (Test-TaskCompleted -TaskId $task.TaskId -Context $Context) {
                                    Write-Log "Task already completed (checkpoint): $($task.TaskId)" 'INFO'
                                    $task.Status = 'Completed'
                                    if (-not $script:TaskResults) { $script:TaskResults = @{} }
                                    $script:TaskResults[$task.TaskId] = @{ Status = 'Completed'; Error = $null }
                                    continue
                                }

                                if ($requestedSkipTaskIds -contains [string]$task.TaskId) {
                                    Write-Log "Task skipped by user request: $($task.TaskId)" 'INFO'
                                    $task.Status = 'Skipped'
                                    $task.Error = $null
                                    if (-not $script:TaskResults) { $script:TaskResults = @{} }
                                    $script:TaskResults[$task.TaskId] = @{ Status = 'Skipped'; Error = $null }
                                    continue
                                }

                                $task.Status = 'Running'
                                Update-ProgressState -Tasks $Tasks
                                Write-Log "Executing task: $($task.TaskId) [$phaseLabel]" 'INFO'

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

                                if (-not $script:TaskResults) { $script:TaskResults = @{} }
                                $script:TaskResults[$task.TaskId] = @{ Status = $taskStatus; Error = $null }

                            } catch {
                                $task.Status = 'Failed'
                                $task.Error = $_.Exception.Message

                                if (-not $script:FailedTasks) { $script:FailedTasks = @() }
                                if ($script:FailedTasks -notcontains $task.TaskId) {
                                    $script:FailedTasks = @($script:FailedTasks) + @($task.TaskId)
                                }

                                Write-Log "Task failed: $($task.TaskId) - $($task.Error)" 'ERROR'

                                if (-not $script:TaskResults) { $script:TaskResults = @{} }
                                $script:TaskResults[$task.TaskId] = @{ Status = 'Failed'; Error = $task.Error }

                                if ($script:StrictMode) {
                                    Write-Log "STRICT MODE: Aborting run due to task failure: $($task.TaskId)" 'ERROR'
                                    throw "Strict mode abort: task '$($task.TaskId)' failed - $($task.Error)"
                                }
                            } finally {
                                Invoke-CollectCompletedParallelInstallJobs
                                Invoke-CollectCompletedExternalAssetPrefetchJobs
                                Reset-HunterTaskIssueState
                            }
                        }
                    }

                    # ── Phase-level bookkeeping (runs once per phase) ──
                    Invoke-CollectCompletedParallelInstallJobs
                    Invoke-CollectCompletedExternalAssetPrefetchJobs
                    Update-ProgressState -Tasks $Tasks

                    if (@($script:CompletedTasks).Count -ne $completedCountBeforePhase) {
                        Save-Checkpoint -Context $Context
                    }
                    Sync-HunterContextFromScriptState -Context $Context

                } finally {
                    if ($hiveSessionOpened) {
                        try { Close-DefaultUserHiveSession } catch {
                            Write-Log "Failed to close hive session after $phaseLabel : $($_.Exception.Message)" 'WARN'
                        }
                    }
                }
            }
        } finally {
            if ($null -ne $pool) {
                try { $pool.Close(); $pool.Dispose() } catch {}
                Write-Log 'Runspace pool closed.' 'INFO'
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
        Constructs all tasks across 10 phases in proper execution order.
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

    $selectedProfile = if ([string]::IsNullOrWhiteSpace($script:SelectedProfile)) {
        'Aggressive'
    } else {
        [string]$script:SelectedProfile
    }

    $tasks = @(
        foreach ($taskDefinition in @(Get-HunterTaskCatalog)) {
            $taskProfiles = @($taskDefinition.Profiles | ForEach-Object { [string]$_ })
            if (-not (Test-HunterTaskIncludedInProfile -Profiles $taskProfiles -Profile $selectedProfile)) {
                continue
            }

            New-Task `
                -TaskId ([string]$taskDefinition.Id) `
                -Phase ([string]$taskDefinition.Phase) `
                -ApplyHandler $taskDefinition.Handler `
                -Description ([string]$taskDefinition.Description) `
                -RiskLevel ([string]$taskDefinition.RiskLevel) `
                -Profiles $taskProfiles
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
