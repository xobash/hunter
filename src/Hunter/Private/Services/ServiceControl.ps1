function Set-ServiceStartType {
    param(
        [string]$Name,
        [ValidateSet('Boot','System','Automatic','Disabled','Manual')]
        [string]$StartType
    )
    try {
        Set-Service -Name $Name -StartupType $StartType -ErrorAction Stop
        Write-Log "Service startup type set: $Name = $StartType"
    } catch {
        $errorMessage = $_.Exception.Message
        if ($errorMessage -match 'Access is denied|cannot be configured|does not exist|was not found|The parameter is incorrect') {
            Write-Log "Skipped service startup type change for ${Name}: $errorMessage" 'WARN'
        } else {
            Write-Log "Failed to set service startup type $Name : $_" 'ERROR'
        }
    }
}

function Test-ServiceStartTypeMatch {
    param(
        [string]$Name,
        [ValidateSet('Automatic', 'Manual', 'Disabled')]
        [string]$ExpectedStartType
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    try {
        $escapedName = $Name.Replace("'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return $true
        }

        $actualStartType = switch ($service.StartMode) {
            'Auto' { 'Automatic' }
            'Manual' { 'Manual' }
            'Disabled' { 'Disabled' }
            default { [string]$service.StartMode }
        }

        return ($actualStartType -eq $ExpectedStartType)
    } catch {
        return $false
    }
}

function Test-ServiceExists {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    try {
        $escapedName = $Name.Replace("'", "''")
        $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='$escapedName'" -ErrorAction SilentlyContinue
        return ($null -ne $service)
    } catch {
        return $false
    }
}

function Test-ServiceAutomaticDelayedStart {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $serviceKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    return (
        (Test-RegistryValue -Path $serviceKeyPath -Name 'Start' -ExpectedValue 2) -and
        (Test-RegistryValue -Path $serviceKeyPath -Name 'DelayedAutostart' -ExpectedValue 1)
    )
}

function Test-ServiceProtected {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $serviceKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    try {
        $launchProtected = Get-ItemProperty -Path $serviceKeyPath -Name 'LaunchProtected' -ErrorAction SilentlyContinue
        if ($null -eq $launchProtected -or $null -eq $launchProtected.LaunchProtected) {
            return $false
        }

        return ([int]$launchProtected.LaunchProtected -gt 0)
    } catch {
        return $false
    }
}

function Stop-ServiceIfPresent {
    param([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return
    }

    try {
        $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
        if ($null -eq $service) {
            return
        }

        if ($service.Status -ne 'Stopped') {
            Stop-Service -Name $Name -Force -ErrorAction Stop
            Write-Log "Service stopped: $Name" 'INFO'
        }
    } catch {
        Write-Log "Failed to stop service ${Name}: $($_.Exception.Message)" 'WARN'
    }
}

function Test-ShouldDisablePrintSpooler {
    try {
        $printers = @(Get-CimInstance -ClassName Win32_Printer -ErrorAction SilentlyContinue)
        return ($printers.Count -eq 0)
    } catch {
        Write-Log "Failed to enumerate printers for Spooler safety check: $($_.Exception.Message)" 'WARN'
        return $false
    }
}


function Disable-ScheduledTaskIfPresent {
    param(
        [string]$TaskPath,
        [string]$TaskName,
        [string]$DisplayName = $TaskName
    )

    if ([string]::IsNullOrWhiteSpace($TaskPath) -or [string]::IsNullOrWhiteSpace($TaskName)) {
        return $false
    }

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return $false
        }

        if ($task.State -eq 'Disabled') {
            Write-Log "Scheduled task already disabled: $DisplayName" 'INFO'
            return $true
        }

        Disable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log "Scheduled task disabled: $DisplayName" 'INFO'
        return $true
    } catch {
        Write-Log "Failed to disable scheduled task ${DisplayName}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Enable-ScheduledTaskIfPresent {
    param(
        [string]$TaskPath,
        [string]$TaskName,
        [string]$DisplayName = $TaskName
    )

    if ([string]::IsNullOrWhiteSpace($TaskPath) -or [string]::IsNullOrWhiteSpace($TaskName)) {
        return $false
    }

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -eq $task) {
            return $false
        }

        if ($task.State -ne 'Disabled') {
            Write-Log "Scheduled task already enabled: $DisplayName" 'INFO'
            return $true
        }

        Enable-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction Stop | Out-Null
        Write-Log "Scheduled task enabled: $DisplayName" 'INFO'
        return $true
    } catch {
        Write-Log "Failed to enable scheduled task ${DisplayName}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Set-ScheduledTaskStartTimeIfPresent {
    param(
        [string]$TaskFullName,
        [string]$StartTime,
        [string]$DisplayName = $TaskFullName
    )

    if ([string]::IsNullOrWhiteSpace($TaskFullName) -or [string]::IsNullOrWhiteSpace($StartTime)) {
        return $false
    }

    try {
        $taskQueryArgs = @('/Query', '/TN', $TaskFullName)
        & schtasks.exe @taskQueryArgs *> $null
        if ([int]$LASTEXITCODE -ne 0) {
            return $false
        }

        Invoke-NativeCommandChecked -FilePath 'schtasks.exe' -ArgumentList @('/Change', '/TN', $TaskFullName, '/ST', $StartTime) | Out-Null
        Write-Log "Scheduled task start time set: $DisplayName -> $StartTime" 'INFO'
        return $true
    } catch {
        Write-Log "Failed to set scheduled task start time for ${DisplayName}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Test-ScheduledTaskDisabledOrMissing {
    param(
        [string]$TaskPath,
        [string]$TaskName
    )

    if ([string]::IsNullOrWhiteSpace($TaskPath) -or [string]::IsNullOrWhiteSpace($TaskName)) {
        return $true
    }

    try {
        $task = Get-ScheduledTask -TaskPath $TaskPath -TaskName $TaskName -ErrorAction SilentlyContinue
        return ($null -eq $task -or $task.State -eq 'Disabled')
    } catch {
        Write-Log "Failed to query scheduled task ${TaskPath}${TaskName}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

