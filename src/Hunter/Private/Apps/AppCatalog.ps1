function Get-HunterEffectiveCustomAppsListPath {
    if (-not [string]::IsNullOrWhiteSpace($script:CustomAppsListPathOverride)) {
        return $script:CustomAppsListPathOverride
    }

    if (-not [string]::IsNullOrWhiteSpace($env:HUNTER_CUSTOM_APPS_LIST)) {
        return $env:HUNTER_CUSTOM_APPS_LIST
    }

    return $script:CustomAppsListPath
}

function Get-HunterAppRemovalCatalog {
    if ($null -ne $script:AppRemovalCatalog) {
        return $script:AppRemovalCatalog
    }

    if ([string]::IsNullOrWhiteSpace($script:AppRemovalCatalogPath) -or -not (Test-Path $script:AppRemovalCatalogPath)) {
        throw "App removal catalog is unavailable at $($script:AppRemovalCatalogPath)"
    }

    try {
        $script:AppRemovalCatalog = Get-Content -Path $script:AppRemovalCatalogPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        return $script:AppRemovalCatalog
    } catch {
        throw "Failed to load app removal catalog: $($_.Exception.Message)"
    }
}

function Test-HunterProtectedAppSelection {
    param([Parameter(Mandatory)][string]$Selection)

    $normalizedSelection = $Selection.Trim().Trim('*')
    if ([string]::IsNullOrWhiteSpace($normalizedSelection)) {
        return $false
    }

    foreach ($protectedApp in @((Get-HunterAppRemovalCatalog).ProtectedApps)) {
        if ([string]$protectedApp.FriendlyName -eq $normalizedSelection) {
            return $true
        }

        foreach ($appId in @($protectedApp.AppIds)) {
            if ([string]$appId -eq $normalizedSelection) {
                return $true
            }
        }
    }

    return $false
}

function Test-HunterAppCatalogEntryMatchesSelection {
    param(
        [Parameter(Mandatory)][object]$Entry,
        [Parameter(Mandatory)][string]$Selection
    )

    $normalizedSelection = $Selection.Trim().Trim('*')
    if ([string]::IsNullOrWhiteSpace($normalizedSelection)) {
        return $false
    }

    if ([string]$Entry.Id -eq $normalizedSelection) {
        return $true
    }

    if ([string]$Entry.FriendlyName -eq $normalizedSelection) {
        return $true
    }

    foreach ($appId in @($Entry.AppIds)) {
        if ([string]$appId -eq $normalizedSelection) {
            return $true
        }
    }

    return $false
}

function Resolve-HunterAppCatalogEntries {
    param(
        [string[]]$Groups = @(),
        [string[]]$Selections = @(),
        [switch]$SelectedByDefaultOnly
    )

    $catalog = Get-HunterAppRemovalCatalog
    $entries = @($catalog.Apps | Where-Object {
        Test-WindowsBuildInRange -MinBuild $_.MinBuild -MaxBuild $_.MaxBuild
    })

    if ($Groups.Count -gt 0) {
        $groupSet = @($Groups | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $entries = @($entries | Where-Object { [string]$_.Group -in $groupSet })
    }

    if ($SelectedByDefaultOnly) {
        $entries = @($entries | Where-Object { [bool]$_.SelectedByDefault })
    }

    if ($Selections.Count -eq 0) {
        return @($entries)
    }

    $resolvedEntries = New-Object 'System.Collections.Generic.List[object]'
    foreach ($selection in @($Selections | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })) {
        $matchingEntries = @($entries | Where-Object { Test-HunterAppCatalogEntryMatchesSelection -Entry $_ -Selection ([string]$selection) })
        foreach ($matchingEntry in $matchingEntries) {
            if (-not ($resolvedEntries | Where-Object { [string]$_.Id -eq [string]$matchingEntry.Id })) {
                [void]$resolvedEntries.Add($matchingEntry)
            }
        }
    }

    return @($resolvedEntries.ToArray())
}

