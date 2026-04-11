#!/usr/bin/env python3

from pathlib import Path
import hashlib
import re
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]
LOADER_PATH = REPO_ROOT / "src/Hunter/Private/Bootstrap/Loader.ps1"
HUNTER_PATH = REPO_ROOT / "hunter.ps1"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


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

    if failures:
        print("Bootstrap hash audit failed:", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print("Bootstrap hash audit passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
