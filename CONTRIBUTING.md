# Contributing

## Prerequisites

- Windows PowerShell 5.1 for runtime validation
- Python 3.12 for the verification scripts
- An elevated PowerShell session for full end-to-end execution

## Local Checks

Run these before opening a pull request or cutting a release:

```powershell
python scripts/verification/audit_bootstrap_hashes.py
python scripts/verification/audit_task_issue_compatibility.py
Invoke-ScriptAnalyzer -Path .\hunter.ps1, .\src -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester .\tests\Smoke -CI -Output Detailed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\hunter.ps1 -WhatIf -Profile Balanced
```

## Editing Rules

- Keep tracked PowerShell sources ASCII-only.
- Preserve task ID order unless the change intentionally adds, removes, or reorders a catalog entry and updates the matching smoke tests plus `docs/task-catalog.md`.
- Reuse the shared helpers in `src/Hunter/Private` for registry, service, scheduled-task, and optional-feature changes instead of open-coding new mutation paths.
- Update rollback coverage or add a manual-restore note when a change mutates state outside the existing rollback surfaces.

## Bootstrap-Managed Changes

If you change anything loaded by `src/Hunter/Private/Bootstrap/Loader.ps1`:

1. Refresh the loader manifest hashes.
2. Before publishing or tagging, update `hunter.ps1` so `HunterBootstrapRevision` and `BootstrapLoaderSha256` point at an immutable commit that already contains the private-layer change.
3. Re-run `python scripts/verification/audit_bootstrap_hashes.py`.

Command:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\Update-BootstrapHashes.ps1 -BootstrapRevision <commit-sha>
```

Use a commit SHA that is already present in the target branch history. If `HunterBootstrapRevision` points at an earlier bootstrap commit, do not squash that commit away before publishing.

## Release Flow

- Update `CHANGELOG.md`.
- Ensure `HunterReleaseVersion` matches the tag you plan to push.
- Push `v<semver>` to trigger `.github/workflows/release.yml`.

The release workflow packages the tagged tree and creates the GitHub release entry. It does not backfill bootstrap metadata for you.
