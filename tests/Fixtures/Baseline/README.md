# Baseline Artifact Capture

Use the Phase 1 verification scripts to capture before/after artifacts from a Windows test VM and compare them across refactor phases.

## Artifacts To Capture

- `hunter.log`
- latest desktop `Hunter-Report-*.txt`
- `checkpoint.json`
- exported registry snapshots for selected keys
- service startup and state snapshot
- scheduled task snapshot
- shortcut inventory for desktop and Start Menu locations
- capture metadata and file hashes

## Suggested Workflow

Capture a baseline before a refactor phase:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verification\Capture-Baseline.ps1 -OutputPath .\artifacts\baseline\before
```

Capture another baseline after the phase:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verification\Capture-Baseline.ps1 -OutputPath .\artifacts\baseline\after
```

Compare the two captures:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\verification\Compare-Baseline.ps1 -BeforePath .\artifacts\baseline\before -AfterPath .\artifacts\baseline\after -OutputPath .\artifacts\baseline\compare
```

## Output Layout

`Capture-Baseline.ps1` writes:

- `capture-manifest.json`
- `metadata.json`
- `copies\`
- `registry\`
- `snapshots\`

`Compare-Baseline.ps1` writes:

- `comparison-summary.json`
- `comparison-summary.md`

## Notes

- The capture script is observational only. It should not modify Hunter state.
- Missing artifacts are recorded in the manifest instead of failing the entire capture.
- Registry snapshots are intentionally limited to a representative set of Hunter-managed areas.
