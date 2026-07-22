#!/usr/bin/env python3
"""
tests/check_markdown_links.py

Walks every .md file in the skill directory and verifies that every
relative (non-http, non-anchor-only) markdown link resolves to a real file
on disk. Does not check external http(s) links (no network access assumed
in CI) or bare anchors within the same file.

Usage: tests/check_markdown_links.py [path-to-skill-dir]
Exit 0 if every link resolves, 1 otherwise (with the broken links listed).
"""
import re
import sys
from pathlib import Path

LINK_RE = re.compile(r"\[([^\]]*)\]\(([^)]+)\)")


def main():
    root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    md_files = sorted(root.rglob("*.md"))
    broken = []

    for md in md_files:
        content = md.read_text(encoding="utf-8")
        for _text, target in LINK_RE.findall(content):
            if target.startswith(("http://", "https://", "mailto:")):
                continue
            if target.startswith("#"):
                continue
            path_part = target.split("#", 1)[0]
            if not path_part:
                continue
            resolved = (md.parent / path_part).resolve()
            if not resolved.exists():
                broken.append((str(md.relative_to(root)), target, str(resolved)))

    if broken:
        print(f"FAIL: {len(broken)} broken internal link(s):")
        for md, target, resolved in broken:
            print(f"  {md} -> {target}  (resolved: {resolved})")
        sys.exit(1)

    print(f"PASS: all internal links across {len(md_files)} markdown file(s) resolve")
    sys.exit(0)


if __name__ == "__main__":
    main()
