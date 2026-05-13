$moduleRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $moduleRoot)
$loaderPath = Join-Path $moduleRoot 'Private\Bootstrap\Loader.ps1'

. ([scriptblock]::Create((Get-Content -Path $loaderPath -Raw -Encoding UTF8)))
$script:HunterSourceRoot = $repoRoot
foreach ($privateScript in @(Get-HunterPrivateScriptManifest)) {
    $privateScriptPath = Join-Path $repoRoot ([string]$privateScript.RelativePath)
    . ([scriptblock]::Create((Get-Content -Path $privateScriptPath -Raw -Encoding UTF8)))
}

Remove-Variable -Name moduleRoot -ErrorAction SilentlyContinue
Remove-Variable -Name repoRoot -ErrorAction SilentlyContinue
Remove-Variable -Name loaderPath -ErrorAction SilentlyContinue
Remove-Variable -Name privateScriptPath -ErrorAction SilentlyContinue
