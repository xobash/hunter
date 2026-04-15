function Test-ShouldDisableWlanService {
    try {
        $wirelessAdapters = @()

        if ($null -ne (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue)) {
            $wirelessAdapters = @(
                Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
                    Where-Object {
                        $adapterName = [string]$_.Name
                        $adapterDescription = [string]$_.InterfaceDescription
                        $physicalMedium = ''
                        if ($null -ne $_.PSObject.Properties['NdisPhysicalMedium']) {
                            $physicalMedium = [string]$_.NdisPhysicalMedium
                        }

                        $adapterName -match '(?i)wi-?fi|wireless|wlan|802\.11' -or
                        $adapterDescription -match '(?i)wi-?fi|wireless|wlan|802\.11' -or
                        $physicalMedium -match '(?i)wireless|802\.11'
                    }
            )
        }

        if ($wirelessAdapters.Count -eq 0) {
            $wirelessAdapters = @(
                Get-CimInstance -ClassName Win32_NetworkAdapter -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.PhysicalAdapter -and (
                            [string]$_.Name -match '(?i)wi-?fi|wireless|wlan|802\.11' -or
                            [string]$_.NetConnectionID -match '(?i)wi-?fi|wireless|wlan|802\.11' -or
                            [string]$_.AdapterType -match '(?i)wireless|802\.11'
                        )
                    }
            )
        }

        return ($wirelessAdapters.Count -eq 0)
    } catch {
        Write-Log "Unable to determine WLAN AutoConfig policy from adapter inventory: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Get-HunterDetectedGameLibraryPaths {
    $candidateRoots = New-Object 'System.Collections.Generic.List[string]'
    $discoveredPaths = New-Object 'System.Collections.Generic.List[string]'
    $programFilesX86Root = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')

    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        $rootPath = [string]$drive.Root
        if ([string]::IsNullOrWhiteSpace($rootPath)) {
            continue
        }

        $normalizedRoot = $rootPath.TrimEnd('\')
        if (-not $candidateRoots.Contains($normalizedRoot)) {
            [void]$candidateRoots.Add($normalizedRoot)
        }
    }

    foreach ($root in @($candidateRoots.ToArray())) {
        foreach ($relativePath in @(
                'Program Files (x86)\Steam\steamapps\common',
                'Program Files\Steam\steamapps\common',
                'SteamLibrary\steamapps\common',
                'Steam\steamapps\common',
                'XboxGames',
                'Games',
                'Program Files\Epic Games',
                'Epic Games',
                'Program Files\GOG Galaxy\Games',
                'GOG Games',
                'EA Games',
                'Program Files\EA Games',
                'Ubisoft\Ubisoft Game Launcher\games',
                'Program Files\Ubisoft\Ubisoft Game Launcher\games',
                'Program Files\Rockstar Games',
                'Program Files\Riot Games',
                'Riot Games'
            )) {
            $candidatePath = Join-Path $root $relativePath
            if (-not (Test-Path $candidatePath)) {
                continue
            }

            $normalizedCandidatePath = [System.IO.Path]::GetFullPath($candidatePath).TrimEnd('\')
            if (-not $discoveredPaths.Contains($normalizedCandidatePath)) {
                [void]$discoveredPaths.Add($normalizedCandidatePath)
            }
        }
    }

    foreach ($steamRoot in @(
            $(if (-not [string]::IsNullOrWhiteSpace($programFilesX86Root)) { Join-Path $programFilesX86Root 'Steam' }),
            $(if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) { Join-Path $env:ProgramFiles 'Steam' })
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and (Test-Path $_) }) {
        $libraryFile = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
        if (-not (Test-Path $libraryFile)) {
            continue
        }

        foreach ($line in @(Get-Content -Path $libraryFile -ErrorAction SilentlyContinue)) {
            if ([string]$line -match '"path"\s+"([^"]+)"') {
                $steamLibraryRoot = ($matches[1] -replace '\\\\', '\').Trim()
                if ([string]::IsNullOrWhiteSpace($steamLibraryRoot)) {
                    continue
                }

                $steamCommonPath = Join-Path $steamLibraryRoot 'steamapps\common'
                if (-not (Test-Path $steamCommonPath)) {
                    continue
                }

                $normalizedSteamCommonPath = [System.IO.Path]::GetFullPath($steamCommonPath).TrimEnd('\')
                if (-not $discoveredPaths.Contains($normalizedSteamCommonPath)) {
                    [void]$discoveredPaths.Add($normalizedSteamCommonPath)
                }
            }
        }
    }

    return @($discoveredPaths.ToArray() | Sort-Object -Unique)
}

function Invoke-ConfigureDefenderGameFolderExclusions {
    try {
        if ($null -eq (Get-Command Get-MpPreference -ErrorAction SilentlyContinue) -or
            $null -eq (Get-Command Add-MpPreference -ErrorAction SilentlyContinue)) {
            Write-Log 'Skipping Defender game-folder exclusions because Defender preference cmdlets are unavailable.' 'INFO'
            return $true
        }

        $gameLibraryPaths = @(Get-HunterDetectedGameLibraryPaths)
        if ($gameLibraryPaths.Count -eq 0) {
            Write-Log 'No existing game library directories were detected for Defender path exclusions.' 'INFO'
            return $true
        }

        $existingExclusions = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
        try {
            $mpPreference = Get-MpPreference -ErrorAction Stop
            foreach ($existingPath in @($mpPreference.ExclusionPath)) {
                if ([string]::IsNullOrWhiteSpace([string]$existingPath)) {
                    continue
                }

                try {
                    [void]$existingExclusions.Add([System.IO.Path]::GetFullPath([string]$existingPath).TrimEnd('\'))
                } catch {
                    [void]$existingExclusions.Add(([string]$existingPath).TrimEnd('\'))
                }
            }
        } catch {
            Write-Log "Could not read existing Defender exclusions: $($_.Exception.Message)" 'WARN'
        }

        $pathsToAdd = @()
        foreach ($gameLibraryPath in $gameLibraryPaths) {
            if (-not $existingExclusions.Contains($gameLibraryPath)) {
                $pathsToAdd += $gameLibraryPath
            }
        }

        if ($pathsToAdd.Count -eq 0) {
            Write-Log 'Defender path exclusions already cover the detected game library directories.' 'INFO'
            return $true
        }

        Add-MpPreference -ExclusionPath $pathsToAdd -ErrorAction Stop
        Write-Log "Added Defender path exclusions for detected game libraries: $($pathsToAdd -join ', ')" 'INFO'
        return $true
    } catch {
        Write-Log "Failed to configure Defender game-folder exclusions: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-SetDwmFrameInterval {
    try {
        if (-not $script:IsHyperVGuest) {
            Write-Log 'Skipping DWMFRAMEINTERVAL on non-Hyper-V hardware.' 'INFO'
            return (New-TaskSkipResult -Reason 'DWMFRAMEINTERVAL applies only to Hyper-V guests')
        }

        $registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations'
        if (Test-RegistryValue -Path $registryPath -Name 'DWMFRAMEINTERVAL' -ExpectedValue 15) {
            Write-Log 'DWMFRAMEINTERVAL already set to 15. Skipping.' 'INFO'
            return $true
        }

        Set-RegistryValue -Path $registryPath -Name 'DWMFRAMEINTERVAL' -Value 15 -Type DWord
        Write-Log 'DWMFRAMEINTERVAL set to 15.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to set DWMFRAMEINTERVAL: $_" 'ERROR'
        return $false
    }
}


function Invoke-SetServiceProfileManual {
    <#
    .SYNOPSIS
    Sets service startup types according to Hunter's aggressive gaming profile.
    .DESCRIPTION
    Starts from the WinUtil service baseline but intentionally keeps Hunter's
    broader, more aggressive service reductions for gaming-oriented systems.
    #>
    param()

    try {
        Write-Log -Message "Setting Hunter aggressive service profile..." -Level 'INFO'

        $disabledServices = @(
            'AppVClient',
            'AssignedAccessManagerSvc',
            'BTAGService',
            'bthserv',
            'BthAvctpSvc',
            'DiagTrack',
            'DialogBlockingService',
            'DsSvc',                     # Data Sharing Service - inter-app data broker
            'DusmSvc',                   # Diagnostic Usage and Telemetry - usage data collection
            'GamingServices',            # Xbox / Game Pass integration (Xbox already nuked)
            'GamingServicesNet',         # Xbox network component (Xbox already nuked)
            'lfsvc',
            'MapsBroker',
            'midisrv',                   # MIDI Service - no MIDI controllers on gaming rigs
            'NetTcpPortSharing',
            'RemoteAccess',
            'RemoteRegistry',
            'RetailDemo',
            'SgrmBroker',               # System Guard Runtime Monitor - VBS component (HVCI already disabled)
            'shpamsvc',
            'ssh-agent',
            'SysMain',
            'WSearch',
            'TabletInputService',
            'tzautoupdate',
            'UevAgentService',
            'WbioSrvc',                 # Windows Biometric Service - not needed on gaming PCs
            'WerSvc',
            'WpcMonSvc',                # Parental Controls - not needed
            'wisvc',                     # Windows Insider Service - not needed
            'XblAuthManager',
            'xbgm',
            'XblGameSave',
            'XboxGipSvc',
            'XboxNetApiSvc'
        )

        $manualServices = @(
            'ALG',
            'Appinfo',
            'AppMgmt',
            'AppReadiness',
            'autotimesvc',
            'AxInstSV',
            'BDESVC',
            'camsvc',
            'CDPSvc',
            'CertPropSvc',
            'cloudidsvc',
            'COMSysApp',
            'CscService',
            'dcsvc',
            'defragsvc',
            'DeviceAssociationService',
            'DeviceInstall',
            'DevQueryBroker',
            'diagsvc',
            'DisplayEnhancementService',
            'dmwappushservice',
            'dot3svc',
            'EapHost',
            'edgeupdate',
            'edgeupdatem',
            'EFS',
            'fdPHost',
            'FDResPub',
            'fhsvc',
            'FrameServer',
            'FrameServerMonitor',
            'GraphicsPerfSvc',
            'hidserv',
            'HvHost',
            'icssvc',
            'IKEEXT',
            'InstallService',
            'InventorySvc',
            'IpxlatCfgSvc',
            'KtmRm',
            'LicenseManager',
            'lltdsvc',
            'lmhosts',
            'LxpSvc',
            'McpManagementService',
            'MicrosoftEdgeElevationService',
            'MSDTC',
            'MSiSCSI',
            'NaturalAuthentication',
            'NcaSvc',
            'NcbService',
            'NcdAutoSetup',
            'Netman',
            'netprofm',
            'NetSetupSvc',
            'NlaSvc',
            'PcaSvc',
            'PeerDistSvc',
            'perceptionsimulation',
            'PerfHost',
            'PhoneSvc',
            'pla',
            'PlugPlay',
            'PolicyAgent',
            'PrintNotify',
            'PushToInstall',
            'QWAVE',
            'RasAuto',
            'RasMan',
            'RmSvc',
            'RpcLocator',
            'SCardSvr',
            'ScDeviceEnum',
            'SCPolicySvc',
            'SDRSVC',
            'seclogon',
            'SEMgrSvc',
            'SensorDataService',
            'SensorService',
            'SensrSvc',
            'SessionEnv',
            'SharedAccess',
            'smphost',
            'SmsRouter',
            'SSDPSRV',
            'SstpSvc',
            'StiSvc',
            'StorSvc',
            'svsvc',
            'swprv',
            'TapiSrv',
            'TermService',
            'TieringEngineService',
            'TokenBroker',
            'TroubleshootingSvc',
            'TrustedInstaller',
            'UmRdpService',
            'upnphost',
            'UsoSvc',
            'VaultSvc',
            'vds',
            'vmicguestinterface',
            'vmicheartbeat',
            'vmickvpexchange',
            'vmicrdv',
            'vmicshutdown',
            'vmictimesync',
            'vmicvmsession',
            'vmicvss',
            'VSS',
            'W32Time',
            'WalletService',
            'WarpJITSvc',
            'wbengine',
            'wcncsvc',
            'WdiServiceHost',
            'WdiSystemHost',
            'WebClient',
            'webthreatdefsvc',
            'Wecsvc',
            'WEPHOSTSVC',
            'wercplsupport',
            'WFDSConMgrSvc',
            'WiaRpc',
            'WinRM',
            'wlidsvc',
            'wlpasvc',
            'WManSvc',
            'wmiApSrv',
            'WMPNetworkSvc',
            'workfolderssvc',
            'WPDBusEnum',
            'WpnService',
            'WSAIFabricSvc',
            'wuauserv'
        )

        $automaticServices = @(
            'AJRouter',
            'AudioEndpointBuilder',
            'Audiosrv',
            'AudioSrv',
            'CryptSvc',
            'Dhcp',
            'DispBrokerDesktopSvc',
            'DPS',
            'EventLog',
            'EventSystem',
            'Fax',
            'FontCache',
            'iphlpsvc',
            'KeyIso',
            'LanmanServer',
            'LanmanWorkstation',
            'nsi',
            'Power',
            'ProfSvc',
            'SamSs',
            'SENS',
            'ShellHWDetection',
            'SNMPTrap',
            'SNMPTRAP',
            'Themes',
            'TrkWks',
            'UserManager',
            'Wcmsvc',
            'Winmgmt'
        )

        $disablePrintSpooler = Test-ShouldDisablePrintSpooler
        if ($disablePrintSpooler) {
            $disabledServices += 'Spooler'
            Write-Log 'No printers detected; Print Spooler will be disabled.' 'INFO'
        } else {
            $automaticServices += 'Spooler'
            Write-Log 'Printer detected; Print Spooler will remain automatic.' 'INFO'
        }

        $disableWlanService = Test-ShouldDisableWlanService
        if ($disableWlanService) {
            $disabledServices += 'WlanSvc'
            Write-Log 'No wireless adapters detected; WLAN AutoConfig will be disabled.' 'INFO'
        } else {
            $automaticServices += 'WlanSvc'
            Write-Log 'Wireless adapter detected; WLAN AutoConfig will remain automatic.' 'INFO'
        }

        $autoDelayedServices = @('BITS')
        $alreadyConfigured = $true

        foreach ($svc in $disabledServices) {
            if (-not (Test-ServiceStartTypeMatch -Name $svc -ExpectedStartType 'Disabled')) {
                $alreadyConfigured = $false
                break
            }
        }

        if ($alreadyConfigured) {
            foreach ($svc in $manualServices) {
                if (-not (Test-ServiceStartTypeMatch -Name $svc -ExpectedStartType 'Manual')) {
                    $alreadyConfigured = $false
                    break
                }
            }
        }

        if ($alreadyConfigured) {
            foreach ($svc in $automaticServices) {
                if (-not (Test-ServiceStartTypeMatch -Name $svc -ExpectedStartType 'Automatic')) {
                    $alreadyConfigured = $false
                    break
                }
            }
        }

        if ($alreadyConfigured) {
            foreach ($svc in $autoDelayedServices) {
                if (-not (Test-ServiceAutomaticDelayedStart -Name $svc)) {
                    $alreadyConfigured = $false
                    break
                }
            }
        }

        if ($alreadyConfigured) {
            Write-Log -Message "Hunter aggressive service profile already configured. Skipping." -Level 'INFO'
            return $true
        }

        # Fire ALL service startup type changes concurrently via sc.exe
        Write-Log -Message "Firing all service startup type changes in parallel..." -Level 'INFO'
        $scProcs = New-Object 'System.Collections.Generic.List[object]'
        $missingServices = New-Object 'System.Collections.Generic.List[string]'

        foreach ($svc in $disabledServices) {
            if (-not (Test-ServiceExists -Name $svc)) {
                if (-not $missingServices.Contains($svc)) {
                    [void]$missingServices.Add($svc)
                }
                continue
            }
            if (Test-ServiceProtected -Name $svc) {
                Write-Log "Skipped startup-type change for protected service ${svc}." 'INFO'
                continue
            }
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= disabled" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Disable service $svc" })
                }
            } catch { Write-Log "Failed to launch sc.exe for disabled service '$svc': $_" 'WARN' }
        }

        foreach ($svc in $manualServices) {
            if (-not (Test-ServiceExists -Name $svc)) {
                if (-not $missingServices.Contains($svc)) {
                    [void]$missingServices.Add($svc)
                }
                continue
            }
            if (Test-ServiceProtected -Name $svc) {
                Write-Log "Skipped startup-type change for protected service ${svc}." 'INFO'
                continue
            }
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= demand" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Set service $svc to demand start" })
                }
            } catch { Write-Log "Failed to launch sc.exe for manual service '$svc': $_" 'WARN' }
        }

        foreach ($svc in $automaticServices) {
            if (-not (Test-ServiceExists -Name $svc)) {
                if (-not $missingServices.Contains($svc)) {
                    [void]$missingServices.Add($svc)
                }
                continue
            }
            if (Test-ServiceProtected -Name $svc) {
                Write-Log "Skipped startup-type change for protected service ${svc}." 'INFO'
                continue
            }
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= auto" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Set service $svc to automatic start" })
                }
                if (Test-ServiceAutomaticDelayedStart -Name $svc) {
                    $p2 = Start-Process -FilePath 'reg.exe' -ArgumentList "add `"HKLM\SYSTEM\CurrentControlSet\Services\$svc`" /v DelayedAutostart /t REG_DWORD /d 0 /f" -PassThru -WindowStyle Hidden -ErrorAction Stop
                    if ($null -ne $p2) {
                        [void]$scProcs.Add([pscustomobject]@{ Process = $p2; Description = "Clear DelayedAutostart for $svc" })
                    }
                }
            } catch { Write-Log "Failed to launch sc.exe for automatic service '$svc': $_" 'WARN' }
        }

        foreach ($svc in $autoDelayedServices) {
            if (-not (Test-ServiceExists -Name $svc)) {
                if (-not $missingServices.Contains($svc)) {
                    [void]$missingServices.Add($svc)
                }
                continue
            }
            if (Test-ServiceProtected -Name $svc) {
                Write-Log "Skipped startup-type change for protected service ${svc}." 'INFO'
                continue
            }
            try {
                $p = Start-Process -FilePath 'sc.exe' -ArgumentList "config `"$svc`" start= delayed-auto" -PassThru -WindowStyle Hidden -ErrorAction Stop
                if ($null -ne $p) {
                    [void]$scProcs.Add([pscustomobject]@{ Process = $p; Description = "Set service $svc to delayed-auto" })
                }
            } catch { Write-Log "Failed to launch sc.exe for delayed-auto service '$svc': $_" 'WARN' }
        }

        if ($missingServices.Count -gt 0) {
            $sampleSize = [Math]::Min($missingServices.Count, 12)
            $sampleServices = @($missingServices | Select-Object -First $sampleSize)
            $remainingCount = $missingServices.Count - $sampleSize
            $sampleSuffix = if ($remainingCount -gt 0) {
                " +$remainingCount more"
            } else {
                ''
            }
            Write-Log "Skipped startup-type changes for $($missingServices.Count) absent service(s): $($sampleServices -join ', ')$sampleSuffix" 'INFO'
        }

        Wait-ProcessBatchUntilDeadline -ProcessInfos $scProcs -TimeoutSeconds 45 -BatchDescription 'Service startup-type changes'

        foreach ($svc in @($disabledServices | Select-Object -Unique)) {
            Stop-ServiceIfPresent -Name $svc
        }

        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\Shell\' -TaskName 'IndexerAutomaticMaintenance' -DisplayName 'Windows Search index maintenance' | Out-Null

        Write-Log -Message "Hunter aggressive service profile applied ($($scProcs.Count) concurrent operations)." -Level 'INFO'
        return $true
    }
    catch {
        Write-Log -Message "Error in Invoke-SetServiceProfileManual: $_" -Level 'ERROR'
        return $false
    }
}

