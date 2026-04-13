function Initialize-HunterDirectory {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Assert-HunterProtectedDataAvailable {
    $protectedDataType = [System.Type]::GetType('System.Security.Cryptography.ProtectedData, System.Security', $false)
    if ($null -ne $protectedDataType) {
        return $true
    }

    Add-Type -AssemblyName 'System.Security' -ErrorAction Stop
    return $true
}

function Protect-StringForLocalMachine {
    param([Parameter(Mandatory)][string]$Value)

    Assert-HunterProtectedDataAvailable | Out-Null
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $protectedBytes = [System.Security.Cryptography.ProtectedData]::Protect(
        $plainBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

    return [Convert]::ToBase64String($protectedBytes)
}

function Unprotect-StringForLocalMachine {
    param([Parameter(Mandatory)][string]$Value)

    Assert-HunterProtectedDataAvailable | Out-Null
    $protectedBytes = [Convert]::FromBase64String($Value)
    $plainBytes = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $protectedBytes,
        $null,
        [System.Security.Cryptography.DataProtectionScope]::LocalMachine
    )

    return [System.Text.Encoding]::UTF8.GetString($plainBytes)
}

function New-HunterRandomPassword {
    param([int]$Length = 24)

    $alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789!@$%&*?'
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $chars = New-Object 'System.Collections.Generic.List[char]'
        $alphabetLength = [uint64]$alphabet.Length
        $unbiasedUpperBound = ([uint64][uint32]::MaxValue + 1) - (([uint64][uint32]::MaxValue + 1) % $alphabetLength)
        for ($i = 0; $i -lt [Math]::Max($Length, 16); $i++) {
            $bytes = New-Object byte[] 4
            do {
                $rng.GetBytes($bytes)
                $candidate = [uint64][BitConverter]::ToUInt32($bytes, 0)
            } while ($candidate -ge $unbiasedUpperBound)

            $index = [int]($candidate % $alphabetLength)
            [void]$chars.Add($alphabet[$index])
        }

        return (-join $chars)
    } finally {
        $rng.Dispose()
    }
}

function Set-HunterManagedLocalUserPassword {
    param([Parameter(Mandatory)][string]$Password)

    Initialize-HunterDirectory $script:SecretsRoot
    $payload = [ordered]@{
        Version   = 1
        UserName  = 'user'
        Password  = (Protect-StringForLocalMachine -Value $Password)
        UpdatedAt = (Get-Date).ToString('o')
    }

    $payload | ConvertTo-Json -Depth 2 | Set-Content -Path $script:LocalUserSecretPath -Encoding UTF8 -Force
}

function Get-HunterManagedLocalUserPassword {
    if (-not [string]::IsNullOrWhiteSpace($env:HUNTER_LOCAL_USER_PASSWORD)) {
        Set-HunterManagedLocalUserPassword -Password $env:HUNTER_LOCAL_USER_PASSWORD
        return $env:HUNTER_LOCAL_USER_PASSWORD
    }

    if (-not (Test-Path $script:LocalUserSecretPath)) {
        return $null
    }

    try {
        $payload = Get-Content -Path $script:LocalUserSecretPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $payload -or [string]::IsNullOrWhiteSpace([string]$payload.Password)) {
            throw 'Managed local-user secret file does not contain a password payload.'
        }

        return (Unprotect-StringForLocalMachine -Value ([string]$payload.Password))
    } catch {
        Add-RunInfrastructureIssue -Message "Failed to load the managed local-user credential: $($_.Exception.Message)" -Level 'ERROR'
        return $null
    }
}

function Resolve-HunterLocalUserPassword {
    param([bool]$UserExists)

    $storedPassword = Get-HunterManagedLocalUserPassword
    if (-not [string]::IsNullOrWhiteSpace($storedPassword)) {
        return [pscustomobject]@{
            Password     = $storedPassword
            WasGenerated = $false
            IsManaged    = $true
            Source       = if (-not [string]::IsNullOrWhiteSpace($env:HUNTER_LOCAL_USER_PASSWORD)) { 'Environment' } else { 'Stored' }
        }
    }

    if ($UserExists) {
        return $null
    }

    $generatedPassword = New-HunterRandomPassword
    Set-HunterManagedLocalUserPassword -Password $generatedPassword
    Write-Log "Generated and stored a machine-protected password for the managed local user." 'INFO'

    return [pscustomobject]@{
        Password     = $generatedPassword
        WasGenerated = $true
        IsManaged    = $true
        Source       = 'Generated'
    }
}

