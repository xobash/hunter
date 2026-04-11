function Invoke-RemoveOneDrive {
    <#
    .SYNOPSIS
    Removes OneDrive from the system.
    .DESCRIPTION
    Stops processes, uninstalls OneDrive, removes registry entries and directories.
    #>
    param()

    try {
        Write-Log -Message "Starting OneDrive removal..." -Level 'INFO'
        Invoke-ApplyAppRemovalStrategies -Entries (Resolve-HunterAppCatalogEntries -Selections @('onedrive')) | Out-Null

        $programFilesRoot = $script:ProgramFilesRoot
        $oneDriveSetup32 = "$env:SystemRoot\SysWOW64\OneDriveSetup.exe"
        $oneDriveSetup64 = "$env:SystemRoot\System32\OneDriveSetup.exe"
        $oneDriveLocalAppData = "$env:LOCALAPPDATA\Microsoft\OneDrive"
        $oneDriveProgramFiles = Join-Path $programFilesRoot 'Microsoft OneDrive'
        $oneDriveUserFolder = $env:OneDrive
        $oneDriveGuid = '{018D5C66-4533-4307-9B53-224DE2ED1FE6}'

        $getOneDriveMarkers = {
            $markers = New-Object 'System.Collections.Generic.List[string]'

            if (Test-Path $oneDriveLocalAppData) {
                [void]$markers.Add('LocalAppData')
            }

            if (Test-Path $oneDriveProgramFiles) {
                [void]$markers.Add('ProgramFiles')
            }

            if ((-not [string]::IsNullOrWhiteSpace($oneDriveUserFolder)) -and (Test-Path $oneDriveUserFolder)) {
                [void]$markers.Add('UserFolder')
            }

            if (Test-ExplorerNamespacePresent -Guid $oneDriveGuid) {
                [void]$markers.Add('ExplorerNamespace')
            }

            foreach ($executablePath in @(
                    "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
                    (Join-Path $oneDriveProgramFiles 'OneDrive.exe')
                )) {
                if (-not [string]::IsNullOrWhiteSpace($executablePath) -and (Test-Path $executablePath)) {
                    [void]$markers.Add("Executable:$executablePath")
                }
            }

            return [string[]]$markers.ToArray()
        }

        $detectedMarkers = @(& $getOneDriveMarkers)
        if ($detectedMarkers.Count -gt 0) {
            Write-Log -Message "OneDrive installation detected." -Level 'INFO'
        } else {
            Write-Log -Message "OneDrive not installed. Skipping." -Level 'INFO'
            return (New-TaskSkipResult -Reason 'OneDrive runtime artifacts were not present')
        }

        $oneDriveExecutablePaths = @(
            "$env:LOCALAPPDATA\Microsoft\OneDrive\OneDrive.exe",
            (Join-Path $oneDriveProgramFiles 'OneDrive.exe')
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }

        foreach ($oneDriveExecutablePath in $oneDriveExecutablePaths) {
            try {
                Write-Log -Message "Shutting down OneDrive..." -Level 'INFO'
                Start-ProcessChecked -FilePath $oneDriveExecutablePath -ArgumentList @('/shutdown') -WindowStyle Hidden | Out-Null
                break
            } catch {
                Write-Log -Message "OneDrive shutdown attempt failed for $oneDriveExecutablePath : $_" -Level 'WARN'
            }
        }

        $aclOverrideApplied = $false
        try {
            if (-not [string]::IsNullOrWhiteSpace($oneDriveUserFolder) -and (Test-Path $oneDriveUserFolder)) {
                $denyRule = 'Administrators:(D,DC)'
                & icacls $oneDriveUserFolder /deny $denyRule 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    $aclOverrideApplied = $true
                } else {
                    Write-Log -Message "Failed to apply OneDrive folder ACL protection." -Level 'WARN'
                }
            }

            Write-Log -Message "Uninstalling OneDrive..." -Level 'INFO'
            $uninstallIssue = $null
            if (Test-Path $oneDriveSetup64) {
                try {
                    $uninstallProcess = Start-Process -FilePath $oneDriveSetup64 -ArgumentList @('/uninstall') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    if ($null -eq $uninstallProcess) {
                        throw "Failed to start process $oneDriveSetup64"
                    }

                    if ([int]$uninstallProcess.ExitCode -ne 0) {
                        $uninstallIssue = "$oneDriveSetup64 exited with code $($uninstallProcess.ExitCode)"
                        Write-Log -Message "OneDrive uninstaller reported a non-zero exit code: $uninstallIssue" -Level 'WARN'
                    }
                } catch {
                    $uninstallIssue = $_.Exception.Message
                    Write-Log -Message "OneDrive uninstall attempt failed: $uninstallIssue" -Level 'WARN'
                }
            } elseif (Test-Path $oneDriveSetup32) {
                try {
                    $uninstallProcess = Start-Process -FilePath $oneDriveSetup32 -ArgumentList @('/uninstall') -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
                    if ($null -eq $uninstallProcess) {
                        throw "Failed to start process $oneDriveSetup32"
                    }

                    if ([int]$uninstallProcess.ExitCode -ne 0) {
                        $uninstallIssue = "$oneDriveSetup32 exited with code $($uninstallProcess.ExitCode)"
                        Write-Log -Message "OneDrive uninstaller reported a non-zero exit code: $uninstallIssue" -Level 'WARN'
                    }
                } catch {
                    $uninstallIssue = $_.Exception.Message
                    Write-Log -Message "OneDrive uninstall attempt failed: $uninstallIssue" -Level 'WARN'
                }
            } else {
                $uninstallIssue = 'OneDrive setup binary was not present; continuing with leftover cleanup only.'
                Write-Log -Message $uninstallIssue -Level 'WARN'
            }
            Start-Sleep -Seconds 3

            Write-Log -Message "Removing leftover OneDrive files..." -Level 'INFO'
            Stop-Process -Name 'FileCoAuth', 'explorer', 'OneDrive', 'OneDriveSetup' -Force -ErrorAction SilentlyContinue
            Remove-PathForce $oneDriveLocalAppData -WarnOnly
            Remove-PathForce "$env:ProgramData\Microsoft OneDrive" -WarnOnly
            Remove-PathForce $oneDriveProgramFiles -WarnOnly
        } finally {
            if ($aclOverrideApplied -and (Test-Path $oneDriveUserFolder)) {
                & icacls $oneDriveUserFolder /remove:d 'Administrators' *> $null
                if ($LASTEXITCODE -ne 0) {
                    Write-Log -Message "Failed to restore OneDrive folder ACLs." -Level 'WARN'
                }
            }
        }

        Set-ServiceStartType -Name 'OneSyncSvc' -StartType Disabled
        Request-ExplorerRestart

        $remainingMarkers = @(& $getOneDriveMarkers)
        if ($remainingMarkers.Count -gt 0) {
            $remainingNonUserDataMarkers = @($remainingMarkers | Where-Object { $_ -ne 'UserFolder' })
            if ($remainingNonUserDataMarkers.Count -eq 0) {
                $userFolderReason = 'OneDrive user folder was left in place to avoid deleting user data.'
                Write-Log -Message $userFolderReason -Level 'WARN'
                return @{
                    Success = $true
                    Status  = 'CompletedWithWarnings'
                    Reason  = $userFolderReason
                }
            }

            Write-Log -Message ("OneDrive removal incomplete. Remaining markers: {0}" -f ($remainingMarkers -join ', ')) -Level 'ERROR'
            return $false
        }

        if (-not [string]::IsNullOrWhiteSpace($uninstallIssue)) {
            Write-Log -Message "OneDrive removal completed with warnings after cleanup verification." -Level 'WARN'
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = $uninstallIssue
            }
        }

        Write-Log -Message "OneDrive removal complete." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveOneDrive: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableOneDriveFolderBackup {
    <#
    .SYNOPSIS
    Disables OneDrive folder backup (KFM - Known Folder Move).
    #>
    param()

    try {
        Write-Log -Message "Disabling OneDrive folder backup..." -Level 'INFO'

        # Pre-check
        $regPath = 'HKLM:\SOFTWARE\Policies\Microsoft\OneDrive'
        if ((Test-RegistryValue -Path $regPath -Name 'KFMBlockOptIn' -ExpectedValue 1) -and
            (Test-RegistryValue -Path $regPath -Name 'KFMSilentOptIn' -ExpectedValue '')) {
            Write-Log -Message "OneDrive folder backup already disabled. Skipping." -Level 'INFO'
            return $true
        }

        Set-RegistryValue -Path $regPath -Name 'KFMBlockOptIn' -Value 1 -Type 'DWord'
        Set-RegistryValue -Path $regPath -Name 'KFMSilentOptIn' -Value '' -Type 'String'

        Write-Log -Message "OneDrive folder backup disabled." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-DisableOneDriveFolderBackup: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-RemoveCopilot {
    <#
    .SYNOPSIS
    Removes Microsoft Copilot and related components.
    #>
    param()

    try {
        if ($script:SkipStoreAndAppxTasks) {
            Write-Log 'Skipping Copilot removal because this Windows edition is not a supported consumer Store/AppX build.' 'INFO'
            return (New-TaskSkipResult -Reason 'Copilot removal is skipped on unsupported LTSC/Server editions')
        }

        $buildContext = Get-WindowsBuildContext
        if (-not (Test-WindowsBuildInRange -MinBuild 22621)) {
            Write-Log "Copilot removal is not applicable on build $($buildContext.CurrentBuild). Skipping." 'INFO'
            return (New-TaskSkipResult -Reason 'Copilot is not a supported inbox feature on this Windows build')
        }

        Write-Log -Message "Starting Copilot removal..." -Level 'INFO'
        $copilotRegistrySettings = @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1; Type = 'DWord'; MinBuild = 22621 },
            @{ Path = 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot'; Name = 'TurnOffWindowsCopilot'; Value = 1; Type = 'DWord'; MinBuild = 22621 },
            @{ Path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ShowCopilotButton'; Value = 0; Type = 'DWord'; MinBuild = 22621 },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot'; Name = 'IsCopilotAvailable'; Value = 0; Type = 'DWord'; MinBuild = 22621 },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot'; Name = 'CopilotDisabledReason'; Value = 'IsEnabledForGeographicRegionFailed'; Type = 'String'; MinBuild = 22621 },
            @{ Path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsCopilot'; Name = 'AllowCopilotRuntime'; Value = 0; Type = 'DWord'; MinBuild = 22621 },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Shell Extensions\Blocked'; Name = '{CB3B0003-8088-4EDE-8769-8B354AB2FF8C}'; Value = ''; Type = 'String'; MinBuild = 22621 },
            @{ Path = 'HKLM:\SOFTWARE\Microsoft\Windows\Shell\Copilot\BingChat'; Name = 'IsUserEligible'; Value = 0; Type = 'DWord'; MinBuild = 22621 }
        )

        Write-Log -Message "Removing Copilot Appx packages..." -Level 'INFO'
        Invoke-ApplyAppRemovalStrategies -Entries (Resolve-HunterAppCatalogEntries -Selections @('copilot')) | Out-Null
        Remove-AppxPatterns -Patterns @('Microsoft.MicrosoftOfficeHub*')

        if (Test-CanUseInlineAppxCommands) {
            $currentUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $coreAiPackage = Get-AppxPackage -AllUsers -Name 'MicrosoftWindows.Client.CoreAI*' -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $coreAiPackage -and -not [string]::IsNullOrWhiteSpace($currentUserSid)) {
                $coreAiEndOfLifePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Appx\AppxAllUserStore\EndOfLife\$currentUserSid\$($coreAiPackage.PackageFullName)"
                New-Item -Path $coreAiEndOfLifePath -Force | Out-Null
                try {
                    Remove-AppxPackage -Package $coreAiPackage.PackageFullName -ErrorAction Stop
                } catch {
                    Write-Log -Message "Failed to remove CoreAI package $($coreAiPackage.PackageFullName): $_" -Level 'WARN'
                }
            }
        } else {
            Write-Log -Message 'Skipping direct CoreAI AppX cleanup in this session because Appx cmdlets are unavailable; registry-based Copilot disablement will still apply.' -Level 'INFO'
        }

        Write-Log -Message "Disabling Copilot via registry..." -Level 'INFO'
        foreach ($setting in $copilotRegistrySettings) {
            if (-not (Test-WindowsBuildInRange -MinBuild $setting.MinBuild -MaxBuild $setting.MaxBuild)) {
                Write-Log "Skipping Copilot registry setting $($setting.Path)\$($setting.Name) because it does not apply to build $($buildContext.CurrentBuild)." 'INFO'
                continue
            }

            Set-RegistryValue -Path $setting.Path -Name $setting.Name -Value $setting.Value -Type $setting.Type
        }

        Get-Process -Name '*Copilot*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Request-ExplorerRestart

        Write-Log -Message "Copilot removal complete." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-RemoveCopilot: $_" -Level 'ERROR'
        return $false
    }
}

#endregion PHASE 5

#region PHASE 6 - APPS / FEATURES NUKE+BLOCK

