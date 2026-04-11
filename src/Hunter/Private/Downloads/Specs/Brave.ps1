function Get-BraveDownloadSpec {
    return @{
        Url      = 'https://laptop-updates.brave.com/latest/winx64'
        FileName = 'BraveSetup.exe'
    }
}

function Get-BraveExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\Application\brave.exe",
        "$env:LOCALAPPDATA\Programs\BraveSoftware\Brave-Browser\Application\brave.exe",
        'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
        'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
        (Get-Command brave.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue)
    ))
}

Register-HunterTool -Name 'Brave' `
    -DownloadSpec { Get-BraveDownloadSpec } `
    -ExecutablePath { Get-BraveExecutablePath } `
    -PostInstall { Invoke-BraveDebloat }
