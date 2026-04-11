Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Task catalog compatibility' {
    BeforeAll {
        $privateRoot = Join-Path (Join-Path $PSScriptRoot '..\..') 'src\Hunter\Private'
        $catalogPath = Join-Path $privateRoot 'Tasks\Catalog.ps1'
        $enginePath = Join-Path $privateRoot 'Execution\Engine.ps1'

        . $catalogPath
        $taskCatalog = @(Get-HunterTaskCatalog)

        $expectedTaskIds = @(
            'preflight-internet',
            'preflight-edition-compatibility',
            'preflight-restore-point',
            'preflight-winget-version',
            'preflight-app-downloads',
            'preflight-predownload-v2',
            'install-launch-packages-v2',
            'core-local-user-v2',
            'core-autologin-v2',
            'core-dark-mode',
            'core-ultimate-performance',
            'startui-bing-search',
            'startui-start-recommendations-v4',
            'startui-search-box',
            'startui-task-view',
            'startui-widgets',
            'startui-end-task',
            'startui-notifications',
            'startui-new-outlook',
            'startui-settings-home',
            'explorer-home-thispc',
            'explorer-remove-home-v2',
            'explorer-remove-gallery-v2',
            'explorer-remove-onedrive',
            'explorer-auto-discovery',
            'cloud-edge-remove',
            'cloud-edge-pins',
            'cloud-edge-update-block',
            'cloud-onedrive-remove',
            'cloud-onedrive-backup',
            'cloud-copilot-remove',
            'apps-consumer-features',
            'apps-nuke-block',
            'apps-inking-typing',
            'apps-delivery-opt',
            'apps-activity-history',
            'tweaks-services',
            'tweaks-virtualization-security',
            'tweaks-telemetry',
            'tweaks-location',
            'tweaks-hibernation',
            'tweaks-background-apps',
            'tweaks-teredo',
            'tweaks-fso',
            'tweaks-graphics-scheduling',
            'tweaks-gpu-interrupt-affinity',
            'tweaks-rebar-audit',
            'tweaks-dwm-frame-interval',
            'tweaks-ui-desktop',
            'tweaks-razer',
            'tweaks-adobe',
            'tweaks-power-tuning',
            'tweaks-nic-power-management',
            'tweaks-memory-disk',
            'tweaks-input-maintenance',
            'tweaks-timer-resolution',
            'tweaks-store-search',
            'tweaks-ipv6',
            'external-wallpaper-v3',
            'external-tcp-optimizer',
            'external-oosu',
            'external-system-properties',
            'external-network-connections-shortcut',
            'install-finalize-packages-v2',
            'cleanup-temp-files',
            'cleanup-retry-failed',
            'cleanup-autologin-secrets',
            'cleanup-disk-cleanup',
            'cleanup-explorer-restart',
            'cleanup-export-log'
        )

        $expectedPhases = @(
            '1', '1', '1', '1', '1', '1',
            '2', '2', '2', '2', '2',
            '3', '3', '3', '3', '3', '3', '3', '3', '3',
            '4', '4', '4', '4', '4',
            '5', '5', '5', '5', '5', '5',
            '6', '6', '6', '6', '6',
            '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7', '7',
            '8', '8', '8', '8', '8',
            '9', '9', '9', '9', '9', '9', '9'
        )
    }

    It 'defines the current total task count' {
        $taskCatalog.Count | Should -Be 70
    }

    It 'preserves the exact task ID order' {
        ($taskCatalog.Id -join '|') | Should -BeExactly ($expectedTaskIds -join '|')
    }

    It 'preserves the exact phase order' {
        (($taskCatalog.Phase | ForEach-Object { [string]$_ }) -join '|') | Should -BeExactly ($expectedPhases -join '|')
    }

    It 'keeps task IDs unique' {
        ($taskCatalog.Id | Sort-Object -Unique).Count | Should -Be $taskCatalog.Count
    }

    It 'keeps every task description populated' {
        @($taskCatalog | Where-Object { [string]::IsNullOrWhiteSpace($_.Description) }).Count | Should -Be 0
    }

    It 'keeps every task handler as a scriptblock' {
        @($taskCatalog | Where-Object { $_.Handler -isnot [scriptblock] }).Count | Should -Be 0
    }

    It 'keeps the engine building tasks from the catalog function' {
        (Get-Content -Path $enginePath -Raw -ErrorAction Stop) | Should -Match 'Get-HunterTaskCatalog'
    }
}
