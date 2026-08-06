#!/usr/bin/env python3
"""Verify every internal documentation link and anchor resolves.

The documentation here is a deliverable, and it cross-references itself
heavily — every ADR cited from another document is an anchor link into
DECISIONS.md. Renaming a heading silently breaks every link pointing at it, and
no other check in CI would notice. This one runs in under a second and needs
neither credentials nor network.

Checks:
  1. Relative file links resolve to a file that exists.
  2. Anchor links (`#adr-003`, `#job-failure`) resolve to a heading or an
     explicit `{#id}` in the target document.
  3. Documents referenced from the README index actually exist.

Deliberately does not check external URLs — a link checker that fails the build
because someone else's site is briefly down is a link checker people disable.

    python3 scripts/python/check_docs.py
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]

# Directories that hold vendored content we neither wrote nor control.
SKIP_PARTS = {".git", ".terraform", "node_modules"}

LINK = re.compile(r"\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
HEADING = re.compile(r"^#{1,6}\s+(.*?)\s*$", re.M)
EXPLICIT_ID = re.compile(r"\{#([A-Za-z0-9._-]+)\}")


def slugify(heading: str) -> str:
    """GitHub's heading-to-anchor rule, closely enough for our headings.

    Strips an explicit {#id}, drops anything that is not alphanumeric, space or
    hyphen, lowercases, then joins on hyphens.
    """
    text = EXPLICIT_ID.sub("", heading)
    text = re.sub(r"`([^`]*)`", r"\1", text)          # inline code keeps its text
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", text)  # links keep their label
    text = re.sub(r"[^\w\s-]", "", text, flags=re.UNICODE)
    return re.sub(r"[\s]+", "-", text.strip()).lower()


def anchors_for(path: Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    found = {slugify(h) for h in HEADING.findall(text)}
    found |= set(EXPLICIT_ID.findall(text))
    return found


def markdown_files() -> list[Path]:
    return sorted(
        p for p in REPO.rglob("*.md")
        if not SKIP_PARTS & set(p.relative_to(REPO).parts)
    )


def main() -> int:
    files = markdown_files()
    if not files:
        print("No markdown found.")
        return 1

    anchor_cache: dict[Path, set[str]] = {}
    problems: list[str] = []
    checked = 0

    for md in files:
        rel = md.relative_to(REPO)
        for target in LINK.findall(md.read_text(encoding="utf-8", errors="replace")):
            # External, absolute, mailto and pure-anchor-to-self are out of scope.
            if target.startswith(("http://", "https://", "mailto:", "//")):
                continue

            path_part, _, anchor = target.partition("#")
            checked += 1

            if path_part:
                resolved = (md.parent / path_part).resolve()
                if not resolved.exists():
                    problems.append(f"{rel} -> {target}  (file not found)")
                    continue
                if resolved.suffix != ".md":
                    continue  # a link to a script or html file; existence is enough
            else:
                resolved = md  # anchor within this document

            if anchor:
                if resolved not in anchor_cache:
                    anchor_cache[resolved] = anchors_for(resolved)
                if anchor.lower() not in anchor_cache[resolved]:
                    problems.append(
                        f"{rel} -> {target}  (no heading or {{#id}} matching "
                        f"'{anchor}' in {resolved.relative_to(REPO)})"
                    )

    print(f"Checked {checked} internal link(s) across {len(files)} document(s).\n")

    if problems:
        print(f"{len(problems)} broken link(s):\n")
        for p in problems:
            print(f"  {p}")
        print("\nRename the heading back, or update the link. Anchors are derived from")
        print("heading text, so editing a heading changes its anchor.")
        return 1

    print("All internal links and anchors resolve.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
