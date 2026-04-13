function Get-TcpOptimizerDownloadPath {
    return (Join-Path $script:DownloadDir 'TCPOptimizer.exe')
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }

    if (-not (Test-Path $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }

    return $true
}

function Get-OOSUDownloadPath {
    return (Join-Path $script:DownloadDir 'OOSU10.exe')
}

function Get-OOSUConfigPath {
    return (Join-Path $script:HunterRoot 'ooshutup10_winutil_settings.cfg')
}

function Get-ResolvedWallpaperAssetUrl {
    if (-not [string]::IsNullOrWhiteSpace($script:ResolvedWallpaperAssetUrl)) {
        return $script:ResolvedWallpaperAssetUrl
    }

    $script:ResolvedWallpaperAssetUrl = Resolve-WallpaperAssetUrl
    return $script:ResolvedWallpaperAssetUrl
}

function Get-WallpaperAssetPath {
    param([string]$WallpaperUrl = (Get-ResolvedWallpaperAssetUrl))

    if ([string]::IsNullOrWhiteSpace($WallpaperUrl)) {
        return $null
    }

    $wallpaperRoot = Join-Path $script:HunterRoot 'Assets'
    Ensure-Directory $wallpaperRoot

    $wallpaperExtension = [System.IO.Path]::GetExtension(([uri]$WallpaperUrl).AbsolutePath)
    if ([string]::IsNullOrWhiteSpace($wallpaperExtension)) {
        $wallpaperExtension = '.jpg'
    }

    return (Join-Path $wallpaperRoot "hunter-wallpaper$wallpaperExtension")
}

function Get-InstalledSystemMemoryBytes {
    try {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        if ($null -ne $computerSystem -and $null -ne $computerSystem.TotalPhysicalMemory) {
            return [uint64]$computerSystem.TotalPhysicalMemory
        }
    } catch {
        Write-Log "Failed to query installed system memory: $($_.Exception.Message)" 'WARN'
    }

    return [uint64]0
}

function Get-DesiredLargeSystemCacheValue {
    $installedMemoryBytes = Get-InstalledSystemMemoryBytes
    if ($installedMemoryBytes -le 0) {
        Write-Log 'Installed system memory could not be determined; defaulting LargeSystemCache to 1.' 'WARN'
        return 1
    }

    $installedMemoryGiB = [Math]::Round(($installedMemoryBytes / 1GB), 2)
    $desiredValue = if ($installedMemoryBytes -lt 16GB) { 1 } else { 0 }
    Write-Log "Installed RAM detected: ${installedMemoryGiB} GiB. LargeSystemCache target = $desiredValue" 'INFO'
    return $desiredValue
}

function Get-FixedPageFileSizeMegabytes {
    $installedMemoryBytes = Get-InstalledSystemMemoryBytes
    if ($installedMemoryBytes -le 0) {
        Write-Log 'Installed system memory could not be determined; pagefile sizing will be skipped.' 'WARN'
        return 0
    }

    return [int][Math]::Ceiling(($installedMemoryBytes / 1MB) * 1.5)
}
