#!/usr/bin/env python3
"""
tests/validate_frontmatter.py

Standalone validator for SKILL.md's frontmatter against the agentskills.io
spec (https://agentskills.io/specification) this project targets. Written
to have zero dependency on any external skill-authoring tool, so CI doesn't
need anything beyond Python + PyYAML.

Usage: tests/validate_frontmatter.py [path-to-skill-dir]
Exit 0 if valid, 1 otherwise (with reasons printed).
"""
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("PyYAML is required: pip install pyyaml")
    sys.exit(2)

ALLOWED_TOP_LEVEL = {"name", "description", "license", "compatibility", "metadata", "allowed-tools"}
NAME_RE = re.compile(r"^[a-z0-9]+(-[a-z0-9]+)*$")
MAX_DESCRIPTION = 1024
MAX_COMPATIBILITY = 500


def fail(msg, errors):
    errors.append(msg)


def main():
    skill_dir = (Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()).resolve()
    skill_md = skill_dir / "SKILL.md"
    errors = []

    if not skill_md.is_file():
        print(f"FAIL: no SKILL.md found at {skill_md}")
        sys.exit(1)

    text = skill_md.read_text(encoding="utf-8")
    m = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
    if not m:
        print("FAIL: SKILL.md does not start with a --- frontmatter block")
        sys.exit(1)

    try:
        fm = yaml.safe_load(m.group(1)) or {}
    except yaml.YAMLError as e:
        print(f"FAIL: frontmatter is not valid YAML: {e}")
        sys.exit(1)

    if not isinstance(fm, dict):
        fail("frontmatter did not parse to a mapping", errors)
        fm = {}

    # required fields
    for req in ("name", "description"):
        if req not in fm:
            fail(f"missing required field: {req}", errors)

    # unknown top-level fields
    for key in fm:
        if key not in ALLOWED_TOP_LEVEL:
            fail(f"unrecognized top-level field: {key} (allowed: {sorted(ALLOWED_TOP_LEVEL)})", errors)

    # name rules
    name = fm.get("name", "")
    if name:
        if not NAME_RE.match(name):
            fail(f"name '{name}' must be lowercase letters/digits/hyphens, no leading/trailing/double hyphens", errors)
        if name != skill_dir.name:
            fail(f"name '{name}' does not match the skill's directory name '{skill_dir.name}'", errors)

    # description length
    desc = fm.get("description", "")
    if len(desc) > MAX_DESCRIPTION:
        fail(f"description is {len(desc)} chars, max is {MAX_DESCRIPTION}", errors)
    if not desc:
        fail("description is empty", errors)

    # compatibility length
    compat = fm.get("compatibility", "")
    if compat and len(compat) > MAX_COMPATIBILITY:
        fail(f"compatibility is {len(compat)} chars, max is {MAX_COMPATIBILITY}", errors)

    # metadata must be a mapping if present
    if "metadata" in fm and not isinstance(fm["metadata"], dict):
        fail("metadata must be a mapping (key: value pairs)", errors)

    # every referenced references/, scripts/, adapters/, commands/ file that
    # SKILL.md links to via a bare relative path should actually exist —
    # lightweight check, not a full markdown-link crawl (see check_markdown_links.py
    # for that), just catches the most common "renamed a file, forgot a reference" case.
    # Paths SKILL.md legitimately references that are NOT expected to exist in
    # the shipped repo — each needs a real reason, not just "the check was noisy":
    #   - config/auditor.conf: generated per-deployment by installer/install.sh
    #     or copied by hand from config/auditor.conf.example; never shipped itself.
    #   - references/domain-focus.md: optional, created by the deployer if they
    #     want deployment-specific risk categories — SKILL.md explicitly treats
    #     its absence as the normal case ("if this file exists...").
    EXPECTED_ABSENT = {"config/auditor.conf", "references/domain-focus.md"}

    for rel in re.findall(r"`((?:references|scripts|adapters|commands|config)/[\w./-]+)`", text):
        if rel in EXPECTED_ABSENT:
            continue
        candidate = skill_dir / rel
        if not candidate.exists():
            fail(f"SKILL.md references `{rel}` (in backticks) which does not exist on disk", errors)

    if errors:
        print(f"FAIL: {len(errors)} issue(s) in {skill_md}")
        for e in errors:
            print(f"  - {e}")
        sys.exit(1)

    print(f"PASS: {skill_md} frontmatter is valid")
    sys.exit(0)


if __name__ == "__main__":
    main()
