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
        $automationSafeParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'AutomationSafe' } | Select-Object -First 1
        $skipTaskParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SkipTask' } | Select-Object -First 1
        $customAppsListPathParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'CustomAppsListPath' } | Select-Object -First 1
        $disableIPv6Parameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableIPv6' } | Select-Object -First 1
        $disableTeredoParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableTeredo' } | Select-Object -First 1
        $disableHagsParameter = $invokeMainParameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'DisableHags' } | Select-Object -First 1

        $validateSetAttribute = $modeParameter.Attributes | Where-Object {
            $_.TypeName.FullName -eq 'ValidateSet'
        } | Select-Object -First 1

        $modeValidateSetValues = @($validateSetAttribute.PositionalArguments | ForEach-Object { [string]$_.SafeGetValue() })
    }

    It 'keeps Invoke-Main with the expected parameters' {
        @($invokeMainParameters.Name.VariablePath.UserPath) -join '|' | Should -BeExactly 'Mode|Strict|AutomationSafe|SkipTask|CustomAppsListPath|DisableIPv6|DisableTeredo|DisableHags'
    }

    It 'keeps Mode defaulted to Execute' {
        [string]$modeParameter.DefaultValue.SafeGetValue() | Should -BeExactly 'Execute'
    }

    It 'keeps Mode restricted to Execute and Resume' {
        ($modeValidateSetValues -join '|') | Should -BeExactly 'Execute|Resume'
    }

    It 'keeps the wrapper parameter types intact' {
        $strictParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $automationSafeParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $skipTaskParameter.StaticType.Name | Should -BeExactly 'String[]'
        $customAppsListPathParameter.StaticType.Name | Should -BeExactly 'String'
        $disableIPv6Parameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableTeredoParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
        $disableHagsParameter.StaticType.Name | Should -BeExactly 'SwitchParameter'
    }

    It 'keeps raw wrapper defaults intact' {
        $sourceText | Should -Match "\\$scriptMode = 'Execute'"
        $sourceText | Should -Match "\\$scriptStrict = \\$false"
        $sourceText | Should -Match "\\$scriptLogPath = \\$null"
        $sourceText | Should -Match "\\$scriptAutomationSafe = \\$false"
        $sourceText | Should -Match "\\$scriptSkipTasks = @\\("
        $sourceText | Should -Match "\\$scriptCustomAppsListPath = \\$null"
        $sourceText | Should -Match "\\$scriptDisableIPv6 = \\$false"
        $sourceText | Should -Match "\\$scriptDisableTeredo = \\$false"
        $sourceText | Should -Match "\\$scriptDisableHags = \\$false"
    }

    It 'keeps raw wrapper argument parsing for all supported options' {
        $sourceText | Should -Match "\$args\[\$i\] -eq '-Mode'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-Strict'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-LogPath'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-AutomationSafe'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-SkipTask'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-CustomAppsListPath'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableIPv6'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableTeredo'"
        $sourceText | Should -Match "\$args\[\$i\] -eq '-DisableHags'"
    }

    It 'keeps the LogPath override behavior' {
        $sourceText | Should -Match "\$script:LogPath = \$scriptLogPath"
    }

    It 'keeps the wrapper invoking Invoke-Main with parsed arguments' {
        $sourceText | Should -Match 'Invoke-Main -Mode \$scriptMode -Strict:\$scriptStrict -AutomationSafe:\$scriptAutomationSafe -SkipTask \$scriptSkipTasks -CustomAppsListPath \$scriptCustomAppsListPath -DisableIPv6:\$scriptDisableIPv6 -DisableTeredo:\$scriptDisableTeredo -DisableHags:\$scriptDisableHags'
    }

    It 'keeps remote bootstrap support for irm pipe iex execution' {
        $sourceText | Should -Match "\$script:HunterRemoteRevision = '[0-9a-f]{40}'"
        $sourceText | Should -Match "\$script:HunterRemoteRoot = 'https://raw\.githubusercontent\.com/xobash/hunter/\{0\}' -f \$script:HunterRemoteRevision"
        $sourceText | Should -Match "\$script:BootstrapLoaderRelativePath = 'src\\\\Hunter\\\\Private\\\\Bootstrap\\\\Loader\.ps1'"
        $sourceText | Should -Match "Join-Path \(\[System\.IO\.Path\]::GetTempPath\(\)\) 'HunterBootstrap'"
        $sourceText | Should -Match 'Invoke-WebRequest `\s*-Uri \$bootstrapLoaderUri'
        $sourceText | Should -Match 'Initialize-HunterPrivateSourceTree'
        $sourceText | Should -Match 'foreach \(\$privateScript in @\(Get-HunterPrivateScriptManifest\)\)'
        $sourceText | Should -Match '\. \(Join-Path \$script:HunterSourceRoot \(\[string\]\$privateScript\.RelativePath\)\)'
    }
}
