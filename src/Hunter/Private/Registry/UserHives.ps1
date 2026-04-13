function Get-HunterDefaultUserHivePath {
    $profileListDefault = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -Name Default -ErrorAction SilentlyContinue).Default
    if ($profileListDefault) {
        $defaultHive = Join-Path $profileListDefault 'NTUSER.DAT'
    }
    if ([string]::IsNullOrEmpty($defaultHive) -or -not (Test-Path $defaultHive)) {
        $defaultHive = Join-Path $env:SystemDrive 'Users\Default\NTUSER.DAT'
    }

    if (Test-Path $defaultHive) {
        return $defaultHive
    }

    return $null
}

function Invoke-WithUserHive {
    param(
        [Parameter(Mandatory)][string]$HiveName,
        [Parameter(Mandatory)][string]$HivePath,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    if ([string]::IsNullOrWhiteSpace($HiveName) -or [string]::IsNullOrWhiteSpace($HivePath)) {
        throw 'A hive name and hive path are required for Invoke-WithUserHive.'
    }

    if (-not (Invoke-RegHiveCommandWithRetry -Action Load -HiveName $HiveName -HivePath $HivePath)) {
        throw "Failed to load user hive '$HiveName' from '$HivePath'."
    }

    try {
        return (& $Action (Resolve-RegistryHivePath -HiveName $HiveName))
    } finally {
        [GC]::Collect()
        if (-not (Invoke-RegHiveCommandWithRetry -Action Unload -HiveName $HiveName)) {
            Write-Log "Failed to unload user hive '$HiveName' after operation." 'WARN'
        }
    }
}

function Set-DwordForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name,
        [int]$Value
    )
    Set-RegistryValueForAllUsers -SubPath $SubPath -Name $Name -Value $Value -Type DWord
}

function Set-StringForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name,
        [string]$Value
    )
    Set-RegistryValueForAllUsers -SubPath $SubPath -Name $Name -Value $Value -Type String
}

function Set-RegistryDefaultValueForAllUsers {
    param(
        [string]$SubPath,
        [string]$Value
    )

    $regPath = Get-NativeSystemExecutablePath -FileName 'reg.exe'
    $allSucceeded = $true

    try {
        Register-HunterRegistryDefaultValueRollback -Path "HKCU:\$SubPath"
        Invoke-NativeCommandChecked -FilePath $regPath -ArgumentList @('add', "HKCU\$SubPath", '/ve', '/d', $Value, '/f') | Out-Null
        Write-Log "Default value set for current user: $SubPath = $Value"
    } catch {
        Write-Log "Failed to set default value for current user ${SubPath}: $($_.Exception.Message)" 'ERROR'
        $allSucceeded = $false
    }

    try {
        $defaultHive = Get-HunterDefaultUserHivePath
        if (Test-Path $defaultHive) {
            Register-HunterDefaultUserRegistryDefaultValueRollback -SubPath $SubPath
            Invoke-WithUserHive -HiveName 'HKU\HunterDefault' -HivePath $defaultHive -Action {
                param($HiveRoot)

                Invoke-NativeCommandChecked -FilePath $regPath -ArgumentList @('add', "HKU\HunterDefault\$SubPath", '/ve', '/d', $Value, '/f') | Out-Null
                Write-Log "Default value set for Default user: $SubPath = $Value"
            } | Out-Null
        }
    } catch {
        Write-Log "Failed to set default value for Default user ${SubPath}: $($_.Exception.Message)" 'ERROR'
        $allSucceeded = $false
    }

    return $allSucceeded
}


function Remove-RegistryValueForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name
    )

    Register-HunterRegistryValueRollback -Path "HKCU:\$SubPath" -Name $Name
    Remove-RegistryValueIfPresent -Path "HKCU:\$SubPath" -Name $Name -SkipRollbackCapture

    try {
        $defaultHive = Get-HunterDefaultUserHivePath
        if (Test-Path $defaultHive) {
            Register-HunterDefaultUserRegistryValueRollback -SubPath $SubPath -Name $Name
            Invoke-WithUserHive -HiveName 'HKU\HunterDefault' -HivePath $defaultHive -Action {
                param($HiveRoot)

                Remove-RegistryValueIfPresent -Path "$HiveRoot\$SubPath" -Name $Name -SkipRollbackCapture
            } | Out-Null
        }
    } catch {
        Write-Log "Failed to remove Default user registry value $SubPath\$Name : $_" 'WARN'
    }
}


