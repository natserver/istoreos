#!/usr/bin/env bash
# Run in the OpenWrt build root: defconfig first, final after make succeeds.
set -euo pipefail
export LC_ALL=C

die() { echo "::error::$*" >&2; exit 1; }
require() { grep -Eq "$2" "$1" || die "$1 is missing required setting: $2"; }
audit=firmware-audit
mkdir -p "$audit"
cp .config "$audit/openwrt.config"

packages=(honk luci-app-honk
  kmod-tun kmod-sched-core kmod-sched-bpf kmod-veth
  kmod-nft-queue kmod-nfnetlink-queue ip-full nftables-json
  v2ray-geoip v2ray-geosite
  jsonfilter jshn sqlite3-cli usign coreutils-stat ca-bundle)

require .config '^CONFIG_TARGET_qualcommax_ipq60xx_DEVICE_jdcloud_re-ss-01=y$'
require .config '^CONFIG_KERNEL_DEBUG_INFO=y$'
require .config '^CONFIG_KERNEL_DEBUG_INFO_BTF=y$'
require .config '^# CONFIG_KERNEL_DEBUG_INFO_REDUCED is not set$'
for package in "${packages[@]}"; do
  require .config "^CONFIG_PACKAGE_${package}=y$"
done

case "${1:-final}" in
  defconfig) echo 'defconfig: BTF dependencies and proxy package selections verified'; exit 0 ;;
  final) ;;
  *) die 'usage: verify-proxy-firmware.sh [defconfig|final]' ;;
esac

mapfile -t kernel_configs < <(find build_dir -type f \
  -path '*/linux-qualcommax_ipq60xx/linux-*/.config' | sort)
[ "${#kernel_configs[@]}" -eq 1 ] || die 'expected exactly one final ipq60xx kernel .config'
kernel_config=${kernel_configs[0]}
linux_dir=${kernel_config%/.config}
kdir=${linux_dir%/*}
cp "$kernel_config" "$audit/kernel.config"
for option in DEBUG_INFO DEBUG_INFO_BTF BPF BPF_SYSCALL BPF_JIT CGROUPS CGROUP_BPF BPF_EVENTS XDP_SOCKETS; do
  require "$kernel_config" "^CONFIG_${option}=y$"
done
require "$kernel_config" '^# CONFIG_DEBUG_INFO_REDUCED is not set$'
for option in NETFILTER_NETLINK_QUEUE NFT_QUEUE; do
  require "$kernel_config" "^CONFIG_${option}=[ym]$"
done

# A seed/config flag is not proof: require a nonempty .BTF section in the ELF.
readelf -SW "$linux_dir/vmlinux" > "$audit/vmlinux-sections.txt"
awk '{ for (i=1; i<=NF; i++) if ($i==".BTF" && $(i+1)=="PROGBITS" && $(i+4)!~/^0+$/) ok=1 }
     END { exit !ok }' "$audit/vmlinux-sections.txt" || die 'vmlinux has no nonempty .BTF section'

shopt -s nullglob
out=bin/targets/qualcommax/ipq60xx
images=("$out"/*jdcloud_re-ss-01-squashfs-sysupgrade.bin)
manifests=("$out"/*jdcloud_re-ss-01.manifest)
[ "${#images[@]}" -eq 1 ] || die 'expected exactly one RE-SS-01 sysupgrade image'
[ "${#manifests[@]}" -eq 1 ] || die 'expected exactly one RE-SS-01 manifest'
image=${images[0]}
manifest=${manifests[0]}
for package in "${packages[@]}"; do
  require "$manifest" "^${package}[[:space:]]"
done
cp "$manifest" "$audit/packages.manifest"

# Validate the bytes actually shipped, not uncompressed Image or a stale file.
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
tar -xOf "$image" sysupgrade-jdcloud_re-ss-01/kernel > "$work/kernel.itb"
tar -xOf "$image" sysupgrade-jdcloud_re-ss-01/root > "$work/root.squashfs"
size=$(stat -c%s "$work/kernel.itb")
[ "$size" -gt 0 ] && [ "$size" -le 12582912 ] || die "FIT kernel exceeds existing HLOS12M: $size bytes"
cmp "$work/kernel.itb" "$kdir/jdcloud_re-ss-01-uImage.itb" \
  || die 'packaged kernel differs from the just-built RE-SS-01 FIT'
staging_dir/host/bin/mkimage -l "$work/kernel.itb" > "$audit/kernel-fit.txt"
require "$audit/kernel-fit.txt" 'Compression:[[:space:]]+gzip compressed'
printf 'FIT_KERNEL_BYTES=%s\nHLOS_LIMIT_BYTES=12582912\n' "$size" > "$audit/kernel-size.txt"

unsquashfs -l "$work/root.squashfs" > "$work/rootfs.list"
for file in usr/bin/honk-core etc/init.d/honk \
  usr/share/luci/menu.d/luci-app-honk.json usr/libexec/rpcd/honk \
  etc/uci-defaults/zz-honk-preinstalled-disabled; do
  require "$work/rootfs.list" "(^|[[:space:]])squashfs-root/${file}$"
done
for pair in 'NETFILTER_NETLINK_QUEUE:nfnetlink_queue' 'NFT_QUEUE:nft_queue'; do
  if grep -Fxq "CONFIG_${pair%%:*}=m" "$kernel_config"; then
    require "$work/rootfs.list" \
      "squashfs-root/lib/modules/[^/]+/${pair##*:}\\.ko(\\.(gz|xz|zst))?$"
  fi
done
unsquashfs -cat "$work/root.squashfs" etc/config/honk > "$work/honk.config"
for option in enabled boot_enabled initialized; do
  require "$work/honk.config" "^[[:space:]]*option[[:space:]]+${option}[[:space:]]+['\"]0['\"][[:space:]]*$"
done
unsquashfs -cat "$work/root.squashfs" usr/share/honk/provenance.json > "$audit/honk-provenance.json"
unsquashfs -cat "$work/root.squashfs" usr/share/doona/SOURCE > "$audit/doona-source.txt"
cp feeds/honk/honk/generated-stage.mk "$audit/honk-stage.mk"
git rev-parse HEAD > "$audit/source-commit.txt"
sha256sum "$work/kernel.itb" | awk '{print $1}' > "$audit/kernel.sha256"
(cd "$out"; sha256sum *.bin *.manifest > SHA256SUMS)
printf 'PASS: BTF ELF, NFQUEUE modules, packaged FIT <=12MiB, Honk defaults disabled\n' \
  > "$audit/verification.txt"
(cd "$audit"; sha256sum *.config *.json *.txt *.manifest *.mk *.tsv *.sha256 > AUDIT-SHA256SUMS)
echo "Verified: $image; compressed FIT kernel $size / 12582912 bytes; audit in $audit"
