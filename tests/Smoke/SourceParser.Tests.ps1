Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'PowerShell source parsing' {
    It 'parses every tracked PowerShell source file without syntax errors' {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        $scriptPaths = @(
            Get-ChildItem -Path $repoRoot -Recurse -Include *.ps1 -File |
                Where-Object { $_.FullName -notmatch '\\bin\\|\\obj\\' } |
                Sort-Object FullName
        )

        $scriptPaths.Count | Should -BeGreaterThan 0

        foreach ($scriptPath in $scriptPaths) {
            $tokens = $null
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($scriptPath.FullName, [ref]$tokens, [ref]$errors)
            $errors.Count | Should -Be 0 -Because $scriptPath.FullName
        }
    }

    It 'keeps tracked PowerShell source files ASCII-only for bootstrap portability' {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        $scriptPaths = @(
            Get-ChildItem -Path $repoRoot -Recurse -Include *.ps1 -File |
                Where-Object { $_.FullName -notmatch '\\bin\\|\\obj\\' } |
                Sort-Object FullName
        )

        $nonAsciiFiles = @()
        foreach ($scriptPath in $scriptPaths) {
            $content = [System.IO.File]::ReadAllText($scriptPath.FullName)
            if ($content -match '[^\u0000-\u007F]') {
                $nonAsciiFiles += $scriptPath.FullName
            }
        }

        $nonAsciiFiles | Should -BeNullOrEmpty -Because 'bootstrap-loaded PowerShell sources must remain ASCII-only'
    }
}
