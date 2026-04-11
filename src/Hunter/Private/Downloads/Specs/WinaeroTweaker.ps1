function Get-WinaeroTweakerDownloadSpec {
    return @{
        Url      = 'https://winaerotweaker.com/download/winaerotweaker.zip'
        FileName = 'WinaeroTweaker.zip'
    }
}

function Get-WinaeroTweakerExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        (Join-Path $script:HunterRoot 'Packages\Winaero-Tweaker\Winaero Tweaker.exe'),
        (Join-Path $script:HunterRoot 'Packages\Winaero-Tweaker\WinaeroTweaker.exe'),
        (Get-ChildItem -Path (Join-Path $script:HunterRoot 'Packages') -Recurse -File -Filter 'Winaero*.exe' -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName)
    ))
}

Register-HunterTool -Name 'WinaeroTweaker' `
    -DownloadSpec { Get-WinaeroTweakerDownloadSpec } `
    -ExecutablePath { Get-WinaeroTweakerExecutablePath }
