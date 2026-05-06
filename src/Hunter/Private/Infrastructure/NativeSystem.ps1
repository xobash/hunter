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

function Invoke-NativeCommandWithTimeout {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [int]$TimeoutSeconds = 60,
        [string]$Description = $FilePath
    )

    $commandId = [guid]::NewGuid().ToString('N')
    $stdoutPath = Join-Path ([System.IO.Path]::GetTempPath()) "Hunter-$commandId.out"
    $stderrPath = Join-Path ([System.IO.Path]::GetTempPath()) "Hunter-$commandId.err"
    $process = $null

    try {
        $process = Start-Process `
            -FilePath $FilePath `
            -ArgumentList $ArgumentList `
            -PassThru `
            -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath `
            -RedirectStandardError $stderrPath `
            -ErrorAction Stop

        if (-not $process.WaitForExit([Math]::Max(1, $TimeoutSeconds) * 1000)) {
            try {
                $process.Kill()
            } catch {
            }

            throw "$Description timed out after $TimeoutSeconds seconds."
        }

        $outputText = ''
        foreach ($outputPath in @($stdoutPath, $stderrPath)) {
            if (Test-Path $outputPath) {
                $content = Get-Content -Path $outputPath -Raw -ErrorAction SilentlyContinue
                if (-not [string]::IsNullOrWhiteSpace([string]$content)) {
                    if (-not [string]::IsNullOrWhiteSpace($outputText)) {
                        $outputText += "`n"
                    }
                    $outputText += [string]$content
                }
            }
        }

        return [pscustomobject]@{
            ExitCode = [int]$process.ExitCode
            Output   = $outputText.Trim()
        }
    } finally {
        Remove-Item -Path $stdoutPath, $stderrPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-DismOptionalFeatureServicingUnavailable {
    $flag = Get-Variable -Name DismOptionalFeatureServicingUnavailable -Scope Script -ErrorAction SilentlyContinue
    return ($null -ne $flag -and [bool]$flag.Value)
}

function Set-DismOptionalFeatureServicingUnavailable {
    $script:DismOptionalFeatureServicingUnavailable = $true
}

function Get-ServiceRegistryStartType {
    param([Parameter(Mandatory)][string]$ServiceName)

    $serviceKeyPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName"
    if (-not (Test-Path $serviceKeyPath)) {
        return ''
    }

    try {
        $serviceConfig = Get-ItemProperty -Path $serviceKeyPath -Name 'Start' -ErrorAction Stop
        return switch ([int]$serviceConfig.Start) {
            0 { 'Boot' }
            1 { 'System' }
            2 { 'Automatic' }
            3 { 'Manual' }
            4 { 'Disabled' }
            default { '' }
        }
    } catch {
        return ''
    }
}

function Invoke-WithOptionalFeatureServicingPrerequisites {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock)

    if (Test-DismOptionalFeatureServicingUnavailable) {
        return $false
    }

    $serviceName = 'TrustedInstaller'
    $serviceDisplayName = 'Windows Modules Installer'
    $originalStartType = Get-ServiceRegistryStartType -ServiceName $serviceName
    if ([string]::IsNullOrWhiteSpace($originalStartType)) {
        Set-DismOptionalFeatureServicingUnavailable
        throw "$serviceDisplayName service ($serviceName) is unavailable."
    }

    $startTypeChanged = $false
    $serviceStarted = $false

    try {
        if ($originalStartType -eq 'Disabled') {
            Write-Log "$serviceDisplayName service is disabled. Temporarily restoring it for Windows optional-feature servicing." 'INFO'
            Set-ServiceStartType -Name $serviceName -StartType 'Manual'
            $startTypeChanged = $true
        }

        $service = Get-Service -Name $serviceName -ErrorAction Stop
        if ($service.Status -ne 'Running') {
            Start-Service -Name $serviceName -ErrorAction Stop
            $serviceStarted = $true
            Write-Log "$serviceDisplayName service started for Windows optional-feature servicing." 'INFO'
        }

        return (& $ScriptBlock)
    } catch {
        if ($_.Exception.Message -match '(?i)class not registered|timed out|0x80040154|unavailable') {
            Set-DismOptionalFeatureServicingUnavailable
        }

        throw
    } finally {
        if ($serviceStarted) {
            try {
                $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
                if ($null -ne $service -and $service.Status -ne 'Stopped') {
                    Stop-Service -Name $serviceName -Force -ErrorAction Stop
                    Write-Log "$serviceDisplayName service stopped after Windows optional-feature servicing." 'INFO'
                }
            } catch {
                Write-Log "Failed to stop $serviceDisplayName service after optional-feature servicing: $($_.Exception.Message)" 'WARN'
            }
        }

        if ($startTypeChanged) {
            try {
                Set-ServiceStartType -Name $serviceName -StartType $originalStartType
                Write-Log "$serviceDisplayName service startup type restored to $originalStartType after optional-feature servicing." 'INFO'
            } catch {
                Write-Log "Failed to restore $serviceDisplayName startup type after optional-feature servicing: $($_.Exception.Message)" 'WARN'
            }
        }
    }
}

