#!/usr/bin/env python3
"""Verify that local Markdown links resolve to tracked repository content."""

from __future__ import annotations

import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from urllib.parse import unquote, urlsplit


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MARKDOWN_LINK = re.compile(
    r"!?\[[^\]]*\]\((?:<(?P<angled>[^>]+)>|(?P<plain>[^)\s]+))"
)
EXTERNAL_SCHEMES = {"app", "http", "https", "mailto", "tel"}


@dataclass(frozen=True)
class LinkIssue:
    document: str
    target: str
    reason: str


def tracked_paths(repository_root: Path) -> set[str]:
    completed = subprocess.run(
        ["git", "ls-files", "-z"],
        cwd=repository_root,
        check=True,
        capture_output=True,
        text=True,
    )
    return {path for path in completed.stdout.split("\0") if path}


def local_target(document: str, target: str) -> str | None:
    if target.startswith("#"):
        return None
    parsed = urlsplit(target)
    if parsed.scheme.lower() in EXTERNAL_SCHEMES:
        return None
    if parsed.scheme or parsed.netloc or target.startswith("/"):
        return ""

    path = unquote(parsed.path)
    if not path:
        return None
    resolved = posixpath.normpath(
        posixpath.join(str(PurePosixPath(document).parent), path)
    )
    if resolved == ".." or resolved.startswith("../"):
        return ""
    return resolved


def find_link_issues(
    repository_root: Path,
    tracked: set[str],
) -> list[LinkIssue]:
    issues: list[LinkIssue] = []
    markdown_files = sorted(path for path in tracked if path.endswith(".md"))
    for document in markdown_files:
        document_path = repository_root / document
        if not document_path.is_file():
            issues.append(LinkIssue(document, document, "tracked document is missing"))
            continue
        contents = document_path.read_text(encoding="utf-8")
        for match in MARKDOWN_LINK.finditer(contents):
            target = match.group("angled") or match.group("plain")
            resolved = local_target(document, target)
            if resolved is None:
                continue
            if not resolved:
                issues.append(LinkIssue(document, target, "non-portable local target"))
                continue

            target_path = repository_root / resolved
            if not target_path.exists():
                reason = "target is missing"
            elif target_path.is_dir():
                prefix = f"{resolved.rstrip('/')}/"
                if any(path.startswith(prefix) for path in tracked):
                    continue
                reason = "target directory has no tracked content"
            elif resolved not in tracked:
                reason = "target exists only as an untracked file"
            else:
                continue
            issues.append(LinkIssue(document, target, reason))
    return issues


def main() -> int:
    try:
        tracked = tracked_paths(REPOSITORY_ROOT)
    except (OSError, subprocess.CalledProcessError) as error:
        print(f"Could not inspect tracked repository files: {error}", file=sys.stderr)
        return 2

    issues = find_link_issues(REPOSITORY_ROOT, tracked)
    if not issues:
        print("Documentation links resolve to tracked repository content.")
        return 0

    for issue in issues:
        print(
            f"{issue.document}: {issue.target}: {issue.reason}",
            file=sys.stderr,
        )
    print(
        f"Documentation integrity check failed with {len(issues)} issue(s).",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
