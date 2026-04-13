Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Rollback surface' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        $configSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Bootstrap/Config.ps1') -Raw -ErrorAction Stop
        $cleanupSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Cleanup.ps1') -Raw -ErrorAction Stop
        $registrySource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Registry/Operations.ps1') -Raw -ErrorAction Stop
        $appRemovalSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Apps/AppRemoval.ps1') -Raw -ErrorAction Stop
        $hardwareSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Tasks/Tweaks/Hardware.ps1') -Raw -ErrorAction Stop
        $loaderSource = Get-Content -Path (Join-Path $repoRoot 'src/Hunter/Private/Bootstrap/Loader.ps1') -Raw -ErrorAction Stop
        $releaseChannelsPath = Join-Path $repoRoot 'releases/channels.json'
    }

    It 'declares rollback and reproducibility paths in bootstrap config' {
        $configSource | Should -Match "\$script:RollbackManifestPath ="
        $configSource | Should -Match "\$script:RollbackScriptPath ="
        $configSource | Should -Match "\$script:RunConfigurationPath ="
    }

    It 'copies the restore script and run configuration into the final desktop export' {
        $cleanupSource | Should -Match 'Restore script copied to:'
        $cleanupSource | Should -Match 'Run configuration copied to:'
    }

    It 'captures registry rollback before shared registry mutations' {
        $registrySource | Should -Match 'Register-HunterRegistryValueRollback -Path \$Path -Name \$Name'
    }

    It 'ships rollback support as a bootstrap-loaded private script' {
        $loaderSource | Should -Match "src\\Hunter\\Private\\State\\Rollback\.ps1"
    }

    It 'records explicit manual restore guidance for app removals and external tweak tools' {
        $appRemovalSource | Should -Match 'Register-HunterManualRestoreNote'
        $hardwareSource | Should -Match "manual-restore\|tcp-optimizer"
        $hardwareSource | Should -Match "manual-restore\|oosu"
    }

    It 'ships explicit release-channel metadata' {
        Test-Path $releaseChannelsPath | Should -BeTrue
    }
}
