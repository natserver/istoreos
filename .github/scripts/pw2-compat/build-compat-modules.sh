#!/usr/bin/env bash
# Offline build probe ONLY: never installs, loads modules, edits config or flashes.
# Requires a fully rebuilt ORIGINAL kernel tree, not a headers-only SDK.
# Sources: Linux 6.12 scripts/Makefile.modfinal and kbuild/modules documentation.
set -euo pipefail
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
if (( $# < 3 || $# > 4 )); then
    echo 'Usage: build-compat-modules.sh KERNEL_BUILD_DIR NEW_OUTPUT_DIR CROSS_COMPILE_PREFIX [JOBS]' >&2
    exit 64
fi
KDIR=$(realpath -e -- "$1")
OUT=$(realpath -m -- "$2")
CROSS=$3
JOBS=${4:-2}
[[ $JOBS =~ ^[1-9][0-9]*$ ]] || die 'JOBS must be a positive integer'
[[ ! -e $OUT && ! -L $OUT ]] || die 'output directory must not exist'
[[ $OUT != "$KDIR" && $OUT != "$KDIR/"* && $OUT != / ]] || die 'output must be outside the kernel tree'
[[ $KDIR != *'"'* && $KDIR != *$'\n'* ]] || die 'unsupported quote/newline in kernel path'
[[ -d $(dirname -- "$OUT") ]] || die 'output parent directory must exist'
# Reject overrides that could mask missing exports or silently alter the probe.
for var in KBUILD_MODPOST_WARN KBUILD_MODPOST_NOFINAL KBUILD_EXTRA_SYMBOLS KCFLAGS KCPPFLAGS CFLAGS_MODULE LDFLAGS_MODULE KBUILD_OUTPUT KCONFIG_CONFIG; do
    [[ -z ${!var:-} ]] || die "unset $var before running this probe"
done
for tool in make sha256sum realpath "${CROSS}gcc" "${CROSS}objcopy" "${CROSS}readelf"; do
    command -v "$tool" >/dev/null || die "missing tool: $tool"
done
[[ $("${CROSS}gcc" -dumpfullversion -dumpversion) == 14.3.0 ]] || die 'original GCC 14.3.0 toolchain required'
CONFIG_SHA=66abcbdc255de79fe23ae3f0559ead0b6c6f115aedb928c1a8e51a09d539a8cf
LIVE_BTF_SHA=ce67f10fcaf9beee2b6547bd4640a2dc981a7862d7d46787998e6865dc6d60f3
ABI=7f38d6580edcb2bc3d6da411c29e1504
[[ $(sha256sum "$KDIR/.config" | cut -d' ' -f1) == "$CONFIG_SHA" ]] || die 'kernel .config differs from the archived original release'
[[ $(cat "$KDIR/.vermagic") == "$ABI" ]] || die 'OpenWrt baseline ABI differs from original'
[[ $(cat "$KDIR/include/config/kernel.release") == 6.12.94 ]] || die 'kernel release mismatch'
for required in CONFIG_MODULES=y CONFIG_MODULE_UNLOAD=y CONFIG_IPV6=y CONFIG_NF_TABLES=m CONFIG_NF_CONNTRACK=m CONFIG_DEBUG_INFO_BTF=y CONFIG_DEBUG_INFO_BTF_MODULES=y; do
    grep -Fxq "$required" "$KDIR/.config" || die "missing baseline option: $required"
done
for absent in CONFIG_NF_CONNTRACK_EVENTS CONFIG_NF_CT_NETLINK CONFIG_NFT_SOCKET CONFIG_NFT_TPROXY CONFIG_NF_SOCKET_IPV4 CONFIG_NF_SOCKET_IPV6 CONFIG_NF_TPROXY_IPV4 CONFIG_NF_TPROXY_IPV6 CONFIG_MODVERSIONS CONFIG_TRIM_UNUSED_KSYMS CONFIG_MODULE_ALLOW_BTF_MISMATCH; do
    grep -Fxq "# $absent is not set" "$KDIR/.config" || die "unexpected baseline option: $absent"
done
baseline=(.config .vermagic Module.symvers vmlinux include/generated/autoconf.h include/config/auto.conf include/config/kernel.release)
for file in "${baseline[@]}"; do
    [[ -s $KDIR/$file ]] || die "missing complete original build artifact: $file"
done
sources=(net/ipv4/netfilter/nf_socket_ipv4.c net/ipv6/netfilter/nf_socket_ipv6.c net/ipv4/netfilter/nf_tproxy_ipv4.c net/ipv6/netfilter/nf_tproxy_ipv6.c net/netfilter/nft_socket.c net/netfilter/nft_tproxy.c)
for file in "${sources[@]}"; do
    [[ -s $KDIR/$file ]] || die "missing patched original source: $file"
done
mkdir -m 700 -- "$OUT"
for file in "${baseline[@]}"; do sha256sum "$KDIR/$file"; done > "$OUT/baseline-before.sha256"
for file in "${sources[@]}"; do sha256sum "$KDIR/$file"; done > "$OUT/sources-before.sha256"
trap 'rc=$?; trap - EXIT; if ! sha256sum -c "$OUT/baseline-before.sha256" "$OUT/sources-before.sha256" > "$OUT/baseline-integrity.log" 2>&1; then echo "STOP: baseline/source mutation; discard outputs" >&2; rc=90; fi; exit "$rc"' EXIT
"${CROSS}objcopy" --dump-section ".BTF=$OUT/baseline-vmlinux.BTF" "$KDIR/vmlinux" /dev/null
[[ $(sha256sum "$OUT/baseline-vmlinux.BTF" | cut -d' ' -f1) == "$LIVE_BTF_SHA" ]] || die 'rebuilt base BTF differs from live router; do not bypass this gate'
cat > "$OUT/Makefile" <<'KBUILD'
obj-m += nf_socket_ipv4.o nf_socket_ipv6.o nf_tproxy_ipv4.o nf_tproxy_ipv6.o nft_socket.o nft_tproxy.o
# Local compile flags only: original autoconf and all core structure options stay unchanged.
ccflags-y += -DCONFIG_NF_SOCKET_IPV4_MODULE=1 -DCONFIG_NF_SOCKET_IPV6_MODULE=1
ccflags-y += -DCONFIG_NF_TPROXY_IPV4_MODULE=1 -DCONFIG_NF_TPROXY_IPV6_MODULE=1
ccflags-y += -DCONFIG_NFT_SOCKET_MODULE=1 -DCONFIG_NFT_TPROXY_MODULE=1
KBUILD
for file in "${sources[@]}"; do
    printf '#include "%s/%s"\n' "$KDIR" "$file" > "$OUT/${file##*/}"
done
# Native modpost checks exports against the baseline plus these six objects.
# Never set KBUILD_MODPOST_WARN=1 or use a replacement/edited Module.symvers.
make -C "$KDIR" M="$OUT" ARCH=arm64 CROSS_COMPILE="$CROSS" \
    KBUILD_MODPOST_WARN= KBUILD_MODPOST_NOFINAL= KBUILD_EXTRA_SYMBOLS= \
    -j"$JOBS" V=1 modules 2>&1 | tee "$OUT/build.log"
for file in "${sources[@]}"; do
    ko="$OUT/${file##*/}"; ko=${ko%.c}.ko
    [[ -s $ko ]] || die "module not produced: $ko"
    "${CROSS}readelf" -SW "$ko" > "$ko.sections"
    grep -Eq '\] \.BTF[[:space:]]' "$ko.sections" || die "module BTF missing: $ko"
    "${CROSS}readelf" -p .modinfo "$ko" > "$ko.modinfo"
    grep -Fq 'vermagic=6.12.94 SMP mod_unload aarch64' "$ko.modinfo" || die "module vermagic mismatch: $ko"
    sha256sum "$ko"
done | tee "$OUT/modules.sha256"
printf 'OFFLINE_BUILD_ONLY\nNo runtime compatibility claim. No install/load/flash performed.\n' > "$OUT/RESULT.txt"
echo 'Offline six-module build passed config/base-BTF/export gates; outputs require further review, not deployment.'
