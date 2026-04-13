Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

param(
    [string]$HunterScriptPath = 'hunter.ps1',
    [string]$LoaderRelativePath = 'src\Hunter\Private\Bootstrap\Loader.ps1',
    [Alias('RemoteRevision')]
    [string]$BootstrapRevision = '',
    [string]$ReleaseChannel = '',
    [string]$ReleaseVersion = ''
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
$bootstrapRevisionPattern = "(?m)(?<prefix>\$script:HunterBootstrapRevision\s*=\s*')[0-9A-Fa-f]*(?<suffix>')"
$resolvedBootstrapRevision = $BootstrapRevision
if ([string]::IsNullOrWhiteSpace($resolvedBootstrapRevision)) {
    try {
        $resolvedBootstrapRevision = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
    } catch {
        $resolvedBootstrapRevision = ''
    }
}

if ([string]::IsNullOrWhiteSpace($resolvedBootstrapRevision)) {
    throw 'Could not determine HunterBootstrapRevision. Pass -BootstrapRevision explicitly or run inside a git worktree.'
}

if (-not [regex]::IsMatch($hunterScriptContent, $bootstrapRevisionPattern)) {
    throw "Could not find HunterBootstrapRevision assignment in $HunterScriptPath"
}

$hunterScriptContent = [regex]::Replace(
    $hunterScriptContent,
    $bootstrapRevisionPattern,
    ('${prefix}' + $resolvedBootstrapRevision + '${suffix}'),
    1
)

if (-not [string]::IsNullOrWhiteSpace($ReleaseChannel)) {
    $releaseChannelPattern = "(?m)(?<prefix>\$script:HunterReleaseChannel\s*=\s*')[^']*(?<suffix>')"
    if (-not [regex]::IsMatch($hunterScriptContent, $releaseChannelPattern)) {
        throw "Could not find HunterReleaseChannel assignment in $HunterScriptPath"
    }

    $hunterScriptContent = [regex]::Replace(
        $hunterScriptContent,
        $releaseChannelPattern,
        ('${prefix}' + $ReleaseChannel + '${suffix}'),
        1
    )
}

if (-not [string]::IsNullOrWhiteSpace($ReleaseVersion)) {
    $releaseVersionPattern = "(?m)(?<prefix>\$script:HunterReleaseVersion\s*=\s*')[^']*(?<suffix>')"
    if (-not [regex]::IsMatch($hunterScriptContent, $releaseVersionPattern)) {
        throw "Could not find HunterReleaseVersion assignment in $HunterScriptPath"
    }

    $hunterScriptContent = [regex]::Replace(
        $hunterScriptContent,
        $releaseVersionPattern,
        ('${prefix}' + $ReleaseVersion + '${suffix}'),
        1
    )
}

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

Write-Host ("{0} HunterRemoteRevision" -f $resolvedBootstrapRevision)
Write-Host ("{0} {1}" -f $loaderSha256, $LoaderRelativePath)
Write-Host ("{0} HunterBootstrapRevision" -f $resolvedBootstrapRevision)
if (-not [string]::IsNullOrWhiteSpace($ReleaseChannel)) {
    Write-Host ("{0} HunterReleaseChannel" -f $ReleaseChannel)
}
if (-not [string]::IsNullOrWhiteSpace($ReleaseVersion)) {
    Write-Host ("{0} HunterReleaseVersion" -f $ReleaseVersion)
}
Write-Host "Updated bootstrap manifest hashes in $LoaderRelativePath and loader metadata in $HunterScriptPath"
