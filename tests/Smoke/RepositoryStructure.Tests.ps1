Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Describe 'Repository structure' {
    BeforeAll {
        $repoRoot = Join-Path $PSScriptRoot '..\..'
        $architecturePath = Join-Path $repoRoot 'ARCHITECTURE.md'
        $contributingPath = Join-Path $repoRoot 'CONTRIBUTING.md'
        $changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
        $scriptAnalyzerSettingsPath = Join-Path $repoRoot 'PSScriptAnalyzerSettings.psd1'
        $ciWorkflowPath = Join-Path $repoRoot '.github/workflows/windows-ci.yml'
        $e2eWorkflowPath = Join-Path $repoRoot '.github/workflows/windows-e2e-self-hosted.yml'
        $releaseWorkflowPath = Join-Path $repoRoot '.github/workflows/release.yml'
        $ciWorkflowSource = Get-Content -Path $ciWorkflowPath -Raw -ErrorAction Stop
        $e2eWorkflowSource = Get-Content -Path $e2eWorkflowPath -Raw -ErrorAction Stop
        $releaseWorkflowSource = Get-Content -Path $releaseWorkflowPath -Raw -ErrorAction Stop
    }

    It 'ships top-level maintainer docs' {
        Test-Path $architecturePath | Should -BeTrue
        Test-Path $contributingPath | Should -BeTrue
        Test-Path $changelogPath | Should -BeTrue
    }

    It 'ships ScriptAnalyzer settings and runs them in Windows workflows' {
        Test-Path $scriptAnalyzerSettingsPath | Should -BeTrue
        $ciWorkflowSource | Should -Match 'PSScriptAnalyzer'
        $ciWorkflowSource | Should -Match 'Invoke-ScriptAnalyzer'
        $e2eWorkflowSource | Should -Match 'PSScriptAnalyzer'
        $e2eWorkflowSource | Should -Match 'Invoke-ScriptAnalyzer'
    }

    It 'ships a tag-driven release workflow' {
        Test-Path $releaseWorkflowPath | Should -BeTrue
        $releaseWorkflowSource | Should -Match 'tags:'
        $releaseWorkflowSource | Should -Match 'v\*'
        $releaseWorkflowSource | Should -Match 'gh release create'
    }
}
