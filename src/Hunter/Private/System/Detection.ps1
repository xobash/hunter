function Get-WindowsEditionContext {
    if ($null -ne $script:WindowsEditionContext) {
        return $script:WindowsEditionContext
    }

    $currentVersionPath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $editionId = ''
    $installationType = ''
    $productName = ''

    try {
        $currentVersion = Get-ItemProperty -Path $currentVersionPath -ErrorAction Stop
        $editionId = [string]$currentVersion.EditionID
        $installationType = [string]$currentVersion.InstallationType
        $productName = [string]$currentVersion.ProductName
    } catch {
        Write-Log "Failed to query Windows edition metadata from the registry: $($_.Exception.Message)" 'WARN'
    }

    if ([string]::IsNullOrWhiteSpace($productName) -or [string]::IsNullOrWhiteSpace($installationType)) {
        try {
            $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($productName)) {
                $productName = [string]$operatingSystem.Caption
            }
            if ([string]::IsNullOrWhiteSpace($installationType)) {
                $installationType = if ([int]$operatingSystem.ProductType -eq 1) { 'Client' } else { 'Server' }
            }
        } catch {
            Write-Log "Failed to query Windows edition metadata from Win32_OperatingSystem: $($_.Exception.Message)" 'INFO'
        }
    }

    $combinedEditionText = (@($editionId, $installationType, $productName) | Where-Object {
        -not [string]::IsNullOrWhiteSpace([string]$_)
    }) -join ' '

    $isServer = ($combinedEditionText -match '(?i)\bserver\b') -or ([string]$installationType -match '(?i)\bserver\b')
    $isLtsc = ($combinedEditionText -match '(?i)\bltsc\b') -or ([string]$editionId -in @('EnterpriseS', 'EnterpriseSN', 'IoTEnterpriseS', 'IoTEnterpriseSK'))
    $isSupportedConsumerEdition = -not $isServer -and -not $isLtsc

    $script:WindowsEditionContext = [pscustomobject]@{
        EditionId                  = $editionId
        InstallationType           = $installationType
        ProductName                = $productName
        OnlineEdition              = ''
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

function Get-HunterStorageMediaContext {
    if ($null -ne $script:StorageMediaContext) {
        return $script:StorageMediaContext
    }

    $diskSummaries = New-Object 'System.Collections.Generic.List[object]'
    $hasSsd = $false
    $hasHdd = $false
    $probeWarnings = New-Object 'System.Collections.Generic.List[string]'

    $physicalDiskCommand = Get-Command -Name 'Get-PhysicalDisk' -ErrorAction SilentlyContinue
    if ($null -ne $physicalDiskCommand) {
        try {
            foreach ($disk in @(Get-PhysicalDisk -ErrorAction Stop)) {
                if ($null -eq $disk) {
                    continue
                }

                $mediaType = [string]$disk.MediaType
                $friendlyName = [string]$disk.FriendlyName
                if ($mediaType -match '(?i)\bssd\b|solid state|scm') {
                    $hasSsd = $true
                } elseif ($mediaType -match '(?i)\bhdd\b|hard disk') {
                    $hasHdd = $true
                }

                [void]$diskSummaries.Add([pscustomobject]@{
                    Name      = $friendlyName
                    MediaType = $mediaType
                    Source    = 'Get-PhysicalDisk'
                })
            }
        } catch {
            [void]$probeWarnings.Add("Get-PhysicalDisk probe failed: $($_.Exception.Message)")
        }
    }

    if ($diskSummaries.Count -eq 0) {
        try {
            foreach ($disk in @(Get-CimInstance -ClassName Win32_DiskDrive -ErrorAction Stop)) {
                if ($null -eq $disk) {
                    continue
                }

                $combinedText = [string]::Join(' ', @(
                    [string]$disk.Model,
                    [string]$disk.MediaType,
                    [string]$disk.InterfaceType
                ))
                $normalizedText = $combinedText.ToLowerInvariant()

                if ($normalizedText -match 'ssd|solid state|nvme') {
                    $hasSsd = $true
                } elseif ($normalizedText -match 'hdd|hard disk|rotational') {
                    $hasHdd = $true
                }

                [void]$diskSummaries.Add([pscustomobject]@{
                    Name      = [string]$disk.Model
                    MediaType = [string]$disk.MediaType
                    Source    = 'Win32_DiskDrive'
                })
            }
        } catch {
            [void]$probeWarnings.Add("Win32_DiskDrive probe failed: $($_.Exception.Message)")
        }
    }

    $script:StorageMediaContext = [pscustomobject]@{
        HasSolidStateDrives = [bool]$hasSsd
        HasHardDiskDrives   = [bool]$hasHdd
        DiskSummaries       = @($diskSummaries)
        ProbeWarnings       = @($probeWarnings)
    }

    if ($probeWarnings.Count -gt 0) {
        Write-Log ("Storage media detection completed with warnings: {0}" -f ($probeWarnings -join ' | ')) 'WARN'
    }

    return $script:StorageMediaContext
}

function Get-HunterPowerPlatformContext {
    if ($null -ne $script:PowerPlatformContext) {
        return $script:PowerPlatformContext
    }

    $batteryCount = 0
    $pcSystemTypeEx = -1
    $pcSystemType = -1
    $probeWarnings = New-Object 'System.Collections.Generic.List[string]'

    try {
        $batteryCount = @(
            Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop |
                Where-Object { $null -ne $_ }
        ).Count
    } catch {
        [void]$probeWarnings.Add("Win32_Battery probe failed: $($_.Exception.Message)")
    }

    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $computerSystem) {
            if ($null -ne $computerSystem.PSObject.Properties['PCSystemTypeEx']) {
                $pcSystemTypeEx = [int]$computerSystem.PCSystemTypeEx
            }
            if ($null -ne $computerSystem.PSObject.Properties['PCSystemType']) {
                $pcSystemType = [int]$computerSystem.PCSystemType
            }
        }
    } catch {
        [void]$probeWarnings.Add("Win32_ComputerSystem power-platform probe failed: $($_.Exception.Message)")
    }

    $portableSystemTypes = @(2, 8, 9, 10, 14)
    $isPortable = ($batteryCount -gt 0) -or ($pcSystemTypeEx -in $portableSystemTypes) -or ($pcSystemType -in $portableSystemTypes)

    $script:PowerPlatformContext = [pscustomobject]@{
        HasBattery      = ($batteryCount -gt 0)
        BatteryCount    = [int]$batteryCount
        IsPortable      = [bool]$isPortable
        PcSystemType    = [int]$pcSystemType
        PcSystemTypeEx  = [int]$pcSystemTypeEx
        ProbeWarnings   = @($probeWarnings)
    }

    if ($probeWarnings.Count -gt 0) {
        Write-Log ("Power-platform detection completed with warnings: {0}" -f ($probeWarnings -join ' | ')) 'WARN'
    }

    return $script:PowerPlatformContext
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
