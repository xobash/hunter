function Request-ExplorerRestart {
    if ($script:ExplorerRestartPending) {
        return
    }

    $script:ExplorerRestartPending = $true
    Write-Log "Explorer restart queued (will apply at end of run)"
}

function Request-StartSurfaceRestart {
    if ($script:StartSurfaceRestartPending) {
        return
    }

    $script:StartSurfaceRestartPending = $true
    Write-Log "Start surface restart queued (will apply at end of run)"
}

function Invoke-DeferredExplorerRestart {
    try {
        $reconcileSucceeded = $true
        if ($script:TaskbarReconcilePending) {
            $reconcileSucceeded = Invoke-ReconcileTaskbarPins
        }

        if ($script:ExplorerRestartPending) {
            Write-Log "Restarting Explorer..."
            Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            $null = Start-Process explorer.exe -ErrorAction Stop
            $script:ExplorerRestartPending = $false
            $script:StartSurfaceRestartPending = $false
            Write-Log "Explorer restarted"
            return $reconcileSucceeded
        }

        if ($script:StartSurfaceRestartPending) {
            return ((Restart-StartSurface) -and $reconcileSucceeded)
        }

        return $reconcileSucceeded
    } catch {
        Write-Log "Failed to apply deferred Explorer restart actions: $_" 'ERROR'
        return $false
    }
}

function Restart-StartSurface {
    try {
        Get-Process -Name 'StartMenuExperienceHost', 'ShellExperienceHost' -ErrorAction SilentlyContinue |
            Stop-Process -Force -ErrorAction SilentlyContinue
        $script:StartSurfaceRestartPending = $false
        Write-Log "Start surface restarted"
        return $true
    } catch {
        Write-Log "Failed to restart Start surface : $_" 'ERROR'
        return $false
    }
}

function Invoke-ReconcileTaskbarPins {
    try {
        Write-Log 'Reconciling taskbar pins...' 'INFO'

        $taskbarPinPath = "$env:APPDATA\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"

        if (-not (Restart-StartSurface)) {
            throw 'Failed to restart the Start surface before deferred taskbar reconciliation.'
        }
        $null = Invoke-RemoveDefaultTaskbarSurfaceArtifacts

        # Ensure shortcuts exist for all apps that need pinning (required for both
        # the direct placement approach and the Group Policy XML layout).
        Initialize-HunterDirectory $taskbarPinPath
        $preparedPinnedApps = Get-PreparedTaskbarPinnedApps -LogMissingExecutable $true
        foreach ($preparedPin in @($preparedPinnedApps)) {
            $pinSpec = $preparedPin.PinSpec
            # Place .lnk in the Quick Launch pin folder (works on Win10, best-effort on Win11)
            $pinLnkPath = Join-Path $taskbarPinPath "$($pinSpec.ShortcutName).lnk"
            if (-not (Test-Path $pinLnkPath)) {
                if (-not (New-WindowsShortcut -ShortcutPath $pinLnkPath -TargetPath $preparedPin.ExecutablePath -Description $pinSpec.PackageName)) {
                    throw "Failed to prepare taskbar shortcut for $($pinSpec.PackageName)."
                }
            }
        }

        # Clear Explorer Taskband cache so it rebuilds from pin folder on restart (Win10).
        try {
            $taskbandPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband'
            if (Test-Path $taskbandPath) {
                Remove-Item -Path $taskbandPath -Recurse -Force -ErrorAction Stop
                Write-Log 'Cleared Explorer Taskband cache.' 'INFO'
            }
        } catch {
            Write-Log "Failed to clear Taskband cache: $_" 'WARN'
        }

        # Register a logon script that retries pinning via shell verbs at fresh logon.
        # At fresh logon the shell:AppsFolder is properly initialized and pin verbs are
        # available on Win10 and some Win11 builds where they fail mid-session.
        if (-not (Register-TaskbarPinAtLogonTask)) {
            throw 'Failed to register the deferred taskbar pin retry task.'
        }

        $script:TaskbarReconcilePending = $false
        return $true
    } catch {
        Write-Log "Failed to reconcile taskbar pins : $_" 'ERROR'
        return $false
    }
}