function Migrate-HunterStateToProgramData {
    $legacyCheckpointPath = [string]$script:LegacyCheckpointPath
    if (-not [string]::IsNullOrWhiteSpace($legacyCheckpointPath) -and
        (Test-Path $legacyCheckpointPath) -and
        -not (Test-Path $script:CheckpointPath)) {
        try {
            Initialize-HunterDirectory (Split-Path -Parent $script:CheckpointPath)
            Copy-Item -Path $legacyCheckpointPath -Destination $script:CheckpointPath -Force -ErrorAction Stop
            Write-Log "Migrated legacy checkpoint state from $legacyCheckpointPath to $($script:CheckpointPath)." 'INFO'
        } catch {
            Add-RunInfrastructureIssue -Message "Failed to migrate legacy checkpoint state from ${legacyCheckpointPath}: $($_.Exception.Message)" -Level 'WARN'
        }
    }

    foreach ($legacySecretPath in @($script:LegacyLocalUserSecretPaths)) {
        if ([string]::IsNullOrWhiteSpace([string]$legacySecretPath) -or
            -not (Test-Path $legacySecretPath) -or
            (Test-Path $script:LocalUserSecretPath)) {
            continue
        }

        try {
            Initialize-HunterDirectory (Split-Path -Parent $script:LocalUserSecretPath)
            Copy-Item -Path $legacySecretPath -Destination $script:LocalUserSecretPath -Force -ErrorAction Stop
            Write-Log "Migrated legacy local-user secret from $legacySecretPath to $($script:LocalUserSecretPath)." 'INFO'
            break
        } catch {
            Add-RunInfrastructureIssue -Message "Failed to migrate legacy local-user secret from ${legacySecretPath}: $($_.Exception.Message)" -Level 'WARN'
        }
    }
}

function Clear-HunterManagedLocalUserPassword {
    if (-not (Test-Path $script:LocalUserSecretPath)) {
        return $true
    }

    try {
        Remove-Item -Path $script:LocalUserSecretPath -Force -ErrorAction Stop
        Write-Log 'Managed local-user secret file removed from disk.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to remove the managed local-user secret file: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-ClearAutologinSecrets {
    try {
        Write-Log 'Clearing Winlogon autologin values and Hunter-managed secrets...' 'INFO'

        $winlogonPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
        $autologinValueNames = @('DefaultPassword', 'AutoAdminLogon', 'DefaultUserName', 'DefaultDomainName')
        $removedValueCount = 0
        $warnings = New-Object 'System.Collections.Generic.List[string]'

        foreach ($valueName in $autologinValueNames) {
            try {
                $existingValue = Get-ItemProperty -Path $winlogonPath -Name $valueName -ErrorAction SilentlyContinue
                if ($null -eq $existingValue -or -not ($existingValue.PSObject.Properties.Name -contains $valueName)) {
                    continue
                }

                Remove-ItemProperty -Path $winlogonPath -Name $valueName -ErrorAction Stop
                $removedValueCount++
                Write-Log "Removed Winlogon autologin value: $valueName" 'INFO'
            } catch {
                [void]$warnings.Add("Failed to remove Winlogon autologin value ${valueName}: $($_.Exception.Message)")
            }
        }

        $secretRemoved = Clear-HunterManagedLocalUserPassword
        if (-not $secretRemoved) {
            [void]$warnings.Add('Hunter-managed local-user secret could not be removed from disk.')
        }

        if (Test-Path $script:LocalUserSecretPath) {
            [void]$warnings.Add("Hunter-managed local-user secret still exists at $($script:LocalUserSecretPath).")
        }

        foreach ($warning in @($warnings)) {
            Write-Log $warning 'WARN'
        }

        if ($warnings.Count -gt 0) {
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'Autologin cleanup completed with warnings'
            }
        }

        if ($removedValueCount -eq 0 -and -not (Test-Path $script:LocalUserSecretPath)) {
            Write-Log 'No Winlogon autologin values or Hunter-managed local-user secrets were present.' 'INFO'
        } else {
            Write-Log 'Autologin registry values and Hunter-managed secrets were cleared.' 'SUCCESS'
        }

        return $true
    } catch {
        Write-Log "Failed to clear autologin secrets: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}
