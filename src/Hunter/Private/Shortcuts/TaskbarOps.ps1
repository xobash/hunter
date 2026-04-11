function Remove-TaskbarPinsByPattern {
    param(
        [string[]]$Patterns,
        [string[]]$Paths
    )
    if (($null -eq $Patterns -or $Patterns.Count -eq 0) -and ($null -eq $Paths -or $Paths.Count -eq 0)) { return }

    try {
        $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        if (Test-Path $taskbarPath) {
            foreach ($file in @(Get-ChildItem -Path $taskbarPath -Recurse -File -ErrorAction SilentlyContinue)) {
                if ($file.Extension -ne '.lnk') { continue }

                $removePin = $false
                foreach ($pattern in @($Patterns)) {
                    if ($file.Name -like $pattern) {
                        $removePin = $true
                        break
                    }
                }

                if (-not $removePin) {
                    $targetPath = Get-ShortcutTargetPath -ShortcutPath $file.FullName
                    foreach ($candidatePath in @($Paths)) {
                        if ([string]::IsNullOrWhiteSpace($candidatePath)) {
                            continue
                        }

                        if ($targetPath -ieq $candidatePath) {
                            $removePin = $true
                            break
                        }
                    }
                }

                if (-not $removePin) {
                    continue
                }

                try {
                    Remove-Item -Path $file.FullName -Force
                    Write-Log "Taskbar pin removed: $($file.FullName)"
                } catch {
                    Write-Log "Failed to remove taskbar pin $($file.FullName) : $_" 'ERROR'
                }
            }
        }
    } catch {
        Write-Log "Failed to process taskbar pins : $_" 'ERROR'
    }
}

function Get-NormalizedShellVerbName {
    param([object]$Verb)
    if ($null -eq $Verb) { return '' }

    $verbName = [string]$Verb.Name
    if ([string]::IsNullOrWhiteSpace($verbName)) { return '' }

    return (($verbName -replace '&', '') -replace '\s+', ' ').Trim()
}

function Find-ShellVerbByPattern {
    param(
        [object]$Item,
        [string[]]$Patterns
    )

    foreach ($verb in @($Item.Verbs())) {
        $verbName = Get-NormalizedShellVerbName -Verb $verb
        foreach ($pattern in @($Patterns)) {
            if ($verbName -like $pattern) {
                return $verb
            }
        }
    }

    return $null
}

function Get-TaskbarPinnedInstallTargets {
    return @((Get-InstallTargetCatalog | Where-Object { $_.PinToTaskbar }))
}

function Get-PreparedTaskbarPinnedApps {
    param([bool]$LogMissingExecutable = $false)

    $preparedPins = @()
    foreach ($pinSpec in @(Get-TaskbarPinnedInstallTargets)) {
        $executablePath = & $pinSpec.GetExecutable
        if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path $executablePath)) {
            if ($LogMissingExecutable) {
                Write-Log "$($pinSpec.PackageName) executable not found - skipping taskbar pin." 'WARN'
            }
            continue
        }

        $shortcutPaths = Initialize-CachedAppShortcutSet `
            -ShortcutName $pinSpec.ShortcutName `
            -TargetPath $executablePath `
            -Description $pinSpec.PackageName `
            -CreateDesktopShortcut $false

        $managedLinkPath = Join-Path $script:AllUsersStartMenuProgramsPath "$($pinSpec.ShortcutName).lnk"
        $linkPath = Find-FirstExistingPath -CandidatePaths (@($managedLinkPath) + @($shortcutPaths))
        if ([string]::IsNullOrWhiteSpace($linkPath)) {
            continue
        }

        $preparedPins += [pscustomobject]@{
            PinSpec        = $pinSpec
            ExecutablePath = $executablePath
            ShortcutPaths  = @($shortcutPaths)
            LinkPath       = $linkPath
        }
    }

    return @($preparedPins)
}

function Get-DefaultTaskbarCleanupDefinition {
    return [pscustomobject]@{
        EdgePatterns = @('*Edge*', '*Microsoft Edge*', '*msedge*')
        StorePatterns = @('*Microsoft Store*')
        EdgePaths = @(
            'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
        )
        StorePaths = @(
            "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Microsoft Store.lnk",
            (Join-Path $script:AllUsersStartMenuProgramsPath 'Microsoft Store.lnk')
        )
        ShortcutDirectories = @(((Get-DesktopShortcutDirectories) + (Get-StartMenuShortcutDirectories)) | Select-Object -Unique)
    }
}

