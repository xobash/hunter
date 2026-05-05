Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Behavior contracts' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        . (Join-Path $repoRoot 'src/Hunter/Private/System/Detection.ps1')
        . (Join-Path $repoRoot 'src/Hunter/Private/Common/PathPolicy.ps1')
        . (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Catalog.ps1')
        $cleanupSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Cleanup.ps1') -Raw -ErrorAction Stop
        $copilotSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/OneDriveCopilot.ps1') -Raw -ErrorAction Stop
        $detectionSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/System/Detection.ps1') -Raw -ErrorAction Stop
        $hardwareSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Hardware.ps1') -Raw -ErrorAction Stop
        $nativeSystemSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Infrastructure/NativeSystem.ps1') -Raw -ErrorAction Stop
    }

    BeforeEach {
        $script:WindowsBuildContext = [pscustomobject]@{
            CurrentBuild = 19045
            UBR = 0
            DisplayVersion = '22H2'
            ReleaseId = '22H2'
            ProductName = 'Windows 10'
            IsWindows11 = $false
            IsWindows10 = $true
        }
        $script:HunterRoot = 'C:\ProgramData\Hunter'
    }

    It 'treats Windows 10 22H2 as inside the Windows 10 build range' {
        Test-WindowsBuildInRange -MinBuild 10240 -MaxBuild 22000 | Should -BeTrue
    }

    It 'rejects a Windows 11 minimum build on Windows 10' {
        Test-WindowsBuildInRange -MinBuild 22000 | Should -BeFalse
    }

    It 'rejects ranges whose maximum build is below the current build' {
        Test-WindowsBuildInRange -MaxBuild 18363 | Should -BeFalse
    }

    It 'keeps retry cleanup as warning/reporting rather than a synthetic failed task' {
        $cleanupSource | Should -Match "Status\s*=\s*'CompletedWithWarnings'"
        $cleanupSource | Should -Not -Match 'return \(@\(\$script:FailedTasks\)\.Count -eq 0\)'
    }

    It 'allows optional MaxBuild keys in Copilot registry settings under strict mode' {
        $copilotSource | Should -Match "ContainsKey\('MaxBuild'\)"
        $copilotSource | Should -Not -Match '-MaxBuild \$setting\.MaxBuild'
    }

    It 'returns a single wallpaper asset path string without leaking Ensure-Directory output' {
        $wallpaperPath = Get-WallpaperAssetPath -WallpaperUrl 'https://example.com/wallpaper.png'

        $wallpaperPath | Should -BeOfType ([string])
        $wallpaperPath | Should -BeExactly 'C:\ProgramData\Hunter\Assets\hunter-wallpaper.png'
    }

    It 'blocks Windows Update driver installation before package downloads begin' {
        $taskIds = @((Get-HunterTaskCatalog).Id)

        [array]::IndexOf($taskIds, 'preflight-driver-install-block') | Should -BeGreaterThan -1
        [array]::IndexOf($taskIds, 'preflight-driver-install-block') | Should -BeLessThan ([array]::IndexOf($taskIds, 'preflight-predownload-v2'))
        $hardwareSource | Should -Match 'ExcludeWUDriversInQualityUpdate'
        $hardwareSource | Should -Match 'PreventDeviceMetadataFromNetwork'
        $hardwareSource | Should -Match 'SearchOrderConfig'
        $hardwareSource | Should -Match "Stop-ServiceIfPresent -Name 'wuauserv'"
        $hardwareSource | Should -Match "Set-ServiceStartType -Name 'wuauserv' -StartType 'Disabled'"
    }

    It 'avoids blocking DISM PowerShell cmdlets for edition and optional-feature handling' {
        $detectionSource | Should -Not -Match 'Get-WindowsEdition\s+-Online'
        $nativeSystemSource | Should -Not -Match 'Get-WindowsOptionalFeature\s+-Online'
        $nativeSystemSource | Should -Not -Match 'Disable-WindowsOptionalFeature\s+-Online'
        $nativeSystemSource | Should -Match 'dism\.exe'
        $nativeSystemSource | Should -Match 'Invoke-NativeCommandWithTimeout'
    }
}
