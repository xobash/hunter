function Test-CanUseInlineAppxCommands {
    if ($null -ne $script:InlineAppxCommandsAvailable) {
        return [bool]$script:InlineAppxCommandsAvailable
    }

    if ($PSVersionTable.PSEdition -ne 'Desktop') {
        $script:InlineAppxCommandsAvailable = $false
        return $false
    }

    try {
        Import-Module Appx -ErrorAction Stop | Out-Null
        Get-Command Get-AppxPackage -ErrorAction Stop | Out-Null
        Get-Command Get-AppxProvisionedPackage -ErrorAction Stop | Out-Null
        $script:InlineAppxCommandsAvailable = $true
    } catch {
        $script:InlineAppxCommandsAvailable = $false
    }

    return [bool]$script:InlineAppxCommandsAvailable
}

function Invoke-AppxPatternOperationViaWindowsPowerShell {
    param(
        [string[]]$Patterns,
        [ValidateSet('Remove', 'Test')]
        [string]$Mode = 'Remove'
    )

    $patterns = @($Patterns | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($patterns.Count -eq 0) {
        if ($Mode -eq 'Test') {
            return [pscustomobject]@{ Exists = $false }
        }

        return [pscustomobject]@{
            RemovedInstalled   = @()
            RemovedProvisioned = @()
            Warnings           = @()
        }
    }

    $desktopPowerShellPath = Get-NativeSystemExecutablePath -FileName 'powershell.exe'
    $tempRoot = Join-Path $script:HunterRoot 'Temp'
    Initialize-HunterDirectory $tempRoot

    $operationId = [guid]::NewGuid().ToString('N')
    $patternsPath = Join-Path $tempRoot "appx-patterns-$operationId.json"
    $runnerPath = Join-Path $tempRoot "appx-runner-$operationId.ps1"

    try {
        @($patterns) | ConvertTo-Json -Depth 3 | Set-Content -Path $patternsPath -Encoding UTF8 -Force

        $runnerScript = @'
param(
    [Parameter(Mandatory)][string]$PatternsPath,
    [Parameter(Mandatory)][string]$Mode
)

$patterns = @((Get-Content -Path $PatternsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop))
$result = [ordered]@{
    Exists             = $false
    RemovedInstalled   = @()
    RemovedProvisioned = @()
    Warnings           = @()
}

$installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
$provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

foreach ($pattern in $patterns) {
    $matchingInstalled = @($installedPackages | Where-Object { $_.PSObject.Properties['Name'] -and $_.Name -like $pattern })
    $matchingProvisioned = @($provisionedPackages | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $pattern })

    if ($Mode -eq 'Test') {
        if ($matchingInstalled.Count -gt 0 -or $matchingProvisioned.Count -gt 0) {
            $result.Exists = $true
            break
        }

        continue
    }

    foreach ($package in $matchingInstalled) {
        try {
            Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
            $result.RemovedInstalled += @([string]$package.Name)
        } catch {
            $result.Warnings += @("Skipping installed AppX package $($package.Name): $($_.Exception.Message)")
        }
    }

    foreach ($package in $matchingProvisioned) {
        try {
            Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop | Out-Null
            $result.RemovedProvisioned += @([string]$package.DisplayName)
        } catch {
            $result.Warnings += @("Skipping built-in AppX provisioned package $($package.DisplayName): $($_.Exception.Message)")
        }
    }
}

$result | ConvertTo-Json -Depth 6 -Compress
'@

        Set-Content -Path $runnerPath -Value $runnerScript -Encoding UTF8 -Force
        $operationOutput = & $desktopPowerShellPath -NoProfile -ExecutionPolicy Bypass -File $runnerPath -PatternsPath $patternsPath -Mode $Mode 2>&1
        $operationExitCode = [int]$LASTEXITCODE
        $operationOutput = @($operationOutput)
        if ($operationExitCode -ne 0) {
            $operationMessage = [string]::Join(' ', @($operationOutput | ForEach-Object { [string]$_ })).Trim()
            if ([string]::IsNullOrWhiteSpace($operationMessage)) {
                $operationMessage = "$desktopPowerShellPath exited with code $operationExitCode"
            }

            throw $operationMessage
        }

        $operationJson = [string]::Join([Environment]::NewLine, @($operationOutput | ForEach-Object { [string]$_ })).Trim()
        if ([string]::IsNullOrWhiteSpace($operationJson)) {
            throw 'Desktop AppX helper did not return any JSON output.'
        }

        return ($operationJson | ConvertFrom-Json -ErrorAction Stop)
    } finally {
        Remove-Item -Path $patternsPath -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $runnerPath -Force -ErrorAction SilentlyContinue
    }
}

