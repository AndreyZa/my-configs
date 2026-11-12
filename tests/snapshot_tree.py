#!/usr/bin/env python3
"""Assert that a repeat operation leaves managed files and metadata untouched."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat


def capture(root, excluded):
    result = {}

    def ignored(relative):
        return any(relative == item or relative.startswith(item + "/") for item in excluded)

    def record(path):
        relative = path.relative_to(root).as_posix()
        if ignored(relative):
            return
        info = path.lstat()
        entry = {
            "mode": info.st_mode,
            "inode": info.st_ino,
            "mtime_ns": info.st_mtime_ns,
            "ctime_ns": info.st_ctime_ns,
        }
        if stat.S_ISLNK(info.st_mode):
            entry["target"] = os.readlink(path)
        elif stat.S_ISREG(info.st_mode):
            entry["size"] = info.st_size
            # Metadata catches replaced/rewritten large binaries. Hash small
            # configs too, without rereading gigabytes of installed toolchains.
            if info.st_size <= 1024 * 1024:
                entry["sha256"] = hashlib.sha256(path.read_bytes()).hexdigest()
        result[relative] = entry

    record(root)
    for directory, subdirectories, files in os.walk(root, followlinks=False):
        parent = Path(directory)
        subdirectories[:] = sorted(
            item for item in subdirectories
            if not ignored((parent / item).relative_to(root).as_posix())
        )
        for name in subdirectories + sorted(files):
            record(parent / name)
    return result


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("operation", choices=("capture", "check"))
parser.add_argument("root", type=Path)
parser.add_argument("snapshot", type=Path)
parser.add_argument("--exclude", action="append", default=[])
args = parser.parse_args()
root = args.root.resolve(strict=True)
if args.operation == "capture":
    excluded = [item.strip("/") for item in args.exclude]
    state = {"excluded": excluded, "entries": capture(root, excluded)}
    args.snapshot.write_text(json.dumps(state, sort_keys=True))
    print(f"Captured {len(state['entries'])} managed paths")
else:
    state = json.loads(args.snapshot.read_text())
    previous = state["entries"]
    current = capture(root, state["excluded"])
    differences = []
    for name in sorted(previous.keys() | current.keys()):
        if name not in previous:
            differences.append(f"added: {name}")
        elif name not in current:
            differences.append(f"removed: {name}")
        elif previous[name] != current[name]:
            fields = sorted(key for key in previous[name].keys() | current[name].keys()
                            if previous[name].get(key) != current[name].get(key))
            differences.append(f"changed ({', '.join(fields)}): {name}")
    if differences:
        print("\n".join(differences[:30]))
        raise SystemExit(f"Repeat operation changed {len(differences)} managed paths")
    print(f"Unchanged: all {len(current)} managed paths (access times excluded)")
