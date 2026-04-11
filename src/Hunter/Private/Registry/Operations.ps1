function Set-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$Value,
        [ValidateSet('DWord','String','QWord','Binary','ExpandString','MultiString')]
        [string]$Type = 'String'
    )
    try {
        if (-not (Initialize-RegistryKeyPath -Path $Path)) {
            throw "Failed to create registry path $Path"
        }

        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
        if (-not (Test-RegistryValue -Path $Path -Name $Name -ExpectedValue $Value)) {
            throw "Registry read-back verification failed for $Path\$Name"
        }
        Write-Log "Registry set: $Path\$Name = $Value ($Type)"
        return $true
    } catch {
        Write-Log "Failed to set registry $Path\$Name : $_" 'ERROR'
        return $false
    }
}

function Initialize-RegistryKeyPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or (Test-Path $Path)) {
        return $true
    }

    $parentPath = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parentPath) -and $parentPath -ne $Path -and -not (Test-Path $parentPath)) {
        if (-not (Initialize-RegistryKeyPath -Path $parentPath)) {
            return $false
        }
    }

    try {
        New-Item -Path $Path -Force | Out-Null
        return $true
    } catch {
        return $false
    }
}

function Remove-RegistryKey {
    param([string]$Path)
    try {
        if (Test-Path $Path) {
            Remove-Item -Path $Path -Recurse -Force -ErrorAction Stop
            Write-Log "Registry key removed: $Path"
        }
    } catch {
        Write-Log "Failed to remove registry key $Path : $_" 'ERROR'
    }
}

function Test-RegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [object]$ExpectedValue
    )
    try {
        if (-not (Test-Path $Path)) {
            return $false
        }
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $prop) {
            return $false
        }
        if ($null -eq $ExpectedValue) {
            return $true
        }
        return (Test-HunterValueEquals -ActualValue $prop.$Name -ExpectedValue $ExpectedValue)
    } catch {
        return $false
    }
}

function Test-HunterValueEquals {
    param(
        [object]$ActualValue,
        [object]$ExpectedValue
    )

    if ($ActualValue -is [byte[]] -and $ExpectedValue -is [byte[]]) {
        if ($ActualValue.Length -ne $ExpectedValue.Length) {
            return $false
        }

        for ($index = 0; $index -lt $ActualValue.Length; $index++) {
            if ($ActualValue[$index] -ne $ExpectedValue[$index]) {
                return $false
            }
        }

        return $true
    }

    if (($ActualValue -is [System.Array]) -or ($ExpectedValue -is [System.Array])) {
        $actualItems = @($ActualValue)
        $expectedItems = @($ExpectedValue)
        if ($actualItems.Count -ne $expectedItems.Count) {
            return $false
        }

        for ($index = 0; $index -lt $actualItems.Count; $index++) {
            if (-not (Test-HunterValueEquals -ActualValue $actualItems[$index] -ExpectedValue $expectedItems[$index])) {
                return $false
            }
        }

        return $true
    }

    return ($ActualValue -eq $ExpectedValue)
}

function Remove-RegistryValueIfPresent {
    param(
        [string]$Path,
        [string]$Name
    )

    try {
        if (-not (Test-Path $Path)) {
            return
        }

        if ($null -eq (Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue)) {
            return
        }

        Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop
        Write-Log "Registry value removed: $Path\$Name"
    } catch {
        Write-Log "Failed to remove registry value $Path\$Name : $_" 'WARN'
    }
}


function Invoke-RegHiveCommandWithRetry {
    param(
        [ValidateSet('Load','Unload')]
        [string]$Action,
        [string]$HiveName,
        [string]$HivePath = '',
        [int]$MaxAttempts = 5
    )

    $regExePath = Get-NativeSystemExecutablePath -FileName 'reg.exe'
    $resolvedHivePath = Resolve-RegistryHivePath -HiveName $HiveName

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $hiveIsLoaded = if (-not [string]::IsNullOrWhiteSpace($resolvedHivePath)) {
            Test-Path $resolvedHivePath
        } else {
            $false
        }

        if ($Action -eq 'Load' -and $hiveIsLoaded) {
            return $true
        }

        if ($Action -eq 'Unload' -and -not $hiveIsLoaded) {
            return $true
        }

        try {
            $regArguments = @($Action.ToLowerInvariant(), $HiveName)
            if ($Action -eq 'Load') {
                $regArguments += $HivePath
            }

            $regProcess = Start-Process -FilePath $regExePath -ArgumentList $regArguments -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            $exitCode = [int]$regProcess.ExitCode
        } catch {
            $exitCode = -1
        }

        $hiveStateMatches = if (-not [string]::IsNullOrWhiteSpace($resolvedHivePath)) {
            $currentlyLoaded = Test-Path $resolvedHivePath
            (($Action -eq 'Load' -and $currentlyLoaded) -or ($Action -eq 'Unload' -and -not $currentlyLoaded))
        } else {
            ($exitCode -eq 0)
        }

        if ($hiveStateMatches) {
            return $true
        }

        if ($attempt -lt $MaxAttempts) {
            $delayMs = [Math]::Min(2000, (150 * [Math]::Pow(2, ($attempt - 1))))
            Start-Sleep -Milliseconds ([int]$delayMs)
        }
    }

    return $false
}

function Resolve-RegistryHivePath {
    param([string]$HiveName)

    if ([string]::IsNullOrWhiteSpace($HiveName)) {
        return $null
    }

    if ($HiveName -match '^HKU\\(.+)$') {
        return "Registry::HKEY_USERS\$($Matches[1])"
    }

    if ($HiveName -match '^HKLM\\(.+)$') {
        return "Registry::HKEY_LOCAL_MACHINE\$($Matches[1])"
    }

    return $null
}
