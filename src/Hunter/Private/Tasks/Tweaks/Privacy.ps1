function Invoke-DisableDeliveryOptimization {
    <#
    .SYNOPSIS
    Disables Windows Delivery Optimization (P2P update downloads).
    #>
    param()

    try {
        Write-Log -Message "Disabling Delivery Optimization..." -Level 'INFO'

        # Pre-check
        $doPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'
        if (Test-RegistryValue -Path $doPath -Name 'DODownloadMode' -ExpectedValue 0) {
            Write-Log -Message "Delivery Optimization already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $doPath -Name 'DODownloadMode' -Value 0 -Type 'DWord'

        Write-Log -Message "Delivery Optimization disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableDeliveryOptimization: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableConsumerFeatures {
    <#
    .SYNOPSIS
    Disables Windows consumer features and cloud content.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/consumerfeatures/
    #>
    param()

    try {
        Write-Log -Message "Disabling Windows consumer features..." -Level 'INFO'

        # Pre-check
        $cloudPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent'
        $contentDeliveryManagerPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
        $contentDeliveryChecks = @(
            'ContentDeliveryAllowed',
            'FeatureManagementEnabled',
            'OEMPreInstalledAppsEnabled',
            'PreInstalledAppsEnabled',
            'PreInstalledAppsEverEnabled',
            'RotatingLockScreenEnabled',
            'RotatingLockScreenOverlayEnabled',
            'SilentInstalledAppsEnabled',
            'SoftLandingEnabled',
            'SystemPaneSuggestionsEnabled',
            'SubscribedContent-310093Enabled',
            'SubscribedContent-314563Enabled',
            'SubscribedContent-338388Enabled',
            'SubscribedContent-338389Enabled',
            'SubscribedContent-338393Enabled',
            'SubscribedContent-353694Enabled',
            'SubscribedContent-353695Enabled',
            'SubscribedContent-353696Enabled',
            'SubscribedContent-353698Enabled',
            'SubscribedContent-88000326Enabled'
        )

        $consumerFeaturesDisabled = (
            (Test-RegistryValue -Path $cloudPath -Name 'DisableWindowsConsumerFeatures' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $cloudPath -Name 'DisableSoftLanding' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $cloudPath -Name 'DisableWindowsSpotlightFeatures' -ExpectedValue 1)
        )

        if ($consumerFeaturesDisabled) {
            foreach ($name in $contentDeliveryChecks) {
                if (-not (Test-RegistryValue -Path $contentDeliveryManagerPath -Name $name -ExpectedValue 0)) {
                    $consumerFeaturesDisabled = $false
                    break
                }
            }
        }

        if ($consumerFeaturesDisabled) {
            Write-Log -Message "Consumer features already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $cloudPath -Name 'DisableWindowsConsumerFeatures' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $cloudPath -Name 'DisableSoftLanding' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $cloudPath -Name 'DisableWindowsSpotlightFeatures' -Value 1 -Type 'DWord'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'ContentDeliveryAllowed'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'FeatureManagementEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'OEMPreInstalledAppsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'PreInstalledAppsEverEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'RotatingLockScreenOverlayEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SilentInstalledAppsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SoftLandingEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SystemPaneSuggestionsEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-310093Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-314563Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338388Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338389Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-338393Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353694Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353695Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353696Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-353698Enabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'; Name = 'SubscribedContent-88000326Enabled'; Value = 0 }
        )

        Write-Log -Message "Windows consumer features disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableConsumerFeatures: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableActivityHistory {
    <#
    .SYNOPSIS
    Disables Windows activity history, clipboard history, and user activity uploads.
    .DESCRIPTION
    Covers the WinUtil activity-history baseline and Hunter's adjacent clipboard-history
    suppression so cross-device activity surfaces do not remain enabled.
    #>
    param()

    try {
        Write-Log -Message "Disabling activity history..." -Level 'INFO'

        # Pre-check
        $systemPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        if ((Test-RegistryValue -Path $systemPath -Name 'EnableActivityFeed' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'PublishUserActivities' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'UploadUserActivities' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'AllowClipboardHistory' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPath -Name 'AllowCrossDeviceClipboard' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Clipboard' -Name 'EnableClipboardHistory' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Clipboard' -Name 'EnableCloudClipboard' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Clipboard' -Name 'CloudClipboardAutomaticUpload' -ExpectedValue 0)) {
            Write-Log -Message "Activity history already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $systemPath -Name 'EnableActivityFeed' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'PublishUserActivities' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'UploadUserActivities' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'AllowClipboardHistory' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPath -Name 'AllowCrossDeviceClipboard' -Value 0 -Type 'DWord'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Clipboard'; Name = 'EnableClipboardHistory'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Clipboard'; Name = 'EnableCloudClipboard'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Clipboard'; Name = 'CloudClipboardAutomaticUpload'; Value = 0 }
        )

        Write-Log -Message "Activity history disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableActivityHistory: $_" -Level 'ERROR'
        return $false
    }
}

#endregion PHASE 6

#region PHASE 7 - TWEAKS

function Invoke-DisableTelemetry {
    <#
    .SYNOPSIS
    Disables Windows telemetry and Hunter's related privacy/web-content policies.
    .DESCRIPTION
    Starts from the WinUtil telemetry baseline and intentionally extends it with
    SmartScreen/AppHost suppression that Hunter applies as part of its broader
    privacy-hardening pass.
    #>
    param()

    try {
        Write-Log -Message "Disabling Windows telemetry and related privacy/web-content policies..." -Level 'INFO'

        $dcPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection'
        $systemPolicyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System'
        $svcHostPath = 'HKLM:\SYSTEM\CurrentControlSet\Control'
        $siufRulesPath = 'HKCU:\Software\Microsoft\Siuf\Rules'
        $werPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting'
        $splitThresholdKb = [int]((Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB)
        $telemetryScheduledTasks = @(
            @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'Microsoft Compatibility Appraiser'; DisplayName = 'Microsoft Compatibility Appraiser' },
            @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'ProgramDataUpdater'; DisplayName = 'ProgramDataUpdater' },
            @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'StartupAppTask'; DisplayName = 'Application Experience StartupAppTask' },
            @{ TaskPath = '\Microsoft\Windows\Application Experience\'; TaskName = 'PcaPatchDbTask'; DisplayName = 'Application Experience PcaPatchDbTask' },
            @{ TaskPath = '\Microsoft\Windows\Autochk\'; TaskName = 'Proxy'; DisplayName = 'Autochk Proxy' },
            @{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'Consolidator'; DisplayName = 'CEIP Consolidator' },
            @{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'KernelCeipTask'; DisplayName = 'CEIP KernelCeipTask' },
            @{ TaskPath = '\Microsoft\Windows\Customer Experience Improvement Program\'; TaskName = 'UsbCeip'; DisplayName = 'CEIP UsbCeip' },
            @{ TaskPath = '\Microsoft\Windows\DiskDiagnostic\'; TaskName = 'Microsoft-Windows-DiskDiagnosticDataCollector'; DisplayName = 'Disk Diagnostic Data Collector' },
            @{ TaskPath = '\Microsoft\Windows\Feedback\Siuf\'; TaskName = 'DmClient'; DisplayName = 'Feedback DmClient' },
            @{ TaskPath = '\Microsoft\Windows\Feedback\Siuf\'; TaskName = 'DmClientOnScenarioDownload'; DisplayName = 'Feedback DmClientOnScenarioDownload' },
            @{ TaskPath = '\Microsoft\Windows\Windows Error Reporting\'; TaskName = 'QueueReporting'; DisplayName = 'Windows Error Reporting QueueReporting' }
        )
        $telemetryTasksDisabled = $true
        foreach ($telemetryTask in $telemetryScheduledTasks) {
            if (-not (Test-ScheduledTaskDisabledOrMissing -TaskPath $telemetryTask.TaskPath -TaskName $telemetryTask.TaskName)) {
                $telemetryTasksDisabled = $false
                break
            }
        }

        $defenderCloudProtectionDisabled = $false
        try {
            $mpPreference = Get-MpPreference -ErrorAction Stop
            $mapsReportingDisabled = ($mpPreference.MAPSReporting -eq 0 -or [string]$mpPreference.MAPSReporting -eq 'Disabled')
            $sampleSubmissionDisabled = ($mpPreference.SubmitSamplesConsent -eq 2 -or [string]$mpPreference.SubmitSamplesConsent -eq 'NeverSend')
            $defenderCloudProtectionDisabled = ($mapsReportingDisabled -and $sampleSubmissionDisabled -and [bool]$mpPreference.DisableBlockAtFirstSeen)
        } catch {
            $defenderCloudProtectionDisabled = $false
        }

        if ((Test-RegistryValue -Path $dcPath -Name 'AllowTelemetry' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPolicyPath -Name 'PublishUserActivities' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $svcHostPath -Name 'SvcHostSplitThresholdInKB' -ExpectedValue $splitThresholdKb) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Input\TIPC' -Name 'Enabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $siufRulesPath -Name 'NumberOfSIUFInPeriod' -ExpectedValue 0) -and
            (-not (Test-RegistryValue -Path $siufRulesPath -Name 'PeriodInNanoSeconds' -ExpectedValue $null)) -and
            (Test-RegistryValue -Path $dcPath -Name 'DoNotShowFeedbackNotifications' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $werPath -Name 'Disabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $werPath -Name 'DontShowUI' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $systemPolicyPath -Name 'EnableSmartScreen' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $systemPolicyPath -Name 'ShellSmartScreenLevel' -ExpectedValue 'Off') -and
            (Test-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AppHost' -Name 'EnableWebContentEvaluation' -ExpectedValue 0) -and
            (Test-ServiceStartTypeMatch -Name 'diagtrack' -ExpectedStartType 'Disabled') -and
            (Test-ServiceStartTypeMatch -Name 'dmwappushservice' -ExpectedStartType 'Disabled') -and
            (Test-ServiceStartTypeMatch -Name 'WerSvc' -ExpectedStartType 'Disabled') -and
            $telemetryTasksDisabled -and
            $defenderCloudProtectionDisabled) {
            Write-Log -Message "Telemetry already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $dcPath -Name 'AllowTelemetry' -Value 0 -Type 'DWord'

        Set-RegistryValue -Path $systemPolicyPath -Name 'PublishUserActivities' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $svcHostPath -Name 'SvcHostSplitThresholdInKB' -Value $splitThresholdKb -Type 'DWord'

        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Input\TIPC' -Name 'Enabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_TrackProgs' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $siufRulesPath -Name 'NumberOfSIUFInPeriod' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $dcPath -Name 'DoNotShowFeedbackNotifications' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $werPath -Name 'Disabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $werPath -Name 'DontShowUI' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $systemPolicyPath -Name 'EnableSmartScreen' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $systemPolicyPath -Name 'ShellSmartScreenLevel' -Value 'Off' -Type 'String'
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\AppHost'; Name = 'EnableWebContentEvaluation'; Value = 0 }
        )
        Remove-ItemProperty -Path $siufRulesPath -Name 'PeriodInNanoSeconds' -ErrorAction SilentlyContinue

        Write-Log -Message "Disabling telemetry services..." -Level 'INFO'
        Set-ServiceStartType -Name 'diagtrack' -StartType 'Disabled'
        Set-ServiceStartType -Name 'dmwappushservice' -StartType 'Disabled'
        Set-ServiceStartType -Name 'WerSvc' -StartType 'Disabled'
        Stop-ServiceIfPresent -Name 'DiagTrack'
        Stop-ServiceIfPresent -Name 'dmwappushservice'
        Stop-ServiceIfPresent -Name 'WerSvc'

        Write-Log -Message "Disabling telemetry scheduled tasks..." -Level 'INFO'
        foreach ($telemetryTask in $telemetryScheduledTasks) {
            Disable-ScheduledTaskIfPresent -TaskPath $telemetryTask.TaskPath -TaskName $telemetryTask.TaskName -DisplayName $telemetryTask.DisplayName | Out-Null
        }

        Write-Log -Message "Disabling Defender telemetry..." -Level 'INFO'
        try {
            Set-MpPreference -SubmitSamplesConsent 2 -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Could not set Defender telemetry preference: $_" -Level 'WARN'
        }
        try {
            Set-MpPreference -MAPSReporting Disabled -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Could not disable Defender cloud reporting: $_" -Level 'WARN'
        }
        try {
            Set-MpPreference -DisableBlockAtFirstSeen $true -ErrorAction Stop
        }
        catch {
            Write-Log -Message "Could not disable Defender block-at-first-seen: $_" -Level 'WARN'
        }

        Write-Log -Message "Windows telemetry and related privacy/web-content policies disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableTelemetry: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableLocationTracking {
    <#
    .SYNOPSIS
    Disables Windows location tracking and related services.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/location/
    #>
    param()

    try {
        Write-Log -Message "Disabling location tracking..." -Level 'INFO'

        $locPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location'
        $sensorPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Sensor\Overrides\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}'
        $lfsvcConfigurationPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\lfsvc\Service\Configuration'
        $mapsPath = 'HKLM:\SYSTEM\Maps'

        if ((Test-RegistryValue -Path $locPath -Name 'Value' -ExpectedValue 'Deny') -and
            (Test-RegistryValue -Path $sensorPath -Name 'SensorPermissionState' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $lfsvcConfigurationPath -Name 'Status' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $mapsPath -Name 'AutoUpdateEnabled' -ExpectedValue 0)) {
            Write-Log -Message "Location tracking already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $locPath -Name 'Value' -Value 'Deny' -Type 'String'
        Set-RegistryValue -Path $sensorPath -Name 'SensorPermissionState' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $lfsvcConfigurationPath -Name 'Status' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $mapsPath -Name 'AutoUpdateEnabled' -Value 0 -Type 'DWord'

        Write-Log -Message "Location tracking disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableLocationTracking: $_" -Level 'ERROR'
        return $false
    }
}

