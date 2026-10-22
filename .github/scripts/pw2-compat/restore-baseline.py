#!/usr/bin/env python3
"""Restore public build inputs only. Never contacts or configures a router."""
import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

PIN = "130d1ed6577e15aa379884b1a43bc6f53574cfe1"
AUDIT_SHA = "4b1bccd7780f7df5d37c4ec56bdd01c544645687df5cf28ab90bcdfb7a5dd994"


def restore(source: Path, audit: Path, proof: Path):
    manifest = audit / "AUDIT-SHA256SUMS"
    assert hashlib.sha256(manifest.read_bytes()).hexdigest() == AUDIT_SHA
    for line in manifest.read_text().splitlines():
        expected, name = line.split(None, 1)
        name = name.strip().lstrip("*")
        assert name == Path(name).name, "Unexpected checksum path"
        assert hashlib.sha256((audit / name).read_bytes()).hexdigest() == expected, name
    assert (audit / "source-commit.txt").read_text().strip() == PIN
    pins = dict(line.split() for line in (audit / "feeds-commits.tsv").read_text().splitlines())
    lines, restored = [], set()
    for line in (source / "feeds.conf.default").read_text().splitlines():
        if line.startswith("src-git "):
            kind, name, url = line.split()
            assert name in pins and re.fullmatch(r"[0-9a-f]{40}", pins[name])
            url = re.split(r"[;^]", url)[0]
            assert url.startswith("https://github.com/") and url.endswith(".git")
            line = f"{kind} {name} {url}^{pins[name]}"
            restored.add(name)
        lines.append(line)
    assert restored == set(pins), "Feed set differs from original audit"
    (source / "feeds.conf.default").write_text("\n".join(lines) + "\n")
    shutil.copyfile(audit / "openwrt.config", source / ".config")
    proof.mkdir(parents=True, exist_ok=True)
    (proof / "baseline-inputs.json").write_text(json.dumps({
        "source_commit": PIN, "audit_manifest_sha256": AUDIT_SHA,
        "feeds": pins, "scope": "OFFLINE PROBE ONLY; NO INSTALL/LOAD/FLASH",
    }, indent=2) + "\n")


def self_test():
    # Fail closed before touching a source tree when the audit anchor changes.
    import tempfile
    with tempfile.TemporaryDirectory() as tmp:
        p = Path(tmp)
        (p / "AUDIT-SHA256SUMS").write_text("tampered\n")
        try:
            restore(p, p, p / "proof")
        except AssertionError:
            pass
        else:
            raise AssertionError("Tampered audit was accepted")
    print("PASS: changed audit anchor rejected")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--source", type=Path)
    parser.add_argument("--audit", type=Path)
    parser.add_argument("--proof", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
    else:
        assert all([args.source, args.audit, args.proof]), "All three directories are required"
        restore(args.source.resolve(), args.audit.resolve(), args.proof.resolve())
