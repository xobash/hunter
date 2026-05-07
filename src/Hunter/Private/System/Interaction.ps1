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
        $script:CreateLocalUser = $true
        return $true
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
        $script:ConfigureAutologin = $true
        return $true
    }

    if (-not (Resolve-CreateLocalUserPreference)) {
        $script:ConfigureAutologin = $false
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