function Load-HunterCustomAppsList {
    $appsListPath = Get-HunterEffectiveCustomAppsListPath
    if ([string]::IsNullOrWhiteSpace($appsListPath) -or -not (Test-Path $appsListPath)) {
        return @()
    }

    $rawSelections = @()
    try {
        if ($appsListPath -like '*.json') {
            $jsonContent = Get-Content -Path $appsListPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            foreach ($appData in @($jsonContent.Apps)) {
                $appIds = if ($appData.AppId -is [array]) { @($appData.AppId) } else { @($appData.AppId) }
                if (-not [bool]$appData.SelectedByDefault) {
                    continue
                }

                foreach ($appId in @($appIds)) {
                    if (-not [string]::IsNullOrWhiteSpace([string]$appId)) {
                        $rawSelections += [string]$appId
                    }
                }
            }
        } else {
            foreach ($line in @(Get-Content -Path $appsListPath -ErrorAction Stop)) {
                $selection = [string]$line
                if ($selection -match '^\s*#' -or [string]::IsNullOrWhiteSpace($selection)) {
                    continue
                }

                if ($selection.Contains('#')) {
                    $selection = $selection.Substring(0, $selection.IndexOf('#'))
                }

                $selection = $selection.Trim().Trim('*')
                if (-not [string]::IsNullOrWhiteSpace($selection)) {
                    $rawSelections += $selection
                }
            }
        }
    } catch {
        Write-Log "Failed to read custom apps list at $appsListPath: $($_.Exception.Message)" 'WARN'
        return @()
    }

    $validatedSelections = New-Object 'System.Collections.Generic.List[string]'
    foreach ($selection in @($rawSelections | Select-Object -Unique)) {
        if (Test-HunterProtectedAppSelection -Selection $selection) {
            Write-Log "Custom apps list entry '$selection' targets a protected app and will be skipped." 'WARN'
            continue
        }

        $matchingEntries = Resolve-HunterAppCatalogEntries -Selections @($selection)
        if ($matchingEntries.Count -eq 0) {
            Write-Log "Custom apps list entry '$selection' is not supported by Hunter and will be skipped." 'WARN'
            continue
        }

        [void]$validatedSelections.Add([string]$selection)
    }

    if ($validatedSelections.Count -gt 0) {
        Write-Log "Loaded custom apps list from $appsListPath with $($validatedSelections.Count) validated selection(s)." 'INFO'
    }

    return @($validatedSelections.ToArray())
}

function Invoke-ValidateSupportedWindowsEdition {
    try {
        $editionContext = Get-WindowsEditionContext
        $editionSummary = (@(
            [string]$editionContext.ProductName,
            [string]$editionContext.EditionId,
            [string]$editionContext.InstallationType
        ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' | '

        if ([string]::IsNullOrWhiteSpace($editionSummary)) {
            $editionSummary = 'Unknown edition'
        }

        if (-not $editionContext.IsSupportedConsumerEdition) {
            $script:IsUnsupportedEdition = $true
            $script:SkipStoreAndAppxTasks = $true
            Write-Log "Unsupported Windows edition detected: $editionSummary. Hunter is designed for consumer Home/Pro-style installs; Store/AppX consumer-removal tasks will be skipped." 'WARN'
            return @{
                Success = $true
                Status  = 'CompletedWithWarnings'
                Reason  = 'Unsupported Windows edition detected; Store/AppX consumer tasks will be skipped'
            }
        }

        $script:IsUnsupportedEdition = $false
        $script:SkipStoreAndAppxTasks = $false
        Write-Log "Windows edition compatibility check passed: $editionSummary" 'INFO'
        return $true
    } catch {
        Write-Log "Failed to validate Windows edition compatibility: $($_.Exception.Message)" 'WARN'
        return @{
            Success = $true
            Status  = 'CompletedWithWarnings'
            Reason  = 'Windows edition compatibility could not be verified'
        }
    }
}