function Set-RegistryValueForAllUsers {
    param(
        [string]$SubPath,
        [string]$Name,
        [object]$Value,
        [ValidateSet('DWord','String')]
        [string]$Type
    )

    try {
        Register-HunterRegistryValueRollback -Path "HKCU:\$SubPath" -Name $Name
        $currentUserPath = "HKCU:\$SubPath"
        $currentUserParentPath = Split-Path -Parent $currentUserPath
        $currentUserLeaf = Split-Path -Leaf $currentUserPath

        if (-not (Test-Path $currentUserPath)) {
            New-Item -Path $currentUserParentPath -Name $currentUserLeaf -Force | Out-Null
        }

        New-ItemProperty -Path $currentUserPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
        if (-not (Test-RegistryValue -Path $currentUserPath -Name $Name -ExpectedValue $Value)) {
            throw "Registry read-back verification failed for current user ${currentUserPath}\$Name"
        }
        Write-Log "$Type set for current user: $currentUserPath\$Name = $Value"
    } catch {
        Write-Log "Failed to set $Type for current user $SubPath\$Name : $_" 'ERROR'
    }

    try {
        $defaultHive = Get-HunterDefaultUserHivePath
        if (Test-Path $defaultHive) {
            Register-HunterDefaultUserRegistryValueRollback -SubPath $SubPath -Name $Name
            Invoke-WithUserHive -HiveName 'HKU\HunterDefault' -HivePath $defaultHive -Action {
                param($HiveRoot)

                $regPath = "$HiveRoot\$SubPath"
                $regParentPath = Split-Path -Parent $regPath
                $regLeaf = Split-Path -Leaf $regPath

                if (-not (Test-Path $regPath)) {
                    New-Item -Path $regParentPath -Name $regLeaf -Force | Out-Null
                }

                New-ItemProperty -Path $regPath -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
                if (-not (Test-RegistryValue -Path $regPath -Name $Name -ExpectedValue $Value)) {
                    throw "Registry read-back verification failed for Default user ${regPath}\$Name"
                }
                Write-Log "$Type set for Default user: $SubPath\$Name = $Value"
            } | Out-Null
        }
    } catch {
        Write-Log "Failed to set $Type for Default user $SubPath\$Name : $_" 'ERROR'
    }
}

function Set-DwordBatchForAllUsers {
    <#
    .SYNOPSIS
    Applies multiple DWORD registry values under the Default user hive in a single
    load/unload cycle. Each entry is a hashtable with SubPath, Name, and Value keys.
    #>
    param([hashtable[]]$Settings)

    if ($null -eq $Settings -or $Settings.Count -eq 0) { return }

    # Apply to current user first (no hive load needed)
    foreach ($setting in $Settings) {
        try {
            Register-HunterRegistryValueRollback -Path "HKCU:\$($setting.SubPath)" -Name ([string]$setting.Name)
            $currentUserPath = "HKCU:\$($setting.SubPath)"
            $parentPath = Split-Path -Parent $currentUserPath
            $leaf = Split-Path -Leaf $currentUserPath

            if (-not (Test-Path $currentUserPath)) {
                New-Item -Path $parentPath -Name $leaf -Force | Out-Null
            }

            New-ItemProperty -Path $currentUserPath -Name $setting.Name -Value $setting.Value -PropertyType DWord -Force | Out-Null
            if (-not (Test-RegistryValue -Path $currentUserPath -Name $setting.Name -ExpectedValue $setting.Value)) {
                throw "Registry read-back verification failed for current user ${currentUserPath}\$($setting.Name)"
            }
            Write-Log "DWord set for current user: $currentUserPath\$($setting.Name) = $($setting.Value)"
        } catch {
            Write-Log "Failed to set DWord for current user $($setting.SubPath)\$($setting.Name) : $_" 'ERROR'
        }
    }

    # Load Default hive once, apply all settings, unload once
    try {
        $defaultHive = Get-HunterDefaultUserHivePath
        if (Test-Path $defaultHive) {
            foreach ($setting in $Settings) {
                Register-HunterDefaultUserRegistryValueRollback -SubPath ([string]$setting.SubPath) -Name ([string]$setting.Name)
            }

            Invoke-WithUserHive -HiveName 'HKU\HunterDefault' -HivePath $defaultHive -Action {
                param($HiveRoot)

                foreach ($setting in $Settings) {
                    try {
                        $regPath = "$HiveRoot\$($setting.SubPath)"
                        $regParentPath = Split-Path -Parent $regPath
                        $regLeaf = Split-Path -Leaf $regPath

                        if (-not (Test-Path $regPath)) {
                            New-Item -Path $regParentPath -Name $regLeaf -Force | Out-Null
                        }

                        New-ItemProperty -Path $regPath -Name $setting.Name -Value $setting.Value -PropertyType DWord -Force | Out-Null
                        if (-not (Test-RegistryValue -Path $regPath -Name $setting.Name -ExpectedValue $setting.Value)) {
                            throw "Registry read-back verification failed for Default user ${regPath}\$($setting.Name)"
                        }
                        Write-Log "DWord set for Default user: $($setting.SubPath)\$($setting.Name) = $($setting.Value)"
                    } catch {
                        Write-Log "Failed to set DWord for Default user $($setting.SubPath)\$($setting.Name) : $_" 'ERROR'
                    }
                }
            } | Out-Null
        }
    } catch {
        Write-Log "Failed during batch Default user hive update: $_" 'ERROR'
    }
}
