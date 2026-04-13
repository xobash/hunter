function Get-WindowsActivationStateSummary {
    $statusMap = @{
        0 = 'Unlicensed'
        1 = 'Licensed'
        2 = 'OOBGrace'
        3 = 'OOTGrace'
        4 = 'NonGenuineGrace'
        5 = 'Notification'
        6 = 'ExtendedGrace'
    }

    try {
        $activationProducts = @(
            Get-CimInstance -ClassName SoftwareLicensingProduct `
                -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" `
                -ErrorAction Stop
        )
        if ($activationProducts.Count -eq 0) {
            return 'Unknown (no activation product instance exposed)'
        }

        $licensedProduct = @($activationProducts | Where-Object { [int]$_.LicenseStatus -eq 1 } | Select-Object -First 1)
        if ($licensedProduct.Count -gt 0) {
            return 'Licensed'
        }

        $sampleProduct = @($activationProducts | Select-Object -First 1)
        if ($sampleProduct.Count -eq 0) {
            return 'Unknown'
        }

        $statusCode = [int]$sampleProduct[0].LicenseStatus
        if ($statusMap.ContainsKey($statusCode)) {
            return $statusMap[$statusCode]
        }

        return "Unknown ($statusCode)"
    } catch {
        return "Unknown ($($_.Exception.Message))"
    }
}

function ConvertTo-HunterVersionOrNull {
    param([string]$VersionText)

    $normalizedVersionText = ([string]$VersionText) -replace '[^0-9.]', ''
    if ([string]::IsNullOrWhiteSpace($normalizedVersionText)) {
        return $null
    }

    try {
        return [version]$normalizedVersionText
    } catch {
        return $null
    }
}

function Test-WingetFunctional {
    $wingetCommand = Get-Command winget -ErrorAction SilentlyContinue
    if ($null -eq $wingetCommand) {
        return [pscustomobject]@{
            Available           = $false
            Version             = ''
            ParsedVersion       = $null
            MeetsMinimumVersion = $false
            Message             = 'winget.exe was not found on PATH.'
        }
    }

    try {
        $versionOutput = & $wingetCommand.Source --version 2>&1
        $exitCode = [int]$LASTEXITCODE
        $versionOutput = @($versionOutput)
        $versionText = [string]::Join(' ', @($versionOutput | ForEach-Object { [string]$_ })).Trim()
        $parsedVersion = ConvertTo-HunterVersionOrNull -VersionText $versionText
        $minimumWingetVersion = ConvertTo-HunterVersionOrNull -VersionText $script:WingetMinimumVersion
        if ($exitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($versionText)) {
            return [pscustomobject]@{
                Available           = $true
                Version             = $versionText
                ParsedVersion       = $parsedVersion
                MeetsMinimumVersion = ($null -ne $parsedVersion -and $null -ne $minimumWingetVersion -and $parsedVersion -ge $minimumWingetVersion)
                Message             = ''
            }
        }

        if ([string]::IsNullOrWhiteSpace($versionText)) {
            $versionText = "winget exited with code $exitCode."
        }

        return [pscustomobject]@{
            Available           = $false
            Version             = ''
            ParsedVersion       = $null
            MeetsMinimumVersion = $false
            Message             = $versionText
        }
    } catch {
        return [pscustomobject]@{
            Available           = $false
            Version             = ''
            ParsedVersion       = $null
            MeetsMinimumVersion = $false
            Message             = $_.Exception.Message
        }
    }
}

function Invoke-EnsureWingetMinVersion {
    try {
        if ($script:IsUnsupportedEdition) {
            Write-Log 'Skipping winget minimum-version enforcement because this Windows edition is not a supported Store-backed consumer build.' 'INFO'
            return (New-TaskSkipResult -Reason 'winget minimum-version enforcement is skipped on unsupported Windows editions')
        }

        $minimumWingetVersion = ConvertTo-HunterVersionOrNull -VersionText $script:WingetMinimumVersion
        if ($null -eq $minimumWingetVersion) {
            Write-Log "Hunter could not parse its configured minimum winget version '$($script:WingetMinimumVersion)'." 'WARN'
            return (New-TaskWarningResult -Reason 'Configured minimum winget version could not be parsed')
        }

        $wingetStatus = Test-WingetFunctional
        if (-not $wingetStatus.Available) {
            Write-Log "winget minimum-version check could not run because winget is unavailable: $($wingetStatus.Message)" 'WARN'
            return (New-TaskWarningResult -Reason 'winget is not currently available for version validation')
        }

        if ($null -eq $wingetStatus.ParsedVersion) {
            Write-Log "winget responded but Hunter could not parse its version string '$($wingetStatus.Version)'." 'WARN'
            return (New-TaskWarningResult -Reason 'winget version string could not be parsed')
        }

        if ($wingetStatus.ParsedVersion -ge $minimumWingetVersion) {
            Write-Log "winget $($wingetStatus.ParsedVersion) satisfies Hunter's minimum version requirement of $minimumWingetVersion." 'SUCCESS'
            return $true
        }

        Write-Log "winget $($wingetStatus.ParsedVersion) is below Hunter's minimum version requirement of $minimumWingetVersion. Attempting App Installer refresh..." 'WARN'
        if (-not (Install-WingetFromOfficialBundle)) {
            return (New-TaskWarningResult -Reason "winget $($wingetStatus.ParsedVersion) is below the supported minimum version and App Installer refresh failed")
        }

        $retestedWingetStatus = Test-WingetFunctional
        if ($retestedWingetStatus.Available -and $retestedWingetStatus.MeetsMinimumVersion) {
            Write-Log "winget refreshed successfully to $($retestedWingetStatus.ParsedVersion)." 'SUCCESS'
            return $true
        }

        Write-Log "winget refresh completed but the current version is still '$($retestedWingetStatus.Version)', which does not satisfy Hunter's minimum version requirement of $minimumWingetVersion." 'WARN'
        return (New-TaskWarningResult -Reason 'winget is still below Hunter’s minimum supported version after refresh')
    } catch {
        Write-Log "Failed to validate Hunter's minimum winget version: $($_.Exception.Message)" 'WARN'
        return (New-TaskWarningResult -Reason 'winget minimum-version validation failed unexpectedly')
    }
}

