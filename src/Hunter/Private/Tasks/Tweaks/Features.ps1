function Invoke-DisableIPv6 {
    <#
    .SYNOPSIS
    Fully disables IPv6 on all adapters via registry and adapter binding.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disableipv6/
    #>
    try {
        if (-not $script:DisableIPv6Requested) {
            Write-Log 'Skipping IPv6 disable by default. Pass -DisableIPv6 or set HUNTER_DISABLE_IPV6=1 to opt in.' 'INFO'
            return (New-TaskSkipResult -Reason 'IPv6 disable is opt-in because some remote access and gaming services rely on IPv6')
        }

        Write-Log 'Disabling IPv6...' 'INFO'

        # Set DisabledComponents = 255 (0xFF) to disable all IPv6 components
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' `
            -Name 'DisabledComponents' -Value 255 -Type 'DWord'

        # Disable IPv6 binding on all network adapters
        try {
            Disable-NetAdapterBinding -Name '*' -ComponentID 'ms_tcpip6' -ErrorAction Stop
            Write-Log 'IPv6 adapter bindings disabled on all adapters.' 'SUCCESS'
        } catch {
            Write-Log "Failed to disable IPv6 adapter binding: $($_.Exception.Message)" 'WARN'
        }

        Write-Log 'IPv6 disabled (DisabledComponents=255).' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to disable IPv6: $_" 'ERROR'
        return $false
    }
}

# ==============================================================================
# PHASE 4 - EXPLORER
# ==============================================================================


function Invoke-DisableHibernation {
    <#
    .SYNOPSIS
    Disables Windows hibernation mode.
    .DESCRIPTION
    Ref: https://winutil.christitus.com/dev/tweaks/essential-tweaks/hiber/
    #>
    param()

    try {
        Write-Log -Message "Disabling hibernation..." -Level 'INFO'

        # Pre-check
        $powerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        if (Test-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -ExpectedValue 0) {
            Write-Log -Message "Hibernation already disabled. Skipping." -Level 'INFO'
            return $true
        }

        # Disable via powercfg
        Write-Log -Message "Running powercfg /h off..." -Level 'INFO'
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/h', 'off') | Out-Null

        # Registry settings
        Set-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings' -Name 'ShowHibernateOption' -Value 0 -Type 'DWord'

        Write-Log -Message "Hibernation disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableHibernation: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableBackgroundApps {
    <#
    .SYNOPSIS
    Disables background app refresh and adjacent background-activity surfaces.
    #>
    param()

    try {
        Write-Log -Message "Disabling background apps and adjacent background activity..." -Level 'INFO'

        # Pre-check
        $bgAppsPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\BackgroundAccessApplications'
        $teamsStartupTaskDisabled = Test-ScheduledTaskDisabledOrMissing -TaskPath '\Microsoft\Teams\' -TaskName 'TeamsStartupTask'
        $teamsAutoStartDisabled = (
            $null -eq (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'com.squirrel.Teams.Teams' -ErrorAction SilentlyContinue) -and
            $null -eq (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams' -ErrorAction SilentlyContinue) -and
            $null -eq (Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams' -ErrorAction SilentlyContinue)
        )
        if ((Test-RegistryValue -Path $bgAppsPath -Name 'GlobalUserDisabled' -ExpectedValue 1) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'DisableFileSyncNGSC' -ExpectedValue 1) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowWidgets' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main' -Name 'AllowPrelaunch' -ExpectedValue 0) -and
            (Test-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\TabPreloader' -Name 'AllowTabPreloading' -ExpectedValue 0) -and
            $teamsAutoStartDisabled -and
            $teamsStartupTaskDisabled) {
            Write-Log -Message "Background apps already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $bgAppsPath -Name 'GlobalUserDisabled' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive' -Name 'DisableFileSyncNGSC' -Value 1 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowWidgets' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'BackgroundModeEnabled' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -Name 'StartupBoostEnabled' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\Main' -Name 'AllowPrelaunch' -Value 0 -Type DWord
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\MicrosoftEdge\TabPreloader' -Name 'AllowTabPreloading' -Value 0 -Type DWord
        Remove-RegistryValueIfPresent -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'com.squirrel.Teams.Teams'
        Remove-RegistryValueIfPresent -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -Name 'Teams'
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Teams\' -TaskName 'TeamsStartupTask' -DisplayName 'Teams startup task' | Out-Null

        Write-Log -Message "Background apps and adjacent background activity disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableBackgroundApps: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableTeredo {
    <#
    .SYNOPSIS
    Disables Windows Teredo IPv6 tunneling service.
    #>
    param()

    try {
        if (-not (Resolve-DisableTeredoPreference)) {
            Write-Log 'Skipping Teredo disable by default. Pass -DisableTeredo or set HUNTER_DISABLE_TEREDO=1 to opt in.' 'INFO'
            return (New-TaskSkipResult -Reason 'Teredo disable is opt-in because some gaming, Xbox Live, and VPN scenarios still rely on it')
        }

        Write-Log -Message "Disabling Teredo..." -Level 'INFO'

        # Pre-check: Is Teredo already disabled?
        $teredoState = & netsh interface teredo show state 2>$null
        if ($teredoState -match 'offline|disabled') {
            Write-Log -Message "Teredo already disabled. Skipping." -Level 'INFO'
            return (New-TaskSkipResult -Reason 'Teredo already disabled')
        }

        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('interface', 'teredo', 'set', 'state', 'disabled') | Out-Null

        # Persist Teredo disable across reboots via registry (WinUtil parity)
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters' -Name 'DisabledComponents' -Value 1 -Type 'DWord'

        Write-Log -Message "Teredo disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableTeredo: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableFullscreenOptimizations {
    <#
    .SYNOPSIS
    Disables DirectX fullscreen optimizations (GameDVR settings).
    #>
    param()

    try {
        Write-Log -Message "Disabling fullscreen optimizations..." -Level 'INFO'

        # Pre-check
        $gamePath = 'HKCU:\System\GameConfigStore'
        if ((Test-RegistryValue -Path $gamePath -Name 'GameDVR_DXGIHonorFSEWindowsCompatible' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $gamePath -Name 'GameDVR_Enabled' -ExpectedValue 0) -and
            (Test-RegistryValue -Path $gamePath -Name 'GameDVR_FSEBehaviorMode' -ExpectedValue 2)) {
            Write-Log -Message "Fullscreen optimizations already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $gamePath -Name 'GameDVR_DXGIHonorFSEWindowsCompatible' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $gamePath -Name 'GameDVR_Enabled' -Value 0 -Type 'DWord'
        Set-RegistryValue -Path $gamePath -Name 'GameDVR_FSEBehaviorMode' -Value 2 -Type 'DWord'
        Set-RegistryValue -Path $gamePath -Name 'GameDVR_HonorUserFSEBehaviorMode' -Value 1 -Type 'DWord'

        Write-Log -Message "Fullscreen optimizations disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableFullscreenOptimizations: $_" -Level 'ERROR'
        return $false
    }
}
