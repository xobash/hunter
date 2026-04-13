function Set-DirectXGlobalPreferenceValue {
    param(
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    $path = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
    $existingPairs = [ordered]@{}
    $currentSerializedValue = ''

    try {
        $currentSettings = Get-ItemProperty -Path $path -Name 'DirectXUserGlobalSettings' -ErrorAction SilentlyContinue
        if ($null -ne $currentSettings) {
            $currentSerializedValue = [string]$currentSettings.DirectXUserGlobalSettings
        }
    } catch {
        $currentSerializedValue = ''
    }

    foreach ($segment in @($currentSerializedValue -split ';')) {
        if ($segment -notmatch '^([^=]+)=(.*)$') {
            continue
        }

        $existingPairs[$Matches[1]] = $Matches[2]
    }

    $existingPairs[$Key] = $Value
    $serializedValue = (($existingPairs.GetEnumerator() | ForEach-Object {
        '{0}={1}' -f $_.Key, $_.Value
    }) -join ';')

    if (-not [string]::IsNullOrWhiteSpace($serializedValue)) {
        $serializedValue += ';'
    }

    Set-RegistryValue -Path $path -Name 'DirectXUserGlobalSettings' -Value $serializedValue -Type String
}


function Get-GpuPciDeviceContexts {
    $displayClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
    $pciEnumPath = 'HKLM:\SYSTEM\CurrentControlSet\Enum\PCI'

    if (-not (Test-Path $pciEnumPath)) {
        return @()
    }

    $gpuContexts = New-Object 'System.Collections.Generic.List[object]'
    foreach ($pciDeviceKey in @(Get-ChildItem -Path $pciEnumPath -ErrorAction SilentlyContinue)) {
        foreach ($pciInstanceKey in @(Get-ChildItem -Path $pciDeviceKey.PSPath -ErrorAction SilentlyContinue)) {
            try {
                $instanceProperties = Get-ItemProperty -Path $pciInstanceKey.PSPath -ErrorAction Stop
                if ([string]$instanceProperties.ClassGUID -ne $displayClassGuid) {
                    continue
                }

                $friendlyName = @(
                    [string]$instanceProperties.FriendlyName,
                    [string]$instanceProperties.DeviceDesc,
                    [string]$instanceProperties.DriverDesc,
                    [string]$pciInstanceKey.PSChildName
                ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1

                $vendorName = 'Unknown'
                $hardwareIds = @($instanceProperties.HardwareID)
                if (([string]::Join(' ', @($hardwareIds))) -match '(?i)VEN_10DE') {
                    $vendorName = 'NVIDIA'
                } elseif (([string]::Join(' ', @($hardwareIds))) -match '(?i)VEN_1002|VEN_1022') {
                    $vendorName = 'AMD'
                } elseif (([string]::Join(' ', @($hardwareIds))) -match '(?i)VEN_8086') {
                    $vendorName = 'Intel'
                }

                [void]$gpuContexts.Add([pscustomobject]@{
                    Name           = $friendlyName
                    Vendor         = $vendorName
                    PciInstancePath = $pciInstanceKey.PSPath
                    PciInstanceId  = $pciInstanceKey.PSChildName
                })
            } catch {
                Write-Log "Failed to inspect PCI display device $($pciInstanceKey.PSChildName): $($_.Exception.Message)" 'WARN'
            }
        }
    }

    return @($gpuContexts.ToArray())
}

function Invoke-EnableGpuMsiMode {
    $gpuContexts = @(Get-GpuPciDeviceContexts)
    if ($gpuContexts.Count -eq 0) {
        Write-Log 'No PCI display devices were detected for GPU MSI-mode enablement.' 'INFO'
        return $true
    }

    $msiEnabledCount = 0
    Write-Log ("Detected GPU device(s) for tuning: {0}" -f ((@($gpuContexts | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Vendor }) -join '; '))) 'INFO'

    foreach ($gpuContext in $gpuContexts) {
        try {
            $msiPath = "$($gpuContext.PciInstancePath)\Interrupt Management\MessageSignaledInterruptProperties"
            Set-RegistryValue -Path $msiPath -Name 'MSISupported' -Value 1 -Type DWord | Out-Null
            if (Test-RegistryValue -Path $msiPath -Name 'MSISupported' -ExpectedValue 1) {
                $msiEnabledCount++
            }
        } catch {
            Write-Log "Failed to enable MSI mode for PCI display device $($gpuContext.PciInstanceId): $($_.Exception.Message)" 'WARN'
        }
    }

    Write-Log "GPU MSI mode enabled for $msiEnabledCount/$($gpuContexts.Count) PCI display device(s)." 'INFO'
    return ($msiEnabledCount -gt 0)
}

function Invoke-ConfigureGpuInterruptAffinity {
    $gpuContexts = @(Get-GpuPciDeviceContexts)
    if ($gpuContexts.Count -eq 0) {
        return (New-TaskSkipResult -Reason 'No PCI display devices were detected for interrupt-affinity tuning')
    }

    $logicalProcessorCount = [Environment]::ProcessorCount
    if ($logicalProcessorCount -le 1) {
        return (New-TaskSkipResult -Reason 'Interrupt-affinity tuning requires more than one logical processor')
    }

    if ($logicalProcessorCount -gt 64) {
        Write-Log "Skipping GPU interrupt-affinity tuning because this system exposes $logicalProcessorCount logical processors and Hunter only applies a single-group affinity mask." 'INFO'
        return (New-TaskSkipResult -Reason 'Interrupt-affinity tuning is limited to single-group systems (64 logical processors or fewer)')
    }

    $targetProcessorIndex = $logicalProcessorCount - 1
    $assignmentMask = [BitConverter]::GetBytes(([UInt64]1 -shl $targetProcessorIndex))
    $configuredGpuCount = 0

    foreach ($gpuContext in $gpuContexts) {
        try {
            $affinityPolicyPath = "$($gpuContext.PciInstancePath)\Interrupt Management\Affinity Policy"
            Set-RegistryValue -Path $affinityPolicyPath -Name 'DevicePolicy' -Value 4 -Type DWord | Out-Null
            Set-RegistryValue -Path $affinityPolicyPath -Name 'AssignmentSetOverride' -Value $assignmentMask -Type Binary | Out-Null
            $configuredGpuCount++
        } catch {
            Write-Log "Failed to configure interrupt affinity for GPU device $($gpuContext.PciInstanceId): $($_.Exception.Message)" 'WARN'
        }
    }

    if ($configuredGpuCount -eq 0) {
        return @{
            Success = $true
            Status  = 'CompletedWithWarnings'
            Reason  = 'Interrupt-affinity tuning did not persist for any GPU devices'
        }
    }

    Write-Log "GPU interrupt affinity pinned to logical processor $targetProcessorIndex for $configuredGpuCount/$($gpuContexts.Count) GPU device(s)." 'INFO'
    return $true
}

function Invoke-AuditResizableBarSupport {
    $gpuContexts = @(Get-GpuPciDeviceContexts)
    if ($gpuContexts.Count -eq 0) {
        return (New-TaskSkipResult -Reason 'No PCI display devices were detected for Resizable BAR auditing')
    }

    $likelyCapableCount = 0
    foreach ($gpuContext in $gpuContexts) {
        $gpuName = [string]$gpuContext.Name
        $likelyCapable = $false

        switch ([string]$gpuContext.Vendor) {
            'NVIDIA' {
                $likelyCapable = ($gpuName -match '\bRTX\s*[345]\d{3}\b')
            }
            'AMD' {
                $likelyCapable = ($gpuName -match '\bRX\s*[6789]\d{3}\b')
            }
            'Intel' {
                $likelyCapable = ($gpuName -match '\bArc\b')
            }
        }

        if ($likelyCapable) {
            $likelyCapableCount++
            Write-Log "Resizable BAR audit: $gpuName appears to be in a GPU family that commonly supports ReBAR when firmware, VBIOS, and drivers also support it." 'INFO'
        } else {
            Write-Log "Resizable BAR audit: no obvious support marker was detected for ${gpuName}. Firmware and driver validation is still required." 'INFO'
        }
    }

    Write-Log 'Resizable BAR audit completed. Hunter does not apply undocumented force-enablement because BAR sizing is negotiated by firmware and display drivers.' 'INFO'
    return $true
}
