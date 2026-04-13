function Invoke-WingetUninstallBestEffort {
    param(
        [Parameter(Mandatory)][string]$WingetId,
        [Parameter(Mandatory)][string]$FriendlyName
    )

    if ($null -eq (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Log "Skipping WinGet uninstall for $FriendlyName because winget is unavailable." 'WARN'
        return $false
    }

    try {
        $exitCode = Invoke-WingetWithMutex -Arguments @(
            'uninstall',
            '--id', $WingetId,
            '-e',
            '--accept-source-agreements',
            '--disable-interactivity'
        )

        if ([int]$exitCode -eq 0) {
            Write-Log "WinGet uninstall succeeded for $FriendlyName via id '$WingetId'." 'INFO'
            return $true
        }

        Write-Log "WinGet uninstall for ${FriendlyName} via id '$WingetId' exited with code ${exitCode}." 'WARN'
        return $false
    } catch {
        Write-Log "Skipping WinGet uninstall for $FriendlyName via id '$WingetId': $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Invoke-ApplyAppRemovalStrategies {
    param([object[]]$Entries)

    $completedWithWarnings = $false
    $completedWithFailures = $false
    foreach ($entry in @($Entries)) {
        if ($null -eq $entry) {
            continue
        }

        $friendlyName = [string]$entry.FriendlyName
        $manualRestoreInstructions = New-Object 'System.Collections.Generic.List[string]'
        $wingetIds = New-Object 'System.Collections.Generic.List[string]'
        foreach ($strategy in @($entry.RemovalStrategies)) {
            if ([string]$strategy.Type -eq 'Winget') {
                foreach ($wingetId in @($strategy.Ids)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$wingetId)) {
                        [void]$wingetIds.Add([string]$wingetId)
                    }
                }
            }
        }

        if ($wingetIds.Count -gt 0) {
            foreach ($wingetId in @($wingetIds | Select-Object -Unique)) {
                [void]$manualRestoreInstructions.Add("Restore ${friendlyName} with: winget install --id $wingetId -e")
            }
        } else {
            [void]$manualRestoreInstructions.Add("Restore ${friendlyName} from Microsoft Store or reinstall the matching AppX package if you want it back.")
        }

        if (@($entry.AppIds).Count -gt 0) {
            [void]$manualRestoreInstructions.Add("Known package identifiers for ${friendlyName}: $((@($entry.AppIds) | ForEach-Object { [string]$_ }) -join ', ')")
        }

        Register-HunterManualRestoreNote `
            -Key ('manual-app-restore|{0}' -f ([string]$entry.Id).ToLowerInvariant()) `
            -Description ("Manual restore note for app removal: {0}" -f $friendlyName) `
            -Instructions @($manualRestoreInstructions)

        Write-Log "Applying surgical app removal target: $friendlyName" 'INFO'
        $entryAttemptedStrategy = $false
        $entryConfirmedStrategy = $false
        foreach ($strategy in @($entry.RemovalStrategies)) {
            switch ([string]$strategy.Type) {
                'Winget' {
                    foreach ($wingetId in @($strategy.Ids)) {
                        if ([string]::IsNullOrWhiteSpace([string]$wingetId)) {
                            continue
                        }

                        $entryAttemptedStrategy = $true
                        if (Invoke-WingetUninstallBestEffort -WingetId ([string]$wingetId) -FriendlyName $friendlyName) {
                            $entryConfirmedStrategy = $true
                        } else {
                            $completedWithWarnings = $true
                        }
                    }
                }
                'AppxPattern' {
                    $entryAttemptedStrategy = $true
                    if ($null -ne $strategy.PSObject.Properties['PatternJustification'] -and
                        -not [string]::IsNullOrWhiteSpace([string]$strategy.PatternJustification)) {
                        Write-Log "Wildcard AppX match rationale for ${friendlyName}: $([string]$strategy.PatternJustification)" 'INFO'
                    }

                    $appxResult = Remove-AppxPatterns -Patterns @($strategy.Patterns)
                    if ($null -ne $appxResult) {
                        if ([bool]$appxResult.Success) {
                            $entryConfirmedStrategy = $true
                        } else {
                            $completedWithFailures = $true
                        }

                        if (@($appxResult.Warnings).Count -gt 0) {
                            $completedWithWarnings = $true
                        }

                        if (@($appxResult.Failures).Count -gt 0) {
                            $completedWithFailures = $true
                        }
                    }
                }
            }
        }

        if ($entryAttemptedStrategy -and -not $entryConfirmedStrategy) {
            Write-Log "Hunter could not confirm removal for ${friendlyName}; one or more best-effort strategies failed or returned warnings." 'WARN'
            $completedWithWarnings = $true
        }
    }

    if ($completedWithFailures) {
        return @{
            Success = $false
            Status  = 'Failed'
            Reason  = 'One or more surgical app removal operations failed'
        }
    }

    if ($completedWithWarnings) {
        return (New-TaskWarningResult -Reason 'One or more surgical app removal operations completed with warnings')
    }

    return @{
        Success = $true
        Status  = 'Completed'
        Reason  = ''
    }
}
