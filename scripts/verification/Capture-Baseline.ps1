[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path (Join-Path $PSScriptRoot '..\..\artifacts\baseline') (Get-Date -Format 'yyyyMMdd-HHmmss')),
    [string]$HunterRoot = (Join-Path $(if ([string]::IsNullOrWhiteSpace($env:ProgramData)) { 'C:\ProgramData' } else { $env:ProgramData }) 'Hunter'),
    [string]$DesktopPath = [Environment]::GetFolderPath('Desktop')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    $InputObject | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Add-ManifestEntry {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RelativePath,
        [bool]$Exists,
        [string]$SourcePath = '',
        [string]$Hash = $null,
        [string]$Notes = ''
    )

    $script:ManifestEntries.Add([pscustomobject]@{
        Category     = $Category
        Name         = $Name
        RelativePath = $RelativePath
        Exists       = $Exists
        SourcePath   = $SourcePath
        Hash         = $Hash
        Notes        = $Notes
    }) | Out-Null
}

function Copy-ObservedArtifact {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $relativePath = Join-Path $Category ([IO.Path]::GetFileName($SourcePath))
    $destinationPath = Join-Path $DestinationRoot $relativePath
    Ensure-Directory (Split-Path -Parent $destinationPath)

    if (Test-Path -LiteralPath $SourcePath) {
        Copy-Item -LiteralPath $SourcePath -Destination $destinationPath -Force
        Add-ManifestEntry -Category $Category -Name $Name -RelativePath $relativePath -Exists $true -SourcePath $SourcePath -Hash (Get-FileSha256 -Path $destinationPath)
    } else {
        Add-ManifestEntry -Category $Category -Name $Name -RelativePath $relativePath -Exists $false -SourcePath $SourcePath -Notes 'Source artifact was not present.'
    }
}

function Export-RegistrySnapshot {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$RegistryPath,
        [Parameter(Mandatory)][string]$DestinationRoot
    )

    $relativePath = Join-Path 'registry' "$Name.reg"
    $destinationPath = Join-Path $DestinationRoot $relativePath
    Ensure-Directory (Split-Path -Parent $destinationPath)

    $query = & reg.exe query $RegistryPath 2>$null
    if ($LASTEXITCODE -ne 0) {
        Add-ManifestEntry -Category 'registry' -Name $Name -RelativePath $relativePath -Exists $false -SourcePath $RegistryPath -Notes 'Registry path was not present.'
        return
    }

    & reg.exe export $RegistryPath $destinationPath /y | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Add-ManifestEntry -Category 'registry' -Name $Name -RelativePath $relativePath -Exists $false -SourcePath $RegistryPath -Notes 'Registry export failed.'
        return
    }

    Add-ManifestEntry -Category 'registry' -Name $Name -RelativePath $relativePath -Exists $true -SourcePath $RegistryPath -Hash (Get-FileSha256 -Path $destinationPath)
}

function Export-ServiceSnapshot {
    param([Parameter(Mandatory)][string]$DestinationRoot)

    $relativePath = Join-Path 'snapshots' 'services.csv'
    $destinationPath = Join-Path $DestinationRoot $relativePath
    Ensure-Directory (Split-Path -Parent $destinationPath)

    Get-CimInstance -ClassName Win32_Service -ErrorAction Stop |
        Select-Object Name, DisplayName, StartMode, State, StartName |
        Sort-Object Name |
        Export-Csv -Path $destinationPath -NoTypeInformation -Encoding UTF8

    Add-ManifestEntry -Category 'snapshots' -Name 'services' -RelativePath $relativePath -Exists $true -Hash (Get-FileSha256 -Path $destinationPath)
}

function Export-ScheduledTaskSnapshot {
    param([Parameter(Mandatory)][string]$DestinationRoot)

    $relativePath = Join-Path 'snapshots' 'scheduled-tasks.csv'
    $destinationPath = Join-Path $DestinationRoot $relativePath
    Ensure-Directory (Split-Path -Parent $destinationPath)

    try {
        Get-ScheduledTask -ErrorAction Stop |
            Select-Object @{ Name = 'TaskKey'; Expression = { '{0}{1}' -f $_.TaskPath, $_.TaskName } }, TaskName, TaskPath, State, Author, Description |
            Sort-Object TaskKey |
            Export-Csv -Path $destinationPath -NoTypeInformation -Encoding UTF8

        Add-ManifestEntry -Category 'snapshots' -Name 'scheduled-tasks' -RelativePath $relativePath -Exists $true -Hash (Get-FileSha256 -Path $destinationPath)
    } catch {
        Set-Content -Path $destinationPath -Value "Get-ScheduledTask failed: $($_.Exception.Message)" -Encoding UTF8
        Add-ManifestEntry -Category 'snapshots' -Name 'scheduled-tasks' -RelativePath $relativePath -Exists $false -Hash (Get-FileSha256 -Path $destinationPath) -Notes 'Scheduled task snapshot could not be collected.'
    }
}

