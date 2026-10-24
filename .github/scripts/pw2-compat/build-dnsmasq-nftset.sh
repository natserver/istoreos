#!/usr/bin/env bash
# Build only a userspace APK in a restored Linux OpenWrt tree; never install it.
# Usage: bash build-dnsmasq-nftset.sh SOURCE_DIR ORIGINAL_AUDIT_DIR NEW_OUTPUT_DIR
# For an offline build, populate dl/ and the host/toolchain beforehand.
set -euo pipefail
[[ $# == 3 ]] || { echo "Usage: $0 SOURCE_DIR ORIGINAL_AUDIT_DIR NEW_OUTPUT_DIR" >&2; exit 2; }
ROOT=$(realpath "$1"); AUDIT=$(realpath "$2"); OUT=$(realpath -m "$3")
PIN=130d1ed6577e15aa379884b1a43bc6f53574cfe1
[[ -f "$ROOT/Makefile" && -f "$AUDIT/openwrt.config" && -f "$AUDIT/kernel.config" ]]
[[ ! -e "$OUT" ]] || { echo "Output must not already exist" >&2; exit 2; }
cd "$ROOT"
[[ $(git rev-parse HEAD) == "$PIN" ]] || { echo "Wrong source commit" >&2; exit 2; }
cmp -s .config "$AUDIT/openwrt.config" || { echo "Restore the original openwrt.config first" >&2; exit 2; }
git show "$PIN:package/network/services/dnsmasq/Makefile" | cmp - package/network/services/dnsmasq/Makefile
mkdir -p "$OUT"
cp -p .config "$OUT/config.before"
[[ ! -e .config.old ]] || cp -p .config.old "$OUT/config.old.before"
restore_config() {
    cp -p "$OUT/config.before" .config
    if [[ -f "$OUT/config.old.before" ]]; then cp -p "$OUT/config.old.before" .config.old; else rm -f -- .config.old; fi
}
trap restore_config EXIT
export ROOT AUDIT OUT

python3 - <<'PY'
import hashlib,json,os,re
from pathlib import Path
r=Path(os.environ['ROOT']); out=Path(os.environ['OUT'])
# The module probe already checked the final-initramfs projection and live BTF.
# Pin its ACTUAL prepared-stage config, not the different final-stage archive.
proof=out.parent/'module-probe'
assert 'OFFLINE_BUILD_ONLY' in (proof/'RESULT.txt').read_text().splitlines(), 'Successful module proof required'
module_config=(proof/'kernel.config').read_bytes()
kernels=sorted((r/'build_dir').glob('target-*/linux-*/linux-*/.config'))
assert kernels, 'No prepared target kernel config found'
assert all(p.read_bytes()==module_config for p in kernels), 'Prepared kernel config differs from successful module proof'
kernel_hashes={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in kernels}
(out/'kernel-config.before.json').write_text(json.dumps(kernel_hashes,sort_keys=True))
# Make no changes to target/linux. Track every existing file, including local
# reconstruction patches, instead of assuming the release used a clean tree.
files={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest()
       for p in (r/'target/linux').rglob('*') if p.is_file()}
(out/'target-linux.before.json').write_text(json.dumps(files,sort_keys=True))
desired={'CONFIG_PACKAGE_dnsmasq':'n','CONFIG_PACKAGE_dnsmasq-dhcpv6':'n',
 'CONFIG_PACKAGE_dnsmasq-full':'y','CONFIG_PACKAGE_dnsmasq_full_dhcp':'y',
 'CONFIG_PACKAGE_dnsmasq_full_dhcpv6':'n','CONFIG_PACKAGE_dnsmasq_full_dnssec':'n',
 'CONFIG_PACKAGE_dnsmasq_full_auth':'n','CONFIG_PACKAGE_dnsmasq_full_ipset':'n',
 'CONFIG_PACKAGE_dnsmasq_full_nftset':'y','CONFIG_PACKAGE_dnsmasq_full_conntrack':'n',
 'CONFIG_PACKAGE_dnsmasq_full_noid':'y','CONFIG_PACKAGE_dnsmasq_full_broken_rtc':'n',
 'CONFIG_PACKAGE_dnsmasq_full_tftp':'y'}
# Matches the running original: IPv6, DHCP, UBus, TFTP; not DHCPv6, auth,
# DNSSEC, ipset or conntrack. nftset is the only new functional feature.
p=r/'.config'; lines=p.read_text().splitlines()
pattern=re.compile(r'^(?:# )?(CONFIG_[\w-]+)(?:=| is not set)')
lines=[l for l in lines if not ((m:=pattern.match(l)) and m[1] in desired)]
lines += [f'# {k} is not set' if v=='n' else f'{k}={v}' for k,v in desired.items()]
p.write_text('\n'.join(lines)+'\n')
(out/'requested-selectors.json').write_text(json.dumps(desired,indent=2))
PY

make defconfig >"$OUT/defconfig.log" 2>&1
cp .config "$OUT/config.after-defconfig"

audit_config() {
    python3 - <<'PY'
import hashlib,json,os,re
from pathlib import Path
r=Path(os.environ['ROOT']); out=Path(os.environ['OUT'])
def config(p):
    result={}
    for l in p.read_text().splitlines():
        m=re.match(r'^(CONFIG_[\w-]+)=(.*)$',l)
        if m: result[m[1]]=m[2]
        m=re.match(r'^# (CONFIG_[\w-]+) is not set$',l)
        if m: result[m[1]]='n'
    return result
before=config(out/'config.before'); after=config(r/'.config')
want=json.loads((out/'requested-selectors.json').read_text())
changed={k:[before.get(k,'n'),after.get(k,'n')] for k in before.keys()|after.keys()
         if before.get(k,'n')!=after.get(k,'n')}
(out/'config.diff.json').write_text(json.dumps(changed,indent=2,sort_keys=True))
assert set(changed)<=set(want), 'Unexpected config changes; inspect config.diff.json'
assert all(after.get(k,'n')==v for k,v in want.items()), 'Requested dnsmasq flags were overridden'
expected=json.loads((out/'target-linux.before.json').read_text())
actual={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (r/'target/linux').rglob('*') if p.is_file()}
assert actual==expected, 'target/linux source/config files changed'
# Byte-exact config and path-set equality before AND after userspace compile.
# A newly created, removed or rewritten prepared config is a failed build.
expected=json.loads((out/'kernel-config.before.json').read_text())
actual={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest()
        for p in (r/'build_dir').glob('target-*/linux-*/linux-*/.config')}
assert actual==expected, 'Prepared kernel config set/bytes changed during userspace build'
print('PASS: only requested userspace selectors changed; target kernel/source unchanged')
PY
}
audit_config | tee "$OUT/config-audit.before-build.txt"

# No world, image, target/linux or firmware build target is invoked.
# This may fetch missing build inputs unless its environment is offline/cached.
make -j"${JOBS:-2}" package/network/services/dnsmasq/compile V=s >"$OUT/build.log" 2>&1
audit_config | tee "$OUT/config-audit.after-build.txt"
mapfile -t PACKAGES < <(find bin/packages -type f -name 'dnsmasq-full-*.apk')
[[ ${#PACKAGES[@]} == 1 ]] || { echo "Expected one dnsmasq-full APK" >&2; exit 1; }
mapfile -t BINARIES < <(find build_dir -type f -path '*/dnsmasq-full/dnsmasq-*/src/dnsmasq')
[[ ${#BINARIES[@]} == 1 ]] || { echo "Expected one built dnsmasq-full executable" >&2; exit 1; }
readelf -h "${BINARIES[0]}" >"$OUT/elf-header.txt"
readelf -d "${BINARIES[0]}" >"$OUT/dynamic-dependencies.txt"
grep -q 'AArch64' "$OUT/elf-header.txt"
grep -q 'Shared library:.*libnftables' "$OUT/dynamic-dependencies.txt"
! grep -E 'Shared library:.*(libnetfilter_conntrack|libnfnetlink)' "$OUT/dynamic-dependencies.txt"
cp -- "${PACKAGES[0]}" "$OUT/"
sha256sum "$OUT"/*.apk >"$OUT/SHA256SUMS"
printf '%s\n' 'BUILD ONLY: APK not installed, router untouched; validate native APK deps/signing before installation.'
