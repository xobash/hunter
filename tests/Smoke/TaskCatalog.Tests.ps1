Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-BuildTaskCatalog {
    param(
        [Parameter(Mandatory)]
        [string]$ScriptPath
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)

    if ($errors.Count -gt 0) {
        throw "PowerShell parser reported $($errors.Count) error(s) for $ScriptPath."
    }

    $buildTasksFunction = $ast.Find({
        param($node)
        $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Build-Tasks'
    }, $true)

    if ($null -eq $buildTasksFunction) {
        throw 'Build-Tasks function was not found.'
    }

    $taskCommands = $buildTasksFunction.Body.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'New-Task'
    }, $true)

    $catalog = foreach ($command in $taskCommands) {
        $taskId = $null
        $phase = $null
        $description = $null

        for ($index = 0; $index -lt $command.CommandElements.Count; $index++) {
            $element = $command.CommandElements[$index]
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) {
                continue
            }

            $nextElement = if (($index + 1) -lt $command.CommandElements.Count) {
                $command.CommandElements[$index + 1]
            } else {
                $null
            }

            switch ($element.ParameterName) {
                'TaskId' {
                    $taskId = [string]$nextElement.SafeGetValue()
                }
                'Phase' {
                    $phase = [int]$nextElement.SafeGetValue()
                }
                'Description' {
                    $description = [string]$nextElement.SafeGetValue()
                }
            }
        }

        [pscustomobject]@{
            TaskId      = $taskId
            Phase       = $phase
            Description = $description
        }
    }

    return ,$catalog
}

Describe 'Build-Tasks catalog compatibility' {
    BeforeAll {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..\..') 'src\Hunter\Private\Execution\Engine.ps1'
        $taskCatalog = @(Get-BuildTaskCatalog -ScriptPath $scriptPath)

        $expectedTaskIds = @(
            'preflight-internet',
            'preflight-restore-point',
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
            'tweaks-dwm-frame-interval',
            'tweaks-ui-desktop',
            'tweaks-razer',
            'tweaks-adobe',
            'tweaks-power-tuning',
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
            'cleanup-disk-cleanup',
            'cleanup-explorer-restart',
            'cleanup-export-log'
        )

        $expectedPhases = @(
            1, 1, 1,
            2, 2, 2, 2, 2,
            3, 3, 3, 3, 3, 3, 3, 3, 3,
            4, 4, 4, 4, 4,
            5, 5, 5, 5, 5,
            6, 6, 6, 6, 6,
            7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
            8, 8, 8, 8, 8,
            9, 9, 9, 9, 9, 9
        )
    }

    It 'defines the current total task count' {
        $taskCatalog.Count | Should -Be 62
    }

    It 'preserves the exact task ID order' {
        ($taskCatalog.TaskId -join '|') | Should -BeExactly ($expectedTaskIds -join '|')
    }

    It 'preserves the exact phase order' {
        (($taskCatalog.Phase | ForEach-Object { [string]$_ }) -join '|') | Should -BeExactly (($expectedPhases | ForEach-Object { [string]$_ }) -join '|')
    }

    It 'keeps task IDs unique' {
        ($taskCatalog.TaskId | Sort-Object -Unique).Count | Should -Be $taskCatalog.Count
    }

    It 'keeps every task description populated' {
        @($taskCatalog | Where-Object { [string]::IsNullOrWhiteSpace($_.Description) }).Count | Should -Be 0
    }
}
