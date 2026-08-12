from pathlib import Path

from scripts.check_docs import find_link_issues, local_target


def test_local_target_resolves_relative_paths_and_skips_external_links():
    assert local_target("docs/current.md", "sprints/next.md#scope") == (
        "docs/sprints/next.md"
    )
    assert local_target("docs/current.md", "#scope") is None
    assert local_target("docs/current.md", "https://example.test/privacy") is None
    assert local_target("docs/current.md", "../../outside.md") == ""


def test_find_link_issues_rejects_missing_and_untracked_targets(tmp_path: Path):
    docs = tmp_path / "docs"
    docs.mkdir()
    (docs / "current.md").write_text(
        "[Tracked](tracked.md) [Untracked](untracked.md) [Missing](missing.md)",
        encoding="utf-8",
    )
    (docs / "tracked.md").write_text("# Tracked\n", encoding="utf-8")
    (docs / "untracked.md").write_text("# Untracked\n", encoding="utf-8")

    issues = find_link_issues(
        tmp_path,
        {"docs/current.md", "docs/tracked.md"},
    )

    assert [(issue.target, issue.reason) for issue in issues] == [
        ("untracked.md", "target exists only as an untracked file"),
        ("missing.md", "target is missing"),
    ]
