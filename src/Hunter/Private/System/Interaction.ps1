function Show-YesNoDialog {
    param(
        [Parameter(Mandatory)][string]$Title,
        [Parameter(Mandatory)][string]$Message,
        [bool]$DefaultToNo = $true
    )

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop

        $defaultButton = if ($DefaultToNo) {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        } else {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        }

        $dialogResult = [System.Windows.Forms.MessageBox]::Show(
            $Message,
            $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            $defaultButton
        )

        return ($dialogResult -eq [System.Windows.Forms.DialogResult]::Yes)
    } catch {
        Add-RunInfrastructureIssue -Message "Failed to show confirmation dialog '$Title': $($_.Exception.Message). Defaulting to No." -Level 'WARN'
        return $false
    }
}

function Test-HunterProgressWindowReady {
    if ($null -eq $script:UiSync) {
        return $false
    }

    try {
        return [bool]$script:UiSync.Ready
    } catch {
        return $false
    }
}

function Initialize-HunterInteractivePreferences {
    param(
        [object[]]$Tasks,
        [object]$Context = $null
    )

    if ($null -ne $Context) {
        Set-HunterContext -Context $Context
    } else {
        $Context = Get-HunterContext
    }

    if ($script:IsAutomationRun -or $script:DryRunMode) {
        return
    }

    $taskList = @($Tasks)
    if ($taskList.Count -eq 0) {
        return
    }

    $requestedSkipTaskIds = @($script:SkipTaskIds | Select-Object -Unique)
    $pendingTaskIds = @(
        $taskList |
            Where-Object {
                $taskId = [string]$_.TaskId
                -not (Test-TaskCompleted -TaskId $taskId -Context $Context) -and $taskId -notin $requestedSkipTaskIds
            } |
            ForEach-Object { [string]$_.TaskId }
    )

    if ($pendingTaskIds -contains 'core-local-user-v2') {
        Write-Log 'Capturing standard-user setup consent before the progress overlay starts.' 'INFO'
        Resolve-CreateLocalUserPreference | Out-Null
    }

    if (($pendingTaskIds -contains 'core-autologin-v2') -and -not $script:IsHyperVGuest -and [bool]$script:CreateLocalUser) {
        Write-Log 'Capturing autologin consent before the progress overlay starts.' 'INFO'
        Resolve-ConfigureAutologinPreference | Out-Null
    }
}

function Resolve-SkipAppDownloadsPreference {
    if ($null -ne $script:SkipAppDownloads) {
        return [bool]$script:SkipAppDownloads
    }

    if ($script:IsAutomationRun) {
        $script:SkipAppDownloads = $false
        return $false
    }

    $script:SkipAppDownloads = Show-YesNoDialog `
        -Title 'Hunter App Downloads' `
        -Message "Skip app downloads and installs?`n`nChoose Yes to skip package downloads and installs, or No to continue with the normal app download and install pipeline." `
        -DefaultToNo $true

    if ($script:SkipAppDownloads) {
        Write-Log 'App downloads and installs skipped by user.' 'INFO'
    } else {
        Write-Log 'App downloads and installs enabled by user.' 'INFO'
    }

    return [bool]$script:SkipAppDownloads
}

function Resolve-CreateLocalUserPreference {
    if ($null -ne $script:CreateLocalUser) {
        return [bool]$script:CreateLocalUser
    }

    if ($script:IsAutomationRun) {
        $script:CreateLocalUser = $false
        Write-Log 'Skipping standard user creation in automation-safe mode because Hunter requires explicit user consent for this step.' 'INFO'
        return $false
    }

    if (Test-HunterProgressWindowReady) {
        $script:CreateLocalUser = $false
        Add-RunInfrastructureIssue -Message 'Standard user consent was requested after the progress overlay started. Defaulting to No to avoid a blocked run.' -Level 'WARN'
        return $false
    }

    $script:CreateLocalUser = Show-YesNoDialog `
        -Title 'Hunter Standard User' `
        -Message "Create the standard local 'user' account?`n`nChoose Yes to create (or normalize) the standard local user account that Hunter manages, or No to skip this step. Skipping this account also skips autologin." `
        -DefaultToNo $true

    if ($script:CreateLocalUser) {
        Write-Log 'Standard user creation enabled by user.' 'INFO'
    } else {
        Write-Log 'Standard user creation skipped by user.' 'INFO'
    }

    return [bool]$script:CreateLocalUser
}

