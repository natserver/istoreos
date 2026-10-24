"""Small offline regression check for the defconfig guards, not a firmware test."""
import os
from pathlib import Path
import re
import shlex
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
guard = root / ".github/scripts/verify-proxy-firmware.sh"
workflow = (root / ".github/workflows/build-ax1800pro.yml").read_text(encoding="utf-8")
seed = re.search(r"cat > \.config <<'EOF'\n(.*?)\n\s*EOF", workflow, re.S)
assert seed, "missing workflow seed"
config = "\n".join(line[10:] for line in seed.group(1).splitlines()) + "\n"
for setting in (
    "CONFIG_PACKAGE_kmod-nf-socket=y",
    "CONFIG_PACKAGE_kmod-nf-tproxy=y",
    "CONFIG_PACKAGE_kmod-nft-socket=y",
    "CONFIG_PACKAGE_kmod-nft-tproxy=y",
    "# CONFIG_PACKAGE_dnsmasq is not set",
    "# CONFIG_PACKAGE_dnsmasq-dhcpv6 is not set",
    "CONFIG_PACKAGE_dnsmasq-full=y",
    "CONFIG_PACKAGE_dnsmasq_full_nftset=y",
):
    assert setting in config.splitlines(), f"missing PassWall2 firmware setting: {setting}"
packages = re.search(r"^packages=\((.*?)\)$", guard.read_text(encoding="utf-8"), re.S | re.M)
assert packages, "missing required package list"
# Model package dependencies resolved to y; this does not simulate Kconfig.
for package in shlex.split(packages.group(1)):
    setting = f"CONFIG_PACKAGE_{package}=y"
    if setting not in config.splitlines():
        config += setting + "\n"

bash = os.environ.get("BASH_EXE", "bash")
subprocess.run([bash, "-n", guard.as_posix()], check=True)
cases = [
    ("valid policy", config, True),
    ("REDUCED conflicts with BTF", config.replace(
        "# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set",
        "CONFIG_KERNEL_DEBUG_INFO_REDUCED=y"), False),
    ("BTF silently removed", config.replace(
        "CONFIG_KERNEL_DEBUG_INFO_BTF=y", "# CONFIG_KERNEL_DEBUG_INFO_BTF is not set"), False),
    ("NFQUEUE package omitted", config.replace(
        "CONFIG_PACKAGE_kmod-nft-queue=y", "# CONFIG_PACKAGE_kmod-nft-queue is not set"), False),
    ("Honk core omitted", config.replace(
        "CONFIG_PACKAGE_honk=y", "# CONFIG_PACKAGE_honk is not set"), False),
    ("PassWall2 nft tproxy module omitted", config.replace(
        "CONFIG_PACKAGE_kmod-nft-tproxy=y", "# CONFIG_PACKAGE_kmod-nft-tproxy is not set"), False),
    ("dnsmasq nftset omitted", config.replace(
        "CONFIG_PACKAGE_dnsmasq_full_nftset=y", "# CONFIG_PACKAGE_dnsmasq_full_nftset is not set"), False),
]
for name, content, expected_success in cases:
    with tempfile.TemporaryDirectory(prefix="istoreos-guard-") as directory:
        Path(directory, ".config").write_text(content, encoding="utf-8", newline="\n")
        result = subprocess.run(
            [bash, guard.as_posix(), "defconfig"], cwd=directory,
            capture_output=True, text=True,
        )
        assert (result.returncode == 0) == expected_success, (
            name, result.returncode, result.stdout, result.stderr
        )
    print(f"PASS: {name}")
