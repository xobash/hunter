$script:LogDirectoryEnsured = $false
$script:TaskIssueTrackingEnabled = $false
$script:CurrentTaskLoggedWarning = $false
$script:CurrentTaskLoggedError = $false

function Reset-HunterTaskIssueState {
    $script:CurrentTaskLoggedWarning = $false
    $script:CurrentTaskLoggedError = $false
}

function Enable-HunterTaskIssueTracking {
    Reset-HunterTaskIssueState
    $script:TaskIssueTrackingEnabled = $true
}

function Disable-HunterTaskIssueTracking {
    $script:TaskIssueTrackingEnabled = $false
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS')]
        [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] [$Level] $Message"
    if (-not $script:LogDirectoryEnsured) {
        $logDir = Split-Path $script:LogPath -Parent
        if (-not (Test-Path $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
        $script:LogDirectoryEnsured = $true
    }
    try {
        Add-Content -Path $script:LogPath -Value $line -ErrorAction Stop
    } catch {
        [Console]::Error.WriteLine("[Hunter] Failed to append to log file '$($script:LogPath)': $($_.Exception.Message)")
    }

    # Preserve legacy task-status semantics while split handlers are still being
    # converted to explicit result objects end-to-end.
    if ($script:TaskIssueTrackingEnabled) {
        switch ($Level) {
            'ERROR' { $script:CurrentTaskLoggedError = $true }
            'WARN' { $script:CurrentTaskLoggedWarning = $true }
        }
    }

    switch ($Level) {
        'ERROR'   { Write-Host $line -ForegroundColor Red }
        'WARN'    { Write-Host $line -ForegroundColor Yellow }
        'SUCCESS' { Write-Host $line -ForegroundColor Green }
        default   { Write-Host $line }
    }

    try {
        [Console]::Out.Flush()
        [Console]::Error.Flush()
    } catch { }
}

function Add-RunInfrastructureIssue {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('WARN','ERROR')]
        [string]$Level = 'ERROR'
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return
    }

    if ($script:RunInfrastructureIssues -notcontains $Message) {
        $script:RunInfrastructureIssues += $Message
    }

    Write-Log $Message $Level
}

function New-TaskSkipResult {
    param([string]$Reason = '')

    return [ordered]@{
        Success = $true
        Status  = 'Skipped'
        Reason  = $Reason
    }
}

function New-TaskWarningResult {
    param([string]$Reason = '')

    return [ordered]@{
        Success = $true
        Status = 'CompletedWithWarnings'
        Reason = $Reason
    }
}

function Get-TaskResultField {
    param(
        [object]$TaskResult,
        [string]$Name
    )

    if ($null -eq $TaskResult -or [string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if ($TaskResult -is [System.Collections.IDictionary]) {
        if ($TaskResult.Contains($Name)) {
            return $TaskResult[$Name]
        }

        return $null
    }

    if ($null -ne $TaskResult.PSObject -and $null -ne $TaskResult.PSObject.Properties[$Name]) {
        return $TaskResult.$Name
    }

    return $null
}

function Get-TaskHandlerCompletionStatus {
    param(
        [object]$TaskResult,
        [bool]$LoggedWarning = $false
    )

    $explicitStatus = Get-TaskResultField -TaskResult $TaskResult -Name 'Status'
    if ($null -ne $explicitStatus) {
        $explicitStatus = [string]$explicitStatus
    }

    switch ($explicitStatus) {
        'Skipped' { return 'Skipped' }
        'CompletedWithWarnings' { return 'CompletedWithWarnings' }
        'Warning' { return 'CompletedWithWarnings' }
        'Completed' {
            if ($LoggedWarning) {
                return 'CompletedWithWarnings'
            }

            return 'Completed'
        }
    }

    if ($LoggedWarning) {
        return 'CompletedWithWarnings'
    }

    return 'Completed'
}

function Format-ElapsedDuration {
    param([TimeSpan]$Duration)

    if ($Duration.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int]$Duration.TotalHours, $Duration.Minutes, $Duration.Seconds)
    }

    return ('{0:00}:{1:00}' -f $Duration.Minutes, $Duration.Seconds)
}

function Test-TaskHandlerReturnedFailure {
    param(
        [object]$TaskResult,
        [bool]$LoggedError = $false
    )

    if ($TaskResult -is [System.Exception] -or $TaskResult -is [System.Management.Automation.ErrorRecord]) {
        return $true
    }

    if ($LoggedError) {
        return $true
    }

    $successValue = Get-TaskResultField -TaskResult $TaskResult -Name 'Success'
    if ($null -ne $successValue) {
        return (-not [bool]$successValue)
    }

    $statusValue = Get-TaskResultField -TaskResult $TaskResult -Name 'Status'
    if ($null -ne $statusValue) {
        return ([string]$statusValue -eq 'Failed')
    }

    if ($TaskResult -is [bool]) {
        return (-not $TaskResult)
    }

    $resultItems = @($TaskResult | Where-Object { $null -ne $_ })
    if ($resultItems.Count -eq 0) {
        return $false
    }

    $booleanItems = @($resultItems | Where-Object { $_ -is [bool] })
    if ($booleanItems.Count -eq 0) {
        return $false
    }

    return (-not [bool]$booleanItems[-1])
}
