function Register-ResumeTask {
    <#
    .SYNOPSIS
        Registers a Windows scheduled task for Hunter resume on logon.

    .DESCRIPTION
        Creates a scheduled task named 'Hunter-Resume' that automatically runs
        the script with -Mode Resume on system logon, enabling recovery from
        mid-operation reboots.
    #>

    try {
        if ($script:IsAutomationRun) {
            Write-Log "Automation-safe mode enabled; skipping resume task registration." 'INFO'
            return
        }

        $scriptPath = $MyInvocation.ScriptName
        $resumeCustomAppsListPath = $null
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }

        if (-not $scriptPath) {
            if (-not [string]::IsNullOrWhiteSpace($script:SelfScriptContent)) {
                Initialize-HunterDirectory (Split-Path -Parent $script:ResumeScriptPath)
                Set-Content -Path $script:ResumeScriptPath -Value $script:SelfScriptContent -Force
                $resumeSupportPaths = @(
                    Get-HunterPrivateAssetManifest |
                        Where-Object { $_.RelativePath -ne 'src\Hunter\Private\Bootstrap\Loader.ps1' } |
                        Sort-Object Order, RelativePath |
                        ForEach-Object { [string]$_.RelativePath }
                )
                $resumeSupportRoot = if (-not [string]::IsNullOrWhiteSpace($script:HunterSourceRoot)) {
                    $script:HunterSourceRoot
                } elseif (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
                    $PSScriptRoot
                } else {
                    throw "Could not determine Hunter support root for resume task registration."
                }
                $resumeRoot = Split-Path -Parent $script:ResumeScriptPath
                foreach ($resumeSupportRelativePath in $resumeSupportPaths) {
                    $resumeSupportSourcePath = Join-Path $resumeSupportRoot $resumeSupportRelativePath
                    $resumeSupportDestinationPath = Join-Path $resumeRoot $resumeSupportRelativePath
                    Initialize-HunterDirectory (Split-Path -Parent $resumeSupportDestinationPath)
                    Copy-Item -Path $resumeSupportSourcePath -Destination $resumeSupportDestinationPath -Force -ErrorAction Stop
                }

                $effectiveCustomAppsListPath = Get-HunterEffectiveCustomAppsListPath
                if (-not [string]::IsNullOrWhiteSpace($effectiveCustomAppsListPath) -and (Test-Path $effectiveCustomAppsListPath)) {
                    $resumeCustomAppsListExtension = [System.IO.Path]::GetExtension($effectiveCustomAppsListPath)
                    if ([string]::IsNullOrWhiteSpace($resumeCustomAppsListExtension)) {
                        $resumeCustomAppsListExtension = '.txt'
                    }

                    $resumeCustomAppsListPath = Join-Path $resumeRoot ("CustomAppsList{0}" -f $resumeCustomAppsListExtension)
                    Copy-Item -Path $effectiveCustomAppsListPath -Destination $resumeCustomAppsListPath -Force -ErrorAction Stop
                }

                $scriptPath = $script:ResumeScriptPath
            } else {
                throw "Could not determine script path for resume task registration."
            }
        }

        $resumeActionArguments = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode Resume"
        if (-not [string]::IsNullOrWhiteSpace($resumeCustomAppsListPath)) {
            $resumeActionArguments += " -CustomAppsListPath `"$resumeCustomAppsListPath`""
        } elseif (-not [string]::IsNullOrWhiteSpace($script:CustomAppsListPathOverride)) {
            $resumeActionArguments += " -CustomAppsListPath `"$($script:CustomAppsListPathOverride)`""
        }

        if ($script:SkipTaskIds.Count -gt 0) {
            $resumeActionArguments += " -SkipTask `"$((@($script:SkipTaskIds | Select-Object -Unique) -join ','))`""
        }
        if ($script:DisableIPv6Requested) {
            $resumeActionArguments += ' -DisableIPv6'
        }
        if ($script:DisableTeredoRequested) {
            $resumeActionArguments += ' -DisableTeredo'
        }
        if ($script:DisableHagsRequested) {
            $resumeActionArguments += ' -DisableHags'
        }

        $action = New-ScheduledTaskAction -Execute 'powershell.exe' `
            -Argument $resumeActionArguments

        $trigger = New-ScheduledTaskTrigger -AtLogOn

        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries

        $principal = New-ScheduledTaskPrincipal `
            -UserId 'SYSTEM' `
            -LogonType ServiceAccount `
            -RunLevel Highest

        Register-ScheduledTask `
            -TaskName 'Hunter-Resume' `
            -Action $action `
            -Trigger $trigger `
            -Settings $settings `
            -Principal $principal `
            -Force | Out-Null

        Write-Log "Resume scheduled task registered: Hunter-Resume" 'SUCCESS'

    } catch {
        Write-Log "Error registering resume task: $_" 'ERROR'
        throw
    }
}


function Unregister-ResumeTask {
    <#
    .SYNOPSIS
        Removes the Hunter resume scheduled task.

    .DESCRIPTION
        Deletes the 'Hunter-Resume' scheduled task when script execution
        completes successfully (no pending reboot needed).
    #>

    try {
        if ($script:IsAutomationRun) {
            Write-Log "Automation-safe mode enabled; skipping resume task cleanup." 'INFO'
            return
        }

        $existingTask = Get-ScheduledTask -TaskName 'Hunter-Resume' -ErrorAction SilentlyContinue
        if ($null -eq $existingTask) {
            Write-Log "Resume scheduled task was already absent" 'INFO'
            return $true
        }

        Unregister-ScheduledTask -TaskName 'Hunter-Resume' `
            -Confirm:$false `
            -ErrorAction Stop

        $remainingTask = Get-ScheduledTask -TaskName 'Hunter-Resume' -ErrorAction SilentlyContinue
        if ($null -ne $remainingTask) {
            Add-RunInfrastructureIssue -Message 'Hunter-Resume scheduled task still exists after cleanup was requested.' -Level 'ERROR'
            return $false
        }

        Write-Log "Resume scheduled task unregistered" 'INFO'
        return $true

    } catch {
        Add-RunInfrastructureIssue -Message "Error unregistering resume task: $($_.Exception.Message)" -Level 'ERROR'
        return $false
    }
}