function Get-DismOptionalFeatureInfo {
    param([Parameter(Mandatory)][string]$FeatureName)

    $dismPath = Get-NativeSystemExecutablePath -FileName 'dism.exe'
    $result = Invoke-NativeCommandWithTimeout `
        -FilePath $dismPath `
        -ArgumentList @('/Online', '/English', '/Get-FeatureInfo', "/FeatureName:$FeatureName") `
        -TimeoutSeconds 30 `
        -Description "DISM optional feature query for $FeatureName"

    $outputText = [string]$result.Output
    if ([int]$result.ExitCode -ne 0) {
        if ($outputText -match '(?i)feature name .* is unknown|unknown feature|0x800f080c|not found') {
            return [pscustomobject]@{
                FeatureName = $FeatureName
                Present     = $false
                State       = ''
            }
        }

        throw "dism.exe feature query for $FeatureName exited with code $($result.ExitCode): $outputText"
    }

    $state = ''
    if ($outputText -match '(?im)^\s*State\s*:\s*(?<State>.+?)\s*$') {
        $state = [string]$Matches['State']
    }

    return [pscustomobject]@{
        FeatureName = $FeatureName
        Present     = $true
        State       = $state.Trim()
    }
}

function Disable-DismOptionalFeature {
    param([Parameter(Mandatory)][string]$FeatureName)

    $dismPath = Get-NativeSystemExecutablePath -FileName 'dism.exe'
    $result = Invoke-NativeCommandWithTimeout `
        -FilePath $dismPath `
        -ArgumentList @('/Online', '/English', '/Disable-Feature', "/FeatureName:$FeatureName", '/NoRestart') `
        -TimeoutSeconds 120 `
        -Description "DISM optional feature disable for $FeatureName"

    if (@(0, 3010) -notcontains [int]$result.ExitCode) {
        throw "dism.exe feature disable for $FeatureName exited with code $($result.ExitCode): $($result.Output)"
    }

    return $true
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

    if (Test-DismOptionalFeatureServicingUnavailable) {
        Write-Log "Skipping $DisplayName optional feature disable because Windows optional-feature servicing is unavailable in this session." 'WARN'
        return $false
    }

    try {
        $resolvedFeature = $null
        foreach ($candidateName in $CandidateNames) {
            $feature = Get-DismOptionalFeatureInfo -FeatureName $candidateName
            if ($null -ne $feature -and $feature.Present) {
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

        Disable-DismOptionalFeature -FeatureName $resolvedFeature.FeatureName | Out-Null
        Write-Log "$DisplayName optional feature disabled." 'INFO'
        return $true
    } catch {
        if ($_.Exception.Message -match '(?i)class not registered|timed out|0x80040154') {
            Set-DismOptionalFeatureServicingUnavailable
        }

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

    $queryOutput = & $PowerCfgPath /query $Scheme $SubGroup $Setting 2>&1
    $queryExitCode = [int]$LASTEXITCODE
    $queryOutput = @($queryOutput)
    $queryText = [string]::Join(' ', @($queryOutput | ForEach-Object { [string]$_ })).Trim()
    if ($queryExitCode -ne 0 -or $queryText -match $unsupportedPattern) {
        Write-Log "Skipped power setting ${settingLabel} ($Mode): unavailable on this system." 'INFO'
        return $false
    }

    $setOutput = & $PowerCfgPath $operation $Scheme $SubGroup $Setting $Value 2>&1
    $setExitCode = [int]$LASTEXITCODE
    $setOutput = @($setOutput)
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