function Remove-AppxPatterns {
    param([string[]]$Patterns)
    $summary = [ordered]@{
        Success             = $true
        RemovedInstalled    = @()
        RemovedProvisioned  = @()
        Warnings            = @()
        Failures            = @()
    }
    if ($null -eq $Patterns -or $Patterns.Count -eq 0) { return [pscustomobject]$summary }

    if (-not (Test-CanUseInlineAppxCommands)) {
        try {
            $desktopResult = Invoke-AppxPatternOperationViaWindowsPowerShell -Patterns $Patterns -Mode Remove
            foreach ($removedPackageName in @($desktopResult.RemovedInstalled)) {
                Write-Log "AppX package removed: $removedPackageName"
                $summary.RemovedInstalled += @($removedPackageName)
            }

            foreach ($removedProvisionedName in @($desktopResult.RemovedProvisioned)) {
                Write-Log "AppX provisioned package removed: $removedProvisionedName"
                $summary.RemovedProvisioned += @($removedProvisionedName)
            }

            foreach ($warning in @($desktopResult.Warnings)) {
                Write-Log $warning 'WARN'
                $summary.Warnings += @($warning)
            }
        } catch {
            $failureMessage = "AppX package removal helper failed: $($_.Exception.Message)"
            Write-Log $failureMessage 'ERROR'
            $summary.Success = $false
            $summary.Failures += @($failureMessage)
        }

        return [pscustomobject]$summary
    }

    $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

    foreach ($pattern in $Patterns) {
        try {
            foreach ($package in @($installedPackages |
                    Where-Object { $_.PSObject.Properties['Name'] -and $_.Name -like $pattern })) {
                try {
                    Remove-AppxPackage -Package $package.PackageFullName -AllUsers -ErrorAction Stop
                    Write-Log "AppX package removed: $($package.Name)"
                    $summary.RemovedInstalled += @([string]$package.Name)
                } catch {
                    $errorMessage = $_.Exception.Message
                    if ($errorMessage -match '0x80070032|part of Windows and cannot be uninstalled|The request is not supported|The system cannot find the path specified|cannot find the file specified') {
                        $warningMessage = "Skipping built-in AppX package $($package.Name): $errorMessage"
                        Write-Log $warningMessage 'WARN'
                        $summary.Warnings += @($warningMessage)
                    } else {
                        $warningMessage = "Failed to remove AppX package $($package.Name) : $_"
                        Write-Log $warningMessage 'WARN'
                        $summary.Warnings += @($warningMessage)
                    }
                }
            }

            foreach ($package in @($provisionedPackages |
                    Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $pattern })) {
                try {
                    Remove-AppxProvisionedPackage -Online -PackageName $package.PackageName -ErrorAction Stop
                    Write-Log "AppX provisioned package removed: $($package.DisplayName)"
                    $summary.RemovedProvisioned += @([string]$package.DisplayName)
                } catch {
                    $errorMessage = $_.Exception.Message
                    if ($errorMessage -match '0x80070032|part of Windows and cannot be uninstalled|The request is not supported|The system cannot find the path specified|cannot find the file specified') {
                        $warningMessage = "Skipping built-in AppX provisioned package $($package.DisplayName): $errorMessage"
                        Write-Log $warningMessage 'WARN'
                        $summary.Warnings += @($warningMessage)
                    } else {
                        $warningMessage = "Failed to remove AppX provisioned package $($package.DisplayName) : $_"
                        Write-Log $warningMessage 'WARN'
                        $summary.Warnings += @($warningMessage)
                    }
                }
            }
        } catch {
            $failureMessage = "Failed to process AppX pattern $pattern : $_"
            Write-Log $failureMessage 'ERROR'
            $summary.Success = $false
            $summary.Failures += @($failureMessage)
        }
    }

    return [pscustomobject]$summary
}

function Test-AppxPatternExists {
    param([string[]]$Patterns)

    if ($null -eq $Patterns -or $Patterns.Count -eq 0) {
        return $false
    }

    if (-not (Test-CanUseInlineAppxCommands)) {
        try {
            $desktopResult = Invoke-AppxPatternOperationViaWindowsPowerShell -Patterns $Patterns -Mode Test
            return [bool]$desktopResult.Exists
        } catch {
            Write-Log "Failed to query AppX patterns via desktop helper: $($_.Exception.Message)" 'WARN'
            return $false
        }
    }

    $installedPackages = @(Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue)
    $provisionedPackages = @(Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue)

    foreach ($pattern in @($Patterns)) {
        if (@($installedPackages | Where-Object { $_.PSObject.Properties['Name'] -and $_.Name -like $pattern }).Count -gt 0) {
            return $true
        }
        if (@($provisionedPackages | Where-Object { $_.PSObject.Properties['DisplayName'] -and $_.DisplayName -like $pattern }).Count -gt 0) {
            return $true
        }
    }

    return $false
}

