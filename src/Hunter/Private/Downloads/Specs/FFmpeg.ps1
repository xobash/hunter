function Get-FFmpegDownloadSpec {
    return @{
        Url      = 'https://www.gyan.dev/ffmpeg/builds/ffmpeg-release-essentials.zip'
        FileName = 'ffmpeg-release-essentials.zip'
    }
}

function Get-FFmpegExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        (Join-Path $script:HunterRoot 'Tools\FFmpeg\ffmpeg.exe'),
        (Join-Path $script:HunterRoot 'Packages\FFmpeg\ffmpeg.exe'),
        (Get-Command ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -File -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path $script:HunterRoot -Recurse -File -Filter 'ffmpeg.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
    ))
}

Register-HunterTool -Name 'FFmpeg' `
    -DownloadSpec { Get-FFmpegDownloadSpec } `
    -ExecutablePath { Get-FFmpegExecutablePath }
