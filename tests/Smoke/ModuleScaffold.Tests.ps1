Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Module scaffold compatibility' {
    BeforeAll {
        $moduleRoot = Join-Path (Join-Path $PSScriptRoot '..\..') 'src\Hunter'
        $manifestPath = Join-Path $moduleRoot 'Hunter.psd1'
        $modulePath = Join-Path $moduleRoot 'Hunter.psm1'
        $manifestText = Get-Content -Path $manifestPath -Raw -ErrorAction Stop
        $moduleText = Get-Content -Path $modulePath -Raw -ErrorAction Stop
    }

    It 'defines the root module manifest' {
        $manifestText | Should -Match "RootModule\s*=\s*'Hunter\.psm1'"
        $manifestText | Should -Match "PowerShellVersion\s*=\s*'5\.1'"
    }

    It 'keeps the scaffold non-exporting until Invoke-Main moves into the module' {
        $manifestText | Should -Match 'FunctionsToExport\s*=\s*@\(\)'
    }

    It 'loads the private source tree through the loader' {
        $moduleText | Should -Match 'Bootstrap\\Loader\.ps1'
        $moduleText | Should -Match 'Import-HunterPrivateScripts -SourceRoot \$repoRoot'
    }
}