function Invoke-DisableVirtualizationSecurityOverhead {
    try {
        Write-Log 'Disabling virtualization security overhead and legacy optional features...' 'INFO'

        $deviceGuardPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard'
        $hvciPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity'

        Set-RegistryValue -Path $deviceGuardPath -Name 'EnableVirtualizationBasedSecurity' -Value 0 -Type DWord
        Set-RegistryValue -Path $deviceGuardPath -Name 'RequirePlatformSecurityFeatures' -Value 0 -Type DWord
        Set-RegistryValue -Path $hvciPath -Name 'Enabled' -Value 0 -Type DWord
        Set-RegistryValue -Path $hvciPath -Name 'Locked' -Value 0 -Type DWord
        Set-RegistryValue -Path $hvciPath -Name 'WasEnabledBy' -Value 0 -Type DWord

        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Virtual Machine Platform' -CandidateNames @('VirtualMachinePlatform') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Windows Hypervisor Platform' -CandidateNames @('HypervisorPlatform') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Hyper-V' -CandidateNames @('Microsoft-Hyper-V-All', 'Microsoft-Hyper-V') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Windows Sandbox' -CandidateNames @('Containers-DisposableClientVM') -SkipOnHyperVGuest | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Application Guard' -CandidateNames @('Windows-Defender-ApplicationGuard') | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'Windows Subsystem for Linux' -CandidateNames @('Microsoft-Windows-Subsystem-Linux') | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'SMB 1.0/CIFS File Sharing Support' -CandidateNames @('SMB1Protocol') | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'SMB 1.0/CIFS Client' -CandidateNames @('SMB1Protocol-Client') | Out-Null
        Disable-WindowsOptionalFeatureIfPresent -DisplayName 'SMB 1.0/CIFS Server' -CandidateNames @('SMB1Protocol-Server') | Out-Null

        Write-Log 'Virtualization security overhead and legacy optional features disabled.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error disabling virtualization security overhead: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyGraphicsSchedulingTweaks {
    try {
        Write-Log 'Applying graphics scheduling, MPO, and frame pacing tweaks...' 'INFO'

        $graphicsDriversPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
        $dwmPath = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
        $gpuContexts = @(Get-GpuPciDeviceContexts)
        $gpuDetectionIsReliable = ($gpuContexts.Count -gt 0)

        if (Resolve-DisableHagsPreference) {
            Set-RegistryValue -Path $graphicsDriversPath -Name 'HwSchMode' -Value 1 -Type DWord | Out-Null
            Write-Log 'HAGS override applied: HwSchMode=1 (disabled).' 'INFO'
        } elseif ($gpuDetectionIsReliable) {
            Set-RegistryValue -Path $graphicsDriversPath -Name 'HwSchMode' -Value 2 -Type DWord | Out-Null
            Write-Log 'HAGS enabled by default: HwSchMode=2.' 'INFO'
        } else {
            Write-Log 'Skipping HAGS enable because no PCI display devices were confidently detected.' 'INFO'
        }

        if ($gpuDetectionIsReliable) {
            Set-RegistryValue -Path $graphicsDriversPath -Name 'TdrLevel' -Value 0 -Type DWord
            Set-RegistryValue -Path $graphicsDriversPath -Name 'TdrDelay' -Value 10 -Type DWord
            Set-RegistryValue -Path $graphicsDriversPath -Name 'TdrDdiDelay' -Value 10 -Type DWord
            Set-RegistryValue -Path $dwmPath -Name 'OverlayTestMode' -Value 5 -Type DWord
            Invoke-EnableGpuMsiMode | Out-Null
        } else {
            Write-Log 'Skipping TDR, MPO, and GPU MSI-mode mutations because GPU detection was inconclusive.' 'INFO'
        }

        Set-DirectXGlobalPreferenceValue -Key 'VRROptimizeEnable' -Value '1'
        Set-DirectXGlobalPreferenceValue -Key 'SwapEffectUpgradeEnable' -Value '1'
        Set-DirectXGlobalPreferenceValue -Key 'AutoHDREnable' -Value '0'

        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -Type DWord
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'AppCaptureEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\GameDVR'; Name = 'HistoricalCaptureEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'AutoGameModeEnabled'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'ShowStartupPanel'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\GameBar'; Name = 'UseNexusForGameBarEnabled'; Value = 0 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_Enabled'; Value = 0 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_DXGIHonorFSEWindowsCompatible'; Value = 1 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_FSEBehaviorMode'; Value = 2 },
            @{ SubPath = 'System\GameConfigStore'; Name = 'GameDVR_HonorUserFSEBehaviorMode'; Value = 1 }
        )

        if ($gpuDetectionIsReliable) {
            Write-Log 'MPO was disabled via OverlayTestMode=5 and windowed-game swap-effect upgrade was enabled.' 'INFO'
        } else {
            Write-Log 'Windowed-game swap-effect upgrade was enabled, but MPO/TDR/HAGS changes were limited because GPU detection was inconclusive.' 'INFO'
        }
        Write-Log 'Resizable BAR auditing is handled separately because BAR sizing is negotiated by firmware and display drivers on supported hardware.' 'INFO'
        Write-Log 'Graphics scheduling and frame pacing tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying graphics scheduling tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyMemoryDiskBehaviorTweaks {
    try {
        Write-Log 'Applying memory and disk behavior tweaks...' 'INFO'
        $currentMemoryDiskStep = 'updating memory and Storage Sense registry values'
        $mmAgentState = $null
        $fsutilPath = Get-NativeSystemExecutablePath -FileName 'fsutil.exe'
        $systemVolume = $env:SystemDrive.TrimEnd('\')
        try {
            $mmAgentState = Get-MMAgent -ErrorAction Stop
        } catch {
            $mmAgentState = $null
        }

        $prefetchPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management\PrefetchParameters'
        $memoryManagementPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'

        Set-RegistryValue -Path $prefetchPath -Name 'EnablePrefetcher' -Value 0 -Type DWord
        Set-RegistryValue -Path $prefetchPath -Name 'EnableSuperfetch' -Value 0 -Type DWord
        Set-LargeSystemCacheByRamPolicy -Path $memoryManagementPath | Out-Null
        Set-RegistryValue -Path $memoryManagementPath -Name 'DisablePagingExecutive' -Value 1 -Type DWord
        Set-FixedPageFileByRamPolicy | Out-Null
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense' -Name 'AllowStorageSenseGlobal' -Value 0 -Type DWord
        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'; Name = '01'; Value = 0 }
        )

        $currentMemoryDiskStep = 'disabling 8.3 short-name creation'
        try {
            Invoke-NativeCommandChecked -FilePath $fsutilPath -ArgumentList @('behavior', 'set', 'disable8dot3', '1') | Out-Null
            Write-Log '8.3 filename creation disabled.' 'INFO'
        } catch {
            Write-Log "Failed to disable 8.3 filename creation: $($_.Exception.Message)" 'WARN'
        }

        $currentMemoryDiskStep = 'disabling memory compression'
        if ($null -ne $mmAgentState -and $null -ne $mmAgentState.PSObject.Properties['MemoryCompression'] -and -not [bool]$mmAgentState.MemoryCompression) {
            Write-Log 'Memory compression already disabled.' 'INFO'
        } else {
            try {
                Disable-MMAgent -MemoryCompression -ErrorAction Stop
                Write-Log 'Memory compression disabled.' 'INFO'
            } catch {
                $errorMessage = $_.Exception.Message
                if ($errorMessage -match 'service cannot be started|no enabled devices associated with it|not supported') {
                    Write-Log "Skipping memory compression disable: $errorMessage" 'INFO'
                } else {
                    Write-Log "Failed to disable memory compression: $errorMessage" 'WARN'
                }
            }
        }

        $currentMemoryDiskStep = 'disabling page combining'
        if ($null -ne $mmAgentState -and $null -ne $mmAgentState.PSObject.Properties['PageCombining'] -and -not [bool]$mmAgentState.PageCombining) {
            Write-Log 'Page combining already disabled.' 'INFO'
        } else {
            try {
                Disable-MMAgent -PageCombining -ErrorAction Stop
                Write-Log 'Page combining disabled.' 'INFO'
            } catch {
                $errorMessage = $_.Exception.Message
                if ($errorMessage -match 'service cannot be started|no enabled devices associated with it|not supported') {
                    Write-Log "Skipping page combining disable: $errorMessage" 'INFO'
                } else {
                    Write-Log "Failed to disable page combining: $errorMessage" 'WARN'
                }
            }
        }

        $currentMemoryDiskStep = 'disabling NTFS last access updates'
        try {
            Invoke-NativeCommandChecked -FilePath $fsutilPath -ArgumentList @('behavior', 'set', 'disablelastaccess', '1') | Out-Null
            Write-Log 'NTFS last access updates disabled.' 'INFO'
        } catch {
            Write-Log "Failed to disable NTFS last access updates: $($_.Exception.Message)" 'WARN'
        }

        $currentMemoryDiskStep = 'deleting the NTFS USN journal'
        try {
            & $fsutilPath usn queryjournal $systemVolume *> $null
            if ($LASTEXITCODE -eq 0) {
                Invoke-NativeCommandChecked -FilePath $fsutilPath -ArgumentList @('usn', 'deletejournal', '/d', $systemVolume) | Out-Null
                Write-Log "NTFS USN journal deleted on ${systemVolume}." 'INFO'
            } else {
                Write-Log "NTFS USN journal is not active on ${systemVolume}. Skipping delete." 'INFO'
            }
        } catch {
            Write-Log "Failed to delete the NTFS USN journal on ${systemVolume}: $($_.Exception.Message)" 'WARN'
        }

        $currentMemoryDiskStep = 'disabling disk write-cache buffer flushing'
        Invoke-DisableDiskWriteCacheBufferFlushing | Out-Null

        Write-Log 'Memory and disk behavior tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        $message = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = [string]$_
        }

        if ($message -match '(?i)access is denied') {
            Write-Log ("Memory and disk behavior tweaks completed with warnings during {0}: {1}" -f $currentMemoryDiskStep, $message) 'WARN'
            return $true
        }

        Write-Log "Error applying memory and disk behavior tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyUiDesktopPerformanceTweaks {
    try {
        Write-Log 'Applying desktop compositor and UI performance tweaks...' 'INFO'

        Set-DwordBatchForAllUsers -Settings @(
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'; Name = 'EnableTransparency'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'TaskbarAnimations'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'DisablePreviewDesktop'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'DisallowShaking'; Value = 1 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'EnableSnapAssistFlyout'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'SnapAssist'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewAlphaSelect'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'; Name = 'ListviewShadow'; Value = 0 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects'; Name = 'VisualFXSetting'; Value = 2 },
            @{ SubPath = 'Software\Microsoft\Windows\CurrentVersion\Explorer\Wallpapers'; Name = 'BackgroundType'; Value = 0 }
        )

        Set-StringForAllUsers -SubPath 'Control Panel\Desktop\WindowMetrics' -Name 'MinAnimate' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'WindowArrangementActive' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'MenuShowDelay' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'SmoothScroll' -Value '0'
        Invoke-DisableAudioEnhancements | Out-Null
        Set-NoSoundsSchemeForAllUsers | Out-Null

        Request-ExplorerRestart
        Write-Log 'Desktop compositor and UI performance tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying desktop compositor and UI tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ApplyInputAndMaintenanceTweaks {
    try {
        Write-Log 'Applying input latency and maintenance tweaks...' 'INFO'
        $maintenancePath = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Schedule\Maintenance'

        Set-StringForAllUsers -SubPath 'Control Panel\Mouse' -Name 'MouseSpeed' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0'
        Set-StringForAllUsers -SubPath 'Control Panel\Accessibility\Keyboard Response' -Name 'Flags' -Value '0'

        Set-RegistryValue -Path $maintenancePath -Name 'MaintenanceDisabled' -Value 1 -Type DWord
        Set-RegistryValue -Path $maintenancePath -Name 'MaintenanceStartTime' -Value 10800 -Type DWord
        Set-RegistryValue -Path $maintenancePath -Name 'MaintenanceMaxCpuPercent' -Value 10 -Type DWord

        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\TaskScheduler\' -TaskName 'Regular Maintenance' -DisplayName 'Regular Maintenance' | Out-Null
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\TaskScheduler\' -TaskName 'Idle Maintenance' -DisplayName 'Idle Maintenance' | Out-Null
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\TaskScheduler\' -TaskName 'Maintenance Configurator' -DisplayName 'Maintenance Configurator' | Out-Null
        Disable-ScheduledTaskIfPresent -TaskPath '\Microsoft\Windows\Defrag\' -TaskName 'ScheduledDefrag' -DisplayName 'Scheduled Defrag' | Out-Null

        Invoke-BCDEditBestEffort -ArgumentList @('/timeout', '0') -Description 'Boot manager timeout set to 0 seconds.' | Out-Null
        Invoke-BCDEditBestEffort -ArgumentList @('/deletevalue', 'useplatformclock') -Description 'HPET platform clock override removed.' | Out-Null
        Invoke-BCDEditBestEffort -ArgumentList @('/deletevalue', 'tscsyncpolicy') -Description 'TSC sync policy override removed.' | Out-Null

        if ($script:IsHyperVGuest) {
            Write-Log 'Skipping useplatformtick/disabledynamictick on a Hyper-V guest.' 'INFO'
        } else {
            Invoke-BCDEditBestEffort -ArgumentList @('/set', 'useplatformtick', 'yes') -Description 'Platform tick forced to hardware timer resolution.' | Out-Null
            Invoke-BCDEditBestEffort -ArgumentList @('/set', 'disabledynamictick', 'yes') -Description 'Dynamic ticks disabled.' | Out-Null
        }

        Write-Log 'Input latency and maintenance tweaks applied.' 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error applying input and maintenance tweaks: $_" 'ERROR'
        return $false
    }
}

function Invoke-ExhaustivePowerTuning {
    <#
    .SYNOPSIS
    Applies the full WinSux exhaustive power-tuning profile.
    .DESCRIPTION
    Creates and activates the dedicated WinSux Ultimate Performance plan GUID, preserves the
    existing plans, applies the full powercfg AC/DC setting matrix from WinSux, and then
    layers on Hunter's additional per-device power-management disables for NIC/USB/HID/PCI.
    #>
    param()

    try {
        Write-Log 'Starting exhaustive power tuning...' 'INFO'
        Register-HunterActivePowerSchemeRollback

        $ultimatePerformanceGuid = 'e9a42b02-d5df-448d-aa00-03f14749eb61'
        $winsuxPowerSchemeGuid = '99999999-9999-9999-9999-999999999999'

        $getPowerSchemeGuids = {
            $guidPattern = [regex]'(?i)[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}'
            $schemeGuids = New-Object 'System.Collections.Generic.List[string]'
            foreach ($line in @(& powercfg /L 2>$null)) {
                $match = $guidPattern.Match([string]$line)
                if (-not $match.Success) {
                    continue
                }

                $schemeGuid = $match.Value.ToLowerInvariant()
                if (-not $schemeGuids.Contains($schemeGuid)) {
                    [void]$schemeGuids.Add($schemeGuid)
                }
            }

            return @($schemeGuids.ToArray())
        }

        $existingSchemes = @(& $getPowerSchemeGuids)
        if ($existingSchemes -notcontains $winsuxPowerSchemeGuid.ToLowerInvariant()) {
            Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/duplicatescheme', $ultimatePerformanceGuid, $winsuxPowerSchemeGuid) | Out-Null
        }

        $existingSchemes = @(& $getPowerSchemeGuids)
        $activeSchemeGuid = if ($existingSchemes -contains $winsuxPowerSchemeGuid.ToLowerInvariant()) {
            $winsuxPowerSchemeGuid
        } elseif ($existingSchemes -contains $ultimatePerformanceGuid.ToLowerInvariant()) {
            Write-Log 'WinSux power scheme GUID could not be created; falling back to native Ultimate Performance.' 'WARN'
            $ultimatePerformanceGuid
        } else {
            Write-Log 'Ultimate Performance power scheme is unavailable; exhaustive power tuning cannot continue.' 'ERROR'
            return $false
        }

        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $activeSchemeGuid) | Out-Null
        Write-Log 'Preserving pre-existing power schemes; Hunter will no longer delete alternate plans during exhaustive tuning.' 'INFO'

        # ---- System-wide power registry settings ----

        # Disable hibernate and related shell power entries
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/hibernate', 'off') | Out-Null

        $powerPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
        if (-not (Test-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -ExpectedValue 0)) {
            Set-RegistryValue -Path $powerPath -Name 'HibernateEnabled' -Value 0 -Type DWord
        }
        if (-not (Test-RegistryValue -Path $powerPath -Name 'HibernateEnabledDefault' -ExpectedValue 0)) {
            Set-RegistryValue -Path $powerPath -Name 'HibernateEnabledDefault' -Value 0 -Type DWord
        }

        $flyoutMenuSettingsPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\FlyoutMenuSettings'
        if (-not (Test-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowLockOption' -ExpectedValue 0)) {
            Set-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowLockOption' -Value 0 -Type DWord
        }
        if (-not (Test-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowSleepOption' -ExpectedValue 0)) {
            Set-RegistryValue -Path $flyoutMenuSettingsPath -Name 'ShowSleepOption' -Value 0 -Type DWord
        }

        # Disable power throttling
        $ptPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling'
        if (-not (Test-RegistryValue -Path $ptPath -Name 'PowerThrottlingOff' -ExpectedValue 1)) {
            Set-RegistryValue -Path $ptPath -Name 'PowerThrottlingOff' -Value 1 -Type DWord
        } else {
            Write-Log 'Power throttling already disabled.' 'INFO'
        }

        # Disable fast boot (Hiberboot)
        $hbPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power'
        if (-not (Test-RegistryValue -Path $hbPath -Name 'HiberbootEnabled' -ExpectedValue 0)) {
            Set-RegistryValue -Path $hbPath -Name 'HiberbootEnabled' -Value 0 -Type DWord
        } else {
            Write-Log 'Fast boot already disabled.' 'INFO'
        }

        $powercfgPath = Get-NativeSystemExecutablePath -FileName 'powercfg.exe'
        $invokePowerSettingBestEffort = {
            param(
                [string]$SubGroup,
                [string]$Setting,
                [string]$Value,
                [ValidateSet('AC', 'DC')][string]$Mode,
                [string]$Description
            )

            try {
                return (Invoke-PowerCfgValueBestEffort `
                    -PowerCfgPath $powercfgPath `
                    -Scheme $activeSchemeGuid `
                    -SubGroup $SubGroup `
                    -Setting $Setting `
                    -Value $Value `
                    -Mode $Mode `
                    -Description $Description)
            } catch {
                Write-Log "Skipped power setting ${Description} ($Mode): $($_.Exception.Message)" 'INFO'
                return $false
            }
        }

        # Unpark CPU cores - set max parking percentage to 100 (= never park)
        $coreUnparkPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\54533251-82be-4824-96c1-47b60b740d00\0cc5b647-c1df-4637-891a-dec35c318583'
        if (-not (Test-RegistryValue -Path $coreUnparkPath -Name 'Attributes' -ExpectedValue 0)) {
            Set-RegistryValue -Path $coreUnparkPath -Name 'Attributes' -Value 0 -Type DWord | Out-Null
            Write-Log 'Exposed the processor core parking minimum cores setting in Power Options (Attributes=0).' 'INFO'
        }
        if (-not (Test-RegistryValue -Path $coreUnparkPath -Name 'ValueMin' -ExpectedValue 100)) {
            Set-RegistryValue -Path $coreUnparkPath -Name 'ValueMin' -Value 100 -Type DWord
        }
        if (-not (Test-RegistryValue -Path $coreUnparkPath -Name 'ValueMax' -ExpectedValue 100)) {
            Set-RegistryValue -Path $coreUnparkPath -Name 'ValueMax' -Value 100 -Type DWord
        } else {
            Write-Log 'CPU cores already unparked.' 'INFO'
        }
        foreach ($processorPowerSetting in @(
            @{ Mode = 'AC'; Setting = 'CPMINCORES'; Value = '100'; Description = 'processor core parking minimum cores' },
            @{ Mode = 'DC'; Setting = 'CPMINCORES'; Value = '100'; Description = 'processor core parking minimum cores' },
            @{ Mode = 'AC'; Setting = 'PROCTHROTTLEMIN'; Value = '100'; Description = 'processor minimum performance state' },
            @{ Mode = 'DC'; Setting = 'PROCTHROTTLEMIN'; Value = '100'; Description = 'processor minimum performance state' },
            @{ Mode = 'AC'; Setting = 'PROCTHROTTLEMAX'; Value = '100'; Description = 'processor maximum performance state' },
            @{ Mode = 'DC'; Setting = 'PROCTHROTTLEMAX'; Value = '100'; Description = 'processor maximum performance state' }
        )) {
            & $invokePowerSettingBestEffort `
                -SubGroup 'SUB_PROCESSOR' `
                -Setting $processorPowerSetting.Setting `
                -Value $processorPowerSetting.Value `
                -Mode $processorPowerSetting.Mode `
                -Description $processorPowerSetting.Description | Out-Null
        }

        foreach ($energyPreferenceSetting in @(
                @{ Mode = 'AC'; Setting = 'PERFEPP'; Value = '0'; Description = 'processor energy performance preference policy' },
                @{ Mode = 'DC'; Setting = 'PERFEPP'; Value = '0'; Description = 'processor energy performance preference policy' },
                @{ Mode = 'AC'; Setting = 'PERFEPP1'; Value = '0'; Description = 'heterogeneous processor energy performance preference policy' },
                @{ Mode = 'DC'; Setting = 'PERFEPP1'; Value = '0'; Description = 'heterogeneous processor energy performance preference policy' }
            )) {
            & $invokePowerSettingBestEffort `
                -SubGroup 'SUB_PROCESSOR' `
                -Setting $energyPreferenceSetting.Setting `
                -Value $energyPreferenceSetting.Value `
                -Mode $energyPreferenceSetting.Mode `
                -Description $energyPreferenceSetting.Description | Out-Null
        }

        $buildContext = Get-WindowsBuildContext
        if ($buildContext.IsWindows11) {
            foreach ($smtPowerMode in @('AC', 'DC')) {
                & $invokePowerSettingBestEffort `
                    -SubGroup 'SUB_PROCESSOR' `
                    -Setting 'SmtUnparkPolicy' `
                    -Value '1' `
                    -Mode $smtPowerMode `
                    -Description 'SMT thread unpark policy (core-per-thread)' | Out-Null
            }
        } else {
            Write-Log "Skipping SMT unpark policy because build $($buildContext.CurrentBuild) does not expose the Windows 11 SmtUnparkPolicy setting." 'INFO'
        }

        # Enable global timer resolution requests
        Enable-GlobalTimerResolutionRequests -LogIfAlreadyEnabled | Out-Null

        $hubSelectiveSuspendTimeoutPath = 'HKLM:\SYSTEM\ControlSet001\Control\Power\PowerSettings\2a737441-1930-4402-8d77-b2bebba308a3\0853a681-27c8-4100-a2fd-82013e970683'
        if (-not (Test-RegistryValue -Path $hubSelectiveSuspendTimeoutPath -Name 'Attributes' -ExpectedValue 2)) {
            Set-RegistryValue -Path $hubSelectiveSuspendTimeoutPath -Name 'Attributes' -Value 2 -Type DWord
        }

        $usb3LinkPowerMgmtPath = 'HKLM:\SYSTEM\ControlSet001\Control\Power\PowerSettings\2a737441-1930-4402-8d77-b2bebba308a3\d4e98f31-5ffe-4ce1-be31-1b38b384c009'
        if (-not (Test-RegistryValue -Path $usb3LinkPowerMgmtPath -Name 'Attributes' -ExpectedValue 2)) {
            Set-RegistryValue -Path $usb3LinkPowerMgmtPath -Name 'Attributes' -Value 2 -Type DWord
        }

        # Disable console lock timeout (AC and DC)
        $consoleLockAcUpdated = & $invokePowerSettingBestEffort `
            -SubGroup 'SUB_NONE' `
            -Setting 'CONSOLELOCK' `
            -Value '0' `
            -Mode 'AC' `
            -Description 'console lock timeout'
        $consoleLockDcUpdated = & $invokePowerSettingBestEffort `
            -SubGroup 'SUB_NONE' `
            -Setting 'CONSOLELOCK' `
            -Value '0' `
            -Mode 'DC' `
            -Description 'console lock timeout'
        if ($consoleLockAcUpdated -or $consoleLockDcUpdated) {
            Write-Log 'Console lock timeout disabled where supported.' 'INFO'
        } else {
            Write-Log 'Console lock timeout setting is unavailable on this system. Skipping.' 'INFO'
        }

        $powerValueMatrix = @(
            @{ SubGroup = '0012ee47-9041-4b5d-9b77-535fba8b1442'; Setting = '6738e2c4-e8a5-4a42-b16a-e040e769756e'; Value = '0x00000000' },
            @{ SubGroup = '0d7dbae2-4294-402a-ba8e-26777e8488cd'; Setting = '309dce9b-bef4-4119-9921-a851fb12f0f4'; Value = '001' },
            @{ SubGroup = '19cbb8fa-5279-450e-9fac-8a3d5fedd0c1'; Setting = '12bbebe6-58d6-4636-95bb-3217ef867c1a'; Value = '000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '29f6c1db-86da-48c5-9fdb-f2b67b1f44da'; Value = '0x00000000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '94ac6d29-73ce-41a6-809f-6363ba21b47e'; Value = '000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = '9d7815a6-7ee4-497e-8888-515a05f02364'; Value = '0x00000000' },
            @{ SubGroup = '238c9fa8-0aad-41ed-83f4-97be242c8f20'; Setting = 'bd3b718a-0680-4d9d-8ab2-e1d2b4ac806d'; Value = '000' },
            @{ SubGroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '0853a681-27c8-4100-a2fd-82013e970683'; Value = '0x00000000' },
            @{ SubGroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = '48e6b7a6-50f5-4782-a5d4-53bb8f07e226'; Value = '000' },
            @{ SubGroup = '2a737441-1930-4402-8d77-b2bebba308a3'; Setting = 'd4e98f31-5ffe-4ce1-be31-1b38b384c009'; Value = '000' },
            @{ SubGroup = '4f971e89-eebd-4455-a8de-9e59040e7347'; Setting = 'a7066653-8d6c-40a8-910e-a1f54b84c7e5'; Value = '002' },
            @{ SubGroup = '501a4d13-42af-4429-9fd1-a8218c268e20'; Setting = 'ee12f906-d277-404b-b6da-e5fa1a576df5'; Value = '000' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '36687f9e-e3a5-4dbf-b1dc-15eb381c6863'; Value = '000' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '893dee8e-2bef-41e0-89c6-b55d0929964c'; Value = '0x00000064' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = '94d3a615-a899-4ac5-ae2b-e4d8f634367f'; Value = '001' },
            @{ SubGroup = '54533251-82be-4824-96c1-47b60b740d00'; Setting = 'bc5038f7-23e0-4960-96da-33abaf5935ec'; Value = '0x00000064' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = '3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e'; Value = '600' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = 'aded5e82-b909-4619-9949-f5d71dac0bcb'; Value = '0x00000064' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = 'f1fbfde2-a960-4165-9f88-50667911ce96'; Value = '0x00000064' },
            @{ SubGroup = '7516b95f-f776-4464-8c53-06167f40cc99'; Setting = 'fbd9aa66-9553-4097-ba44-ed6e9d65eab8'; Value = '000' },
            @{ SubGroup = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; Setting = '10778347-1370-4ee0-8bbd-33bdacaade49'; Value = '001' },
            @{ SubGroup = '9596fb26-9850-41fd-ac3e-f7c3c00afd4b'; Setting = '34c7b99f-9a6d-4b3c-8dc7-b6693b78cef4'; Value = '000' },
            @{ SubGroup = '44f3beca-a7c0-460e-9df2-bb8b99e0cba6'; Setting = '3619c3f2-afb2-4afc-b0e9-e7fef372de36'; Value = '002' },
            @{ SubGroup = 'c763b4ec-0e50-4b6b-9bed-2b92a6ee884e'; Setting = '7ec1751b-60ed-4588-afb5-9819d3d77d90'; Value = '003' },
            @{ SubGroup = 'f693fb01-e858-4f00-b20f-f30e12ac06d6'; Setting = '191f65b5-d45c-4a4f-8aae-1ab8bfd980e6'; Value = '001' },
            @{ SubGroup = 'e276e160-7cb0-43c6-b20b-73f5dce39954'; Setting = 'a1662ab2-9d34-4e53-ba8b-2639b9e20857'; Value = '003' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '5dbb7c9f-38e9-40d2-9749-4f8a0e9f640f'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '637ea02f-bbcb-4015-8e2c-a1c7b9c0b546'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '8183ba9a-e910-48da-8769-14ae6dc1170a'; Value = '0x00000000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = '9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469'; Value = '0x00000000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = 'bcded951-187b-4d05-bccc-f7e51960c258'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = 'd8742dcb-3e6a-4b3c-b3fe-374623cdcf06'; Value = '000' },
            @{ SubGroup = 'e73a048d-bf27-4f12-9731-8b2076e8891f'; Setting = 'f3c5027d-cd16-4930-aa6b-90db844a8f00'; Value = '0x00000000' },
            @{ SubGroup = 'de830923-a562-41af-a086-e3a2c6bad2da'; Setting = '13d09884-f74e-474a-a852-b6bde8ad03a8'; Value = '0x00000064' },
            @{ SubGroup = 'de830923-a562-41af-a086-e3a2c6bad2da'; Setting = 'e69653ca-cf7f-4f05-aa73-cb833fa90ad4'; Value = '0x00000000' }
        )

        # ---- Apply the powercfg matrix best-effort ----
        $appliedPowerSettings = 0
        $skippedPowerSettings = 0
        foreach ($pv in $powerValueMatrix) {
            foreach ($powerMode in @('AC', 'DC')) {
                $wasApplied = & $invokePowerSettingBestEffort `
                    -SubGroup $pv.SubGroup `
                    -Setting $pv.Setting `
                    -Value $pv.Value `
                    -Mode $powerMode `
                    -Description "power setting $($pv.SubGroup)/$($pv.Setting)"
                if ($wasApplied) {
                    $appliedPowerSettings++
                } else {
                    $skippedPowerSettings++
                }
            }
        }
        Write-Log "Applied $appliedPowerSettings power scheme value update(s); skipped $skippedPowerSettings unsupported or unavailable update(s)." 'INFO'

        # ---- Fire device bus enumerations concurrently (USB/HID/PCI) ----
        $busEnumJobs = @()
        foreach ($bus in @('USB', 'HID', 'PCI')) {
            $busEnumJobs += Start-Job -ScriptBlock {
                param($busName)
                $busRoot = "HKLM:\SYSTEM\ControlSet001\Enum\$busName"
                $result = @{ Bus = $busName; DeviceParams = @(); WdfKeys = @() }
                if (-not (Test-Path $busRoot)) { return $result }
                $allKeys = @(Get-ChildItem -Path $busRoot -Recurse -ErrorAction SilentlyContinue)
                $result.DeviceParams = @($allKeys | Where-Object { $_.PSChildName -eq 'Device Parameters' } | ForEach-Object { $_.Name })
                $result.WdfKeys = @($allKeys | Where-Object { $_.PSChildName -eq 'WDF' } | ForEach-Object { $_.Name })
                return $result
            } -ArgumentList $bus
        }

        # ---- Enumerate NIC keys inline (fast, non-recursive) while jobs run ----
        $nicRegLines = [System.Collections.Generic.List[string]]::new()
        $nicBasePath = 'HKLM:\SYSTEM\ControlSet001\Control\Class\{4d36e972-e325-11ce-bfc1-08002be10318}'
        $nicCount = 0
        if (Test-Path $nicBasePath) {
            $nicKeys = Get-ChildItem -Path $nicBasePath -ErrorAction SilentlyContinue
            foreach ($key in $nicKeys) {
                if ($key.PSChildName -notmatch '^\d{4}$') { continue }
                $regPath = $key.Name
                [void]$nicRegLines.Add("[$regPath]")
                [void]$nicRegLines.Add('"PnPCapabilities"=dword:00000018')
                [void]$nicRegLines.Add('"AdvancedEEE"="0"')
                [void]$nicRegLines.Add('"*EEE"="0"')
                [void]$nicRegLines.Add('"EEELinkAdvertisement"="0"')
                [void]$nicRegLines.Add('"SipsEnabled"="0"')
                [void]$nicRegLines.Add('"ULPMode"="0"')
                [void]$nicRegLines.Add('"GigaLite"="0"')
                [void]$nicRegLines.Add('"EnableGreenEthernet"="0"')
                [void]$nicRegLines.Add('"PowerSavingMode"="0"')
                [void]$nicRegLines.Add('"S5WakeOnLan"="0"')
                [void]$nicRegLines.Add('"*WakeOnMagicPacket"="0"')
                [void]$nicRegLines.Add('"*ModernStandbyWoLMagicPacket"="0"')
                [void]$nicRegLines.Add('"*WakeOnPattern"="0"')
                [void]$nicRegLines.Add('"WakeOnLink"="0"')
                [void]$nicRegLines.Add('')
                $nicCount++
            }
        }
        Write-Log "Prepared NIC power settings for $nicCount adapter(s)." 'INFO'

        # ---- Reactivate the tuned scheme after applying value updates ----
        Invoke-NativeCommandChecked -FilePath 'powercfg.exe' -ArgumentList @('/setactive', $activeSchemeGuid) | Out-Null
        Write-Log 'Power value matrix applied and scheme reactivated.' 'INFO'

        # ---- Wait for device bus enumerations to complete ----
        $busEnumJobs | Wait-Job -Timeout 120 | Out-Null
        $busResults = @()
        foreach ($busJob in @($busEnumJobs)) {
            if ($busJob.State -ne 'Completed') {
                Write-Log "Device bus enumeration job '$($busJob.Name)' finished in state $($busJob.State)." 'WARN'
            }

            try {
                $receivedResult = Receive-Job -Job $busJob -ErrorAction Stop
                if ($null -ne $receivedResult) {
                    $busResults += @($receivedResult)
                }
            } catch {
                Write-Log "Failed to collect device bus enumeration job '$($busJob.Name)': $($_.Exception.Message)" 'WARN'
            }

            try {
                Remove-Job -Job $busJob -Force -ErrorAction Stop
            } catch {
                Write-Log "Failed to remove device bus enumeration job '$($busJob.Name)': $($_.Exception.Message)" 'WARN'
            }
        }

        # ---- Build combined .reg file (NIC + device buses) and import once ----
        $regContent = [System.Text.StringBuilder]::new()
        [void]$regContent.AppendLine('Windows Registry Editor Version 5.00')
        [void]$regContent.AppendLine()

        foreach ($line in $nicRegLines) {
            [void]$regContent.AppendLine($line)
        }

        $deviceEntryCount = 0
        foreach ($result in $busResults) {
            if ($null -eq $result -or $null -eq $result.DeviceParams) { continue }
            foreach ($regPath in $result.DeviceParams) {
                [void]$regContent.AppendLine("[$regPath]")
                [void]$regContent.AppendLine('"EnhancedPowerManagementEnabled"=dword:00000000')
                [void]$regContent.AppendLine('"SelectiveSuspendEnabled"=hex:00')
                [void]$regContent.AppendLine('"SelectiveSuspendOn"=dword:00000000')
                [void]$regContent.AppendLine('"WaitWakeEnabled"=dword:00000000')
                [void]$regContent.AppendLine()
                $deviceEntryCount++
            }
            foreach ($regPath in $result.WdfKeys) {
                [void]$regContent.AppendLine("[$regPath]")
                [void]$regContent.AppendLine('"IdleInWorkingState"=dword:00000000')
                [void]$regContent.AppendLine()
                $deviceEntryCount++
            }
            $busDevCount = $result.DeviceParams.Count + $result.WdfKeys.Count
            Write-Log "Enumerated $busDevCount device keys for $($result.Bus) bus." 'INFO'
        }

        $regFile = Join-Path $script:HunterRoot 'device-power-mgmt.reg'
        [System.IO.File]::WriteAllText($regFile, $regContent.ToString(), [System.Text.Encoding]::Unicode)
        try {
            $regImport = Start-Process -FilePath 'reg.exe' -ArgumentList @('import', $regFile) -Wait -PassThru -WindowStyle Hidden -ErrorAction Stop
            if ($null -eq $regImport -or $regImport.ExitCode -ne 0) {
                $exitCode = if ($null -ne $regImport) { $regImport.ExitCode } else { -1 }
                throw "reg import failed with exit code $exitCode"
            }
        } finally {
            Remove-Item -Path $regFile -Force -ErrorAction SilentlyContinue
        }
        Write-Log "Device power management imported via .reg file ($nicCount NIC(s), $deviceEntryCount device entries)." 'INFO'

        Invoke-ConfigureDefenderGameFolderExclusions | Out-Null

        Write-Log 'Exhaustive power tuning complete.' 'SUCCESS'
        return $true
    }
    catch {
        Write-Log "Error in Invoke-ExhaustivePowerTuning: $_" 'ERROR'
        return $false
    }
}

function Invoke-DisableNicPowerManagement {
    try {
        Write-Log 'Disabling NIC power-management and wake policies on active physical adapters...' 'INFO'

        if ($null -eq (Get-Command Get-NetAdapter -ErrorAction SilentlyContinue) -or
            $null -eq (Get-Command Disable-NetAdapterPowerManagement -ErrorAction SilentlyContinue) -or
            $null -eq (Get-Command Set-NetAdapterPowerManagement -ErrorAction SilentlyContinue)) {
            Write-Log 'Skipping NIC power-management tuning because required NetAdapter cmdlets are unavailable on this Windows build.' 'WARN'
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'NetAdapter power-management cmdlets are unavailable on this system'
            }
        }

        $adapters = @(
            Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Up' }
        )

        if ($adapters.Count -eq 0) {
            Write-Log 'No active physical network adapters were detected for NIC power-management tuning.' 'INFO'
            return (New-TaskSkipResult -Reason 'No active physical network adapters were detected')
        }

        $warningMessages = New-Object 'System.Collections.Generic.List[string]'
        $configuredAdapterCount = 0

        foreach ($adapter in $adapters) {
            $adapterConfigured = $false

            try {
                Disable-NetAdapterPowerManagement -Name $adapter.Name -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "Disabled generic power-management offloads for NIC: $($adapter.Name)" 'INFO'
                $adapterConfigured = $true
            } catch {
                [void]$warningMessages.Add("Could not disable generic power management for NIC '$($adapter.Name)': $($_.Exception.Message)")
            }

            try {
                Set-NetAdapterPowerManagement -Name $adapter.Name -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -NoRestart -ErrorAction Stop | Out-Null
                Write-Log "Disabled NIC wake triggers for: $($adapter.Name)" 'INFO'
                $adapterConfigured = $true
            } catch {
                [void]$warningMessages.Add("Could not disable wake policies for NIC '$($adapter.Name)': $($_.Exception.Message)")
            }

            if ($adapterConfigured) {
                $configuredAdapterCount++
            }
        }

        foreach ($warningMessage in @($warningMessages | Select-Object -Unique)) {
            Write-Log $warningMessage 'WARN'
        }

        if ($configuredAdapterCount -eq 0) {
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'NIC power-management cmdlets did not persist changes for any active physical adapter'
            }
        }

        if ($warningMessages.Count -gt 0) {
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'NIC power-management tuning completed with warnings'
            }
        }

        Write-Log "NIC power-management disabled for $configuredAdapterCount/$($adapters.Count) active physical adapter(s)." 'SUCCESS'
        return $true
    } catch {
        Write-Log "Error disabling NIC power-management: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Invoke-InstallTimerResolutionService {
    <#
    .SYNOPSIS
    Installs the WinSux-style timer resolution Windows service.
    .DESCRIPTION
    Builds a C# service that mirrors WinSux's process-aware timer resolution service. When no
    EXE-name INI is present beside the service binary, the service requests the maximum timer
    resolution continuously. When an INI exists, it raises the timer only while listed
    processes are running.
    #>
    param()

    try {
        Write-Log 'Installing timer resolution service...' 'INFO'

        $serviceName = 'SetTimerResolutionService'
        $displayName = 'Set Timer Resolution Service'
        $serviceDir = Join-Path $script:ProgramFilesRoot $serviceName
        $exePath = Join-Path $serviceDir "$serviceName.exe"
        $existingSvc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue

        Initialize-HunterDirectory $serviceDir

        if ($null -ne $existingSvc -and (Test-Path $exePath)) {
            Enable-GlobalTimerResolutionRequests | Out-Null

            if ($existingSvc.Status -ne 'Running') {
                try {
                    Start-Service -Name $serviceName -ErrorAction Stop
                    Start-Sleep -Milliseconds 500
                    $existingSvc = Get-Service -Name $serviceName -ErrorAction Stop
                } catch {
                    Write-Log "Existing timer resolution service could not be started cleanly and will be reinstalled: $($_.Exception.Message)" 'WARN'
                }
            }

            if ($null -ne $existingSvc -and $existingSvc.Status -eq 'Running') {
                Write-Log "Timer resolution service already installed and running ($exePath)." 'INFO'
                return (New-TaskSkipResult -Reason 'Timer resolution service already installed and running')
            }
        } elseif ($null -ne $existingSvc) {
            Write-Log 'Timer resolution service exists but its binary is missing; reinstalling it.' 'WARN'
        }

        # Compile the process-aware WinSux timer resolution service.
        $csSource = @'
using System;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.ComponentModel;
using System.Configuration.Install;
using System.Collections.Generic;
using System.Reflection;
using System.IO;
using System.Management;
using System.Threading;
using System.Diagnostics;
[assembly: AssemblyVersion("2.1")]
[assembly: AssemblyProduct("Set Timer Resolution service")]

namespace HunterTimerResolution
{
    public class SetTimerResolutionService : ServiceBase
    {
        public SetTimerResolutionService()
        {
            this.ServiceName = "SetTimerResolutionService";
            this.EventLog.Log = "Application";
            this.CanStop = true;
            this.CanHandlePowerEvent = false;
            this.CanHandleSessionChangeEvent = false;
            this.CanPauseAndContinue = false;
            this.CanShutdown = false;
        }

        public static void Main()
        {
            ServiceBase.Run(new SetTimerResolutionService());
        }

        protected override void OnStart(string[] args)
        {
            base.OnStart(args);
            ReadProcessList();
            NtQueryTimerResolution(out this.MinimumResolution, out this.MaximumResolution, out this.DefaultResolution);
            if (null != this.EventLog)
                try { this.EventLog.WriteEntry(String.Format("Minimum={0}; Maximum={1}; Default={2}; Processes='{3}'", this.MinimumResolution, this.MaximumResolution, this.DefaultResolution, null != this.ProcessesNames ? String.Join("','", this.ProcessesNames) : "")); }
                catch {}
            if (null == this.ProcessesNames)
            {
                SetMaximumResolution();
                return;
            }
            if (0 == this.ProcessesNames.Count)
            {
                return;
            }
            this.ProcessStartDelegate = new OnProcessStart(this.ProcessStarted);
            try
            {
                String query = String.Format("SELECT * FROM __InstanceCreationEvent WITHIN 0.5 WHERE (TargetInstance isa \"Win32_Process\") AND (TargetInstance.Name=\"{0}\")", String.Join("\" OR TargetInstance.Name=\"", this.ProcessesNames));
                this.startWatch = new ManagementEventWatcher(query);
                this.startWatch.EventArrived += this.startWatch_EventArrived;
                this.startWatch.Start();
            }
            catch (Exception ee)
            {
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Error); }
                    catch {}
            }
        }

        protected override void OnStop()
        {
            if (null != this.startWatch)
            {
                this.startWatch.Stop();
            }

            base.OnStop();
        }

        ManagementEventWatcher startWatch;
        void startWatch_EventArrived(object sender, EventArrivedEventArgs e)
        {
            try
            {
                ManagementBaseObject process = (ManagementBaseObject)e.NewEvent.Properties["TargetInstance"].Value;
                UInt32 processId = (UInt32)process.Properties["ProcessId"].Value;
                this.ProcessStartDelegate.BeginInvoke(processId, null, null);
            }
            catch (Exception ee)
            {
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Warning); }
                    catch {}
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern Int32 WaitForSingleObject(IntPtr Handle, Int32 Milliseconds);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr OpenProcess(UInt32 DesiredAccess, Int32 InheritHandle, UInt32 ProcessId);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern Int32 CloseHandle(IntPtr Handle);
        const UInt32 SYNCHRONIZE = 0x00100000;

        delegate void OnProcessStart(UInt32 processId);
        OnProcessStart ProcessStartDelegate = null;

        void ProcessStarted(UInt32 processId)
        {
            SetMaximumResolution();
            IntPtr processHandle = IntPtr.Zero;
            try
            {
                processHandle = OpenProcess(SYNCHRONIZE, 0, processId);
                if (processHandle != IntPtr.Zero)
                    WaitForSingleObject(processHandle, -1);
            }
            catch (Exception ee)
            {
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(ee.ToString(), EventLogEntryType.Warning); }
                    catch {}
            }
            finally
            {
                if (processHandle != IntPtr.Zero)
                    CloseHandle(processHandle);
            }
            SetDefaultResolution();
        }

        List<String> ProcessesNames = null;
        void ReadProcessList()
        {
            String iniFilePath = Assembly.GetExecutingAssembly().Location + ".ini";
            if (File.Exists(iniFilePath))
            {
                this.ProcessesNames = new List<String>();
                String[] iniFileLines = File.ReadAllLines(iniFilePath);
                foreach (var line in iniFileLines)
                {
                    String[] names = line.Split(new char[] { ',', ' ', ';' }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (var name in names)
                    {
                        String lowerName = name.ToLowerInvariant();
                        if (!lowerName.EndsWith(".exe"))
                            lowerName += ".exe";
                        if (!this.ProcessesNames.Contains(lowerName))
                            this.ProcessesNames.Add(lowerName);
                    }
                }
            }
        }

        [DllImport("ntdll.dll", SetLastError = true)]
        static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
        [DllImport("ntdll.dll", SetLastError = true)]
        static extern int NtQueryTimerResolution(out uint MinimumResolution, out uint MaximumResolution, out uint ActualResolution);

        uint DefaultResolution = 0;
        uint MinimumResolution = 0;
        uint MaximumResolution = 0;
        long processCounter = 0;

        void SetMaximumResolution()
        {
            long counter = Interlocked.Increment(ref this.processCounter);
            if (counter <= 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.MaximumResolution, true, out actual);
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(String.Format("Actual resolution = {0}", actual)); }
                    catch {}
            }
        }

        void SetDefaultResolution()
        {
            long counter = Interlocked.Decrement(ref this.processCounter);
            if (counter < 1)
            {
                uint actual = 0;
                NtSetTimerResolution(this.DefaultResolution, true, out actual);
                if (null != this.EventLog)
                    try { this.EventLog.WriteEntry(String.Format("Actual resolution = {0}", actual)); }
                    catch {}
            }
        }
    }

    [RunInstaller(true)]
    public class TimerResolutionServiceInstaller : Installer
    {
        public TimerResolutionServiceInstaller()
        {
            ServiceProcessInstaller processInstaller = new ServiceProcessInstaller();
            ServiceInstaller serviceInstaller = new ServiceInstaller();
            processInstaller.Account = ServiceAccount.LocalSystem;
            processInstaller.Username = null;
            processInstaller.Password = null;
            serviceInstaller.DisplayName = "Set Timer Resolution Service";
            serviceInstaller.StartType = ServiceStartMode.Automatic;
            serviceInstaller.ServiceName = "SetTimerResolutionService";
            this.Installers.Add(processInstaller);
            this.Installers.Add(serviceInstaller);
        }
    }
}
'@

        $csFilePath = Join-Path $serviceDir "$serviceName.cs"
        Set-Content -Path $csFilePath -Value $csSource -Encoding UTF8 -Force

        # Find the C# compiler
        $cscPath = $null
        $frameworkDirs = @(
            "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319",
            "$env:WINDIR\Microsoft.NET\Framework\v4.0.30319"
        )
        foreach ($dir in $frameworkDirs) {
            $candidate = Join-Path $dir 'csc.exe'
            if (Test-Path $candidate) {
                $cscPath = $candidate
                break
            }
        }

        if ($null -eq $cscPath) {
            Write-Log 'C# compiler (csc.exe) not found - cannot build timer resolution service.' 'ERROR'
            return $false
        }

        # Compile the service
        $compileOutput = & $cscPath `
            /nologo `
            /out:$exePath `
            /target:exe `
            /reference:System.ServiceProcess.dll `
            /reference:System.Configuration.Install.dll `
            /reference:System.Management.dll `
            $csFilePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log "Timer resolution service compilation failed: $($compileOutput -join ' ')" 'ERROR'
            return $false
        }

        if (-not (Test-Path $exePath)) {
            Write-Log "Timer resolution service compilation did not produce ${exePath}." 'ERROR'
            return $false
        }

        Write-Log 'Timer resolution service compiled successfully.' 'INFO'
        Remove-Item -Path $csFilePath -Force -ErrorAction SilentlyContinue

        if ($null -ne $existingSvc) {
            if ($existingSvc.Status -ne 'Stopped') {
                Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
                Start-Sleep -Milliseconds 500
            }
            Invoke-NativeCommandChecked -FilePath 'sc.exe' -ArgumentList @('delete', $serviceName) | Out-Null
            Start-Sleep -Seconds 2
        }

        New-Service -Name $serviceName -BinaryPathName ('"{0}"' -f $exePath) -DisplayName $displayName -StartupType Automatic -ErrorAction Stop | Out-Null
        Invoke-NativeCommandChecked -FilePath 'sc.exe' -ArgumentList @('description', $serviceName, 'Mirrors the WinSux timer-resolution service and holds the system timer at maximum resolution, or only while configured processes are running.') | Out-Null
        Start-Service -Name $serviceName -ErrorAction Stop

        Enable-GlobalTimerResolutionRequests | Out-Null

        try {
            Invoke-NativeCommandChecked -FilePath 'cmd.exe' -ArgumentList @('/c', 'cd /d %systemroot%\system32 && lodctr /R >nul 2>&1') | Out-Null
        } catch {
            Write-Log "Failed to rebuild 64-bit performance counters: $_" 'WARN'
        }
        try {
            Invoke-NativeCommandChecked -FilePath 'cmd.exe' -ArgumentList @('/c', 'cd /d %systemroot%\sysWOW64 && lodctr /R >nul 2>&1') | Out-Null
        } catch {
            Write-Log "Failed to rebuild 32-bit performance counters: $_" 'WARN'
        }

        $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $svc -and $svc.Status -eq 'Running') {
            Write-Log "Timer resolution service installed and running ($exePath)." 'SUCCESS'
            return $true
        } else {
            Write-Log "Timer resolution service did not reach Running state after installation." 'ERROR'
            return $false
        }
    }
    catch {
        Write-Log "Error in Invoke-InstallTimerResolutionService: $_" 'ERROR'
        return $false
    }
}

#endregion PHASE 7

#region INSTALL PIPELINE


function Set-NetAdapterAdvancedDisplayValueIfPresent {
    param(
        [Parameter(Mandatory)][string]$AdapterName,
        [Parameter(Mandatory)][string]$DisplayName,
        [Parameter(Mandatory)][string]$DisplayValue,
        [string]$SettingLabel = $DisplayName
    )

    try {
        $matchingProperties = @(
            Get-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $DisplayName -ErrorAction SilentlyContinue
        )

        if ($matchingProperties.Count -eq 0) {
            Write-Log "${SettingLabel} advanced property is not exposed on NIC ${AdapterName}. Skipping." 'INFO'
            return $false
        }

        $allAlreadyConfigured = $true
        foreach ($property in $matchingProperties) {
            if ([string]$property.DisplayValue -ne $DisplayValue) {
                Set-NetAdapterAdvancedProperty -Name $AdapterName -DisplayName $property.DisplayName -DisplayValue $DisplayValue -ErrorAction Stop
                $allAlreadyConfigured = $false
            }
        }

        if ($allAlreadyConfigured) {
            Write-Log "${SettingLabel} already set to ${DisplayValue} on NIC ${AdapterName}." 'INFO'
        } else {
            Write-Log "${SettingLabel} set to ${DisplayValue} on NIC ${AdapterName}." 'INFO'
        }

        return $true
    } catch {
        Write-Log "Failed to set ${SettingLabel} on NIC ${AdapterName}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-ApplyTcpOptimizerTutorialProfile {
    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log 'Applying TCP Optimizer settings...' 'INFO'
        Register-HunterManualRestoreNote `
            -Key 'manual-restore|tcp-optimizer' `
            -Description 'Manual restore note for TCP Optimizer profile' `
            -Instructions @(
                'Hunter changed TCP, adapter offload, and NetBIOS settings as part of the TCP Optimizer profile.',
                'To restore those networking changes, review the generated Hunter restore script first, then reset any remaining adapter-level networking changes with your preferred NIC defaults or by using the TCP Optimizer defaults/reset workflow.'
            )

        # Cache active adapters once - avoids 5 redundant WMI/CIM round trips
        # Ref: https://learn.microsoft.com/en-us/powershell/scripting/dev-cross-plat/performance/script-authoring-considerations
        $activeAdapters = @(Get-NetAdapter | Where-Object { $_.Status -eq 'Up' })

        # -- General tab settings --
        # MTU 1500 on all adapters
        foreach ($adapter in $activeAdapters) {
            try {
                Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('interface', 'ipv4', 'set', 'subinterface', $adapter.Name, 'mtu=1500', 'store=persistent') | Out-Null
            } catch {
                Write-Log "Failed to set MTU on $($adapter.Name): $_" 'WARN'
            }
        }
        foreach ($adapter in $activeAdapters) {
            Write-Log "Preserving existing DNS servers on $($adapter.Name)." 'INFO'
        }

        # -- Main TCP settings --
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'autotuninglevel=disabled') | Out-Null
        # Windows Scaling Heuristics: Disabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'heuristics', 'disabled') | Out-Null
        # Congestion Control Provider: CTCP
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'supplemental', 'template=Internet', 'congestionprovider=ctcp') | Out-Null
        # RSS: Enabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'rss=enabled') | Out-Null
        # RSC: Enabled
        foreach ($adapter in $activeAdapters) {
            try {
                Enable-NetAdapterRsc -Name $adapter.Name -ErrorAction Stop
            } catch {
                Write-Log "Failed to enable RSC on $($adapter.Name): $_" 'WARN'
            }
        }
        foreach ($adapter in $activeAdapters) {
            Set-NetAdapterAdvancedDisplayValueIfPresent -AdapterName $adapter.Name -DisplayName 'Interrupt Moderation' -DisplayValue 'Disabled' -SettingLabel 'Interrupt Moderation' | Out-Null
            Set-NetAdapterAdvancedDisplayValueIfPresent -AdapterName $adapter.Name -DisplayName 'Flow Control' -DisplayValue 'Disabled' -SettingLabel 'Flow Control' | Out-Null
        }
        # ECN: Disabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'ecncapability=disabled') | Out-Null
        # Timestamps: Disabled
        Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'timestamps=disabled') | Out-Null
        # Chimney Offload: Disabled (legacy, may fail)
        try {
            Invoke-NativeCommandChecked -FilePath 'netsh.exe' -ArgumentList @('int', 'tcp', 'set', 'global', 'chimney=disabled') | Out-Null
        } catch {
            Write-Log "Failed to disable chimney offload (legacy, expected on newer builds): $_" 'WARN'
        }
        # Checksum Offloading: Disabled
        foreach ($adapter in $activeAdapters) {
            try {
                Set-NetAdapterAdvancedProperty -Name $adapter.Name -DisplayName '*Checksum Offload*' -DisplayValue 'Disabled' -ErrorAction Stop
            } catch {
                Write-Log "Failed to set checksum offload advanced property on $($adapter.Name): $_" 'WARN'
            }
            try {
                Set-NetAdapterChecksumOffload -Name $adapter.Name -TcpIPv4 Disabled -TcpIPv6 Disabled -UdpIPv4 Disabled -UdpIPv6 Disabled -ErrorAction Stop
            } catch {
                Write-Log "Failed to disable checksum offload on $($adapter.Name): $_" 'WARN'
            }
        }
        # Large Send Offload (LSO): Disabled
        foreach ($adapter in $activeAdapters) {
            try {
                Set-NetAdapterLso -Name $adapter.Name -V1IPv4Enabled $false -IPv4Enabled $false -IPv6Enabled $false -ErrorAction Stop
            } catch {
                Write-Log "Failed to disable LSO on $($adapter.Name): $_" 'WARN'
            }
        }

        # -- Registry-based TCP settings --
        $tcpParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'

        # TTL: 64
        Set-RegistryValue -Path $tcpParams -Name 'DefaultTTL' -Value 64 -Type DWord
        # TCP 1323 Timestamps: Disabled (0)
        Set-RegistryValue -Path $tcpParams -Name 'Tcp1323Opts' -Value 0 -Type DWord
        # MaxUserPort: 65534
        Set-RegistryValue -Path $tcpParams -Name 'MaxUserPort' -Value 65534 -Type DWord
        # TcpTimedWaitDelay: 30
        Set-RegistryValue -Path $tcpParams -Name 'TcpTimedWaitDelay' -Value 30 -Type DWord
        # Max SYN Retransmissions: 2
        Set-RegistryValue -Path $tcpParams -Name 'TcpMaxConnectRetransmissions' -Value 2 -Type DWord
        # TcpMaxDataRetransmissions: 5
        Set-RegistryValue -Path $tcpParams -Name 'TcpMaxDataRetransmissions' -Value 5 -Type DWord

        # -- Advanced tab --
        $lanmanParams = 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters'
        # IRPStackSize / first two boxes: 10
        Set-RegistryValue -Path $lanmanParams -Name 'IRPStackSize' -Value 10 -Type DWord
        Set-RegistryValue -Path $lanmanParams -Name 'SizReqBuf' -Value 10 -Type DWord

        # -- Priorities --
        $priorityCtrl = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\ServiceProvider'
        Set-RegistryValue -Path $priorityCtrl -Name 'LocalPriority' -Value 4 -Type DWord
        Set-RegistryValue -Path $priorityCtrl -Name 'HostsPriority' -Value 5 -Type DWord
        Set-RegistryValue -Path $priorityCtrl -Name 'DnsPriority' -Value 6 -Type DWord
        Set-RegistryValue -Path $priorityCtrl -Name 'NetbtPriority' -Value 7 -Type DWord

        # -- Retransmission / timeout --
        # Non-SACK RTT Resiliency: Disabled
        Set-RegistryValue -Path $tcpParams -Name 'SackOpts' -Value 1 -Type DWord
        # Initial RTO: 2000
        Set-RegistryValue -Path $tcpParams -Name 'InitialRto' -Value 2000 -Type DWord
        # Minimum RTO: 300
        Set-RegistryValue -Path $tcpParams -Name 'MinRto' -Value 300 -Type DWord

        # -- QoS / Throttling --
        $qosPath = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Psched'
        # NonBestEffortLimit: 0
        Set-RegistryValue -Path $qosPath -Name 'NonBestEffortLimit' -Value 0 -Type DWord
        # QoS Do Not Use NLA: Optimal (undocumented but registry-set)
        Set-RegistryValue -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\QoS' -Name 'DoNotUseNLA' -Value 1 -Type DWord
        # Network Throttling Index: Disabled (FFFFFFFF = 4294967295)
        Set-RegistryValue -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -Value ([uint32]::MaxValue) -Type DWord -FailureLevel WARN

        # -- Gaming / ACK settings --
        $sysProfile = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        $gamesTaskPath = Join-Path $sysProfile 'Tasks\Games'
        $priorityControlPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\PriorityControl'
        # System Responsiveness: reserve 10% CPU for low-priority work
        Set-RegistryValue -Path $sysProfile -Name 'SystemResponsiveness' -Value 10 -Type DWord
        # Requested scheduler overrides
        Set-RegistryValue -Path $gamesTaskPath -Name 'Scheduling Category' -Value 'High' -Type String
        Set-RegistryValue -Path $gamesTaskPath -Name 'SFIO Priority' -Value 'High' -Type String
        Set-RegistryValue -Path $gamesTaskPath -Name 'Priority' -Value 6 -Type DWord
        Set-RegistryValue -Path $gamesTaskPath -Name 'GPU Priority' -Value 8 -Type DWord
        Set-RegistryValue -Path $priorityControlPath -Name 'Win32PrioritySeparation' -Value 0x26 -Type DWord
        # TCP ACK Frequency: 1 (Disabled/every packet)
        $tcpIntPath = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        Get-ChildItem $tcpIntPath -ErrorAction SilentlyContinue | ForEach-Object {
            Set-RegistryValue -Path $_.PSPath -Name 'TcpAckFrequency' -Value 1 -Type DWord
            # TCP No Delay: 1 (Enabled)
            Set-RegistryValue -Path $_.PSPath -Name 'TCPNoDelay' -Value 1 -Type DWord
        }
        # TCP DelAck Ticks: Disabled (0)
        Set-RegistryValue -Path $tcpParams -Name 'TcpDelAckTicks' -Value 0 -Type DWord
        Write-Log 'Applied native MMCSS game scheduling priorities and per-interface Nagle disable (TcpAckFrequency/TCPNoDelay) before launching TCP Optimizer.' 'INFO'

        # Disable NetBIOS over TCP/IP on IP-enabled adapters
        foreach ($adapterConfig in @(Get-CimInstance -ClassName Win32_NetworkAdapterConfiguration -Filter 'IPEnabled = True' -ErrorAction SilentlyContinue)) {
            try {
                if ($adapterConfig.TcpipNetbiosOptions -eq 2) {
                    Write-Log "NetBIOS over TCP/IP already disabled on $($adapterConfig.Description)." 'INFO'
                    continue
                }

                $netbiosResult = Invoke-CimMethod -InputObject $adapterConfig -MethodName 'SetTcpipNetbios' -Arguments @{ TcpipNetbiosOptions = [uint32]2 } -ErrorAction Stop
                if ($netbiosResult.ReturnValue -in @(0, 1)) {
                    Write-Log "NetBIOS over TCP/IP disabled on $($adapterConfig.Description)." 'INFO'
                } else {
                    Write-Log "Failed to disable NetBIOS over TCP/IP on $($adapterConfig.Description): WMI returned $($netbiosResult.ReturnValue)." 'WARN'
                }
            } catch {
                Write-Log "Failed to disable NetBIOS over TCP/IP on $($adapterConfig.Description): $($_.Exception.Message)" 'WARN'
            }
        }

        # -- Cache / memory / ports --
        $memMgmt = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        # Large System Cache: RAM-aware policy
        Set-LargeSystemCacheByRamPolicy -Path $memMgmt | Out-Null
        # Size: Default (1)
        Set-RegistryValue -Path $memMgmt -Name 'Size' -Value 1 -Type DWord

        Write-Log 'TCP optimization settings applied via registry and netsh' 'SUCCESS'

        # Download and open TCP Optimizer for user verification
        $tcpOptimizerPath = Get-TcpOptimizerDownloadPath
        if (-not (Test-Path $tcpOptimizerPath)) {
            Write-Log 'Downloading TCP Optimizer...' 'INFO'
            Download-File -Url 'https://www.speedguide.net/files/TCPOptimizer.exe' -Destination $tcpOptimizerPath
        }
        Initialize-InstallerHelpers
        Confirm-InstallerSignature -PackageName 'TCP Optimizer' -Path $tcpOptimizerPath -ExpectedSha256 $script:TcpOptimizerSha256 | Out-Null

        Initialize-DesktopShortcut -ShortcutName 'TCP Optimizer' -TargetPath $tcpOptimizerPath -Description 'TCP Optimizer' | Out-Null
        if ($script:IsAutomationRun) {
            Write-Log 'Automation-safe mode enabled; skipping TCP Optimizer UI launch.' 'INFO'
        } else {
            Write-Log 'Opening TCP Optimizer and continuing without manual confirmation...' 'INFO'
            Start-Process $tcpOptimizerPath
        }
        Write-Log 'TCP Optimizer profile applied.' 'SUCCESS'

    } catch {
        Write-Log "Error applying TCP Optimizer profile: $_" 'ERROR'
        throw
    }
}


function Invoke-ApplyOOSUSilentRecommendedPlusSomewhat {
    <#
    .SYNOPSIS
        Opens O&O ShutUp10 for user-guided privacy and performance optimization.

    .DESCRIPTION
        Downloads and opens O&O ShutUp10 (https://www.oo-software.com/en/shutup10)
        for the user to apply recommended and somewhat recommended privacy/performance
        settings. Targets 170+ privacy-focused settings.
    #>

    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log "Preparing O&O ShutUp10..." 'INFO'
        Register-HunterManualRestoreNote `
            -Key 'manual-restore|oosu' `
            -Description 'Manual restore note for O&O ShutUp10 preset import' `
            -Instructions @(
                'Hunter imported an O&O ShutUp10 preset that can change settings outside Hunter''s native rollback capture.',
                'To restore those privacy settings, reopen O&O ShutUp10 and use its built-in revert/default workflow, or restore from the Windows restore point if you created one before the run.'
            )

        # Download O&O ShutUp10
        $oosuPath = Get-OOSUDownloadPath
        $oosuConfigPath = Get-OOSUConfigPath
        if (-not (Test-Path $oosuPath)) {
            Write-Log "Downloading O&O ShutUp10..." 'INFO'
            Download-File -Url 'https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe' -Destination $oosuPath
        }
        Initialize-InstallerHelpers
        Confirm-InstallerSignature -PackageName 'O&O ShutUp10' -Path $oosuPath -ExpectedSha256 $script:OOSUSha256 | Out-Null

        Write-Log "Downloading O&O ShutUp10 preset..." 'INFO'
        $forceOOSUConfigRefresh = -not ($script:PrefetchedExternalAssets.ContainsKey('oosu-config') -and [bool]$script:PrefetchedExternalAssets['oosu-config'])
        Download-File -Url $script:OOSUConfigUrl -Destination $oosuConfigPath -Force:$forceOOSUConfigRefresh | Out-Null

        Write-Log "Importing O&O ShutUp10 preset silently..." 'INFO'
        Start-ProcessChecked -FilePath $oosuPath -ArgumentList @($oosuConfigPath, '/quiet', '/force') -WindowStyle Hidden | Out-Null

        Initialize-DesktopShortcut -ShortcutName 'O&O ShutUp10' -TargetPath $oosuPath -Description 'O&O ShutUp10' | Out-Null
        if ($script:IsAutomationRun) {
            Write-Log 'Automation-safe mode enabled; skipping O&O ShutUp10 UI launch.' 'INFO'
        } else {
            Start-Process -FilePath $oosuPath | Out-Null
        }

        Write-Log "O&O ShutUp10 preset imported silently.$(if ($script:IsAutomationRun) { ' UI launch skipped for automation-safe mode.' } else { ' Window opened for review.' })" 'SUCCESS'

    } catch {
        Write-Log "Error applying O&O ShutUp10: $_" 'ERROR'
        throw
    }
}

function Resolve-WallpaperAssetUrl {
    try {
        $sourceUrl = [string]$script:WallpaperSourceUrl
        if ([string]::IsNullOrWhiteSpace($sourceUrl)) {
            throw 'Wallpaper source URL is not configured.'
        }

        if ($sourceUrl -match '^https?://drive\.google\.com/file/d/([A-Za-z0-9_-]+)(/|$)') {
            return "https://drive.google.com/uc?export=download&id=$($Matches[1])"
        }

        if ($sourceUrl -match '^https?://drive\.google\.com/open\?id=([A-Za-z0-9_-]+)(&|$)') {
            return "https://drive.google.com/uc?export=download&id=$($Matches[1])"
        }

        if ($sourceUrl -match '^https?://drive\.google\.com/uc\?') {
            return $sourceUrl
        }

        if ($sourceUrl -match '^https?://[^ ]+\.(jpg|jpeg|png)(\?.*)?$') {
            return $sourceUrl
        }

        if ($sourceUrl -match '^https?://wallhaven\.cc/w/([A-Za-z0-9]+)$') {
            $ProgressPreference = 'SilentlyContinue'
            $wallpaperId = $Matches[1]

            if (-not [string]::IsNullOrWhiteSpace($wallpaperId) -and $wallpaperId.Length -ge 2) {
                $assetPrefix = $wallpaperId.Substring(0, 2)
                foreach ($extension in @('jpg', 'jpeg', 'png')) {
                    $candidateUrl = "https://w.wallhaven.cc/full/${assetPrefix}/wallhaven-${wallpaperId}.${extension}"

                    try {
                        $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
                        if ($null -ne $curl) {
                            & $curl.Source -I --silent --fail $candidateUrl > $null 2>&1
                            $exitCode = $LASTEXITCODE
                            if ($exitCode -eq 0) {
                                return $candidateUrl
                            }
                        } else {
                            Invoke-WebRequest -Method Head -Uri $candidateUrl -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 30 -ErrorAction Stop | Out-Null
                            return $candidateUrl
                        }
                    } catch {
                        Write-Log "Wallpaper probe failed for ${candidateUrl}: $($_.Exception.Message)" 'WARN'
                    }
                }
            }
        }

        $headers = @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64)' }
        $page = Invoke-WebRequest -Uri $sourceUrl -Headers $headers -UseBasicParsing -MaximumRedirection 5 -TimeoutSec 60 -ErrorAction Stop
        $html = [string]$page.Content

        foreach ($link in @($page.Links)) {
            $href = [string]$link.href
            if ($href -match '^https?://[^ ]+\.(jpg|jpeg|png)(\?.*)?$') {
                return $Matches[0]
            }
        }

        $patterns = @(
            '<meta[^>]+property=["'']og:image["''][^>]+content=["''](?<url>https://[^"'']+\.(jpg|jpeg|png)(\?[^"'']*)?)["'']',
            '<meta[^>]+content=["''](?<url>https://[^"'']+\.(jpg|jpeg|png)(\?[^"'']*)?)["''][^>]+property=["'']og:image["'']',
            '(?<url>https://[^"'']+\.(jpg|jpeg|png)(\?[^"'']*)?)'
        )

        foreach ($pattern in $patterns) {
            $match = [regex]::Match($html, $pattern)
            if ($match.Success) {
                if ($match.Groups['url'].Success) {
                    return $match.Groups['url'].Value
                }

                return $match.Value
            }
        }

        throw "Could not resolve wallpaper asset from $sourceUrl"
    } catch {
        Write-Log "Failed to resolve wallpaper asset: $_" 'WARN'
        return $null
    }
}

function Set-CurrentUserDesktopWallpaper {
    param([string]$WallpaperPath)

    if (-not ('HunterWallpaperNative' -as [type])) {
        Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class HunterWallpaperNative {
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool SystemParametersInfo(int uiAction, int uiParam, string pvParam, int fWinIni);
}
"@
    }

    $SPI_SETDESKWALLPAPER = 20
    $SPIF_UPDATEINIFILE = 0x01
    $SPIF_SENDCHANGE = 0x02
    $setResult = [HunterWallpaperNative]::SystemParametersInfo(
        $SPI_SETDESKWALLPAPER,
        0,
        $WallpaperPath,
        ($SPIF_UPDATEINIFILE -bor $SPIF_SENDCHANGE)
    )

    if (-not $setResult) {
        $lastError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "SystemParametersInfo failed with Win32 error $lastError"
    }
}

function Invoke-ApplyWallpaperEverywhere {
    try {
        Invoke-CollectCompletedExternalAssetPrefetchJobs
        Write-Log 'Downloading and applying wallpaper to desktop...' 'INFO'

        $wallpaperUrl = Get-ResolvedWallpaperAssetUrl
        if ([string]::IsNullOrWhiteSpace($wallpaperUrl)) {
            Write-Log 'Wallpaper asset could not be resolved. Skipping wallpaper step.' 'WARN'
            return $true
        }

        $wallpaperPath = Get-WallpaperAssetPath -WallpaperUrl $wallpaperUrl
        $forceWallpaperRefresh = -not ($script:PrefetchedExternalAssets.ContainsKey('wallpaper') -and [bool]$script:PrefetchedExternalAssets['wallpaper'])
        Download-File -Url $wallpaperUrl -Destination $wallpaperPath -Force:$forceWallpaperRefresh | Out-Null

        Remove-RegistryValueForAllUsers -SubPath 'Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'Wallpaper'
        Remove-RegistryValueForAllUsers -SubPath 'Software\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'WallpaperStyle'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name 'LockScreenImage'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' -Name 'NoChangingLockScreen'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'DesktopImagePath'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'DesktopImageUrl'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImagePath'
        Remove-RegistryValueIfPresent -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\PersonalizationCSP' -Name 'LockScreenImageUrl'

        Set-CurrentUserDesktopWallpaper -WallpaperPath $wallpaperPath
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'Wallpaper' -Value $wallpaperPath
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'WallpaperStyle' -Value '10'
        Set-StringForAllUsers -SubPath 'Control Panel\Desktop' -Name 'TileWallpaper' -Value '0'

        Start-Process -FilePath rundll32.exe -ArgumentList 'user32.dll,UpdatePerUserSystemParameters' -WindowStyle Hidden | Out-Null
        Request-ExplorerRestart

        Write-Log "Wallpaper applied to desktop without locking future wallpaper changes: $wallpaperPath" 'SUCCESS'
        return $true
    } catch {
        Write-Log "Failed to apply wallpaper everywhere: $_" 'ERROR'
        return $false
    }
}

function Invoke-OpenAdvancedSystemSettings {
    try {
        if ($script:IsAutomationRun) {
            Write-Log 'Automation-safe mode enabled; skipping classic System Properties UI launch.' 'INFO'
            return $true
        }

        Write-Log 'Opening classic System Properties (Advanced tab)...' 'INFO'

        # Snapshot existing SystemSettings processes so we only kill NEW ones that
        # Windows 11 spawns as a side-effect of launching System Properties dialogs.
        $preExistingSettingsPids = @(
            Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty Id
        )

        $spaExe = Join-Path $env:SystemRoot 'System32\SystemPropertiesAdvanced.exe'
        if (Test-Path $spaExe) {
            Start-Process -FilePath $spaExe | Out-Null
            Write-Log 'Launched SystemPropertiesAdvanced.exe' 'SUCCESS'
        } else {
            Start-Process -FilePath 'sysdm.cpl' -ArgumentList ',3' | Out-Null
            Write-Log 'Launched sysdm.cpl directly (SystemPropertiesAdvanced.exe not found)' 'INFO'
        }

        # Windows 11 often opens the native Settings app alongside the classic
        # System Properties dialog. Poll briefly and kill any NEW SystemSettings
        # processes that were not running before the launch.
        for ($poll = 0; $poll -lt 8; $poll++) {
            Start-Sleep -Milliseconds 500
            $newSettingsProcesses = @(
                Get-Process -Name 'SystemSettings' -ErrorAction SilentlyContinue |
                    Where-Object { $_.Id -notin $preExistingSettingsPids }
            )
            foreach ($proc in $newSettingsProcesses) {
                try {
                    Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
                    Write-Log "Killed unwanted SystemSettings process (PID $($proc.Id)) spawned by Windows 11" 'INFO'
                } catch {
                    Write-Log "Failed to kill SystemSettings PID $($proc.Id): $_" 'WARN'
                }
            }
        }

        return $true
    } catch {
        Write-Log "Failed to open Advanced System Settings: $_" 'ERROR'
        return $false
    }
}

function Invoke-CreateNetworkConnectionsShortcut {
    <#
    .SYNOPSIS
        Creates a Network Connections shortcut, places it in the Start Menu, and pins it.
    #>

    try {
        Write-Log 'Creating Network Connections shortcut...' 'INFO'

        $controlExe = Join-Path $env:SystemRoot 'System32\control.exe'
        $iconDllPath = Join-Path $env:SystemRoot 'System32\netshell.dll'
        $iconLocation = "$iconDllPath,0"
        $shortcutName = 'Network Connections'
        $description = 'View and manage network connections'

        # Create desktop shortcut
        Initialize-DesktopShortcut `
            -ShortcutName $shortcutName `
            -TargetPath $controlExe `
            -Arguments 'ncpa.cpl' `
            -Description $description `
            -IconLocation $iconLocation

        # Create shortcut in All Users Start Menu Programs
        $startMenuShortcutPath = Join-Path $script:AllUsersStartMenuProgramsPath "$shortcutName.lnk"
        New-WindowsShortcut `
            -ShortcutPath $startMenuShortcutPath `
            -TargetPath $controlExe `
            -Arguments 'ncpa.cpl' `
            -Description $description `
            -IconLocation $iconLocation

        # Pin to Start menu via shell verb
        if (Test-Path $startMenuShortcutPath) {
            try {
                $shell = New-Object -ComObject Shell.Application
                $folder = $shell.Namespace((Split-Path -Parent $startMenuShortcutPath))
                $item = $folder.ParseName((Split-Path -Leaf $startMenuShortcutPath))
                $pinVerb = $item.Verbs() | Where-Object { $_.Name -match 'Pin to Start|pintostartscreen|Unpin from Start' -and $_.Name -match 'Pin' }
                if ($pinVerb) {
                    $pinVerb.DoIt()
                    Write-Log "Pinned '$shortcutName' to Start menu via shell verb" 'SUCCESS'
                } else {
                    Write-Log "Pin to Start verb not available for '$shortcutName' (may require policy-based pinning)" 'INFO'
                }
            } catch {
                Write-Log "Failed to pin '$shortcutName' to Start menu: $_" 'INFO'
            }
        }

        Write-Log "Network Connections shortcut created and placed in Start Menu" 'SUCCESS'
        return $true

    } catch {
        Write-Log "Failed to create Network Connections shortcut: $_" 'ERROR'
        return $false
    }
}