function Resolve-ConfigureAutologinPreference {
    if ($null -ne $script:ConfigureAutologin) {
        return [bool]$script:ConfigureAutologin
    }

    if ($script:IsAutomationRun) {
        $script:ConfigureAutologin = $false
        Write-Log 'Skipping autologin in automation-safe mode because Hunter requires explicit user consent for this step.' 'INFO'
        return $false
    }

    if (Test-HunterProgressWindowReady) {
        $script:ConfigureAutologin = $false
        Add-RunInfrastructureIssue -Message 'Autologin consent was requested after the progress overlay started. Defaulting to No to avoid a blocked run.' -Level 'WARN'
        return $false
    }

    $script:ConfigureAutologin = Show-YesNoDialog `
        -Title 'Hunter Autologin' `
        -Message "Configure automatic sign-in for the standard local 'user' account?`n`nChoose Yes to configure Sysinternals Autologon for this account, or No to leave Windows sign-in manual." `
        -DefaultToNo $true

    if ($script:ConfigureAutologin) {
        Write-Log 'Autologin configuration enabled by user.' 'INFO'
    } else {
        Write-Log 'Autologin configuration skipped by user.' 'INFO'
    }

    return [bool]$script:ConfigureAutologin
}

function Resolve-ForceStorageOptimizationPreference {
    if ([bool]$script:ForceStorageOptimizationRequested -or $env:HUNTER_FORCE_STORAGE_OPTIMIZATION -eq '1') {
        $script:ForceStorageOptimizationRequested = $true
        return $true
    }

    Write-Log 'Skipping NTFS USN journal deletion and disk write-cache buffer-flushing disable by default. Pass -ForceStorageOptimization or set HUNTER_FORCE_STORAGE_OPTIMIZATION=1 to opt in.' 'INFO'
    return $false
}

function Resolve-DisableAudioEnhancementsPreference {
    if ([bool]$script:DisableAudioEnhancementsRequested -or $env:HUNTER_DISABLE_AUDIO_ENHANCEMENTS -eq '1') {
        $script:DisableAudioEnhancementsRequested = $true
        return $true
    }

    Write-Log 'Skipping audio-enhancement disable by default. Pass -DisableAudioEnhancements or set HUNTER_DISABLE_AUDIO_ENHANCEMENTS=1 to opt in.' 'INFO'
    return $false
}

function Resolve-DisableSystemSoundsPreference {
    if ([bool]$script:DisableSystemSoundsRequested -or $env:HUNTER_DISABLE_SYSTEM_SOUNDS -eq '1') {
        $script:DisableSystemSoundsRequested = $true
        return $true
    }

    Write-Log 'Skipping Windows sound-scheme disable by default. Pass -DisableSystemSounds or set HUNTER_DISABLE_SYSTEM_SOUNDS=1 to opt in.' 'INFO'
    return $false
}

function Resolve-ForceTextInputServiceRedirectPreference {
    if ([bool]$script:ForceTextInputServiceRedirectRequested -or $env:HUNTER_FORCE_TEXT_INPUT_SERVICE_REDIRECT -eq '1') {
        $script:ForceTextInputServiceRedirectRequested = $true
        return $true
    }

    Write-Log 'Skipping the advanced TextInputManagementService ServiceDll redirect by default. Pass -ForceTextInputServiceRedirect or set HUNTER_FORCE_TEXT_INPUT_SERVICE_REDIRECT=1 to opt in.' 'INFO'
    return $false
}

function Resolve-RunTcpOptimizerPreference {
    if ([bool]$script:RunTcpOptimizerRequested -or $env:HUNTER_RUN_TCP_OPTIMIZER -eq '1') {
        $script:RunTcpOptimizerRequested = $true
        return $true
    }

    Write-Log 'Skipping TCP Optimizer download and launch by default to avoid Defender/SmartScreen prompts. Pass -RunTcpOptimizer or set HUNTER_RUN_TCP_OPTIMIZER=1 to opt in.' 'INFO'
    return $false
}

function Resolve-RunOOSUPreference {
    if ([bool]$script:RunOOSURequested -or $env:HUNTER_RUN_OOSU -eq '1') {
        $script:RunOOSURequested = $true
        return $true
    }

    Write-Log 'Skipping O&O ShutUp10 download and execution by default to avoid Defender/SmartScreen prompts. Pass -RunOOSU or set HUNTER_RUN_OOSU=1 to opt in.' 'INFO'
    return $false
}
