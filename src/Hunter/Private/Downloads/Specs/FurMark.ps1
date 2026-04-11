function Get-FurMarkDownloadSpec {
    return @{
        Url            = $script:FurMarkDownloadUrl
        FileName       = $script:FurMarkDownloadFileName
        ExpectedSha256 = $script:FurMarkSha256
    }
}

function Get-FurMarkExecutablePath {
    return (Resolve-CachedExecutablePath -CacheKey 'furmark' -RetryDelaySeconds 10 -Resolver {
        Find-FirstExistingPath -CandidatePaths @(
            'C:\Program Files (x86)\Geeks3D\Benchmarks\FurMark\FurMark.exe',
            'C:\Program Files\Geeks3D\Benchmarks\FurMark\FurMark.exe',
            'C:\Program Files (x86)\Geeks3D\FurMark 2\FurMark.exe',
            'C:\Program Files\Geeks3D\FurMark 2\FurMark.exe',
            'C:\Program Files (x86)\Geeks3D\FurMark\FurMark.exe',
            'C:\Program Files\Geeks3D\FurMark\FurMark.exe',
            (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\FurMark.lnk')),
            (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'FurMark*.exe' -and $_.FullName -match 'FurMark|Geeks3D' } |
                Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like 'FurMark*.exe' -and $_.FullName -match 'FurMark|Geeks3D' } |
                Select-Object -First 1 -ExpandProperty FullName),
            (Get-ChildItem -Path 'C:\Program Files', 'C:\Program Files (x86)' -Recurse -File -Filter 'FurMark.exe' -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match 'FurMark|Geeks3D' } |
                Select-Object -First 1 -ExpandProperty FullName)
        )
    })
}

Register-HunterTool -Name 'FurMark' `
    -DownloadSpec { Get-FurMarkDownloadSpec } `
    -ExecutablePath { Get-FurMarkExecutablePath }
