$moduleRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $moduleRoot)
$loaderPath = Join-Path $moduleRoot 'Private\Bootstrap\Loader.ps1'

. $loaderPath
$script:HunterSourceRoot = $repoRoot
foreach ($privateScript in @(Get-HunterPrivateScriptManifest)) {
    . (Join-Path $repoRoot ([string]$privateScript.RelativePath))
}

Remove-Variable -Name moduleRoot -ErrorAction SilentlyContinue
Remove-Variable -Name repoRoot -ErrorAction SilentlyContinue
Remove-Variable -Name loaderPath -ErrorAction SilentlyContinue