function Export-ShortcutSnapshot {
    param([Parameter(Mandatory)][string]$DestinationRoot)

    $relativePath = Join-Path 'snapshots' 'shortcuts.csv'
    $destinationPath = Join-Path $DestinationRoot $relativePath
    Ensure-Directory (Split-Path -Parent $destinationPath)

    $shortcutRoots = @(
        [pscustomobject]@{ Scope = 'UserDesktop'; Path = [Environment]::GetFolderPath('Desktop') },
        [pscustomobject]@{ Scope = 'PublicDesktop'; Path = (Join-Path $env:PUBLIC 'Desktop') },
        [pscustomobject]@{ Scope = 'UserStartMenu'; Path = (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs') },
        [pscustomobject]@{ Scope = 'AllUsersStartMenu'; Path = (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs') }
    )

    $shell = New-Object -ComObject WScript.Shell
    try {
        $rows = foreach ($root in $shortcutRoots) {
            if (-not (Test-Path -LiteralPath $root.Path)) {
                continue
            }

            Get-ChildItem -LiteralPath $root.Path -Recurse -Filter '*.lnk' -File -ErrorAction SilentlyContinue | ForEach-Object {
                $shortcut = $shell.CreateShortcut($_.FullName)
                [pscustomobject]@{
                    Scope        = $root.Scope
                    ShortcutPath = $_.FullName
                    Name         = $_.Name
                    TargetPath   = $shortcut.TargetPath
                    Arguments    = $shortcut.Arguments
                    WorkingDir   = $shortcut.WorkingDirectory
                }
            }
        }

        @($rows) | Sort-Object Scope, ShortcutPath | Export-Csv -Path $destinationPath -NoTypeInformation -Encoding UTF8
        Add-ManifestEntry -Category 'snapshots' -Name 'shortcuts' -RelativePath $relativePath -Exists $true -Hash (Get-FileSha256 -Path $destinationPath)
    } finally {
        [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell) | Out-Null
    }
}

Ensure-Directory $OutputPath
$script:ManifestEntries = New-Object 'System.Collections.Generic.List[object]'

$metadata = [ordered]@{
    CapturedAt        = (Get-Date).ToString('o')
    ComputerName      = $env:COMPUTERNAME
    UserName          = $env:USERNAME
    PowerShellVersion = $PSVersionTable.PSVersion.ToString()
    HunterRoot        = $HunterRoot
    DesktopPath       = $DesktopPath
    IsAdministrator   = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Save-JsonFile -InputObject $metadata -Path (Join-Path $OutputPath 'metadata.json')

Copy-ObservedArtifact -Category 'copies' -Name 'hunter-log' -SourcePath (Join-Path $HunterRoot 'hunter.log') -DestinationRoot $OutputPath
Copy-ObservedArtifact -Category 'copies' -Name 'checkpoint' -SourcePath (Join-Path $HunterRoot 'checkpoint.json') -DestinationRoot $OutputPath

$latestReport = Get-ChildItem -LiteralPath $DesktopPath -Filter 'Hunter-Report-*.txt' -File -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTimeUtc -Descending |
    Select-Object -First 1

if ($null -ne $latestReport) {
    Copy-ObservedArtifact -Category 'copies' -Name 'desktop-report' -SourcePath $latestReport.FullName -DestinationRoot $OutputPath
} else {
    Add-ManifestEntry -Category 'copies' -Name 'desktop-report' -RelativePath (Join-Path 'copies' 'desktop-report.txt') -Exists $false -SourcePath (Join-Path $DesktopPath 'Hunter-Report-*.txt') -Notes 'No desktop report matched the expected pattern.'
}

$registryTargets = @(
    @{ Name = 'cloud-content'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\CloudContent' },
    @{ Name = 'windows-search'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' },
    @{ Name = 'memory-management'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' },
    @{ Name = 'graphics-drivers'; Path = 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' },
    @{ Name = 'tcpip-parameters'; Path = 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' },
    @{ Name = 'onedrive-policy'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\OneDrive' },
    @{ Name = 'game-dvr-policy'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\GameDVR' },
    @{ Name = 'explorer-advanced'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' },
    @{ Name = 'search-current-user'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search' }
)

foreach ($target in $registryTargets) {
    Export-RegistrySnapshot -Name $target.Name -RegistryPath $target.Path -DestinationRoot $OutputPath
}

Export-ServiceSnapshot -DestinationRoot $OutputPath
Export-ScheduledTaskSnapshot -DestinationRoot $OutputPath
Export-ShortcutSnapshot -DestinationRoot $OutputPath

$manifest = [ordered]@{
    Metadata  = $metadata
    Artifacts = @($script:ManifestEntries)
}

Save-JsonFile -InputObject $manifest -Path (Join-Path $OutputPath 'capture-manifest.json')

Write-Host "Baseline captured to $OutputPath"
