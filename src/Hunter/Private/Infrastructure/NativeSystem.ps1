function Invoke-NativeCommandChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0)
    )

    & $FilePath @ArgumentList
    $exitCode = [int]$LASTEXITCODE
    if ($SuccessExitCodes -notcontains $exitCode) {
        throw "$FilePath exited with code $exitCode"
    }

    return $exitCode
}

function Get-NativeSystemExecutablePath {
    param([Parameter(Mandatory)][string]$FileName)

    $systemDirectory = if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        Join-Path $script:WindowsRoot 'Sysnative'
    } else {
        Join-Path $script:WindowsRoot 'System32'
    }

    $candidatePath = Join-Path $systemDirectory $FileName
    if (Test-Path $candidatePath) {
        return $candidatePath
    }

    return $FileName
}

function Start-ProcessChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int[]]$SuccessExitCodes = @(0),
        [ValidateSet('Normal','Hidden','Minimized','Maximized')]
        [string]$WindowStyle = 'Normal'
    )

    $process = Start-Process -FilePath $FilePath -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle $WindowStyle -ErrorAction Stop
    if ($null -eq $process) {
        throw "Failed to start process $FilePath"
    }

    if ($SuccessExitCodes -notcontains [int]$process.ExitCode) {
        throw "$FilePath exited with code $($process.ExitCode)"
    }

    return $process
}

function Disable-WindowsOptionalFeatureIfPresent {
    param(
        [string]$DisplayName,
        [string[]]$CandidateNames,
        [switch]$SkipOnHyperVGuest
    )

    if ($SkipOnHyperVGuest -and $script:IsHyperVGuest) {
        Write-Log "Hyper-V guest detected, skipping $DisplayName optional feature disable." 'INFO'
        return $true
    }

    if ($null -eq $CandidateNames -or $CandidateNames.Count -eq 0) {
        return $false
    }

    try {
        $resolvedFeature = $null
        foreach ($candidateName in $CandidateNames) {
            $feature = Get-WindowsOptionalFeature -Online -FeatureName $candidateName -ErrorAction SilentlyContinue
            if ($null -ne $feature) {
                $resolvedFeature = $feature
                break
            }
        }

        if ($null -eq $resolvedFeature) {
            Write-Log "$DisplayName optional feature not present. Skipping." 'INFO'
            return $true
        }

        if ([string]$resolvedFeature.State -notin @('Enabled', 'Enable Pending')) {
            Write-Log "$DisplayName optional feature already disabled." 'INFO'
            return $true
        }

        Disable-WindowsOptionalFeature -Online -FeatureName $resolvedFeature.FeatureName -NoRestart -ErrorAction Stop | Out-Null
        Write-Log "$DisplayName optional feature disabled." 'INFO'
        return $true
    } catch {
        Write-Log "Failed to disable $DisplayName optional feature: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-BCDEditBestEffort {
    param(
        [string[]]$ArgumentList,
        [string]$Description
    )

    try {
        $bcdeditPath = Get-NativeSystemExecutablePath -FileName 'bcdedit.exe'
        $process = Start-Process -FilePath $bcdeditPath -ArgumentList $ArgumentList -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
        if ($null -eq $process) {
            throw 'bcdedit.exe did not return a process handle.'
        }

        if ([int]$process.ExitCode -eq 0) {
            Write-Log $Description 'INFO'
            return $true
        }

        Write-Log "$Description skipped (bcdedit exited with code $($process.ExitCode))." 'INFO'
        return $false
    } catch {
        Write-Log "Skipped boot configuration update for ${Description}: $($_.Exception.Message)" 'INFO'
        return $false
    }
}

function Invoke-PowerCfgValueBestEffort {
    param(
        [Parameter(Mandatory)][string]$PowerCfgPath,
        [Parameter(Mandatory)][string]$Scheme,
        [Parameter(Mandatory)][string]$SubGroup,
        [Parameter(Mandatory)][string]$Setting,
        [Parameter(Mandatory)][string]$Value,
        [Parameter(Mandatory)][ValidateSet('AC', 'DC')][string]$Mode,
        [string]$Description = ''
    )

    $settingLabel = if ([string]::IsNullOrWhiteSpace($Description)) {
        "$SubGroup/$Setting"
    } else {
        $Description
    }

    $operation = if ($Mode -eq 'AC') { '/setacvalueindex' } else { '/setdcvalueindex' }
    $unsupportedPattern = '(?i)does not exist|invalid parameter|not supported|not available'

    $queryOutput = @(& $PowerCfgPath /query $Scheme $SubGroup $Setting 2>&1)
    $queryExitCode = [int]$LASTEXITCODE
    $queryText = [string]::Join(' ', @($queryOutput | ForEach-Object { [string]$_ })).Trim()
    if ($queryExitCode -ne 0 -or $queryText -match $unsupportedPattern) {
        Write-Log "Skipped power setting ${settingLabel} ($Mode): unavailable on this system." 'INFO'
        return $false
    }

    $setOutput = @(& $PowerCfgPath $operation $Scheme $SubGroup $Setting $Value 2>&1)
    $setExitCode = [int]$LASTEXITCODE
    $setText = [string]::Join(' ', @($setOutput | ForEach-Object { [string]$_ })).Trim()
    if ($setExitCode -ne 0 -or $setText -match $unsupportedPattern) {
        $detail = if ([string]::IsNullOrWhiteSpace($setText)) {
            "powercfg exited with code $setExitCode"
        } else {
            $setText
        }
        Write-Log "Skipped power setting ${settingLabel} ($Mode): $detail" 'INFO'
        return $false
    }

    return $true
}
