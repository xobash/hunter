function Get-CinebenchR23ExecutablePath {
    return (Resolve-CachedExecutablePath -CacheKey 'cinebench-r23' -RetryDelaySeconds 10 -Resolver {
        $candidatePaths = @(
            (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps') -File -Filter 'Cinebench*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path 'C:\Program Files\WindowsApps' -Directory -Filter 'Maxon.Cinebench*' -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem -Path $_.FullName -Recurse -File -Filter 'Cinebench*.exe' -ErrorAction SilentlyContinue } |
                Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'Cinebench*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
            'C:\Program Files\Maxon Cinema 4D\Cinebench.exe',
            'C:\Program Files\Maxon Cinema 4D\CinebenchR23\Cinebench.exe',
            'C:\Program Files\Maxon\CinebenchR23\Cinebench.exe'
        )

        return (Find-FirstExistingPath -CandidatePaths $candidatePaths)
    })
}

function Test-IsLegacyHunterCinebenchPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    $legacyRoot = Join-Path $script:HunterRoot 'Packages\Cinebench-R23'
    return $Path.StartsWith($legacyRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function Remove-LegacyHunterCinebenchPayload {
    $legacyRoot = Join-Path $script:HunterRoot 'Packages\Cinebench-R23'
    if (-not (Test-Path $legacyRoot)) {
        return
    }

    try {
        Remove-Item -Path $legacyRoot -Recurse -Force -ErrorAction Stop
        Write-Log 'Removed legacy Hunter Cinebench ZIP payload so the Microsoft Store Cinebench install can take precedence.' 'INFO'
    } catch {
        Write-Log "Failed to remove legacy Hunter Cinebench payload: $($_.Exception.Message)" 'WARN'
    }
}

Register-HunterTool -Name 'CinebenchR23' `
    -ExecutablePath { Get-CinebenchR23ExecutablePath }
