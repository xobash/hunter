$moduleRoot = Split-Path -Parent $PSCommandPath
$privateRoot = Join-Path $moduleRoot 'Private'

. (Join-Path $privateRoot 'Bootstrap\Config.ps1')
. (Join-Path $privateRoot 'Common\Common.ps1')
. (Join-Path $privateRoot 'Common\PathPolicy.ps1')
. (Join-Path $privateRoot 'Execution\Engine.ps1')
. (Join-Path $privateRoot 'Infrastructure\NativeSystem.ps1')

Remove-Variable -Name moduleRoot -ErrorAction SilentlyContinue
Remove-Variable -Name privateRoot -ErrorAction SilentlyContinue