function Invoke-RemoveDefaultTaskbarSurfaceArtifacts {
    param([bool]$RemoveEdgeShortcuts = $false)

    $cleanupDefinition = Get-DefaultTaskbarCleanupDefinition

    if (-not $script:DefaultTaskbarPinsRemoved) {
        Invoke-EnsureTaskbarAction -Action Unpin -DisplayPatterns $cleanupDefinition.EdgePatterns -Paths $cleanupDefinition.EdgePaths | Out-Null
        Invoke-EnsureTaskbarAction -Action Unpin -DisplayPatterns $cleanupDefinition.StorePatterns -Paths $cleanupDefinition.StorePaths | Out-Null
        Remove-TaskbarPinsByPattern `
            -Patterns ($cleanupDefinition.EdgePatterns + $cleanupDefinition.StorePatterns) `
            -Paths ($cleanupDefinition.EdgePaths + $cleanupDefinition.StorePaths)
        $script:DefaultTaskbarPinsRemoved = $true
    }

    if ($RemoveEdgeShortcuts -and -not $script:EdgeShortcutsRemoved) {
        if (Test-ShortcutPatternExists -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns) {
            Remove-ShortcutsByPattern -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns
        }
        $script:EdgeShortcutsRemoved = $true
    }

    return $cleanupDefinition
}

function Clear-StaleStartCustomizationPolicies {
    try {
        $policyPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Explorer'
        $currentUserPolicyPath = 'HKCU:\Software\Policies\Microsoft\Windows\Explorer'
        $hadFailure = $false

        Remove-RegistryValueIfPresent -Path $policyPath -Name 'ConfigureStartPins'
        Remove-RegistryValueIfPresent -Path $currentUserPolicyPath -Name 'ConfigureStartPins'
        Remove-RegistryValueIfPresent -Path $policyPath -Name 'StartLayoutFile'
        Remove-RegistryValueIfPresent -Path $policyPath -Name 'LockedStartLayout'

        try {
            $cleanupTask = Get-ScheduledTask -TaskName 'Hunter-TaskbarPolicyCleanup' -ErrorAction SilentlyContinue
            if ($null -ne $cleanupTask) {
                Unregister-ScheduledTask -TaskName 'Hunter-TaskbarPolicyCleanup' -Confirm:$false -ErrorAction Stop | Out-Null
                Write-Log "Removed stale scheduled task 'Hunter-TaskbarPolicyCleanup'." 'INFO'
            }
        } catch {
            $hadFailure = $true
            Write-Log "Failed to remove stale taskbar cleanup task: $($_.Exception.Message)" 'ERROR'
        }

        try {
            $instance = Get-CimInstance `
                -Namespace 'root\cimv2\mdm\dmmap' `
                -ClassName 'MDM_Policy_Config01_Start02' `
                -Filter "ParentID='./Vendor/MSFT/Policy/Config' AND InstanceID='Start'" `
                -ErrorAction Stop

            if ($null -ne $instance) {
                $changed = $false

                if (($instance.PSObject.Properties.Name -contains 'ConfigureStartPins') -and
                    -not [string]::IsNullOrWhiteSpace([string]$instance.ConfigureStartPins)) {
                    $instance.ConfigureStartPins = ''
                    $changed = $true
                }

                if (($instance.PSObject.Properties.Name -contains 'StartLayout') -and
                    -not [string]::IsNullOrWhiteSpace([string]$instance.StartLayout)) {
                    $instance.StartLayout = ''
                    $changed = $true
                }

                if (($instance.PSObject.Properties.Name -contains 'NoPinningToTaskbar') -and
                    ([int]$instance.NoPinningToTaskbar -ne 0)) {
                    $instance.NoPinningToTaskbar = 0
                    $changed = $true
                }

                if ($changed) {
                    Set-CimInstance -CimInstance $instance -ErrorAction Stop | Out-Null
                    Write-Log 'Cleared stale managed Start policy values from the WMI bridge.' 'INFO'
                }
            }
        } catch {
            Write-Log "Managed Start policy WMI cleanup was not available: $($_.Exception.Message)" 'WARN'
        }

        foreach ($leftoverValue in @(
                @{ Path = $policyPath; Name = 'ConfigureStartPins' },
                @{ Path = $currentUserPolicyPath; Name = 'ConfigureStartPins' },
                @{ Path = $policyPath; Name = 'StartLayoutFile' },
                @{ Path = $policyPath; Name = 'LockedStartLayout' }
            )) {
            if (Test-Path $leftoverValue.Path) {
                try {
                    $currentItem = Get-ItemProperty -Path $leftoverValue.Path -ErrorAction Stop
                    if ($null -ne $currentItem.PSObject.Properties[$leftoverValue.Name]) {
                        $hadFailure = $true
                        Write-Log "Stale Start customization policy is still present: $($leftoverValue.Path)\$($leftoverValue.Name)" 'ERROR'
                    }
                } catch [System.Management.Automation.ItemNotFoundException] {
                } catch {
                    $hadFailure = $true
                    Write-Log "Failed to verify Start customization policy cleanup for $($leftoverValue.Path)\$($leftoverValue.Name): $($_.Exception.Message)" 'ERROR'
                }
            }
        }

        if ($hadFailure) {
            return $false
        }

        return $true
    } catch {
        Write-Log "Failed to clear stale Start customization policies: $_" 'ERROR'
        return $false
    }
}


