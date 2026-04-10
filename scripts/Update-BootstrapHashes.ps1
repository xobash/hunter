Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
    [string]$HunterScriptPath = 'hunter.ps1'
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$hunterScriptFullPath = Join-Path $repoRoot $HunterScriptPath
if (-not (Test-Path $hunterScriptFullPath)) {
    throw "Could not find Hunter entry script at $HunterScriptPath"
}

$bootstrapRelativePaths = @(
    'src\Hunter\Private\Bootstrap\Config.ps1',
    'src\Hunter\Private\Common\Common.ps1',
    'src\Hunter\Private\Common\PathPolicy.ps1',
    'src\Hunter\Private\Execution\Engine.ps1',
    'src\Hunter\Private\Infrastructure\NativeSystem.ps1',
    'src\Hunter\Config\Apps.json'
)

$hunterScriptContent = Get-Content -Path $hunterScriptFullPath -Raw -ErrorAction Stop

foreach ($bootstrapRelativePath in $bootstrapRelativePaths) {
    $bootstrapFullPath = Join-Path $repoRoot $bootstrapRelativePath
    if (-not (Test-Path $bootstrapFullPath)) {
        throw "Bootstrap file is missing: $bootstrapRelativePath"
    }

    $sha256 = (Get-FileHash -Path $bootstrapFullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $escapedRelativePath = [regex]::Escape($bootstrapRelativePath)
    $pattern = "(?m)(?<prefix>\s*'$escapedRelativePath'\s*=\s*')[0-9a-f]{64}(?<suffix>')"
    if (-not [regex]::IsMatch($hunterScriptContent, $pattern)) {
        throw "Could not find embedded bootstrap hash entry for $bootstrapRelativePath in $HunterScriptPath"
    }

    $hunterScriptContent = [regex]::Replace(
        $hunterScriptContent,
        $pattern,
        ('${prefix}' + $sha256 + '${suffix}'),
        1
    )

    Write-Host ("{0} {1}" -f $sha256, $bootstrapRelativePath)
}

Set-Content -Path $hunterScriptFullPath -Value $hunterScriptContent -Encoding UTF8 -Force
Write-Host "Updated embedded bootstrap hashes in $HunterScriptPath"
