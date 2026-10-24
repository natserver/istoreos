#!/usr/bin/env python3
"""Offline config-stage projection only; never install, load, flash or route.

The reference is the archived final/initramfs configuration.  Project a COPY
of the real module-stage configuration through the original initramfs input
selectors, let pinned Kconfig derive hidden symbols, and demand byte identity.
This is not a replacement for the separate live-BTF and kernel-ABI gates.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

REFERENCE_SHA = "66abcbdc255de79fe23ae3f0559ead0b6c6f115aedb928c1a8e51a09d539a8cf"
PASS = "PASS: original final-stage projection matched; real kernel files unchanged"
ALGORITHMS = ("GZIP", "BZIP2", "LZMA", "LZO", "XZ", "LZ4", "ZSTD")
# Exactly the user inputs written by pinned Kernel/SetInitramfs.  INITRD
# itself is deliberately NOT projected: both stages must already have it on.
SELECTORS = frozenset(
    "CONFIG_" + name for name in (
        "INITRAMFS_SOURCE", "INITRAMFS_ROOT_UID", "INITRAMFS_ROOT_GID",
        "INITRAMFS_FORCE", "INITRAMFS_PRESERVE_MTIME",
        "INITRAMFS_COMPRESSION_NONE",
        *("INITRAMFS_COMPRESSION_" + a for a in ALGORITHMS),
        *("RD_" + a for a in ALGORITHMS),
    )
)
LINE = re.compile(r"(?:(CONFIG_[A-Za-z0-9_]+)=(.*)|# (CONFIG_[A-Za-z0-9_]+) is not set)")
FORBIDDEN_ENV = (
    "KCONFIG_CONFIG", "KCONFIG_ALLCONFIG", "KBUILD_OUTPUT", "KBUILD_SRC",
    "KBUILD_KCONFIG", "ARCH", "SRCARCH", "CROSS_COMPILE", "CC", "LLVM",
    "LLVM_IAS", "KCFLAGS", "KCPPFLAGS", "CFLAGS_KERNEL", "MAKEFLAGS",
    "GNUMAKEFLAGS", "MFLAGS", "MAKEFILES", "MAKEOVERRIDES",
)


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def parse(text):
    result = {}
    for line in text.splitlines():
        match = LINE.fullmatch(line)
        if match:
            name = match[1] or match[3]
            require(name not in result, "duplicate configuration symbol: " + name)
            result[name] = match[2] if match[1] else "n"
    return result


def changes(left, right):
    return {key: [left.get(key, "n"), right.get(key, "n")]
            for key in sorted(left.keys() | right.keys())
            if left.get(key, "n") != right.get(key, "n")}


def project(actual_text, reference):
    """Change ONLY the explicit boot-image input selectors, never net options."""
    actual = parse(actual_text)
    require(actual.get("CONFIG_BLK_DEV_INITRD") == "y", "real INITRD must already be y")
    require(reference.get("CONFIG_BLK_DEV_INITRD") == "y", "reference INITRD must be y")
    kept = []
    for line in actual_text.splitlines():
        match = LINE.fullmatch(line)
        if not match or (match[1] or match[3]) not in SELECTORS:
            kept.append(line)
    for name in sorted(SELECTORS):
        value = reference.get(name, "n")
        kept.append(f"# {name} is not set" if value == "n" else f"{name}={value}")
    result = "\n".join(kept) + "\n"
    require(set(changes(actual, parse(result))) <= SELECTORS, "non-stage selector changed")
    return result


def snapshot(kernel):
    paths = set(kernel.glob(".config*"))
    paths.update(kernel / name for name in (
        ".vermagic", "Module.symvers", "vmlinux", "System.map", "modules.order",
        "modules.builtin", "arch/arm64/boot/Image",
    ))
    for directory in ("include/generated", "include/config"):
        root = kernel / directory
        if root.exists():
            paths.update(root.rglob("*"))
    result = {}
    for path in sorted(paths):
        name = path.relative_to(kernel).as_posix()
        if path.is_symlink():
            result[name] = {"symlink": os.readlink(path)}
        elif path.is_file():
            result[name] = sha(path)
    return result


def tool_output(command, env, log):
    completed = subprocess.run(command, env=env, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, timeout=30, check=False)
    log.write("$ " + " ".join(command) + "\n" + completed.stdout + "\n")
    log.flush()
    require(completed.returncode == 0, "tool failed: " + command[0])
    return completed.stdout.strip()


def run(args):
    kernel = args.kernel.resolve(strict=True)
    reference = args.reference.resolve(strict=True)
    out = args.out.absolute()
    require(not out.exists() and not out.is_symlink(), "output must be a new directory")
    require(out.parent.is_dir(), "output parent must exist")
    out = out.parent.resolve(strict=True) / out.name
    require(out != kernel and kernel not in out.parents and out not in kernel.parents,
            "output must be outside, and must not contain, the kernel tree")
    out.mkdir(mode=0o700)
    before = snapshot(kernel)
    report = {"changes": {}, "actual_sha256": None, "reference_final_sha256": None}
    error = None
    try:
        actual = kernel / ".config"
        require(actual.is_file() and not actual.is_symlink(), "real .config must be a regular file")
        shutil.copyfile(actual, out / "actual-kernel.config")
        report["actual_sha256"] = sha(actual)
        actual_text = actual.read_text(encoding="utf-8")
        ref_text = reference.read_text(encoding="utf-8")
        ref_values = parse(ref_text)
        report["actual_vs_reference"] = changes(parse(actual_text), ref_values)
        require(sha(reference) == REFERENCE_SHA, "archived reference SHA256 mismatch")
        require(sys.platform.startswith("linux"), "projection runs only on the disposable Linux builder")
        require(all(not os.environ.get(name) for name in FORBIDDEN_ENV),
                "unset kernel/make override environment variables before projection")
        require((kernel / "Makefile").is_file() and (kernel / "usr/Kconfig").is_file(),
                "prepared original kernel source is required")
        projection = out / "reference-final.config"
        projection.write_text(project(actual_text, ref_values), encoding="utf-8", newline="\n")
        report["input_selector_changes"] = changes(parse(actual_text), parse(projection.read_text()))
        gcc = shutil.which(args.cross + "gcc")
        require(gcc is not None, "missing original cross GCC")
        # Prefer the matching OpenWrt host pahole, not Ubuntu's older /usr/bin one.
        staging_host = Path(gcc).absolute().parent.parent.parent / "host/bin"
        pahole = staging_host / "pahole"
        if not pahole.is_file():
            found = shutil.which("pahole")
            require(found is not None, "missing pahole")
            pahole = Path(found).resolve(strict=True)
        env = os.environ.copy()
        env["PATH"] = os.pathsep.join((str(pahole.parent), str(Path(gcc).parent), env.get("PATH", "")))
        env["KCONFIG_OVERWRITECONFIG"] = "1"
        with (out / "projection.log").open("w", encoding="utf-8") as log:
            require(tool_output([gcc, "-dumpfullversion", "-dumpversion"], env, log) == "14.3.0",
                    "original GCC 14.3.0 required")
            version = tool_output([gcc, "--version"], env, log).splitlines()[0]
            require('"' + version + '"' == ref_values.get("CONFIG_CC_VERSION_TEXT"),
                    "cross compiler identity differs from the archived reference")
            require(tool_output([str(pahole), "--version"], env, log) == "v1.31",
                    "original pahole v1.31 required")
            command = ["make", "-C", str(kernel), "ARCH=arm64", "CROSS_COMPILE=" + args.cross,
                       "PAHOLE=" + str(pahole), "KCONFIG_CONFIG=" + str(projection), "olddefconfig"]
            report["command"] = command
            log.write("$ " + " ".join(command) + "\n")
            log.flush()
            completed = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT,
                                       timeout=300, check=False)
            require(completed.returncode == 0, "Kconfig projection failed; see projection.log")
        report["reference_final_sha256"] = sha(projection)
        projected_values = parse(projection.read_text(encoding="utf-8"))
        report["changes"] = changes(parse(actual_text), projected_values)
        report["projection_vs_reference"] = changes(projected_values, ref_values)
        require(report["reference_final_sha256"] == REFERENCE_SHA,
                "final-stage projection differs from the exact archived reference")
    except Exception as exc:
        error = f"{type(exc).__name__}: {exc}"
    finally:
        try:
            after = snapshot(kernel)
        except Exception as exc:
            after = {}
            error = "cannot verify real kernel integrity: " + str(exc)
        report["real_kernel_mutations"] = changes(before, after)
        if report["real_kernel_mutations"]:
            error = "real kernel files changed; discard projection and all outputs"
        projection = out / "reference-final.config"
        actual_copy = out / "actual-kernel.config"
        if projection.is_file() and actual_copy.is_file():
            try:
                report["reference_final_sha256"] = sha(projection)
                report["changes"] = changes(parse(actual_copy.read_text(encoding="utf-8")),
                                            parse(projection.read_text(encoding="utf-8")))
            except Exception as exc:
                report["diff_error"] = str(exc)
                error = error or "cannot parse projection diagnostic"
        report["reference_input_sha256"] = sha(reference)
        report["status"] = "failed" if error else "passed"
        if error:
            report["error"] = error
        stage = {key: report[key] for key in ("changes", "actual_sha256", "reference_final_sha256")}
        (out / "stage-diff.json").write_text(json.dumps(stage, indent=2) + "\n", encoding="utf-8")
        (out / "diagnostics.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        (out / "kernel-files-before.json").write_text(json.dumps(before, indent=2) + "\n", encoding="utf-8")
        (out / "kernel-files-after.json").write_text(json.dumps(after, indent=2) + "\n", encoding="utf-8")
        (out / "RESULT.txt").write_text(("FAIL: " + error if error else PASS) + "\n", encoding="utf-8")
    require(error is None, error)
    print(PASS)


def self_test():
    actual = ('CONFIG_BLK_DEV_INITRD=y\nCONFIG_INITRAMFS_SOURCE=""\n'
              'CONFIG_RD_GZIP=y\nCONFIG_NF_CONNTRACK_EVENTS=y\nCONFIG_NF_TABLES=m\n')
    reference = parse('CONFIG_BLK_DEV_INITRD=y\nCONFIG_INITRAMFS_SOURCE="/trusted/root"\n'
                      'CONFIG_RD_ZSTD=y\n# CONFIG_RD_GZIP is not set\n'
                      '# CONFIG_NF_CONNTRACK_EVENTS is not set\nCONFIG_NF_TABLES=m\n')
    projected = parse(project(actual, reference))
    require(projected["CONFIG_INITRAMFS_SOURCE"] == '"/trusted/root"', "source projection test")
    require(projected["CONFIG_RD_GZIP"] == "n" and projected["CONFIG_RD_ZSTD"] == "y",
            "RD selector projection test")
    require(projected["CONFIG_NF_CONNTRACK_EVENTS"] == "y", "network option was overwritten")
    require("CONFIG_NF_CONNTRACK_EVENTS" in changes(projected, reference),
            "network mismatch was hidden")
    require(set(changes(parse(actual), projected)) <= SELECTORS, "non-selector transformation")
    try:
        project(actual.replace("CONFIG_BLK_DEV_INITRD=y", "# CONFIG_BLK_DEV_INITRD is not set"), reference)
    except ValueError:
        pass
    else:
        raise ValueError("disabled real INITRD accepted")
    print("PASS: only fixed initramfs inputs projected; network mismatch retained; real INITRD enforced")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--kernel", type=Path)
    parser.add_argument("--reference", type=Path)
    parser.add_argument("--cross")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    try:
        if args.self_test:
            self_test()
        else:
            require(all((args.kernel, args.reference, args.cross, args.out)), "all four arguments required")
            run(args)
    except Exception as exc:
        print("STOP: " + str(exc), file=sys.stderr)
        sys.exit(1)