function Get-ShellItemFromPath {
    param(
        [object]$Shell,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path $Path)) {
        return $null
    }

    try {
        $parentPath = Split-Path -Parent $Path
        $leafName = Split-Path -Leaf $Path
        $folder = $Shell.NameSpace($parentPath)
        if ($null -eq $folder) {
            return $null
        }

        return $folder.ParseName($leafName)
    } catch {
        return $null
    }
}

function Get-TaskbarTargetItems {
    param(
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    $shell = New-Object -ComObject Shell.Application
    $items = @()
    $appsFolder = $null

    try {
        $appsFolder = $shell.NameSpace('shell:AppsFolder')
        if ($null -ne $appsFolder) {
            foreach ($item in @($appsFolder.Items())) {
                foreach ($pattern in @($DisplayPatterns)) {
                    if ($item.Name -like $pattern) {
                        $items += $item
                        break
                    }
                }
            }
        }
    } catch {
        Write-Log "Failed to inspect AppsFolder taskbar targets: $_" 'WARN'
    }

    foreach ($path in @($Paths) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique) {
        $item = Get-ShellItemFromPath -Shell $shell -Path $path
        if ($null -ne $item) {
            $items += $item
        }
    }

    if ($null -ne $appsFolder -and [System.Runtime.InteropServices.Marshal]::IsComObject($appsFolder)) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($appsFolder)
    }

    if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    return $items
}

function Test-TaskbarPinnedByShell {
    param(
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    foreach ($item in @(Get-TaskbarTargetItems -DisplayPatterns $DisplayPatterns -Paths $Paths)) {
        $verb = Find-ShellVerbByPattern -Item $item -Patterns $script:TaskbarUnpinVerbPatterns

        if ($null -ne $verb) {
            return $true
        }
    }

    $taskbarPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $taskbarPath) {
        foreach ($file in @(Get-ChildItem -Path $taskbarPath -Recurse -File -Filter '*.lnk' -ErrorAction SilentlyContinue)) {
            foreach ($pattern in @($DisplayPatterns)) {
                if ($file.BaseName -like $pattern -or $file.Name -like $pattern) {
                    return $true
                }
            }

            $targetPath = Get-ShortcutTargetPath -ShortcutPath $file.FullName
            if (-not [string]::IsNullOrWhiteSpace($targetPath)) {
                foreach ($candidatePath in @($Paths)) {
                    if ([string]::IsNullOrWhiteSpace($candidatePath)) {
                        continue
                    }

                    if ($targetPath -ieq $candidatePath) {
                        return $true
                    }
                }
            }
        }
    }

    return $false
}

