function Get-ParsecDownloadSpec {
    return @{
        Url      = 'https://builds.parsec.app/package/parsec-windows.exe'
        FileName = 'ParsecSetup.exe'
    }
}

function Get-ParsecExecutablePath {
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'Parsec\parsecd.exe'),
        (Join-Path $env:ProgramFiles 'Parsec\parsec.exe'),
        (Join-Path $env:ProgramFiles 'Parsec\bin\parsecd.exe'),
        (Join-Path $env:ProgramFiles 'Parsec\bin\parsec.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\parsecd.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\parsec.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\bin\parsecd.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Parsec\bin\parsec.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Parsec\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Parsec\parsec.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\parsec.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\bin\parsecd.exe'),
        (Join-Path $env:LOCALAPPDATA 'Parsec\bin\parsec.exe'),
        (Join-Path $env:APPDATA 'Parsec\parsecd.exe'),
        (Join-Path $env:APPDATA 'Parsec\parsec.exe'),
        (Join-Path $env:APPDATA 'Parsec\bin\parsecd.exe'),
        (Join-Path $env:APPDATA 'Parsec\bin\parsec.exe'),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Parsec\Parsec.lnk')),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Parsec\Parsec.lnk')),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Parsec.lnk')),
        (Get-ShortcutTargetPath -ShortcutPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Parsec.lnk')),
        (Find-ShortcutTargetByPattern -Directories (Get-StartMenuShortcutDirectories) -Patterns @('Parsec*.lnk')),
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'parsecd.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Parsec' } |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'Microsoft\WinGet\Packages') -Recurse -File -Filter 'parsec.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Parsec' } |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path @(
                (Join-Path $env:ProgramFiles 'Parsec'),
                (Join-Path ${env:ProgramFiles(x86)} 'Parsec'),
                (Join-Path $env:LOCALAPPDATA 'Parsec'),
                (Join-Path $env:APPDATA 'Parsec')
            ) -Recurse -File -Filter 'parsecd.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName),
        (Get-ChildItem -Path @(
                (Join-Path $env:ProgramFiles 'Parsec'),
                (Join-Path ${env:ProgramFiles(x86)} 'Parsec'),
                (Join-Path $env:LOCALAPPDATA 'Parsec'),
                (Join-Path $env:APPDATA 'Parsec')
            ) -Recurse -File -Filter 'parsec.exe' -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty FullName)
    )

    return (Find-FirstExistingPath -CandidatePaths $candidatePaths)
}

Register-HunterTool -Name 'Parsec' `
    -DownloadSpec { Get-ParsecDownloadSpec } `
    -ExecutablePath { Get-ParsecExecutablePath }
