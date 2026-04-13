Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
    [string]$HunterScriptPath = 'hunter.ps1',
    [string]$LoaderRelativePath = 'src\Hunter\Private\Bootstrap\Loader.ps1',
    [string]$RemoteRevision = ''
)

$repoRoot = Split-Path -Parent $PSScriptRoot
$hunterScriptFullPath = Join-Path $repoRoot $HunterScriptPath
$loaderFullPath = Join-Path $repoRoot $LoaderRelativePath

if (-not (Test-Path $hunterScriptFullPath)) {
    throw "Could not find Hunter entry script at $HunterScriptPath"
}

if (-not (Test-Path $loaderFullPath)) {
    throw "Could not find Hunter bootstrap loader at $LoaderRelativePath"
}

$loaderContent = Get-Content -Path $loaderFullPath -Raw -ErrorAction Stop
$manifestMatches = [regex]::Matches(
    $loaderContent,
    "(?m)RelativePath\s*=\s*'(?<path>[^']+)'\s*;\s*Sha256\s*=\s*'(?<hash>[0-9A-Fa-f]*)'"
)

if ($manifestMatches.Count -eq 0) {
    throw "Could not find any bootstrap asset manifest entries in $LoaderRelativePath"
}

$processedRelativePaths = @{}

foreach ($manifestMatch in $manifestMatches) {
    $assetRelativePath = [string]$manifestMatch.Groups['path'].Value
    if ($processedRelativePaths.ContainsKey($assetRelativePath)) {
        continue
    }

    $processedRelativePaths[$assetRelativePath] = $true
    $assetFullPath = Join-Path $repoRoot $assetRelativePath
    if (-not (Test-Path $assetFullPath)) {
        throw "Bootstrap asset is missing: $assetRelativePath"
    }

    $assetSha256 = (Get-FileHash -Path $assetFullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
    $escapedRelativePath = [regex]::Escape($assetRelativePath)
    $assetPattern = "(?m)(?<prefix>RelativePath\s*=\s*'$escapedRelativePath'\s*;\s*Sha256\s*=\s*')[0-9A-Fa-f]*(?<suffix>')"
    if (-not [regex]::IsMatch($loaderContent, $assetPattern)) {
        throw "Could not find manifest hash entry for $assetRelativePath in $LoaderRelativePath"
    }

    $loaderContent = [regex]::Replace(
        $loaderContent,
        $assetPattern,
        ('${prefix}' + $assetSha256 + '${suffix}'),
        1
    )

    Write-Host ("{0} {1}" -f $assetSha256, $assetRelativePath)
}

Set-Content -Path $loaderFullPath -Value $loaderContent -Encoding UTF8 -Force

$loaderSha256 = (Get-FileHash -Path $loaderFullPath -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
$hunterScriptContent = Get-Content -Path $hunterScriptFullPath -Raw -ErrorAction Stop
$remoteRevisionPattern = "(?m)(?<prefix>\$script:HunterRemoteRevision\s*=\s*')[0-9A-Fa-f]*(?<suffix>')"
$resolvedRemoteRevision = $RemoteRevision
if ([string]::IsNullOrWhiteSpace($resolvedRemoteRevision)) {
    try {
        $resolvedRemoteRevision = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
    } catch {
        $resolvedRemoteRevision = ''
    }
}

if ([string]::IsNullOrWhiteSpace($resolvedRemoteRevision)) {
    throw 'Could not determine HunterRemoteRevision. Pass -RemoteRevision explicitly or run inside a git worktree.'
}

if (-not [regex]::IsMatch($hunterScriptContent, $remoteRevisionPattern)) {
    throw "Could not find HunterRemoteRevision assignment in $HunterScriptPath"
}

$hunterScriptContent = [regex]::Replace(
    $hunterScriptContent,
    $remoteRevisionPattern,
    ('${prefix}' + $resolvedRemoteRevision + '${suffix}'),
    1
)

$loaderHashPattern = "(?m)(?<prefix>\$script:BootstrapLoaderSha256\s*=\s*')[0-9A-Fa-f]*(?<suffix>')"
if (-not [regex]::IsMatch($hunterScriptContent, $loaderHashPattern)) {
    throw "Could not find BootstrapLoaderSha256 assignment in $HunterScriptPath"
}

$hunterScriptContent = [regex]::Replace(
    $hunterScriptContent,
    $loaderHashPattern,
    ('${prefix}' + $loaderSha256 + '${suffix}'),
    1
)

Set-Content -Path $hunterScriptFullPath -Value $hunterScriptContent -Encoding UTF8 -Force

Write-Host ("{0} HunterRemoteRevision" -f $resolvedRemoteRevision)
Write-Host ("{0} {1}" -f $loaderSha256, $LoaderRelativePath)
Write-Host "Updated bootstrap manifest hashes in $LoaderRelativePath and loader hash in $HunterScriptPath"
