function Get-SteamDownloadSpec {
    return @{
        Url      = 'https://cdn.akamai.steamstatic.com/client/installer/SteamSetup.exe'
        FileName = 'SteamSetup.exe'
    }
}

function Get-SteamExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        'C:\Program Files (x86)\Steam\steam.exe',
        'C:\Program Files\Steam\steam.exe'
    ))
}

Register-HunterTool -Name 'Steam' `
    -DownloadSpec { Get-SteamDownloadSpec } `
    -ExecutablePath { Get-SteamExecutablePath }
