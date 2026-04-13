function Invoke-RemoveEdgeKeepWebView2 {
    <#
    .SYNOPSIS
    Removes Microsoft Edge using the WinUtil uninstaller flow.
    .DESCRIPTION
    Unlocks the official Edge uninstaller stub and launches setup.exe with WinUtil arguments.
    #>
    param()

    try {
        Write-Log -Message 'Edge removal is best-effort. Microsoft frequently blocks or partially resists removal depending on build, WebView2 state, and installer policy.' -Level 'WARN'
        Write-Log -Message "Unlocking the official Edge uninstaller and removing Microsoft Edge..." -Level 'INFO'
        Invoke-ApplyAppRemovalStrategies -Entries (Resolve-HunterAppCatalogEntries -Selections @('edge')) | Out-Null

        $setupPath = Get-ChildItem 'C:\Program Files (x86)\Microsoft\Edge\Application\*\Installer\setup.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName
        $edgeExecutablePaths = @(
            'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
            'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
        )
        if ([string]::IsNullOrWhiteSpace($setupPath)) {
            $edgeStillInstalled = @($edgeExecutablePaths | Where-Object { Test-Path $_ }).Count -gt 0
            if (-not $edgeStillInstalled) {
                Write-Log -Message 'Edge installer was not found because Edge binaries were already removed.' -Level 'SUCCESS'
                return $true
            }

            Write-Log -Message 'Edge installer was not found. Edge removal will be treated as best-effort only on this system.' -Level 'WARN'
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'Edge installer was not present, so removal could not be completed deterministically'
            }
        }

        New-Item 'C:\Windows\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe' -Force | Out-Null
        $edgeUninstall = Start-ProcessChecked `
            -FilePath $setupPath `
            -ArgumentList @('--uninstall', '--system-level', '--force-uninstall', '--delete-profile') `
            -SuccessExitCodes @(0, 19) `
            -WindowStyle Hidden

        $edgeStillInstalled = @($edgeExecutablePaths | Where-Object { Test-Path $_ }).Count -gt 0
        if ([int]$edgeUninstall.ExitCode -eq 19) {
            $warningMessage = 'Edge uninstaller exited with code 19.'
            if ($edgeStillInstalled) {
                Write-Log -Message "$warningMessage Edge still appears to be installed, so this step will be marked as best-effort with warnings." -Level 'WARN'
                return @{
                    Success = $true
                    Status  = 'CompletedWithWarnings'
                    Reason  = 'Edge uninstall was blocked by the current Windows build or installer state'
                }
            }

            Write-Log -Message "$warningMessage Edge binaries are no longer present." -Level 'SUCCESS'
            return $true
        }

        Write-Log -Message "Edge removal complete." -Level 'INFO'

        # Verify WebView2 runtime survived Edge removal
        $webView2RegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
        $webView2Exists = (Test-Path $webView2RegPath) -or
            (Test-Path 'C:\Program Files (x86)\Microsoft\EdgeWebView') -or
            (Test-Path 'C:\Program Files\Microsoft\EdgeWebView')
        if (-not $webView2Exists) {
            Write-Log -Message "WARNING: WebView2 runtime may have been removed alongside Edge. Some apps may not function correctly." -Level 'WARN'
        } else {
            Write-Log -Message "WebView2 runtime verified intact after Edge removal." -Level 'INFO'
        }

        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveEdgeKeepWebView2: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableEdgeUpdateInfrastructure {
    try {
        Write-Log 'Disabling Edge update infrastructure while preserving WebView2...' 'INFO'

        $warnings = New-Object 'System.Collections.Generic.List[string]'
        $edgeTasks = @(
            Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
                $_.TaskName -like 'MicrosoftEdgeUpdateTaskMachine*' -or
                $_.TaskPath -like '\MicrosoftEdgeUpdate*'
            }
        )

        foreach ($edgeTask in $edgeTasks) {
            try {
                if ($edgeTask.State -eq 'Disabled') {
                    Write-Log "Scheduled task already disabled: $($edgeTask.TaskPath)$($edgeTask.TaskName)" 'INFO'
                    continue
                }

                Disable-ScheduledTask -TaskPath $edgeTask.TaskPath -TaskName $edgeTask.TaskName -ErrorAction Stop | Out-Null
                Write-Log "Scheduled task disabled: $($edgeTask.TaskPath)$($edgeTask.TaskName)" 'INFO'
            } catch {
                [void]$warnings.Add("Failed to disable Edge scheduled task $($edgeTask.TaskPath)$($edgeTask.TaskName): $($_.Exception.Message)")
            }
        }

        foreach ($serviceName in @('edgeupdate', 'edgeupdatem', 'MicrosoftEdgeElevationService')) {
            try {
                Stop-ServiceIfPresent -Name $serviceName
                Set-ServiceStartType -Name $serviceName -StartType Disabled
            } catch {
                [void]$warnings.Add("Failed to hard-disable Edge service ${serviceName}: $($_.Exception.Message)")
            }
        }

        $edgeUpdatePaths = @(
            (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\EdgeUpdate'),
            (Join-Path $script:ProgramFilesRoot 'Microsoft\EdgeUpdate')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique

        foreach ($edgeUpdatePath in $edgeUpdatePaths) {
            if (-not (Test-Path $edgeUpdatePath)) {
                continue
            }

            try {
                Remove-Item -Path $edgeUpdatePath -Recurse -Force -ErrorAction Stop
                Write-Log "Removed Edge update directory: $edgeUpdatePath" 'INFO'
            } catch {
                [void]$warnings.Add("Failed to remove Edge update directory ${edgeUpdatePath}: $($_.Exception.Message)")
            }
        }

        $webView2RegPath = 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
        $webView2Exists = (Test-Path $webView2RegPath) -or
            (Test-Path 'C:\Program Files (x86)\Microsoft\EdgeWebView') -or
            (Test-Path 'C:\Program Files\Microsoft\EdgeWebView')
        if ($webView2Exists) {
            Write-Log 'WebView2 runtime remains present after Edge update cleanup.' 'INFO'
        } else {
            [void]$warnings.Add('WebView2 runtime could not be verified after Edge update cleanup.')
        }

        foreach ($warning in @($warnings)) {
            Write-Log $warning 'WARN'
        }

        if ($warnings.Count -gt 0) {
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'Edge update infrastructure cleanup completed with warnings'
            }
        }

        Write-Log 'Edge update infrastructure disabled while preserving WebView2.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error in Invoke-DisableEdgeUpdateInfrastructure: $_" 'ERROR'
        return $false
    }
}

function Invoke-RemoveEdgePinsAndShortcuts {
    <#
    .SYNOPSIS
    Removes Edge taskbar pins and shortcuts from desktop/start menu.
    #>
    param()

    try {
        Write-Log -Message "Removing Edge pins and shortcuts..." -Level 'INFO'

        $cleanupDefinition = Get-DefaultTaskbarCleanupDefinition

        # Remove taskbar pins
        Write-Log -Message "Removing Edge taskbar pins..." -Level 'INFO'
        if (Test-ShortcutPatternExists -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns) {
            Write-Log -Message "Removing Edge shortcuts..." -Level 'INFO'
        }
        $null = Invoke-RemoveDefaultTaskbarSurfaceArtifacts -RemoveEdgeShortcuts $true

        Request-ExplorerRestart
        Restart-StartSurface

        if (Test-TaskbarPinnedByShell -DisplayPatterns $cleanupDefinition.EdgePatterns -Paths $cleanupDefinition.EdgePaths) {
            throw 'Microsoft Edge is still pinned to the taskbar after cleanup'
        }

        if (Test-TaskbarPinnedByShell -DisplayPatterns $cleanupDefinition.StorePatterns -Paths $cleanupDefinition.StorePaths) {
            throw 'Microsoft Store is still pinned to the taskbar after cleanup'
        }

        if (Test-ShortcutPatternExists -Directories $cleanupDefinition.ShortcutDirectories -Patterns $cleanupDefinition.EdgePatterns) {
            Write-Log 'Edge shortcut remnants remain in the shell surface, but the taskbar pin has been removed.' 'WARN'
        }

        Write-Log -Message "Edge pins and shortcuts removal complete." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveEdgePinsAndShortcuts: $_" -Level 'ERROR'
        return $false
    }
}
