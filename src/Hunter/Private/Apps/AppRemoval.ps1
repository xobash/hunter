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

        Write-Log "Applying surgical app removal target: $([string]$entry.FriendlyName)" 'INFO'
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
                        if (Invoke-WingetUninstallBestEffort -WingetId ([string]$wingetId) -FriendlyName ([string]$entry.FriendlyName)) {
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
                        Write-Log "Wildcard AppX match rationale for $([string]$entry.FriendlyName): $([string]$strategy.PatternJustification)" 'INFO'
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
            Write-Log "Hunter could not confirm removal for $([string]$entry.FriendlyName); one or more best-effort strategies failed or returned warnings." 'WARN'
            $completedWithWarnings = $true
        }
    }

    if ($completedWithFailures) {
        return $false
    }

    if ($completedWithWarnings) {
        return (New-TaskWarningResult -Reason 'One or more surgical app removal operations completed with warnings')
    }

    return $true
}
