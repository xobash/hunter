function Invoke-EnableDarkMode {
    if (Test-TaskCompleted -TaskId 'core-dark-mode') {
        Write-Log "Dark mode already enabled, skipping"
        return (New-TaskSkipResult -Reason 'Dark mode is already enabled')
    }

    try {
        $themePath = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $themePath; Name = 'AppsUseLightTheme'; Value = 0 },
            @{ SubPath = $themePath; Name = 'SystemUsesLightTheme'; Value = 0 }
        )

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to enable dark mode : $_" 'ERROR'
        return $false
    }
}


function Invoke-DisableBingStartSearch {
    if (Test-TaskCompleted -TaskId 'startui-bing-search') {
        Write-Log "Bing search already disabled, skipping"
        return (New-TaskSkipResult -Reason 'Bing search is already disabled')
    }

    try {
        $searchPath = 'Software\Microsoft\Windows\CurrentVersion\Search'
        $policyPath = 'SOFTWARE\Policies\Microsoft\Windows\Windows Search'

        Set-RegistryValue -Path "HKLM:\$policyPath" -Name 'DisableWebSearch' -Value 1 -Type DWord
        Set-RegistryValue -Path "HKLM:\$policyPath" -Name 'AllowCortana' -Value 0 -Type DWord

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $searchPath; Name = 'BingSearchEnabled'; Value = 0 },
            @{ SubPath = $searchPath; Name = 'CortanaConsent'; Value = 0 }
        )

        return $true
    } catch {
        Write-Log "Failed to disable Bing search : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableStartRecommendations {
    try {
        $buildContext = Get-WindowsBuildContext
        if (-not $buildContext.IsWindows11) {
            Write-Log "Start recommendations are not applicable on build $($buildContext.CurrentBuild). Skipping." 'INFO'
            return (New-TaskSkipResult -Reason 'Start recommendations only apply to Windows 11')
        }

        $advPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
        $policyPath = 'Software\Policies\Microsoft\Windows\Explorer'
        $policyManagerStartPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Start'
        $policyManagerEducationPath = 'HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\Education'
        $blockedStartPinsPatterns = Get-DefaultBlockedStartPinsPatterns

        if (-not (Clear-StaleStartCustomizationPolicies)) {
            return $false
        }

        # HKLM policy writes (WinUtil-aligned: 3 machine-level keys)
        Set-RegistryValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer" -Name 'HideRecommendedSection' -Value 1 -Type DWord
        Set-RegistryValue -Path $policyManagerStartPath -Name 'HideRecommendedSection' -Value 1 -Type DWord
        Set-RegistryValue -Path $policyManagerEducationPath -Name 'IsEducationEnvironment' -Value 1 -Type DWord

        # Per-user registry writes (additional coverage beyond WinUtil)
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $advPath; Name = 'Start_IrisRecommendations'; Value = 0 },
            @{ SubPath = $advPath; Name = 'Start_AccountNotifications'; Value = 0 },
            @{ SubPath = $policyPath; Name = 'HideRecommendedSection'; Value = 1 }
        )

        # Verify every HKLM write — fail the task if any did not persist
        $verifyFailed = $false
        $verifyPairs = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'; Name = 'HideRecommendedSection'; Expected = 1 },
            @{ Path = $policyManagerStartPath; Name = 'HideRecommendedSection'; Expected = 1 },
            @{ Path = $policyManagerEducationPath; Name = 'IsEducationEnvironment'; Expected = 1 }
        )
        foreach ($v in $verifyPairs) {
            if (-not (Test-RegistryValue -Path $v.Path -Name $v.Name -ExpectedValue $v.Expected)) {
                Write-Log "VERIFY FAILED: $($v.Path)\$($v.Name) expected $($v.Expected) but did not read back" 'ERROR'
                $verifyFailed = $true
            }
        }

        # Also verify HKCU writes
        $hkcuVerifyPairs = @(
            @{ Path = "HKCU:\$advPath"; Name = 'Start_IrisRecommendations'; Expected = 0 },
            @{ Path = "HKCU:\$advPath"; Name = 'Start_AccountNotifications'; Expected = 0 },
            @{ Path = "HKCU:\$policyPath"; Name = 'HideRecommendedSection'; Expected = 1 }
        )
        foreach ($v in $hkcuVerifyPairs) {
            if (-not (Test-RegistryValue -Path $v.Path -Name $v.Name -ExpectedValue $v.Expected)) {
                Write-Log "VERIFY FAILED: $($v.Path)\$($v.Name) expected $($v.Expected) but did not read back" 'ERROR'
                $verifyFailed = $true
            }
        }

        if ($verifyFailed) {
            return $false
        }

        $liveCleanupResult = Invoke-ApplyLiveStartPinCleanup -BlockedPatterns $blockedStartPinsPatterns
        if (Test-TaskHandlerReturnedFailure -TaskResult $liveCleanupResult) {
            return $false
        }
        Request-ExplorerRestart
        return $liveCleanupResult
    } catch {
        Write-Log "Failed to disable Start recommendations : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableTaskbarSearchBox {
    if (Test-TaskCompleted -TaskId 'startui-search-box') {
        Write-Log "Taskbar search box already disabled, skipping"
        return (New-TaskSkipResult -Reason 'Taskbar search box is already disabled')
    }

    try {
        $searchPath = 'Software\Microsoft\Windows\CurrentVersion\Search'

        Set-DwordForAllUsers -SubPath $searchPath -Name 'SearchboxTaskbarMode' -Value 0

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to disable taskbar search box : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableTaskViewButton {
    if (Test-TaskCompleted -TaskId 'startui-task-view') {
        Write-Log "Task view button already disabled, skipping"
        return (New-TaskSkipResult -Reason 'Task view button is already disabled')
    }

    try {
        $advPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'

        Set-DwordForAllUsers -SubPath $advPath -Name 'ShowTaskViewButton' -Value 0

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to disable Task view button : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableWidgets {
    if (Test-TaskCompleted -TaskId 'startui-widgets') {
        Write-Log "Widgets already disabled, skipping"
        return $true
    }

    try {
        if ($script:SkipStoreAndAppxTasks) {
            Write-Log 'Skipping Widgets removal because this Windows edition is not a supported consumer Store/AppX build.' 'INFO'
            return (New-TaskSkipResult -Reason 'Widgets removal is skipped on unsupported LTSC/Server editions')
        }

        $buildContext = Get-WindowsBuildContext
        Stop-Process -Name Widgets -Force -ErrorAction SilentlyContinue
        $widgetEntries = Resolve-HunterAppCatalogEntries -Selections @('widgets')
        if ($widgetEntries.Count -gt 0) {
            Invoke-ApplyAppRemovalStrategies -Entries $widgetEntries | Out-Null
        }

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' -Name 'AllowNewsAndInterests' -Value 0 -Type 'DWord'

        if ($buildContext.IsWindows11) {
            $widgetsAdvancedPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
            try {
                if (-not (Test-Path $widgetsAdvancedPath)) {
                    New-Item -Path (Split-Path -Parent $widgetsAdvancedPath) -Name (Split-Path -Leaf $widgetsAdvancedPath) -Force | Out-Null
                }

                New-ItemProperty -Path $widgetsAdvancedPath -Name 'TaskbarDa' -Value 0 -PropertyType DWord -Force | Out-Null
                Write-Log "DWord set for current user: $widgetsAdvancedPath\TaskbarDa = 0"
            } catch {
                Write-Log "Skipping per-user Widgets taskbar flag update: $($_.Exception.Message)" 'INFO'
            }

            Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\PolicyManager\default\NewsAndInterests\AllowNewsAndInterests' -Name 'value' -Value 0 -Type 'DWord'
        }

        Request-ExplorerRestart
        return $true
    } catch {
        Write-Log "Failed to disable widgets : $_" 'ERROR'
        return $false
    }
}

function Invoke-EnableEndTaskOnTaskbar {
    if (Test-TaskCompleted -TaskId 'startui-end-task') {
        Write-Log "End Task on taskbar already enabled, skipping"
        return $true
    }

    try {
        $buildContext = Get-WindowsBuildContext
        if (-not (Test-WindowsBuildInRange -MinBuild 22621)) {
            Write-Log "End Task on taskbar is not applicable on build $($buildContext.CurrentBuild). Skipping." 'INFO'
            return (New-TaskSkipResult -Reason 'Taskbar End Task is only available on supported Windows 11 builds')
        }

        $taskbarDevPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings'

        Set-RegistryValue -Path "HKCU:\$taskbarDevPath" -Name 'TaskbarEndTask' -Value 1 -Type DWord
        if (-not (Test-RegistryValue -Path "HKCU:\$taskbarDevPath" -Name 'TaskbarEndTask' -ExpectedValue 1)) {
            throw 'TaskbarEndTask was not persisted for the current user.'
        }
        return $true
    } catch {
        Write-Log "Failed to enable End Task on taskbar : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableNotificationsTrayCalendar {
    if (Test-TaskCompleted -TaskId 'startui-notifications') {
        Write-Log "Notifications already disabled, skipping"
        return (New-TaskSkipResult -Reason 'Notifications are already disabled')
    }

    try {
        $notificationsPath = 'Software\Microsoft\Windows\CurrentVersion\PushNotifications'
        $explorerPolicyPath = 'Software\Policies\Microsoft\Windows\Explorer'
        $quietHoursPolicyPath = 'Software\Policies\Microsoft\Windows\CurrentVersion\QuietHours'

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = $notificationsPath; Name = 'ToastEnabled'; Value = 0 },
            @{ SubPath = $explorerPolicyPath; Name = 'DisableNotificationCenter'; Value = 1 },
            @{ SubPath = $quietHoursPolicyPath; Name = 'Enable'; Value = 0 }
        )

        return $true

    } catch {
        Write-Log "Failed to disable notifications : $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableNewOutlook {
    <#
    .SYNOPSIS
    Disables the new Outlook experience and prevents auto-migration.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/customize-preferences/newoutlook/
    #>
    try {
        Write-Log 'Disabling new Outlook toggle and auto-migration...' 'INFO'

        $prefsPath   = 'HKCU:\SOFTWARE\Microsoft\Office\16.0\Outlook\Preferences'
        $generalPath = 'HKCU:\Software\Microsoft\Office\16.0\Outlook\Options\General'
        $policyGen   = 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Options\General'
        $policyPrefs = 'HKCU:\Software\Policies\Microsoft\Office\16.0\Outlook\Preferences'

        # Disable new Outlook
        Set-RegistryValue -Path $prefsPath -Name 'UseNewOutlook' -Value 0 -Type 'DWord'

        # Hide the toggle in classic Outlook
        Set-RegistryValue -Path $generalPath -Name 'HideNewOutlookToggle' -Value 1 -Type 'DWord'

        # Prevent auto-migration via policy
        Set-RegistryValue -Path $policyGen -Name 'DoNewOutlookAutoMigration' -Value 0 -Type 'DWord'

        # Remove any user migration setting
        Remove-RegistryValueIfPresent -Path $policyPrefs -Name 'NewOutlookMigrationUserSetting'

        Write-Log 'New Outlook disabled.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to disable new Outlook: $_" 'ERROR'
        return $false
    }
}

function Invoke-HideSettingsHome {
    <#
    .SYNOPSIS
    Hides the Settings home page introduced in recent Windows 11 builds.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/customize-preferences/hidesettingshome/
    #>
    try {
        $buildContext = Get-WindowsBuildContext
        if (-not (Test-WindowsBuildInRange -MinBuild 22621)) {
            Write-Log "Settings home page policy is not applicable on build $($buildContext.CurrentBuild). Skipping." 'INFO'
            return (New-TaskSkipResult -Reason 'Settings home page policy only applies to supported Windows 11 builds')
        }

        Write-Log 'Hiding Settings home page...' 'INFO'

        $regPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'

        Set-RegistryValue -Path $regPath -Name 'SettingsPageVisibility' -Value 'hide:home' -Type 'String'

        Write-Log 'Settings home page hidden.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to hide Settings home: $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableStoreSearch {
    <#
    .SYNOPSIS
    Disables Microsoft Store results from appearing in Windows Search.
    WinUtil parity: https://winutil.christitus.com/dev/tweaks/essential-tweaks/disablestoresearch/
    #>
    try {
        if ($script:SkipStoreAndAppxTasks) {
            Write-Log 'Skipping Microsoft Store search suppression because this Windows edition does not expose the consumer Store/AppX baseline Hunter expects.' 'INFO'
            return (New-TaskSkipResult -Reason 'Microsoft Store search tuning is skipped on unsupported LTSC/Server editions')
        }

        Write-Log 'Disabling Microsoft Store search results...' 'INFO'

        $storeDbPath = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsStore_8wekyb3d8bbwe\LocalState\store.db'

        if (Test-Path $storeDbPath) {
            $icaclsResult = & icacls.exe $storeDbPath /deny 'Everyone:F' 2>&1
            if ($LASTEXITCODE -ne 0) {
                Write-Log "icacls deny failed for store.db: $icaclsResult" 'WARN'
            } else {
                Write-Log "Microsoft Store search database locked via ACL." 'SUCCESS'
            }
        } else {
            Write-Log "Store database not found at $storeDbPath — Store may not be installed. Skipping." 'INFO'
        }

        return $true
    } catch {
        Write-Log "Failed to disable Store search: $_" 'ERROR'
        return $false
    }
}

