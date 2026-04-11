#!/usr/bin/env python3

from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parents[2]


def require_all(path: Path, required_snippets: list[str]) -> list[str]:
    text = path.read_text(encoding="utf-8")
    missing = [snippet for snippet in required_snippets if snippet not in text]
    return [f"{path}: missing {snippet!r}" for snippet in missing]


def main() -> int:
    failures: list[str] = []

    failures.extend(
        require_all(
            REPO_ROOT / "src/Hunter/Private/Common/Common.ps1",
            [
                "$script:TaskIssueTrackingEnabled = $false",
                "$script:CurrentTaskLoggedWarning = $false",
                "$script:CurrentTaskLoggedError = $false",
                "function Reset-HunterTaskIssueState {",
                "function Enable-HunterTaskIssueTracking {",
                "function Disable-HunterTaskIssueTracking {",
                "if ($script:TaskIssueTrackingEnabled) {",
                "'ERROR' { $script:CurrentTaskLoggedError = $true }",
                "'WARN' { $script:CurrentTaskLoggedWarning = $true }",
                "Success = $true",
                "[bool]$LoggedWarning = $false",
                "'Skipped' { return 'Skipped' }",
                "if ($LoggedWarning) {",
                "[bool]$LoggedError = $false",
                "if ($LoggedError) {",
            ],
        )
    )

    failures.extend(
        require_all(
            REPO_ROOT / "src/Hunter/Private/Execution/Engine.ps1",
            [
                "Enable-HunterTaskIssueTracking",
                "Disable-HunterTaskIssueTracking",
                "-LoggedError:$script:CurrentTaskLoggedError",
                "-LoggedWarning:$script:CurrentTaskLoggedWarning",
                "Reset-HunterTaskIssueState",
            ],
        )
    )

    failures.extend(
        require_all(
            REPO_ROOT / "src/Hunter/Private/Tasks/Cleanup.ps1",
            [
                "Enable-HunterTaskIssueTracking",
                "Disable-HunterTaskIssueTracking",
                "-LoggedError:$script:CurrentTaskLoggedError",
                "-LoggedWarning:$script:CurrentTaskLoggedWarning",
                "Reset-HunterTaskIssueState",
            ],
        )
    )

    if failures:
        print("Task issue compatibility audit failed:", file=sys.stderr)
        for failure in failures:
            print(f" - {failure}", file=sys.stderr)
        return 1

    print("Task issue compatibility audit passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
