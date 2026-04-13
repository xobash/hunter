function Get-WindowsEditionContext {
    if ($null -ne $script:WindowsEditionContext) {
        return $script:WindowsEditionContext
    }

    $currentVersionPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $editionId = ''
    $installationType = ''
    $productName = ''
    $onlineEdition = ''

    try {
        $currentVersion = Get-ItemProperty -Path $currentVersionPath -ErrorAction Stop
        $editionId = [string]$currentVersion.EditionID
        $installationType = [string]$currentVersion.InstallationType
        $productName = [string]$currentVersion.ProductName
    } catch {
        Write-Log "Failed to query Windows edition metadata from the registry: $($_.Exception.Message)" 'WARN'
    }

    try {
        $getWindowsEditionCommand = Get-Command Get-WindowsEdition -ErrorAction SilentlyContinue
        if ($null -ne $getWindowsEditionCommand) {
            $onlineEditionInfo = Get-WindowsEdition -Online -ErrorAction Stop
            if ($null -ne $onlineEditionInfo) {
                $onlineEdition = [string]$onlineEditionInfo.Edition
            }
        }
    } catch {
        Write-Log "Failed to query Get-WindowsEdition -Online: $($_.Exception.Message)" 'INFO'
    }

    $combinedEditionText = (@($onlineEdition, $editionId, $installationType, $productName) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    }) -join ' '

    $isServer = ($combinedEditionText -match '(?i)\bserver\b') -or ([string]$installationType -match '(?i)\bserver\b')
    $isLtsc = ($combinedEditionText -match '(?i)\bltsc\b') -or ([string]$editionId -in @('EnterpriseS', 'EnterpriseSN', 'IoTEnterpriseS', 'IoTEnterpriseSK'))
    $isSupportedConsumerEdition = -not $isServer -and -not $isLtsc

    $script:WindowsEditionContext = [pscustomobject]@{
        EditionId                  = $editionId
        InstallationType           = $installationType
        ProductName                = $productName
        OnlineEdition              = $onlineEdition
        IsServer                   = $isServer
        IsLtsc                     = $isLtsc
        IsSupportedConsumerEdition = $isSupportedConsumerEdition
    }

    return $script:WindowsEditionContext
}

function Get-WindowsBuildContext {
    if ($null -ne $script:WindowsBuildContext) {
        return $script:WindowsBuildContext
    }

    $currentVersionPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $buildNumber = 0
    $ubr = 0
    $displayVersion = ''
    $releaseId = ''
    $productName = ''

    try {
        $currentVersion = Get-ItemProperty -Path $currentVersionPath -ErrorAction Stop
        [void][int]::TryParse([string]$currentVersion.CurrentBuild, [ref]$buildNumber)
        [void][int]::TryParse([string]$currentVersion.UBR, [ref]$ubr)
        $displayVersion = [string]$currentVersion.DisplayVersion
        $releaseId = [string]$currentVersion.ReleaseId
        $productName = [string]$currentVersion.ProductName
    } catch {
        Write-Log "Failed to query Windows build metadata: $($_.Exception.Message)" 'WARN'
    }

    $script:WindowsBuildContext = [pscustomobject]@{
        CurrentBuild   = $buildNumber
        UBR            = $ubr
        DisplayVersion = $displayVersion
        ReleaseId      = $releaseId
        ProductName    = $productName
        IsWindows11    = ($buildNumber -ge 22000)
        IsWindows10    = ($buildNumber -ge 10240 -and $buildNumber -lt 22000)
    }

    return $script:WindowsBuildContext
}

function Test-WindowsBuildInRange {
    param(
        [Nullable[int]]$MinBuild = $null,
        [Nullable[int]]$MaxBuild = $null
    )

    $buildContext = Get-WindowsBuildContext
    $currentBuild = [int]$buildContext.CurrentBuild

    if ($MinBuild -ne $null -and $currentBuild -lt [int]$MinBuild) {
        return $false
    }

    if ($MaxBuild -ne $null -and $currentBuild -gt [int]$MaxBuild) {
        return $false
    }

    return $true
}


function Test-IsHyperVGuest {
    $probeFailures = New-Object 'System.Collections.Generic.List[string]'
    $nonHyperVVirtualizationPattern = '(?i)qemu|kvm|proxmox|virtio|red hat|vmware|virtualbox|xen|parallels'

    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        $computerSystemMarkers = @(
            [string]$cs.Manufacturer,
            [string]$cs.Model
        ) -join ' '

        if ($computerSystemMarkers -match $nonHyperVVirtualizationPattern) {
            return $false
        }

        if ($null -ne $cs -and $cs.Model -eq 'Virtual Machine' -and $cs.Manufacturer -eq 'Microsoft Corporation') {
            return $true
        }
    } catch {
        [void]$probeFailures.Add("Win32_ComputerSystem probe failed: $($_.Exception.Message)")
    }

    try {
        $hardwareMarkers = @()
        $hardwareMarkers += @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
            [string]::Join(' ', @([string]$_.Model, [string]$_.Manufacturer, [string]$_.PNPDeviceID))
        })
        $hardwareMarkers += @(Get-CimInstance Win32_NetworkAdapter -ErrorAction SilentlyContinue | ForEach-Object {
            [string]::Join(' ', @([string]$_.Name, [string]$_.Manufacturer, [string]$_.PNPDeviceID))
        })

        if (([string]::Join(' ', @($hardwareMarkers))).Trim() -match $nonHyperVVirtualizationPattern) {
            return $false
        }
    } catch {
        [void]$probeFailures.Add("Virtual hardware marker probe failed: $($_.Exception.Message)")
    }

    try {
        # Fallback: check for explicit Hyper-V/VMBus devices only.
        $hyperVDevice = Get-CimInstance Win32_PnPEntity -ErrorAction Stop | Where-Object {
            ([string]$_.Name -match '(?i)hyper-v|vmbus')
        } | Select-Object -First 1
        if ($null -ne $hyperVDevice) {
            return $true
        }
    } catch {
        [void]$probeFailures.Add("Win32_PnPEntity Hyper-V device probe failed: $($_.Exception.Message)")
    }

    try {
        # Fallback: check for explicit Hyper-V BIOS/manufacturer markers only.
        $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $biosMarkers = @(
            [string]$bios.Manufacturer,
            [string]$bios.SMBIOSBIOSVersion,
            [string]$bios.SerialNumber,
            [string]$bios.Version
        ) -join ' '
        if ($biosMarkers -match '(?i)hyper-v|microsoft corporation') {
            return $true
        }
    } catch {
        [void]$probeFailures.Add("Win32_BIOS probe failed: $($_.Exception.Message)")
    }

    if ($probeFailures.Count -gt 0) {
        Write-Log ("Hyper-V guest detection completed with probe warnings: {0}" -f ($probeFailures -join ' | ')) 'WARN'
    }

    return $false
}

function Initialize-HyperVDetection {
    $script:IsHyperVGuest = Test-IsHyperVGuest
    if ($script:IsHyperVGuest) {
        Write-Log "Hyper-V guest detected - autologin will be skipped, RDP services preserved" 'WARN'
    }
}