function Register-TaskbarPinAtLogonTask {
    try {
        $taskName = 'Hunter-TaskbarPinAtLogon'
        $scriptPath = Join-Path $script:HunterRoot 'TaskbarPinAtLogon.ps1'
        $logPath = Join-Path $script:HunterRoot 'taskbar-pin-at-logon.log'

        # Build the pin spec list as literal PowerShell that the logon script can use.
        $pinSpecLines = @()
        foreach ($pinSpec in @(Get-TaskbarPinnedInstallTargets)) {
            $executablePath = & $pinSpec.GetExecutable
            if ([string]::IsNullOrWhiteSpace($executablePath) -or -not (Test-Path $executablePath)) {
                continue
            }
            $escapedName = ($pinSpec.ShortcutName -replace "'", "''")
            $escapedPatterns = ($pinSpec.PinPatterns | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ', '
            $pinSpecLines += "    @{ Name = '$escapedName'; Patterns = @($escapedPatterns) }"
        }
        $pinSpecArray = $pinSpecLines -join "`n"

        $logonScript = @"
        `$ErrorActionPreference = 'Stop'
        `$logPath = '$($logPath -replace "'","''")'

        function Write-RetryLog {
            param(
                [string]`$Message,
                [string]`$Level = 'INFO'
            )

            `$line = "[{0}] [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), `$Level, `$Message
            try {
                Add-Content -Path `$logPath -Value `$line -ErrorAction Stop
            } catch {
            }
        }

        `$hadFailure = `$false

# Wait for Explorer shell to fully initialise after logon.
Start-Sleep -Seconds 12

`$pinVerbPatterns = @('*Pin to taskbar*', '*taskbarpin*')
`$unpinVerbPatterns = @('*Unpin from taskbar*', '*taskbarunpin*')
`$appsToPin = @(
$pinSpecArray
)
`$appsToUnpin = @('*Edge*', '*Microsoft Edge*', '*Microsoft Store*')

try {
    `$shell = New-Object -ComObject Shell.Application
    `$appsFolder = `$shell.NameSpace('shell:AppsFolder')
    if (`$null -eq `$appsFolder) {
        throw 'shell:AppsFolder was unavailable at logon.'
    }
} catch {
    Write-RetryLog -Message "Failed to initialize shell: $($_.Exception.Message)" -Level 'ERROR'
    exit 1
}

# Unpin Edge and Store
foreach (`$item in `$appsFolder.Items()) {
    foreach (`$pattern in `$appsToUnpin) {
        if (`$item.Name -like `$pattern) {
            foreach (`$verb in `$item.Verbs()) {
                foreach (`$vp in `$unpinVerbPatterns) {
                    if (`$verb.Name -like `$vp) {
                        try {
                            `$verb.DoIt()
                        } catch {
                            `$hadFailure = `$true
                            Write-RetryLog -Message "Failed to unpin $(`$item.Name): $($_.Exception.Message)" -Level 'WARN'
                        }
                        break
                    }
                }
            }
        }
    }
}

# Pin desired apps
foreach (`$app in `$appsToPin) {
    `$pinned = `$false
    foreach (`$item in `$appsFolder.Items()) {
        if (`$pinned) { break }
        foreach (`$pattern in `$app.Patterns) {
            if (`$item.Name -like `$pattern) {
                foreach (`$verb in `$item.Verbs()) {
                    foreach (`$vp in `$pinVerbPatterns) {
                        if (`$verb.Name -like `$vp) {
                            try {
                                `$verb.DoIt()
                                `$pinned = `$true
                            } catch {
                                `$hadFailure = `$true
                                Write-RetryLog -Message "Failed to pin $(`$item.Name): $($_.Exception.Message)" -Level 'WARN'
                            }
                            break
                        }
                    }
                    if (`$pinned) { break }
                }
            }
            if (`$pinned) { break }
        }
    }

    if (-not `$pinned) {
        `$hadFailure = `$true
        Write-RetryLog -Message "No pin verb succeeded for $(`$app.Name)." -Level 'WARN'
    }
}

if (`$null -ne `$appsFolder -and [System.Runtime.InteropServices.Marshal]::IsComObject(`$appsFolder)) {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject(`$appsFolder)
}
if (`$null -ne `$shell -and [System.Runtime.InteropServices.Marshal]::IsComObject(`$shell)) {
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject(`$shell)
}

