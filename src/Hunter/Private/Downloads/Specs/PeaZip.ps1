function Get-PeaZipDownloadSpec {
    $existingSpec = Get-Variable -Scope Script -Name 'PeaZipDownloadSpec' -ErrorAction SilentlyContinue
    if ($null -ne $existingSpec -and $null -ne $existingSpec.Value) {
        return $script:PeaZipDownloadSpec
    }

    try {
        $script:PeaZipDownloadSpec = Get-GitHubLatestReleaseAsset `
            -Owner 'peazip' `
            -Repo 'PeaZip' `
            -NamePatterns @(
                '^peazip-.*\.win64\.exe$',
                '^peazip-.*\.windows\.x64\.exe$'
            )
    } catch {
        Write-Log "Falling back to pinned PeaZip release asset: $_" 'WARN'
        $script:PeaZipDownloadSpec = @{
            Url      = 'https://github.com/peazip/PeaZip/releases/latest/download/peazip-10.9.0.WIN64.exe'
            FileName = 'peazip-10.9.0.WIN64.exe'
        }
    }

    return $script:PeaZipDownloadSpec
}

function Get-PeaZipExecutablePath {
    return (Find-FirstExistingPath -CandidatePaths @(
        'C:\Program Files\PeaZip\peazip.exe',
        'C:\Program Files (x86)\PeaZip\peazip.exe',
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\PeaZip.lnk')),
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'peazip.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'PeaZip' } |
            Select-Object -First 1 -ExpandProperty FullName)
    ))
}

Register-HunterTool -Name 'PeaZip' `
    -DownloadSpec { Get-PeaZipDownloadSpec } `
    -ExecutablePath { Get-PeaZipExecutablePath }
