#!/usr/bin/env bash
# Disposable Ubuntu 24.04 CI only. Builds host tools; never installs APKs/routes.
# Primary recipe: openwrt/openwrt package/system/apk/Makefile (3.0.5).
# Upstream Meson options: alpinelinux/apk-tools at the immutable commit below.
set -euo pipefail
umask 077
die() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
if (( $# != 1 )); then
    echo 'Usage: CI=true host-apk-tools-ci.sh NEW_BUILD_DIRECTORY' >&2
    exit 64
fi
[[ ${CI:-} == true && $(uname -s) == Linux ]] || die 'run only in disposable Linux CI'
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || die 'Ubuntu 24.04 required'
OUT=$(realpath -m -- "$1")
[[ ! -e $OUT && ! -L $OUT && $OUT != / ]] || die 'build directory must be new'
[[ -d $(dirname -- "$OUT") ]] || die 'build parent must exist'
sudo_cmd=()
if (( EUID != 0 )); then sudo_cmd=(sudo -n); fi
"${sudo_cmd[@]}" apt-get update
"${sudo_cmd[@]}" apt-get install -y --no-install-recommends \
    build-essential meson ninja-build pkg-config ca-certificates curl \
    libssl-dev zlib1g-dev libzstd-dev openssl lua5.3 pahole
mkdir -m 700 -- "$OUT"
COMMIT=b5a31c0d865342ad80be10d68f1bb3d3ad9b0866
SOURCE_SHA=598056e338fa96af030b0f6f2127cc7df151e6f078b0e44a5cae95cc4bba1f79
URL="https://codeload.github.com/alpinelinux/apk-tools/tar.gz/$COMMIT"
curl --fail --location --retry 3 --proto '=https' --tlsv1.2 \
    "$URL" -o "$OUT/source.tar.gz"
printf '%s  %s\n' "$SOURCE_SHA" "$OUT/source.tar.gz" | sha256sum -c -
mkdir "$OUT/source"
tar -xzf "$OUT/source.tar.gz" --strip-components=1 -C "$OUT/source"
[[ $(cat "$OUT/source/VERSION") == 3.0.5 ]] || die 'unexpected source version'
# minimal=true omits mkpkg, mkndx and adbsign. Meson supports glibc; legacy Make does not.
VERSION=3.0.5 meson setup "$OUT/build" "$OUT/source" \
    -Dminimal=false -Dcrypto_backend=openssl -Ddefault_library=static \
    -Durl_backend=wget -Dzstd=enabled -Ddocs=disabled -Dhelp=enabled \
    -Dlua=disabled -Dpython=disabled -Dtests=disabled
ninja -C "$OUT/build" -j2 src/apk
mkdir "$OUT/bin" "$OUT/selftest"
install -m 755 "$OUT/build/src/apk" "$OUT/bin/apk"
APK="$OUT/bin/apk"
TEST="$OUT/selftest"
"$APK" --version | tee "$OUT/version.txt"
grep -Eq 'apk-tools 3\.0\.5([ ,]|$)' "$OUT/version.txt" || die 'host binary version mismatch'
help_rc=0
"$APK" --help > "$OUT/applets.txt" || help_rc=$?
[[ $help_rc == 0 || $help_rc == 1 ]] || die 'host APK help command failed unexpectedly'
for applet in mkpkg mkndx adbsign verify adbdump; do
    grep -wq "$applet" "$OUT/applets.txt" || die "missing full-build applet: $applet"
done
mkdir "$TEST/payload" "$TEST/keys" "$TEST/empty-keys"
printf 'host APK v3 ECP256 signing self-test\n' > "$TEST/payload/probe.txt"
KEY=$(mktemp "${RUNNER_TEMP:-/tmp}/apk-selftest-key.XXXXXX")
trap 'rm -f -- "$KEY"' EXIT
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:prime256v1 -out "$KEY"
openssl pkey -in "$KEY" -pubout -out "$TEST/keys/selftest.pub"
PKG="$TEST/host-signing-probe-1-r0.apk"
"$APK" mkpkg --sign-key "$KEY" --files "$TEST/payload" --output "$PKG" \
    --info name:host-signing-probe --info version:1-r0 --info arch:noarch \
    --info 'description:Disposable host APK signing self-test'
"$APK" --keys-dir "$TEST/keys" adbsign --reset-signatures --sign-key "$KEY" "$PKG"
"$APK" --keys-dir "$TEST/keys" verify "$PKG"
if "$APK" --keys-dir "$TEST/empty-keys" verify "$PKG" > "$TEST/untrusted.log" 2>&1; then
    die 'signature check unexpectedly accepts an untrusted key'
fi
"$APK" --keys-dir "$TEST/keys" mkndx --sign-key "$KEY" --output "$TEST/packages.adb" "$PKG"
"$APK" --keys-dir "$TEST/keys" verify "$TEST/packages.adb"
"$APK" adbdump "$PKG" > "$TEST/package.dump"
"$APK" adbdump "$TEST/packages.adb" > "$TEST/index.dump"
grep -Fq host-signing-probe "$TEST/package.dump" || die 'package round-trip failed'
grep -Fq host-signing-probe "$TEST/index.dump" || die 'index round-trip failed'
printf 'upstream_tag=v3.0.5\nupstream_commit=%s\nsource_url=%s\nsource_sha256=%s\ncrypto=openssl\nselftest=ECP256_signed_package_and_index\n' \
    "$COMMIT" "$URL" "$SOURCE_SHA" > "$OUT/provenance.txt"
sha256sum "$OUT/bin/apk" > "$OUT/apk.sha256"
printf 'HOST_APK_TOOLS_SELFTEST_PASSED\n' > "$OUT/RESULT.txt"
echo "Host APK tools ready: $APK (not installed system-wide)"
