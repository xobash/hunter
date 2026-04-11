function Invoke-NukeBlockApps {
    <#
    .SYNOPSIS
    NUKE+BLOCK pass: Remove multiple apps, services, scheduled tasks, and registry blocks.
    .DESCRIPTION
    Removes Outlook, LinkedIn, Xbox, Games, Feedback Hub, Office, Bing, Clipchamp, News, Teams, ToDo, Power Automate, Sound Recorder, Weather.
    #>
    param()

    try {
        if ($script:SkipStoreAndAppxTasks) {
            Write-Log 'Skipping broad AppX removal because this Windows edition is not a supported consumer Store/AppX build.' 'INFO'
            return (New-TaskSkipResult -Reason 'Broad AppX removal is skipped on unsupported LTSC/Server editions')
        }

        Write-Log -Message "Starting comprehensive app NUKE+BLOCK removal..." -Level 'INFO'

        $startSurfaceShortcutDirs = @(((Get-DesktopShortcutDirectories) + (Get-StartMenuShortcutDirectories)) | Select-Object -Unique)
        $linkedInPatterns = @('*LinkedIn*', '*LinkedInForWindows*')
        $blockedStartPinsPatterns = Get-DefaultBlockedStartPinsPatterns
        $customSelections = Load-HunterCustomAppsList
        $usingCustomAppsList = ($customSelections.Count -gt 0)
        $phase6Targets = if ($usingCustomAppsList) {
            @(Resolve-HunterAppCatalogEntries -Groups @('Phase6Broad') -Selections $customSelections)
        } else {
            @(Resolve-HunterAppCatalogEntries -Groups @('Phase6Broad') -SelectedByDefaultOnly)
        }

        if ($phase6Targets.Count -eq 0) {
            Write-Log 'No supported Phase 6 app removal targets were resolved. Skipping broad app removal.' 'INFO'
            return (New-TaskSkipResult -Reason 'No supported broad app removal targets were selected')
        }

        $selectedTargetIds = @($phase6Targets | ForEach-Object { [string]$_.Id })
        Invoke-ApplyAppRemovalStrategies -Entries $phase6Targets | Out-Null

        # LinkedIn specific shortcut/unpin/start-menu operations
        if ($selectedTargetIds -contains 'linkedin') {
            Write-Log -Message "Removing LinkedIn shortcuts and pins..." -Level 'INFO'
            Invoke-StartMenuUnpinByPatterns -Patterns $linkedInPatterns
            Invoke-AppsFolderUninstallByPatterns -Patterns $linkedInPatterns
            Remove-ShortcutsByPattern -Directories $startSurfaceShortcutDirs -Patterns $linkedInPatterns
        }

        # Disable Game DVR capture (WinUtil parity)
        if ($selectedTargetIds -contains 'xbox') {
            Write-Log -Message "Disabling Xbox Game DVR..." -Level 'INFO'
            Set-DwordBatchForAllUsers -Settings @(
                @{ SubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 },
                @{ SubPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Value = 0 },
                @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 },
                @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Value = 2 },
                @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; Value = 1 }
            )
            Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord
            Set-DwordBatchForAllUsers -Settings @(
                @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'ShowStartupPanel'; Value = 0 },
                @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Value = 0 }
            )
        }

        # Teams folder removal
        if ($selectedTargetIds -contains 'teams') {
            Write-Log -Message "Removing Teams folders..." -Level 'INFO'
            Remove-PathForce "$env:LOCALAPPDATA\Microsoft\Teams"
            Remove-RegistryValueIfPresent -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'com.squirrel.Teams.Teams'
            Remove-RegistryValueIfPresent -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams'
            Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams'
            Remove-ShortcutsByPattern -Directories $startSurfaceShortcutDirs -Patterns @('*Teams*')
            Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Teams\' -TaskName 'TeamsStartupTask' -DisplayName 'Teams startup task' | Out-Null
        }

        # Start pins policy
        $liveCleanupResult = $true
        if (-not $usingCustomAppsList) {
            if (-not (Clear-StaleStartCustomizationPolicies)) {
                return $false
            }

            $liveCleanupResult = Invoke-ApplyLiveStartPinCleanup -BlockedPatterns $blockedStartPinsPatterns
            if (Test-TaskHandlerReturnedFailure -TaskResult $liveCleanupResult) {
                return $false
            }
        }

        # Explorer/Start restart
        Request-ExplorerRestart

        # Verification checks
        if (($selectedTargetIds -contains 'linkedin') -and (Test-AppxPatternExists -Patterns $linkedInPatterns)) {
            throw 'LinkedIn packages are still present after removal.'
        }

        if (($selectedTargetIds -contains 'xbox') -and (Test-AppxPatternExists -Patterns @(
                'Microsoft.XboxIdentityProvider*',
                'Microsoft.XboxSpeechToTextOverlay*',
                'Microsoft.GamingApp*',
                'Microsoft.Xbox.TCUI*',
                'Microsoft.XboxGamingOverlay*'
            ))) {
            throw 'Xbox or gaming AppX packages are still present after removal.'
        }

        Write-Log -Message "App NUKE+BLOCK removal complete." -Level 'INFO'
        return $liveCleanupResult
    }
    catch {
        Write-Log -Message "Error in Invoke-NukeBlockApps: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableInkingTyping {
    <#
    .SYNOPSIS
    Disables inking and typing personalization/telemetry.
    #>
    param()

    try {
        Write-Log -Message "Disabling inking and typing personalization..." -Level 'INFO'

        # Pre-check
        $inkingPath = 'HKCU:\Software\Microsoft\InputPersonalization'
        if ((Test-RegistryValue -Path $inkingPath -Name 'RestrictImplicitTextCollection' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $inkingPath -Name 'RestrictImplicitInkCollection' -ExpectedValue 1)) {
            Write-Log -Message "Inking/typing already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitTextCollection'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\InputPersonalization'; Name = 'RestrictImplicitInkCollection'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\InputPersonalization\TrainedDataStore'; Name = 'HarvestContacts'; Value = 0 }
        )
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsInkWorkspace' -Name 'AllowWindowsInkWorkspace' -Value 0 -Type DWord

        Write-Log -Message "Inking and typing personalization disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableInkingTyping: $_" -Level 'ERROR'
        return $false
    }
}


