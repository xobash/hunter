function Get-YtDlpDownloadSpec {
    return @{
        Url      = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
        FileName = 'yt-dlp.exe'
    }
}

function Get-YtDlpExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        (Join-Path $script:HunterRoot 'Tools\yt-dlp\yt-dlp.exe'),
        (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -File -Filter 'yt-dlp.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
        (Get-Command yt-dlp.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ))
}

Register-HunterTool -Name 'YtDlp' `
    -DownloadSpec { Get-YtDlpDownloadSpec } `
    -ExecutablePath { Get-YtDlpExecutablePath }
