[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BeforePath,
    [Parameter(Mandatory)][string]$AfterPath,
    [string]$OutputPath = (Join-Path (Join-Path $PSScriptRoot '..\..\artifacts\baseline') 'compare')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )

    $InputObject | ConvertTo-Json -Depth 8 | Set-Content -Path $Path -Encoding UTF8
}

function Compare-ArtifactManifest {
    param(
        [Parameter(Mandatory)][object[]]$BeforeArtifacts,
        [Parameter(Mandatory)][object[]]$AfterArtifacts
    )

    $beforeMap = @{}
    foreach ($artifact in $BeforeArtifacts) {
        $beforeMap["$($artifact.Category)|$($artifact.Name)"] = $artifact
    }

    $afterMap = @{}
    foreach ($artifact in $AfterArtifacts) {
        $afterMap["$($artifact.Category)|$($artifact.Name)"] = $artifact
    }

    $allKeys = @($beforeMap.Keys + $afterMap.Keys) | Sort-Object -Unique
    $results = foreach ($key in $allKeys) {
        $before = $beforeMap[$key]
        $after = $afterMap[$key]

        $status = if ($null -eq $before) {
            'Added'
        } elseif ($null -eq $after) {
            'Removed'
        } elseif (-not $before.Exists -and -not $after.Exists) {
            'MissingInBoth'
        } elseif ($before.Exists -ne $after.Exists) {
            'PresenceChanged'
        } elseif ($before.Hash -ne $after.Hash) {
            'Changed'
        } else {
            'Unchanged'
        }

        [pscustomobject]@{
            Key        = $key
            Category   = if ($null -ne $after) { $after.Category } else { $before.Category }
            Name       = if ($null -ne $after) { $after.Name } else { $before.Name }
            Status     = $status
            BeforeHash = if ($null -ne $before) { $before.Hash } else { $null }
            AfterHash  = if ($null -ne $after) { $after.Hash } else { $null }
            BeforePath = if ($null -ne $before) { $before.RelativePath } else { $null }
            AfterPath  = if ($null -ne $after) { $after.RelativePath } else { $null }
        }
    }

    return ,$results
}

function Compare-CsvSnapshot {
    param(
        [Parameter(Mandatory)][string]$BeforeFile,
        [Parameter(Mandatory)][string]$AfterFile,
        [Parameter(Mandatory)][string]$KeyProperty,
        [Parameter(Mandatory)][string[]]$CompareProperties
    )

    if (-not (Test-Path -LiteralPath $BeforeFile) -or -not (Test-Path -LiteralPath $AfterFile)) {
        return [pscustomobject]@{
            Added   = @()
            Removed = @()
            Changed = @()
        }
    }

    $beforeRows = @{}
    foreach ($row in (Import-Csv -Path $BeforeFile)) {
        $beforeRows[$row.$KeyProperty] = $row
    }

    $afterRows = @{}
    foreach ($row in (Import-Csv -Path $AfterFile)) {
        $afterRows[$row.$KeyProperty] = $row
    }

    $allKeys = @($beforeRows.Keys + $afterRows.Keys) | Sort-Object -Unique
    $added = New-Object 'System.Collections.Generic.List[object]'
    $removed = New-Object 'System.Collections.Generic.List[object]'
    $changed = New-Object 'System.Collections.Generic.List[object]'

    foreach ($key in $allKeys) {
        if (-not $beforeRows.ContainsKey($key)) {
            $added.Add($afterRows[$key]) | Out-Null
            continue
        }

        if (-not $afterRows.ContainsKey($key)) {
            $removed.Add($beforeRows[$key]) | Out-Null
            continue
        }

        $differences = @{}
        foreach ($property in $CompareProperties) {
            if ($beforeRows[$key].$property -ne $afterRows[$key].$property) {
                $differences[$property] = @{
                    Before = $beforeRows[$key].$property
                    After  = $afterRows[$key].$property
                }
            }
        }

        if ($differences.Count -gt 0) {
            $changed.Add([pscustomobject]@{
                Key         = $key
                Differences = $differences
            }) | Out-Null
        }
    }

    return [pscustomobject]@{
        Added   = @($added)
        Removed = @($removed)
        Changed = @($changed)
    }
}

