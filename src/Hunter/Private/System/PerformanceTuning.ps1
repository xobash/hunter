function Set-LargeSystemCacheByRamPolicy {
    param(
        [string]$Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
    )

    $desiredValue = Get-DesiredLargeSystemCacheValue
    Set-RegistryValue -Path $Path -Name 'LargeSystemCache' -Value $desiredValue -Type DWord | Out-Null
    return $desiredValue
}

function Set-FixedPageFileByRamPolicy {
    try {
        $targetPageFileSizeMb = Get-FixedPageFileSizeMegabytes
        if ($targetPageFileSizeMb -le 0) {
            return $false
        }

        $pageFilePath = '{0}\pagefile.sys' -f $env:SystemDrive.TrimEnd('\')
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $computerSystem -and [bool]$computerSystem.AutomaticManagedPagefile) {
            Set-CimInstance -InputObject $computerSystem -Property @{ AutomaticManagedPagefile = $false } -ErrorAction Stop | Out-Null
            Write-Log 'Automatic pagefile management disabled.' 'INFO'
        } else {
            Write-Log 'Automatic pagefile management already disabled.' 'INFO'
        }

        $existingPageFileSettings = @(Get-CimInstance -ClassName Win32_PageFileSetting -ErrorAction SilentlyContinue)
        $targetSetting = $null
        foreach ($pageFileSetting in $existingPageFileSettings) {
            if ($null -eq $pageFileSetting) {
                continue
            }

            if ([string]$pageFileSetting.Name -ieq $pageFilePath) {
                $targetSetting = $pageFileSetting
                continue
            }

            try {
                Remove-CimInstance -InputObject $pageFileSetting -ErrorAction Stop
                Write-Log "Removed non-system pagefile setting: $($pageFileSetting.Name)" 'INFO'
            } catch {
                Write-Log "Failed to remove pagefile setting $($pageFileSetting.Name): $($_.Exception.Message)" 'WARN'
            }
        }

        if ($null -eq $targetSetting) {
            New-CimInstance -ClassName Win32_PageFileSetting -Property @{
                Name        = $pageFilePath
                InitialSize = $targetPageFileSizeMb
                MaximumSize = $targetPageFileSizeMb
            } -ErrorAction Stop | Out-Null
            Write-Log "Fixed pagefile created at $pageFilePath (${targetPageFileSizeMb} MB)." 'INFO'
        } elseif ([int]$targetSetting.InitialSize -eq $targetPageFileSizeMb -and [int]$targetSetting.MaximumSize -eq $targetPageFileSizeMb) {
            Write-Log "Fixed pagefile already configured at $pageFilePath (${targetPageFileSizeMb} MB)." 'INFO'
        } else {
            Set-CimInstance -InputObject $targetSetting -Property @{
                InitialSize = $targetPageFileSizeMb
                MaximumSize = $targetPageFileSizeMb
            } -ErrorAction Stop | Out-Null
            Write-Log "Fixed pagefile updated at $pageFilePath (${targetPageFileSizeMb} MB)." 'INFO'
        }

        return $true
    } catch {
        Write-Log "Failed to configure fixed pagefile sizing: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-DisableDiskWriteCacheBufferFlushing {
    try {
        $diskDeviceEntries = @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction SilentlyContinue | Where-Object {
            $null -ne $_ -and -not [string]::IsNullOrWhiteSpace([string]$_.PNPDeviceID)
        })

        if ($diskDeviceEntries.Count -eq 0) {
            Write-Log 'No disk device entries were found for write-cache buffer flushing policy.' 'INFO'
            return $true
        }

        $updatedDiskPolicies = 0
        foreach ($diskDevice in $diskDeviceEntries) {
            $deviceParametersPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\{0}\Device Parameters\Disk' -f $diskDevice.PNPDeviceID
            $cacheProtectedUpdated = Set-RegistryValue -Path $deviceParametersPath -Name 'CacheIsPowerProtected' -Value 1 -Type DWord
            $writeCacheUpdated = Set-RegistryValue -Path $deviceParametersPath -Name 'UserWriteCacheSetting' -Value 1 -Type DWord
            if ($cacheProtectedUpdated -or $writeCacheUpdated) {
                $updatedDiskPolicies++
            }
        }

        Write-Log "Disk write-cache buffer flushing policy disabled on $updatedDiskPolicies disk device policy key(s)." 'INFO'
        return $true
    } catch {
        Write-Log "Failed to disable disk write-cache buffer flushing: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-DisableAudioEnhancements {
    try {
        $endpointPropertyName = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},5'
        $endpointRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio'
        $updatedEndpointCount = 0
        $skippedEndpointCount = 0

        foreach ($endpointType in @('Render', 'Capture')) {
            $typeRootPath = Join-Path $endpointRoot $endpointType
            if (-not (Test-Path $typeRootPath)) {
                continue
            }

            foreach ($endpointKey in @(Get-ChildItem -Path $typeRootPath -ErrorAction SilentlyContinue)) {
                $fxPropertiesPath = Join-Path $endpointKey.PSPath 'FxProperties'
                try {
                    if (-not (Test-Path $fxPropertiesPath)) {
                        New-Item -Path $endpointKey.PSPath -Name 'FxProperties' -Force -ErrorAction Stop | Out-Null
                    }

                    New-ItemProperty -Path $fxPropertiesPath -Name $endpointPropertyName -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
                    Write-Log "Registry set: $fxPropertiesPath\$endpointPropertyName = 1 (DWord)"
                    $updatedEndpointCount++
                } catch {
                    $skippedEndpointCount++
                    Write-Log "Skipping protected or unavailable audio endpoint enhancement policy at ${fxPropertiesPath}: $($_.Exception.Message)" 'INFO'
                }
            }
        }

        Write-Log "Audio enhancements disabled on $updatedEndpointCount endpoint(s); skipped $skippedEndpointCount protected or unavailable endpoint(s)." 'INFO'
        return $true
    } catch {
        Write-Log "Failed to disable audio enhancements: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Set-NoSoundsSchemeForAllUsers {
    try {
        if (Set-RegistryDefaultValueForAllUsers -SubPath 'AppEvents\Schemes' -Value '.None') {
            Write-Log 'Sound scheme set to No Sounds for current and Default users.' 'INFO'
            return $true
        }

        Write-Log 'Sound scheme update completed with partial failures.' 'WARN'
        return $false
    } catch {
        Write-Log "Failed to set sound scheme to No Sounds: $($_.Exception.Message)" 'WARN'
        return $false
    }
}


function Invoke-ActivateUltimatePerformance {
    try {
        Register-HunterActivePowerSchemeRollback
        $activeScheme = (powercfg /getactivescheme 2>$null) -join ''
        $upGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'

        if ($activeScheme -match $upGuid) {
            Write-Log 'Ultimate Performance already active'
            return (New-TaskSkipResult -Reason 'Ultimate Performance is already active')
        }

        # Check if it already exists in the list
        $schemes = (powercfg /list 2>$null) -join "`n"
        if ($schemes -match $upGuid) {
            Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $upGuid) | Out-Null
        } else {
            # Duplicate the scheme - capture new GUID from output
            $result = powercfg /duplicatescheme $upGuid 2>$null
            if ($LASTEXITCODE -ne 0) {
                throw "powercfg /duplicatescheme exited with code $LASTEXITCODE"
            }
            $newGuid = $null
            $duplicateOutput = [string]::Join(' ', @($result))
            foreach ($token in ($duplicateOutput -split '\s+')) {
                $normalizedToken = $token.Replace('(', '').Replace(')', '')
                try {
                    $candidateGuid = [guid]$normalizedToken
                    $newGuid = $candidateGuid.Guid
                    break
                } catch {
                    continue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($newGuid)) {
                Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $newGuid) | Out-Null
            } else {
                # Fallback: try High Performance
                Write-Log 'Ultimate Performance not available, activating High Performance' 'WARN'
                Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c') | Out-Null
            }
        }
        Write-Log 'Power scheme activated'
        return $true
    } catch {
        Write-Log "Failed to activate power plan: $_" 'ERROR'
        return $false
    }
}
