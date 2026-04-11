$moduleRoot = Split-Path -Parent $PSCommandPath
$repoRoot = Split-Path -Parent (Split-Path -Parent $moduleRoot)
$loaderPath = Join-Path $moduleRoot 'Private\Bootstrap\Loader.ps1'

. $loaderPath
$script:HunterSourceRoot = $repoRoot
Import-HunterPrivateScripts -SourceRoot $repoRoot

Remove-Variable -Name moduleRoot -ErrorAction SilentlyContinue
Remove-Variable -Name repoRoot -ErrorAction SilentlyContinue
Remove-Variable -Name loaderPath -ErrorAction SilentlyContinue