function Invoke-TaskbarAction {
    param(
        [ValidateSet('Pin','Unpin')]
        [string]$Action,
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    $currentlyPinned = Test-TaskbarPinnedByShell -DisplayPatterns $DisplayPatterns -Paths $Paths
    if ($Action -eq 'Pin' -and $currentlyPinned) {
        return $true
    }

    if ($Action -eq 'Unpin' -and -not $currentlyPinned) {
        return $true
    }

    $verbPatterns = if ($Action -eq 'Pin') { $script:TaskbarPinVerbPatterns } else { $script:TaskbarUnpinVerbPatterns }
    $actionTaken = $false

    foreach ($item in @(Get-TaskbarTargetItems -DisplayPatterns $DisplayPatterns -Paths $Paths)) {
        try {
            $verb = Find-ShellVerbByPattern -Item $item -Patterns $verbPatterns
            if ($null -eq $verb) {
                continue
            }

            $verb.DoIt()
            $actionTaken = $true
            Write-Log "Taskbar $($Action.ToLowerInvariant()) requested for $($item.Name)"
        } catch {
            Write-Log "Failed to $($Action.ToLowerInvariant()) taskbar target $($item.Name) : $_" 'WARN'
        }
    }

    if (-not $actionTaken) {
        return $false
    }

    $expectedPinned = ($Action -eq 'Pin')
    $deadline = (Get-Date).AddSeconds($script:TaskbarStateTimeoutSec)
    do {
        $isPinnedAfterAction = Test-TaskbarPinnedByShell -DisplayPatterns $DisplayPatterns -Paths $Paths
        if ($isPinnedAfterAction -eq $expectedPinned) {
            return $true
        }

        Start-Sleep -Milliseconds $script:TaskbarStatePollIntervalMs
    } while ((Get-Date) -lt $deadline)

    return $false
}

function Invoke-EnsureTaskbarAction {
    param(
        [ValidateSet('Pin','Unpin')]
        [string]$Action,
        [string[]]$DisplayPatterns,
        [string[]]$Paths
    )

    if ($Action -eq 'Pin' -and $script:TaskbarReconcilePending) {
        return $false
    }

    # Attempt 1: Shell verb approach
    if (Invoke-TaskbarAction -Action $Action -DisplayPatterns $DisplayPatterns -Paths $Paths) {
        return $true
    }

    # Attempt 2: Restart Start Surface and retry Shell verb
    Restart-StartSurface
    $startSurfaceDeadline = (Get-Date).AddSeconds($script:StartSurfaceReadyTimeoutSec)
    do {
        $startSurfaceReady = @(
            Get-Process -Name 'StartMenuExperienceHost', 'ShellExperienceHost' -ErrorAction SilentlyContinue
        ).Count -gt 0

        if ($startSurfaceReady) {
            break
        }

        Start-Sleep -Milliseconds $script:TaskbarStatePollIntervalMs
    } while ((Get-Date) -lt $startSurfaceDeadline)

    if (Invoke-TaskbarAction -Action $Action -DisplayPatterns $DisplayPatterns -Paths $Paths) {
        return $true
    }

    return $false
}

# ==============================================================================
# APPSFOLDER HELPERS
# ==============================================================================

function Invoke-AppsFolderActionByPatterns {
    param(
        [string[]]$Patterns,
        [string[]]$VerbPatterns,
        [string]$SuccessMessagePrefix,
        [string]$UnavailableMessagePrefix,
        [string]$FailureMessagePrefix,
        [ValidateSet('INFO','WARN')]
        [string]$UnavailableLogLevel = 'WARN'
    )

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return [pscustomobject]@{
            MatchedCount     = 0
            SucceededCount   = 0
            UnavailableCount = 0
            FailureCount     = 0
        }
    }

    $shell = $null
    $appsFolder = $null
    $matchedCount = 0
    $succeededCount = 0
    $unavailableCount = 0
    $failureCount = 0

    try {
        $shell = New-Object -ComObject Shell.Application
        $appsFolder = $shell.NameSpace("shell:AppsFolder")
        if ($null -eq $appsFolder) {
            throw 'shell:AppsFolder was unavailable.'
        }

        foreach ($item in @($appsFolder.Items())) {
            foreach ($pattern in $Patterns) {
                if ($item.Name -notlike $pattern) {
                    continue
                }

                $matchedCount++
                try {
                    $verb = Find-ShellVerbByPattern -Item $item -Patterns $VerbPatterns
                    if ($null -ne $verb) {
                        $verb.DoIt()
                        $succeededCount++
                        Write-Log "${SuccessMessagePrefix}: $($item.Name)"
                    } else {
                        $unavailableCount++
                        Write-Log "${UnavailableMessagePrefix}: $($item.Name)" $UnavailableLogLevel
                    }
                } catch {
                    $failureCount++
                    Write-Log "$FailureMessagePrefix $($item.Name) : $_" 'ERROR'
                }

                break
            }
        }
    } catch {
        $failureCount++
        Write-Log "Failed to process AppsFolder action: $_" 'ERROR'
    } finally {
        if ($null -ne $appsFolder -and [System.Runtime.InteropServices.Marshal]::IsComObject($appsFolder)) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($appsFolder)
        }

        if ($null -ne $shell -and [System.Runtime.InteropServices.Marshal]::IsComObject($shell)) {
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
        }
    }

    return [pscustomobject]@{
        MatchedCount     = $matchedCount
        SucceededCount   = $succeededCount
        UnavailableCount = $unavailableCount
        FailureCount     = $failureCount
    }
}

