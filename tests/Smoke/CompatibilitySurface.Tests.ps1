Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-HunterAst {
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

    return $ast
}

Describe 'Wrapper compatibility surface' {
    BeforeAll {
        $scriptPath = Join-Path (Join-Path $PSScriptRoot '..\..') 'hunter.ps1'
        $sourceText = Get-Content -Path $scriptPath -Raw -ErrorAction Stop
        $ast = Get-HunterAst -ScriptPath $scriptPath

        $invokeMain = $ast.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-Main'
        }, $true)

        if ($null -eq $invokeMain) {
            throw 'Invoke-Main function was not found.'
        }

        $invokeMainParameters = @($invokeMain.Body.ParamBlock.Parameters)
        $modeParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Mode' } | Select-Object -First 1
        $strictParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Strict' } | Select-Object -First 1
        $whatIfParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'WhatIf' } | Select-Object -First 1
        $profileParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'Profile' } | Select-Object -First 1
        $automationSafeParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AutomationSafe' } | Select-Object -First 1
        $skipTaskParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SkipTask' } | Select-Object -First 1
        $customAppsListPathParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CustomAppsListPath' } | Select-Object -First 1
        $disableIPv6Parameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableIPv6' } | Select-Object -First 1
        $disableTeredoParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableTeredo' } | Select-Object -First 1
        $disableCpuMitigationsParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableCpuMitigations' } | Select-Object -First 1
        $disableHagsParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableHags' } | Select-Object -First 1
        $forceStorageOptimizationParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ForceStorageOptimization' } | Select-Object -First 1
        $disableAudioEnhancementsParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableAudioEnhancements' } | Select-Object -First 1
        $disableSystemSoundsParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableSystemSounds' } | Select-Object -First 1
        $forceTextInputServiceRedirectParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'ForceTextInputServiceRedirect' } | Select-Object -First 1
        $pagefileDriveParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'PagefileDrive' } | Select-Object -First 1

        $validateSetAttribute = $modeParameter.Attributes | Where-Object {
            $_.TypeName.FullName -eq 'ValidateSet'
        } | Select-Object -First 1

        $modeValidateSetValues = @($validateSetAttribute.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() })
        $profileValidateSetAttribute = $profileParameter.Attributes | Where-Object {
            $_.TypeName.FullName -eq 'ValidateSet'
        } | Select-Object -First 1
        $profileValidateSetValues = @($profileValidateSetAttribute.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() })
    }

    It 'keeps Invoke-Main with the expected parameters' {
        @($invokeMainParameters.Name.VariablePath.UserPath) -join '|' | Should -BeExactly 'Mode|Strict|WhatIf|Profile|AutomationSafe|SkipTask|CustomAppsListPath|DisableIPv6|DisableTeredo|DisableCpuMitigations|DisableHags|ForceStorageOptimization|DisableAudioEnhancements|DisableSystemSounds|ForceTextInputServiceRedirect|PagefileDrive'
    }

    It 'keeps Mode defaulted to Execute' {
        [string]$modeParameter.DefaultValue.SafeGetValue() | Should -BeExactly 'Execute'
    }

    It 'keeps Mode restricted to Execute and Resume' {
        ($modeValidateSetValues -join '|') | Should -BeExactly 'Execute|Resume'
    }

    It 'keeps Profile defaulted to Aggressive and locked to supported presets' {
        [string]$profileParameter.DefaultValue.SafeGetValue() | Should -BeExactly 'Aggressive'
        ($profileValidateSetValues -join '|') | Should -BeExactly 'Minimal|Balanced|Aggressive|VMReset'
    }

    It 'keeps the wrapper parameter types intact' {
        $strictParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $whatIfParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $profileParameter.StaticType.Name | Should -BeExactly 'String'
        $automationSafeParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $skipTaskParameter.StaticType.Name | Should -BeExactly 'String[]'
        $customAppsListPathParameter.StaticType.Name | Should -BeExactly 'String'
        $disableIPv6Parameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableTeredoParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableCpuMitigationsParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableHagsParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $forceStorageOptimizationParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableAudioEnhancementsParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableSystemSoundsParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $forceTextInputServiceRedirectParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $pagefileDriveParameter.StaticType.Name | Should -BeExactly 'String'
    }

    It 'keeps raw wrapper defaults intact' {
        $sourceText | Should -Match "\\$scriptMode = 'Execute'"
        $sourceText | Should -Match "\\$scriptStrict = \\$false"
        $sourceText | Should -Match "\\$scriptWhatIf = \\$false"
        $sourceText | Should -Match "\\$scriptProfile = 'Aggressive'"
        $sourceText | Should -Match "\\$scriptLogPath = \\$null"
        $sourceText | Should -Match "\\$scriptAutomationSafe = \\$false"
        $sourceText | Should -Match "\\$scriptSkipTasks = @\\("
        $sourceText | Should -Match "\\$scriptCustomAppsListPath = \\$null"
        $sourceText | Should -Match "\\$scriptDisableIPv6 = \\$false"
        $sourceText | Should -Match "\\$scriptDisableTeredo = \\$false"
        $sourceText | Should -Match "\\$scriptDisableCpuMitigations = \\$false"
        $sourceText | Should -Match "\\$scriptDisableHags = \\$false"
        $sourceText | Should -Match "\\$scriptForceStorageOptimization = \\$false"
        $sourceText | Should -Match "\\$scriptDisableAudioEnhancements = \\$false"
        $sourceText | Should -Match "\\$scriptDisableSystemSounds = \\$false"
        $sourceText | Should -Match "\\$scriptForceTextInputServiceRedirect = \\$false"
        $sourceText | Should -Match "\\$scriptPagefileDrive = \\$null"
    }

    It 'keeps raw wrapper argument parsing for all supported options' {
        $sourceText | Should -Match "\$args\[\$i\] -eq '-Mode'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-Strict'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-WhatIf'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-Profile'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-LogPath'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-AutomationSafe'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-SkipTask'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-CustomAppsListPath'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableIPv6'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableTeredo'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableCpuMitigations'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableHags'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-ForceStorageOptimization'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableAudioEnhancements'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableSystemSounds'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-ForceTextInputServiceRedirect'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-PagefileDrive'"
    }

    It 'keeps the LogPath override behavior' {
        $sourceText | Should -Match "\$script:LogPath = \$scriptLogPath"
    }

    It 'keeps the wrapper invoking Invoke-Main with parsed arguments' {
        $sourceText | Should -Match 'Invoke-Main -Mode \$scriptMode -Strict:\$scriptStrict -WhatIf:\$scriptWhatIf -Profile \$scriptProfile -AutomationSafe:\$scriptAutomationSafe -SkipTask \$scriptSkipTasks -CustomAppsListPath \$scriptCustomAppsListPath -DisableIPv6:\$scriptDisableIPv6 -DisableTeredo:\$scriptDisableTeredo -DisableCpuMitigations:\$scriptDisableCpuMitigations -DisableHags:\$scriptDisableHags -ForceStorageOptimization:\$scriptForceStorageOptimization -DisableAudioEnhancements:\$scriptDisableAudioEnhancements -DisableSystemSounds:\$scriptDisableSystemSounds -ForceTextInputServiceRedirect:\$scriptForceTextInputServiceRedirect -PagefileDrive \$scriptPagefileDrive'
    }

    It 'syncs context after starting the progress window' {
        $sourceText | Should -Match 'Start-ProgressWindow'
        $sourceText | Should -Match 'Sync-HunterContextFromScriptState -Context \$context'
    }

    It 'keeps remote bootstrap support for irm pipe iex execution' {
        $sourceText | Should -Match "\$script:HunterReleaseChannel = '[^']+'"
        $sourceText | Should -Match "\$script:HunterReleaseVersion = '[^']+'"
        $sourceText | Should -Match "\$script:HunterBootstrapRevision = 'main'"
        $sourceText | Should -Match "\$script:HunterRemoteRoot = 'https://raw\.githubusercontent\.com/xobash/hunter/\{0\}' -f \$script:HunterBootstrapRevision"
        $sourceText | Should -Match "\$script:BootstrapLoaderRelativePath = 'src\\\\Hunter\\\\Private\\\\Bootstrap\\\\Loader\.ps1'"
        $sourceText | Should -Match "Join-Path \(\[System\.IO\.Path\]::GetTempPath\(\)\) 'HunterBootstrap'"
        $sourceText | Should -Match 'Invoke-WebRequest `\s*-Uri \$bootstrapLoaderUri'
        $sourceText | Should -Match 'Initialize-HunterPrivateSourceTree'
        $sourceText | Should -Match 'foreach \(\$privateScript in @\(Get-HunterPrivateScriptManifest\)\)'
        $sourceText | Should -Match '\. \(\[scriptblock\]::Create\(\(Get-Content -Path \$bootstrapLoaderPath -Raw -Encoding UTF8\)\)\)'
        $sourceText | Should -Match '\$privateScriptPath = Join-Path \$script:HunterSourceRoot \(\[string\]\$privateScript\.RelativePath\)'
        $sourceText | Should -Match '\. \(\[scriptblock\]::Create\(\(Get-Content -Path \$privateScriptPath -Raw -Encoding UTF8\)\)\)'
        $sourceText | Should -Not -Match '(?m)^\.\s+\$bootstrapLoaderPath\s*$'
        $sourceText | Should -Not -Match '\. \(Join-Path \$script:HunterSourceRoot \(\[string\]\$privateScript\.RelativePath\)\)'
    }

    It 'initializes rollback capture and run-configuration recording during startup' {
        $sourceText | Should -Match 'Initialize-HunterRollbackState -Mode \$Mode'
        $sourceText | Should -Match 'Save-HunterRunConfiguration -Mode \$Mode'
    }
}