Ensure-Directory $OutputPath

$beforeManifestPath = Join-Path $BeforePath 'capture-manifest.json'
$afterManifestPath = Join-Path $AfterPath 'capture-manifest.json'

if (-not (Test-Path -LiteralPath $beforeManifestPath)) {
    throw "Before manifest not found: $beforeManifestPath"
}

if (-not (Test-Path -LiteralPath $afterManifestPath)) {
    throw "After manifest not found: $afterManifestPath"
}

$beforeManifest = Get-Content -Path $beforeManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
$afterManifest = Get-Content -Path $afterManifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop

$artifactComparison = @(Compare-ArtifactManifest -BeforeArtifacts @($beforeManifest.Artifacts) -AfterArtifacts @($afterManifest.Artifacts))

$serviceComparison = Compare-CsvSnapshot `
    -BeforeFile (Join-Path $BeforePath 'snapshots\services.csv') `
    -AfterFile (Join-Path $AfterPath 'snapshots\services.csv') `
    -KeyProperty 'Name' `
    -CompareProperties @('StartMode', 'State', 'StartName')

$scheduledTaskComparison = Compare-CsvSnapshot `
    -BeforeFile (Join-Path $BeforePath 'snapshots\scheduled-tasks.csv') `
    -AfterFile (Join-Path $AfterPath 'snapshots\scheduled-tasks.csv') `
    -KeyProperty 'TaskKey' `
    -CompareProperties @('State', 'Author', 'Description')

$shortcutComparison = Compare-CsvSnapshot `
    -BeforeFile (Join-Path $BeforePath 'snapshots\shortcuts.csv') `
    -AfterFile (Join-Path $AfterPath 'snapshots\shortcuts.csv') `
    -KeyProperty 'ShortcutPath' `
    -CompareProperties @('TargetPath', 'Arguments', 'WorkingDir')

$summary = [ordered]@{
    ComparedAt             = (Get-Date).ToString('o')
    BeforePath             = $BeforePath
    AfterPath              = $AfterPath
    ArtifactStatusCounts   = $artifactComparison | Group-Object Status | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Status = $_.Name
            Count  = $_.Count
        }
    }
    ArtifactComparison     = $artifactComparison
    ServiceComparison      = $serviceComparison
    ScheduledTaskComparison = $scheduledTaskComparison
    ShortcutComparison     = $shortcutComparison
}

Save-JsonFile -InputObject $summary -Path (Join-Path $OutputPath 'comparison-summary.json')

$markdownLines = @(
    '# Baseline Comparison',
    '',
    "Compared at: $($summary.ComparedAt)",
    '',
    '## Artifact Status Counts',
    ''
)

foreach ($row in @($summary.ArtifactStatusCounts)) {
    $markdownLines += "- $($row.Status): $($row.Count)"
}

$markdownLines += ''
$markdownLines += '## Structured Drift Summary'
$markdownLines += ''
$markdownLines += "- Services changed: $(@($serviceComparison.Changed).Count)"
$markdownLines += "- Services added: $(@($serviceComparison.Added).Count)"
$markdownLines += "- Services removed: $(@($serviceComparison.Removed).Count)"
$markdownLines += "- Scheduled tasks changed: $(@($scheduledTaskComparison.Changed).Count)"
$markdownLines += "- Scheduled tasks added: $(@($scheduledTaskComparison.Added).Count)"
$markdownLines += "- Scheduled tasks removed: $(@($scheduledTaskComparison.Removed).Count)"
$markdownLines += "- Shortcuts changed: $(@($shortcutComparison.Changed).Count)"
$markdownLines += "- Shortcuts added: $(@($shortcutComparison.Added).Count)"
$markdownLines += "- Shortcuts removed: $(@($shortcutComparison.Removed).Count)"
$markdownLines += ''

Set-Content -Path (Join-Path $OutputPath 'comparison-summary.md') -Value $markdownLines -Encoding UTF8

Write-Host "Comparison written to $OutputPath"
