function Invoke-CreateRestorePoint {
    if (Test-TaskCompleted -TaskId 'preflight-restore-point') {
        Write-Log "Restore point already created, skipping"
        return (New-TaskSkipResult -Reason 'Restore point already exists in the checkpoint state')
    }

    if ($script:IsAutomationRun) {
        Write-Log 'Automation-safe mode enabled; skipping restore point creation.' 'INFO'
        return (New-TaskSkipResult -Reason 'Restore point creation skipped in automation-safe mode')
    }

    $shouldCreateRestorePoint = Show-YesNoDialog `
        -Title 'Hunter Restore Point' `
        -Message "Create a Windows System Restore point before Hunter continues?`n`nThis can take several minutes and may stall on some systems.`n`nChoose Yes to create one now, or No to skip this step." `
        -DefaultToNo $true

    if (-not $shouldCreateRestorePoint) {
        Write-Log 'Restore point creation skipped by user.' 'INFO'
        return (New-TaskSkipResult -Reason 'Restore point creation was skipped by the user')
    }

    $restorePointJob = $null
    $restorePointTimeoutSeconds = 300
    $systemRestorePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $originalFrequencyExists = $false
    $originalFrequencyValue = $null

    try {
        if (Test-Path $systemRestorePath) {
            try {
                $existingFrequency = Get-ItemProperty -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop
                $originalFrequencyValue = [int]$existingFrequency.SystemRestorePointCreationFrequency
                $originalFrequencyExists = $true
            } catch [System.Management.Automation.ItemNotFoundException] {
            }
        }

        Set-RegistryValue -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -Value 0 -Type 'DWord'
        if (-not (Test-RegistryValue -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -ExpectedValue 0)) {
            throw 'SystemRestorePointCreationFrequency was not persisted.'
        }

        $restorePointJob = Start-Job -ScriptBlock {
            param($Drive)

            $ErrorActionPreference = 'Stop'
            Enable-ComputerRestore -Drive $Drive -ErrorAction Stop
            Checkpoint-Computer -Description 'Hunter Pre-Install' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop

            return @{
                Success = $true
            }
        } -ArgumentList ('{0}\' -f $env:SystemDrive.TrimEnd('\'))

        if (-not (Wait-Job -Job $restorePointJob -Timeout $restorePointTimeoutSeconds)) {
            try {
                Stop-Job -Job $restorePointJob -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "Failed to stop timed-out restore-point job cleanly: $($_.Exception.Message)" 'WARN'
            }

            throw "Restore point creation timed out after $restorePointTimeoutSeconds seconds."
        }

        $restorePointResult = Receive-Job -Job $restorePointJob -ErrorAction Stop
        if ($null -eq $restorePointResult -or
            ($restorePointResult -is [hashtable] -and $restorePointResult.ContainsKey('Success') -and -not [bool]$restorePointResult.Success)) {
            throw 'Restore point job did not report success.'
        }

        Write-Log "Restore point created successfully"
        return $true
    } catch {
        Write-Log "Failed to create restore point : $_" 'ERROR'
        return $false
    } finally {
        if ($null -ne $restorePointJob) {
            try {
                Remove-Job -Job $restorePointJob -Force -ErrorAction Stop | Out-Null
            } catch {
                Write-Log "Failed to remove restore-point background job: $($_.Exception.Message)" 'WARN'
            }
        }

        if ($originalFrequencyExists) {
            if (-not (Set-RegistryValue -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -Value $originalFrequencyValue -Type 'DWord')) {
                Write-Log 'Failed to restore the original SystemRestorePointCreationFrequency value.' 'ERROR'
            }
        } else {
            Remove-RegistryValueIfPresent -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency'
            if (Test-Path $systemRestorePath) {
                try {
                    $leftoverFrequency = Get-ItemProperty -Path $systemRestorePath -Name 'SystemRestorePointCreationFrequency' -ErrorAction Stop
                    if ($null -ne $leftoverFrequency) {
                        Write-Log 'Failed to remove the temporary SystemRestorePointCreationFrequency override.' 'ERROR'
                    }
                } catch [System.Management.Automation.ItemNotFoundException] {
                } catch {
                    Write-Log "Failed to verify cleanup of SystemRestorePointCreationFrequency: $($_.Exception.Message)" 'ERROR'
                }
            }
        }
    }
}

function Invoke-VerifyInternetConnectivity {
    try {
        Write-Log 'Verifying internet connectivity...' 'INFO'
        $probeFailures = New-Object 'System.Collections.Generic.List[string]'

        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
        if ($null -ne $curl) {
            try {
                $curlOutput = & $curl.Source -L --fail --silent --show-error 'https://www.msftconnecttest.com/connecttest.txt' 2>$null
                if ($LASTEXITCODE -eq 0 -and [string]::Join("`n", @($curlOutput)) -match 'Microsoft Connect Test') {
                    Write-Log 'Internet connectivity verified (curl probe)' 'SUCCESS'
                    return $true
                }

                if ($LASTEXITCODE -ne 0) {
                    [void]$probeFailures.Add("curl-based internet probe exited with code $LASTEXITCODE")
                }
            } catch {
                [void]$probeFailures.Add("curl-based internet probe failed: $($_.Exception.Message)")
            }
        }

        try {
            $response = Invoke-WebRequest -Uri 'http://www.msftconnecttest.com/connecttest.txt' -UseBasicParsing -MaximumRedirection 3 -TimeoutSec 15 -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$response.Content) -and [string]$response.Content -match 'Microsoft Connect Test') {
                Write-Log 'Internet connectivity verified (HTTP probe)' 'SUCCESS'
                return $true
            }
        } catch {
            [void]$probeFailures.Add("HTTP internet probe failed: $($_.Exception.Message)")
        }

        try {
            if (Test-NetConnection -ComputerName 'raw.githubusercontent.com' -Port 443 -InformationLevel Quiet -WarningAction SilentlyContinue) {
                Write-Log 'Internet connectivity verified (TCP probe to raw.githubusercontent.com:443)' 'SUCCESS'
                return $true
            }
        } catch {
            [void]$probeFailures.Add("TCP internet probe failed: $($_.Exception.Message)")
        }

        foreach ($probeFailure in @($probeFailures)) {
            Write-Log $probeFailure 'WARN'
        }

        throw 'All connectivity probes failed.'
    } catch {
        Write-Log "Internet connectivity check failed: $_" 'ERROR'
        throw
    }
}

function Invoke-ConfirmAppDownloads {
    try {
        $skipAppDownloads = Resolve-SkipAppDownloadsPreference
        if (-not $skipAppDownloads) {
            return (Ensure-WingetFunctional)
        }

        return $true
    } catch {
        Write-Log "Failed to capture app download/install preference : $_" 'ERROR'
        return $false
    }
}

function Invoke-PreDownloadInstallers {
    try {
        Write-Log 'Starting background package download/install pipeline during preflight...' 'INFO'
        if (Resolve-SkipAppDownloadsPreference) {
            Write-Log 'Skipping background package download/install pipeline by user request.' 'INFO'
            Invoke-PrefetchExternalAssets
            return $true
        }
        if ($script:PackagePipelineBlocked) {
            Write-Log "Skipping background package download/install pipeline: $($script:PackagePipelineBlockReason)" 'WARN'
            Invoke-PrefetchExternalAssets
            return (New-TaskSkipResult -Reason $script:PackagePipelineBlockReason)
        }

        $launchResult = Invoke-ParallelInstalls -LaunchOnly
        Invoke-PrefetchExternalAssets
        return $launchResult
    } catch {
        Write-Log "Failed during pre-download : $_" 'ERROR'
        return $false
    }
}

