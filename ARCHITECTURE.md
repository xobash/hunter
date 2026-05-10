# Hunter Architecture

Hunter is a single-entry PowerShell runner with a bootstrap-loaded private source tree. The project is organized around a fixed task catalog, checkpoint and resume execution, rollback capture, and reproducible bootstrap assets.

## Runtime Flow

1. `hunter.ps1` is the public entry script. It can run from a local checkout or bootstrap the private source tree from a pinned Git revision.
2. `src/Hunter/Private/Bootstrap/Loader.ps1` defines the private-asset manifest and validates SHA-256 hashes for every bootstrap-loaded file.
3. `src/Hunter/Hunter.psm1` loads the same private source tree when the project is imported as a module.
4. `src/Hunter/Private/Execution/Engine.ps1` builds tasks from `src/Hunter/Private/Tasks/Catalog.ps1`, applies profile and skip filtering, writes checkpoints, and executes handlers in phase order.
5. `src/Hunter/Private/Tasks/Cleanup.ps1` exports logs and reports, then runs post-run validation checks.

## Repository Map

- `hunter.ps1`: public entry point, bootstrap metadata, CLI surface, execution-plan logging.
- `src/Hunter/Private/Bootstrap`: bootstrap manifest, script-state defaults, shared execution context.
- `src/Hunter/Private/Execution`: task execution engine and scheduled resume support.
- `src/Hunter/Private/Tasks`: cataloged task handlers grouped by phase.
- `src/Hunter/Private/Registry`, `Services`, `Infrastructure`, `System`: shared mutation helpers and platform probes.
- `src/Hunter/Private/State`: rollback capture and restore-script generation.
- `src/Hunter/Config/Apps.json`: supported app-removal catalog.
- `tests/Smoke`: parser, compatibility, catalog, and repository-structure guardrails.
- `scripts/verification`: repository audits that are fast enough for CI.

## Task Model

The live task catalog is defined in `src/Hunter/Private/Tasks/Catalog.ps1`.

- Every task has a stable ID, phase, handler, description, risk level, and profile membership.
- Profiles are additive filters over the same ordered catalog rather than separate code paths.
- `docs/task-catalog.md` mirrors the catalog and should change in the same patch when task IDs, descriptions, or profile coverage move.
- The engine records checkpoints by task ID, so task ordering and ID stability matter for resume safety and test coverage.

## Safety Model

Hunter assumes administrative execution and compensates with layered safeguards:

- restore-point creation for interactive runs outside the `VMReset` profile
- rollback capture for shared registry, service, scheduled-task, and active power-plan mutations
- validation checks after the main run completes
- `-WhatIf`, task skips, and profile filters for narrower execution

Any new mutation surface should either reuse existing rollback helpers or record an explicit manual-restore note.

## Bootstrap Pinning

`hunter.ps1` pins two pieces of bootstrap metadata:

- `HunterBootstrapRevision`: immutable Git commit used by remote bootstrap downloads
- `BootstrapLoaderSha256`: integrity check for the bootstrap loader itself

Changes under `src/Hunter/Private` or `src/Hunter/Config/Apps.json` change the loader manifest. Those changes must be followed by a bootstrap-pin refresh before publishing a raw bootstrap build, or `irm ... | iex` can drift from the checked-in private layer.

## CI And Releases

- `.github/workflows/windows-ci.yml`: fast Windows smoke validation for pushes and pull requests
- `.github/workflows/windows-e2e-self-hosted.yml`: disposable self-hosted `VMReset` validation
- `.github/workflows/release.yml`: tag-driven packaging and GitHub release publication

The release pipeline is intentionally downstream of the bootstrap pinning workflow. CI validates the repository state; releases publish the exact tagged artifact set.