function Invoke-AppsFolderUninstallByPatterns {
    param([string[]]$Patterns)
    Invoke-AppsFolderActionByPatterns `
        -Patterns $Patterns `
        -VerbPatterns @('*Uninstall*') `
        -SuccessMessagePrefix 'AppFolder app uninstall invoked' `
        -UnavailableMessagePrefix 'Uninstall verb not available for AppFolder item' `
        -FailureMessagePrefix 'Failed to uninstall AppFolder app'
}

function Invoke-StartMenuUnpinByPatterns {
    param([string[]]$Patterns)
    Invoke-AppsFolderActionByPatterns `
        -Patterns $Patterns `
        -VerbPatterns @('*Unpin*Start*') `
        -SuccessMessagePrefix 'AppFolder app unpinned from Start' `
        -UnavailableMessagePrefix 'Start unpin verb not available for AppFolder item' `
        -FailureMessagePrefix 'Failed to unpin AppFolder app from Start' `
        -UnavailableLogLevel 'INFO'
}

function Get-DefaultBlockedStartPinsPatterns {
    return @(
        '*LinkedIn*',
        '*LinkedInForWindows*',
        '*linkedin.com*',
        '*LinkedInForWindows_8wekyb3d8bbwe*',
        '*7EE7776C.LinkedInforWindows*',
        '*Xbox*',
        '*Gaming*',
        '*Game Bar*',
        '*xbox.com*',
        '*gamebar*',
        '*ms-gamebar*',
        '*Microsoft.XboxIdentityProvider*',
        '*Microsoft.XboxSpeechToTextOverlay*',
        '*Microsoft.GamingApp*',
        '*Microsoft.Xbox.TCUI*',
        '*Microsoft.XboxGamingOverlay*',
        '*Outlook*',
        '*Microsoft.Outlook*',
        '*Clipchamp*',
        '*News*',
        '*Weather*',
        '*Teams*',
        '*MSTeams*',
        '*MicrosoftTeams*',
        '*To Do*',
        '*Todos*',
        '*Power Automate*',
        '*Sound Recorder*',
        '*Solitaire*',
        '*Candy*',
        '*Bubble Witch*',
        '*Office*',
        '*Microsoft 365*'
    )
}

function Invoke-ApplyLiveStartPinCleanup {
    param([string[]]$BlockedPatterns)

    if ($null -eq $BlockedPatterns -or $BlockedPatterns.Count -eq 0) {
        return (New-TaskSkipResult -Reason 'No blocked Start-pin patterns were provided')
    }

    $cleanupResult = Invoke-StartMenuUnpinByPatterns -Patterns $BlockedPatterns
    if ($null -eq $cleanupResult) {
        return $false
    }

    if ([int]$cleanupResult.FailureCount -gt 0) {
        return $false
    }

    Request-StartSurfaceRestart
    Write-Log ("Applied live Start pin cleanup without staging managed Start pin policy. " +
        "Matched={0}, Unpinned={1}, Unavailable={2}" -f
        [int]$cleanupResult.MatchedCount,
        [int]$cleanupResult.SucceededCount,
        [int]$cleanupResult.UnavailableCount) 'INFO'

    return $true
}