function Install-WingetFromOfficialBundle {
    $bundleUrl = 'https://aka.ms/getwinget'
    $desktopPowerShellPath = Get-NativeSystemExecutablePath -FileName 'powershell.exe'
    $bundlePath = Join-Path $script:DownloadDir 'Microsoft.DesktopAppInstaller.msixbundle'
    $installerScriptPath = Join-Path $script:DownloadDir 'Install-WingetBundle.ps1'

    try {
        Initialize-HunterDirectory $script:DownloadDir
        Write-Log "Attempting App Installer bootstrap from $bundleUrl" 'INFO'
        Invoke-WebRequest -Uri $bundleUrl -OutFile $bundlePath -UseBasicParsing -MaximumRedirection 10 -TimeoutSec 300 -ErrorAction Stop

        $installerScript = @'
param([Parameter(Mandatory)][string]$BundlePath)
$ErrorActionPreference = 'Stop'
Add-AppxPackage -Path $BundlePath -ErrorAction Stop
'@

        Set-Content -Path $installerScriptPath -Value $installerScript -Encoding UTF8 -Force
        $installerOutput = & $desktopPowerShellPath -NoProfile -ExecutionPolicy Bypass -File $installerScriptPath -BundlePath $bundlePath 2>&1
        $installerExitCode = [int]$LASTEXITCODE
        $installerOutput = @($installerOutput)
        if ($installerExitCode -ne 0) {
            $installerMessage = [string]::Join(' ', @($installerOutput | ForEach-Object { [string]$_ })).Trim()
            if ([string]::IsNullOrWhiteSpace($installerMessage)) {
                $installerMessage = "App Installer bootstrap exited with code $installerExitCode."
            }

            throw $installerMessage
        }

        Write-Log 'App Installer bootstrap completed. Re-checking winget availability...' 'INFO'
        return $true
    } catch {
        Write-Log "Winget bootstrap failed: $($_.Exception.Message)" 'ERROR'
        return $false
    } finally {
        Remove-Item -Path $installerScriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Ensure-WingetFunctional {
    if (Resolve-SkipAppDownloadsPreference) {
        $script:PackagePipelineBlocked = $false
        $script:PackagePipelineBlockReason = ''
        return $true
    }

    $wingetStatus = Test-WingetFunctional
    if ($wingetStatus.Available) {
        if ($wingetStatus.MeetsMinimumVersion) {
            $script:PackagePipelineBlocked = $false
            $script:PackagePipelineBlockReason = ''
            Write-Log "winget functional check passed: $($wingetStatus.Version)" 'INFO'
            return $true
        }

        Write-Log "winget functional check passed, but version '$($wingetStatus.Version)' is below the supported minimum of $($script:WingetMinimumVersion)." 'WARN'
        if (-not (Install-WingetFromOfficialBundle)) {
            $script:PackagePipelineBlocked = $true
            $script:PackagePipelineBlockReason = "winget is available but below the minimum supported version of $($script:WingetMinimumVersion)"
            return $false
        }

        $wingetStatus = Test-WingetFunctional
        if ($wingetStatus.Available -and $wingetStatus.MeetsMinimumVersion) {
            $script:PackagePipelineBlocked = $false
            $script:PackagePipelineBlockReason = ''
            Write-Log "winget functional check passed after refresh: $($wingetStatus.Version)" 'INFO'
            return $true
        }
    }

    $script:PackagePipelineBlocked = $true
    $script:PackagePipelineBlockReason = if ($wingetStatus.Available) {
        "winget is below the minimum supported version of $($script:WingetMinimumVersion) and Hunter could not safely prepare the package pipeline."
    } else {
        'winget is not functional and Hunter could not safely prepare the package pipeline.'
    }
    $wingetFailureMessage = if ([string]::IsNullOrWhiteSpace($wingetStatus.Message)) {
        if ($wingetStatus.Available -and -not [string]::IsNullOrWhiteSpace($wingetStatus.Version)) {
            "winget $($wingetStatus.Version) is below the minimum supported version of $($script:WingetMinimumVersion)."
        } else {
            'winget did not return a usable version result.'
        }
    } else {
        $wingetStatus.Message
    }
    Write-Log "winget preflight failed: $wingetFailureMessage" 'WARN'
    Write-Log 'Package installs that rely on App Installer may fail until winget is repaired.' 'WARN'

    if ($script:IsAutomationRun) {
        Write-Log 'Automation-safe mode will not attempt interactive winget bootstrap. Install App Installer manually or rerun after winget is repaired.' 'ERROR'
        return $false
    }

    $shouldBootstrapWinget = Show-YesNoDialog `
        -Title 'Hunter winget Repair' `
        -Message "Hunter could not run 'winget --version'.`n`nError:`n$($wingetStatus.Message)`n`nWould you like Hunter to try installing App Installer from https://aka.ms/getwinget now?" `
        -DefaultToNo $true

    if (-not $shouldBootstrapWinget) {
        Write-Log 'winget is required for parts of the package pipeline. The user declined App Installer bootstrap, so app downloads cannot proceed safely.' 'ERROR'
        return $false
    }

    if (-not (Install-WingetFromOfficialBundle)) {
        return $false
    }

    $postBootstrapWingetStatus = Test-WingetFunctional
    if (-not $postBootstrapWingetStatus.Available) {
        Write-Log "winget is still not functional after App Installer bootstrap: $($postBootstrapWingetStatus.Message)" 'ERROR'
        return $false
    }

    $script:PackagePipelineBlocked = $false
    $script:PackagePipelineBlockReason = ''
    Write-Log "winget functional check passed after bootstrap: $($postBootstrapWingetStatus.Version)" 'SUCCESS'
    return $true
}

function Resolve-DisableTeredoPreference {
    if ($script:TeredoPreferenceResolved) {
        return [bool]$script:TeredoDisableResolvedValue
    }

    $script:TeredoPreferenceResolved = $true

    if ([bool]$script:DisableTeredoRequested -or $env:HUNTER_DISABLE_TEREDO -eq '1') {
        $script:DisableTeredoRequested = $true
        $script:TeredoDisableResolvedValue = $true
        return $true
    }

    if ($script:IsAutomationRun) {
        Write-Log 'Skipping Teredo disable by default in automation-safe mode. Set HUNTER_DISABLE_TEREDO=1 or pass -DisableTeredo to opt in.' 'INFO'
        $script:TeredoDisableResolvedValue = $false
        return $false
    }

    $script:DisableTeredoRequested = Show-YesNoDialog `
        -Title 'Hunter Teredo Policy' `
        -Message "Disable Teredo?`n`nTeredo is still used by Xbox Live, some peer-to-peer games, and certain VPN scenarios. Choose Yes only if you specifically want Hunter to disable it." `
        -DefaultToNo $true
    $script:TeredoDisableResolvedValue = [bool]$script:DisableTeredoRequested

    if ($script:DisableTeredoRequested) {
        Write-Log 'Teredo disable was approved by the user.' 'INFO'
    } else {
        Write-Log 'Teredo will be preserved unless -DisableTeredo or HUNTER_DISABLE_TEREDO=1 is supplied.' 'INFO'
    }

    return [bool]$script:TeredoDisableResolvedValue
}

function Resolve-DisableHagsPreference {
    if ($script:HagsPreferenceResolved) {
        return [bool]$script:HagsDisableResolvedValue
    }

    $script:HagsPreferenceResolved = $true

    if ([bool]$script:DisableHagsRequested -or $env:HUNTER_DISABLE_HAGS -eq '1') {
        $script:DisableHagsRequested = $true
        $script:HagsDisableResolvedValue = $true
        Write-Log 'HAGS disable override was requested explicitly.' 'INFO'
        return $true
    }

    $gpuSummary = (@(Get-GpuPciDeviceContexts) | ForEach-Object { '{0} ({1})' -f $_.Name, $_.Vendor }) -join '; '
    if ([string]::IsNullOrWhiteSpace($gpuSummary)) {
        $gpuSummary = 'No PCI display devices detected'
    }

    if ($script:IsAutomationRun) {
        Write-Log "Automation-safe mode will keep Hunter's default HAGS enable policy. Use -DisableHags or HUNTER_DISABLE_HAGS=1 to opt out. GPU(s): $gpuSummary" 'INFO'
        $script:HagsDisableResolvedValue = $false
        return $false
    }

    Write-Log "Hunter will enable HAGS by default for GPU(s): $gpuSummary. Use -DisableHags or HUNTER_DISABLE_HAGS=1 to keep the legacy disable override." 'INFO'
    $script:HagsDisableResolvedValue = $false
    return [bool]$script:HagsDisableResolvedValue
}
