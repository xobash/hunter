function Get-CrystalDiskMarkDownloadSpec {
    return @{
        Url      = 'https://sourceforge.net/projects/crystaldiskmark/files/latest/download'
        FileName = 'CrystalDiskMarkSetup.exe'
    }
}

function Get-CrystalDiskMarkExecutablePath {
    return (Resolve-CachedExecutablePath -CacheKey 'crystaldiskmark' -RetryDelaySeconds 10 -Resolver {
        Find-FirstExistingPath -CandidatePaths @(
            'C:\Program Files\CrystalDiskMark\DiskMark64.exe',
            'C:\Program Files\CrystalDiskMark\CrystalDiskMark.exe',
            'C:\Program Files\CrystalDiskMark8\DiskMark64.exe',
            'C:\Program Files\CrystalDiskMark8\CrystalDiskMark.exe',
            'C:\Program Files\CrystalDiskMark9\DiskMark64.exe',
            'C:\Program Files\CrystalDiskMark9\CrystalDiskMark.exe',
            'C:\Program Files (x86)\CrystalDiskMark\DiskMark64.exe',
            'C:\Program Files (x86)\CrystalDiskMark\CrystalDiskMark.exe',
            (Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -File -Filter 'DiskMark64.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
        )
    })
}

Register-HunterTool -Name 'CrystalDiskMark' `
    -DownloadSpec { Get-CrystalDiskMarkDownloadSpec } `
    -ExecutablePath { Get-CrystalDiskMarkExecutablePath }
