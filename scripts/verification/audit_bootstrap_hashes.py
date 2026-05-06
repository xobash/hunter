#!/usr/bin/env python3

from pathlib import Path
import hashlib
import re
import subprocess
import sys
from typing import Optional


REPO_ROOT = Path(__file__).resolve().parents[2]
LOADER_PATH = REPO_ROOT / "src/Hunter/Private/Bootstrap/Loader.ps1"
HUNTER_PATH = REPO_ROOT / "hunter.ps1"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha256_bytes(payload: bytes) -> str:
    return hashlib.sha256(payload).hexdigest()


def git_show_bytes(revision: str, relative_path: str) -> Optional[bytes]:
    result = subprocess.run(
        ["git", "show", f"{revision}:{relative_path.replace(chr(92), '/')}"],
        cwd=REPO_ROOT,
        capture_output=True,
        check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout


def main() -> int:
    loader_text = LOADER_PATH.read_text(encoding="utf-8")
    manifest_entries = re.findall(
        r"RelativePath = '([^']+)'; Sha256 = '([0-9a-fA-F]+)'",
        loader_text,
    )

    failures: list[str] = []

    if not manifest_entries:
        failures.append(f"{LOADER_PATH}: no bootstrap asset manifest entries found")

    for relative_path, expected_hash in manifest_entries:
        asset_path = REPO_ROOT / relative_path.replace("\\", "/")
        if not asset_path.exists():
            failures.append(f"missing bootstrap asset: {relative_path}")
            continue

        actual_hash = sha256(asset_path)
        if actual_hash.lower() != expected_hash.lower():
            failures.append(
                f"hash mismatch for {relative_path}: expected {expected_hash.lower()} got {actual_hash.lower()}"
            )

    hunter_text = HUNTER_PATH.read_text(encoding="utf-8")
    if not re.search(r"\$script:HunterReleaseChannel = '[^']+'", hunter_text):
        failures.append(f"{HUNTER_PATH}: HunterReleaseChannel assignment not found")

    if not re.search(r"\$script:HunterReleaseVersion = '[^']+'", hunter_text):
        failures.append(f"{HUNTER_PATH}: HunterReleaseVersion assignment not found")

    bootstrap_revision_match = re.search(r"\$script:HunterBootstrapRevision = '([0-9a-fA-F]{40})'", hunter_text)
    bootstrap_revision = None
    if not bootstrap_revision_match:
        failures.append(f"{HUNTER_PATH}: HunterBootstrapRevision assignment not found")
    else:
        bootstrap_revision = bootstrap_revision_match.group(1).lower()

    if not re.search(
        r"\$script:HunterRemoteRevision = \$script:HunterBootstrapRevision",
        hunter_text,
    ):
        failures.append(
            f"{HUNTER_PATH}: HunterRemoteRevision is not derived from HunterBootstrapRevision"
        )

    if not re.search(
        r"\$script:HunterRemoteRoot = 'https://raw\.githubusercontent\.com/xobash/hunter/\{0\}' -f \$script:HunterBootstrapRevision",
        hunter_text,
    ):
        failures.append(
            f"{HUNTER_PATH}: HunterRemoteRoot is not derived from HunterBootstrapRevision"
        )

    match = re.search(r"\$script:BootstrapLoaderSha256 = '([0-9a-fA-F]+)'", hunter_text)
    if not match:
        failures.append(f"{HUNTER_PATH}: BootstrapLoaderSha256 assignment not found")
    else:
        pinned_loader_hash = match.group(1).lower()
        actual_loader_hash = sha256(LOADER_PATH).lower()
        if pinned_loader_hash != actual_loader_hash:
            failures.append(
                f"loader hash mismatch: hunter.ps1 pins {pinned_loader_hash} but Loader.ps1 is {actual_loader_hash}"
            )

        if bootstrap_revision:
            revision_loader_bytes = git_show_bytes(
                bootstrap_revision,
                "src/Hunter/Private/Bootstrap/Loader.ps1",
            )
            if revision_loader_bytes is None:
                failures.append(
                    f"{HUNTER_PATH}: HunterBootstrapRevision {bootstrap_revision} does not expose src/Hunter/Private/Bootstrap/Loader.ps1 via git show"
                )
            else:
                revision_loader_hash = sha256_bytes(revision_loader_bytes).lower()
                if revision_loader_hash != pinned_loader_hash:
                    failures.append(
                        f"bootstrap revision drift: HunterBootstrapRevision {bootstrap_revision} resolves Loader.ps1 to {revision_loader_hash}, but hunter.ps1 pins {pinned_loader_hash}"
                    )

    if not re.search(
        r"\.\s+\(\[scriptblock\]::Create\(\(Get-Content -Path \$bootstrapLoaderPath -Raw -Encoding UTF8\)\)\)",
        hunter_text,
    ):
        failures.append(
            f"{HUNTER_PATH}: bootstrap loader is not executed from raw content via ScriptBlock::Create"
        )

    if not re.search(
        r"\$privateScriptPath = Join-Path \$script:HunterSourceRoot \(\[string\]\$privateScript\.RelativePath\)",
        hunter_text,
    ):
        failures.append(
            f"{HUNTER_PATH}: bootstrap private-script path binding not found"
        )

    if not re.search(
        r"\.\s+\(\[scriptblock\]::Create\(\(Get-Content -Path \$privateScriptPath -Raw -Encoding UTF8\)\)\)",
        hunter_text,
    ):
        failures.append(
            f"{HUNTER_PATH}: private bootstrap scripts are not executed from raw content via ScriptBlock::Create"
        )

    if re.search(r"(?m)^\.\s+\$bootstrapLoaderPath\s*$", hunter_text):
        failures.append(
            f"{HUNTER_PATH}: bootstrap loader still dot-sources the downloaded file path directly"
        )

    if failures:
        print("Bootstrap hash audit failed:", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print("Bootstrap hash audit passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