# Self-cleanup
try {
    Unregister-ScheduledTask -TaskName '$($taskName -replace "'","''")' -Confirm:`$false -ErrorAction Stop
} catch {
    Write-RetryLog -Message "Failed to unregister retry task during self-cleanup: $($_.Exception.Message)" -Level 'WARN'
}
try {
    Remove-Item -LiteralPath '$($scriptPath -replace "'","''")' -Force -ErrorAction Stop
} catch {
    Write-RetryLog -Message "Failed to delete retry script during self-cleanup: $($_.Exception.Message)" -Level 'WARN'
}

if (`$hadFailure) {
    exit 1
}
"@

        Initialize-HunterDirectory (Split-Path -Parent $scriptPath)
        Set-Content -Path $scriptPath -Value $logonScript -Encoding UTF8 -Force

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        Register-ScheduledTask `
            -TaskName $taskName `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Force | Out-Null

        Write-Log "Registered logon task '$taskName' to retry taskbar pinning via shell verbs at next logon." 'INFO'
        return $true
    } catch {
        Write-Log "Failed to register taskbar pin logon task: $_" 'ERROR'
        return $false
    }
}

function Get-ExplorerNamespaceRoots {
    $roots = @()
    $desktopRoots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Desktop',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Explorer\Desktop',
        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Desktop'
    )

    foreach ($desktopRoot in $desktopRoots) {
        if (Test-Path $desktopRoot) {
            foreach ($child in @(Get-ChildItem -Path $desktopRoot -ErrorAction SilentlyContinue)) {
                if ($child.PSChildName -like 'NameSpace*') {
                    $roots += $child.PSPath
                }
            }
        }

        $roots += "$desktopRoot\NameSpace"
    }

    return $roots | Select-Object -Unique
}

function Test-ExplorerNamespacePresent {
    param([string]$Guid)

    foreach ($root in @(Get-ExplorerNamespaceRoots)) {
        if (Test-Path "$root\$Guid") {
            return $true
        }
    }

    return $false
}

function Remove-ExplorerNamespaceGuid {
    param([string]$Guid)

    foreach ($root in @(Get-ExplorerNamespaceRoots)) {
        Remove-RegistryKey -Path "$root\$Guid"
    }
}

function Remove-ExplorerNamespaceAndVerify {
    param(
        [string]$Guid,
        [string]$DisplayName
    )

    Remove-ExplorerNamespaceGuid -Guid $Guid
    Set-ExplorerNamespacePinnedState -Guid $Guid -Value 0

    if (Test-ExplorerNamespacePresent -Guid $Guid) {
        throw "Explorer $DisplayName namespace is still present: $Guid"
    }
}

function Set-ExplorerNamespacePinnedState {
    param(
        [string]$Guid,
        [int]$Value = 0
    )

    $userOverridePath = "Software\Classes\CLSID\$Guid"
    $machineOverridePath = "HKLM:\SOFTWARE\Classes\CLSID\$Guid"

    Set-DwordForAllUsers -SubPath $userOverridePath -Name 'System.IsPinnedToNameSpaceTree' -Value $Value

    try {
        $parentPath = Split-Path -Parent $machineOverridePath
        $leaf = Split-Path -Leaf $machineOverridePath

        if (-not (Test-Path $machineOverridePath) -and (Test-Path $parentPath)) {
            New-Item -Path $parentPath -Name $leaf -Force | Out-Null
        }

        if (Test-Path $machineOverridePath) {
            Set-ItemProperty -Path $machineOverridePath -Name 'System.IsPinnedToNameSpaceTree' -Value $Value -Type DWord -Force
            Write-Log "Registry set: $machineOverridePath\System.IsPinnedToNameSpaceTree = $Value (DWord)"
        }
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match 'Requested registry access is not allowed|Access is denied') {
            Write-Log "Machine-wide namespace pin override skipped for ${Guid}: $errorMessage" 'INFO'
        } else {
            Write-Log "Machine-wide namespace pin override skipped for ${Guid}: $_" 'WARN'
        }
    }
}