function Invoke-BlockRazerSoftware {
    <#
    .SYNOPSIS
    Blocks Razer software installs via the WinUtil installer-folder ACL method.
    #>
    param()

    try {
        Write-Log -Message "Blocking Razer software..." -Level 'INFO'

        $razerPath = 'C:\Windows\Installer\Razer'

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' -Name 'SearchOrderConfig' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Device Installer' -Name 'DisableCoInstallers' -Value 1 -Type 'DWord'

        if (Test-Path $razerPath) {
            Remove-Item "$razerPath\*" -Recurse -Force -ErrorAction SilentlyContinue
        } else {
            New-Item -Path $razerPath -ItemType Directory -Force | Out-Null
        }

        & icacls $razerPath /deny 'Everyone:(W)' 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Failed to deny write access to the Razer installer path.'
        }

        Write-Log -Message "Razer software blocked." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-BlockRazerSoftware: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-BlockAdobeNetworkTraffic {
    <#
    .SYNOPSIS
    Blocks Adobe network traffic via hosts file.
    #>
    param()

    try {
        Write-Log -Message "Blocking Adobe network traffic..." -Level 'INFO'

        $adobeHosts = @(
            'ic-contrib.adobe.io',
            'cc-api-data.adobe.io',
            'notify.adobe.io',
            'prod.adobegenuine.com',
            'gocart.adobe.com',
            'genuine.adobe.com',
            'assets.adobedtm.com',
            'adobeereg.com',
            'activate.adobe.com',
            'practivate.adobe.com',
            'ereg.adobe.com',
            'wip3.adobe.com',
            'activate-sea.adobe.com',
            'activate-sjc0.adobe.com',
            '3dns-3.adobe.com',
            '3dns-2.adobe.com',
            'lm.licenses.adobe.com',
            'na1r.services.adobe.com',
            'hlrcv.stage.adobe.com',
            'lmlicenses.wip4.adobe.com',
            'na2m-stg1.services.adobe.com'
        )

        # Pre-check: Are Adobe hosts already blocked?
        $hostsFile = $script:HostsFilePath
        $hostsContent = Get-Content $hostsFile -ErrorAction SilentlyContinue
        $alreadyBlocked = $true
        foreach ($domain in $adobeHosts) {
            if (-not @($hostsContent | Where-Object { $_ -match [regex]::Escape($domain) })) {
                $alreadyBlocked = $false
                break
            }
        }

        if ($alreadyBlocked) {
            Write-Log -Message "Adobe hosts already blocked. Skipping." -Level 'INFO'
            return $true
        }

        Add-HostsEntries -Hostnames $adobeHosts

        Write-Log -Message "Adobe network traffic blocked." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-BlockAdobeNetworkTraffic: $_" -Level 'ERROR'
        return $false
    }
}


function Invoke-BraveDebloat {
    <#
    .SYNOPSIS
    Disables Brave rewards, wallet, VPN, and AI chat.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/bravedebloat/
    #>
    param()

    try {
        Write-Log -Message "Debloating Brave..." -Level 'INFO'

        $bravePath = 'HKLM:\SOFTWARE\Policies\BraveSoftware\Brave'
        if ((Test-RegistryValue -Path $bravePath -Name 'BraveRewardsDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveWalletDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveVPNDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveAIChatEnabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $bravePath -Name 'BraveStatsPingEnabled' -ExpectedValue 0)) {
            Write-Log -Message "Brave already debloated. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $bravePath -Name 'BraveRewardsDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveWalletDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveVPNDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveAIChatEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $bravePath -Name 'BraveStatsPingEnabled' -Value 0 -Type 'DWord'

        Write-Log -Message "Brave debloated." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-BraveDebloat: $_" -Level 'ERROR'
        return $false
    }
}
