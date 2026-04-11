function Get-PowerShell7DownloadSpec {
    try {
        return (Get-GitHubLatestReleaseAsset `
            -Owner 'PowerShell' `
            -Repo 'PowerShell' `
            -NamePatterns @('^PowerShell-.*-win-x64\.msi$'))
    } catch {
        Write-Log "Falling back to pinned PowerShell 7 release asset: $_" 'WARN'
        return @{
            Url      = 'https://github.com/PowerShell/PowerShell/releases/download/v7.5.4/PowerShell-7.5.4-win-x64.msi'
            FileName = 'PowerShell-7.5.4-win-x64.msi'
        }
    }
}

function Get-PowerShell7ExecutablePath {
    $command = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    return (Find-FirstExistingPath -CandidatePaths @(
        $(if ($PSVersionTable.PSEdition -eq 'Core' -and $PSVersionTable.PSVersion.Major -ge 7) { Join-Path $PSHOME 'pwsh.exe' } else { $null }),
        'C:\Program Files\PowerShell\7\pwsh.exe',
        'C:\Program Files\PowerShell\pwsh.exe',
        $(if ($null -ne $command) { $command.Source } else { $null })
    ))
}

Register-HunterTool -Name 'PowerShell7' `
    -DownloadSpec { Get-PowerShell7DownloadSpec } `
    -ExecutablePath { Get-PowerShell7ExecutablePath } `
    -PostInstall { Invoke-DisablePowerShell7Telemetry }
