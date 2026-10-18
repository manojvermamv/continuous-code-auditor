#!/usr/bin/env python3
"""Create a stable, read-only-by-convention input snapshot for one audit run."""

from __future__ import annotations

import hashlib
import json
import os
import shlex
import shutil
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


EXCLUDED_ROOT_DIRS = {"work", "archives", "backups"}


def digest_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def inventory(path: Path, label: str) -> dict[str, str]:
    result: dict[str, str] = {}
    if path.is_symlink():
        return {label: "symlink:" + os.readlink(path)}
    if path.is_file():
        return {label: digest_file(path)}
    if not path.is_dir():
        raise ValueError(f"target does not exist or is not a file/directory: {path}")
    for current, dirs, files in os.walk(path, followlinks=False):
        current_path = Path(current)
        dirs.sort()
        files.sort()
        if current_path == path and label == ".":
            dirs[:] = [name for name in dirs if name not in EXCLUDED_ROOT_DIRS]
            files[:] = [name for name in files if name != ".git"]
        dirs[:] = [name for name in dirs if name != ".git"]
        files[:] = [name for name in files if name != ".git"]
        for name in list(dirs):
            item = current_path / name
            rel = item.relative_to(path).as_posix()
            if item.is_symlink():
                result[f"{label}/{rel}"] = "symlink:" + os.readlink(item)
                dirs.remove(name)
        for name in files:
            item = current_path / name
            rel = item.relative_to(path).as_posix()
            key = f"{label}/{rel}"
            result[key] = "symlink:" + os.readlink(item) if item.is_symlink() else digest_file(item)
    return result


def root_ignore(root: Path):
    def ignore(directory: str, names: list[str]) -> set[str]:
        ignored = {".git"}.intersection(names)
        if Path(directory).resolve() == root:
            ignored |= EXCLUDED_ROOT_DIRS.intersection(names)
        return ignored
    return ignore


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: create_source_snapshot.py PROJECT AUDIT_TARGET RETENTION_COUNT", file=sys.stderr)
        return 2
    project = Path(sys.argv[1]).resolve()
    target_text = sys.argv[2]
    try:
        retention = max(2, int(sys.argv[3]))
        # AUDIT_TARGET is normally passed as one shell-config value. Preserve
        # a legitimate path containing spaces as one target; only interpret
        # the value as a list when it does not name an existing path itself.
        raw_target = Path(target_text)
        resolved_raw_target = raw_target if raw_target.is_absolute() else project / raw_target
        tokens = [target_text] if resolved_raw_target.exists() or resolved_raw_target.is_symlink() else shlex.split(target_text)
        if not tokens:
            raise ValueError("AUDIT_TARGET is empty")
        whole_project = len(tokens) == 1 and (
            tokens[0] == "."
            or Path(os.path.abspath(tokens[0] if Path(tokens[0]).is_absolute() else project / tokens[0])) == project
        )
        sources: list[tuple[Path, str]] = []
        if whole_project:
            sources.append((project, "."))
        else:
            for token in tokens:
                raw = Path(token)
                source = raw if raw.is_absolute() else project / raw
                source = Path(os.path.abspath(source))
                if not source.exists() and not source.is_symlink():
                    raise ValueError(f"target does not exist: {source}")
                snapshots_dir = project / "work" / "source_snapshots"
                if source == snapshots_dir or snapshots_dir in source.parents:
                    raise ValueError("AUDIT_TARGET cannot include the auditor's own source_snapshots directory")
                label = source.relative_to(project).as_posix() if source.is_relative_to(project) else str(source)
                sources.append((source, label))

        before: dict[str, str] = {}
        for source, label in sources:
            before.update(inventory(source, label))
        if not before:
            raise ValueError("audit target contains no regular files or symlinks")

        manifest_text = "".join(f"{name}\0{value}\n" for name, value in sorted(before.items()))
        source_hash = hashlib.sha256(manifest_text.encode("utf-8")).hexdigest()

        snapshot_root = project / "work" / "source_snapshots"
        snapshot_root.mkdir(parents=True, exist_ok=True)
        pointer = snapshot_root / "current.json"
        if pointer.is_file():
            try:
                current = json.loads(pointer.read_text(encoding="utf-8"))
                current_path = Path(current["snapshot"])
                current_manifest = json.loads((current_path / "manifest.json").read_text(encoding="utf-8"))
                if current["source_hash"] == source_hash and current_path.is_dir():
                    print(current_path)
                    print(source_hash)
                    print(json.dumps(current_manifest["snapshot_targets"]))
                    return 0
            except (OSError, KeyError, json.JSONDecodeError):
                pass

        stage = Path(tempfile.mkdtemp(prefix=".stage-", dir=snapshot_root))
        payload = stage / "payload"
        payload.mkdir()
        snapshot_targets: list[str] = []
        for index, (source, label) in enumerate(sources):
            if whole_project:
                destination = payload / "project"
                shutil.copytree(source, destination, symlinks=True, ignore=root_ignore(project))
            else:
                destination = payload / "targets" / str(index) / source.name
                destination.parent.mkdir(parents=True, exist_ok=True)
                if source.is_dir() and not source.is_symlink():
                    shutil.copytree(source, destination, symlinks=True)
                elif source.is_symlink():
                    destination.symlink_to(os.readlink(source), target_is_directory=source.is_dir())
                else:
                    shutil.copy2(source, destination)
            snapshot_targets.append(str(destination))

        copied: dict[str, str] = {}
        for (source, label), destination in zip(sources, snapshot_targets):
            copied.update(inventory(Path(destination), label))
        after: dict[str, str] = {}
        for source, label in sources:
            after.update(inventory(source, label))
        if before != copied or before != after:
            raise RuntimeError("source changed while its snapshot was being created; retry the audit")

        snapshot_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ") + "_" + source_hash[:16]
        final = snapshot_root / snapshot_id
        final_targets = [str(final / Path(target).relative_to(stage)) for target in snapshot_targets]
        manifest = {
            "schema_version": 1,
            "created_at": datetime.now(timezone.utc).isoformat(),
            "source_hash": source_hash,
            "original_targets": [label for _source, label in sources],
            "snapshot_targets": final_targets,
            "entries": len(before),
            "symlinks": sum(value.startswith("symlink:") for value in before.values()),
        }
        (stage / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        stage.rename(final)

        pointer_tmp = snapshot_root / ".current.json.tmp"
        pointer_tmp.write_text(json.dumps({"snapshot": str(final), "source_hash": source_hash}) + "\n", encoding="utf-8")
        pointer_tmp.replace(snapshot_root / "current.json")

        snapshots = sorted((p for p in snapshot_root.iterdir() if p.is_dir() and not p.name.startswith(".stage-")), key=lambda p: p.stat().st_mtime, reverse=True)
        for old in snapshots[retention:]:
            if old != final:
                shutil.rmtree(old)

        print(final)
        print(source_hash)
        print(json.dumps(final_targets))
        return 0
    except Exception as exc:  # surfaced as a structured source-load failure by the runner
        try:
            if "stage" in locals() and stage.exists():
                shutil.rmtree(stage)
        except OSError:
            pass
        print(f"source snapshot failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
