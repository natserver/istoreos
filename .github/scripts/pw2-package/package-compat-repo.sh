#!/usr/bin/env bash
# LOCAL PACKAGING ONLY. Never connects to a router, installs, loads or flashes.
# Usage: bash package-compat-repo.sh --apk /ABS/staging_dir/host/bin/apk \
#   --proof /ABS/proof --out /ABS/NEW_OUTPUT_DIR
# Requires root in disposable CI, Python 3, full host apk-tools 3.0.5,
# OpenSSL, readelf and pahole. Root preserves native root:root APK ownership.
# --self-test is dependency-free and writes nothing. No production override gates.
set -euo pipefail
exec "${PYTHON:-python3}" - "$@" <<'PY'
import argparse
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path, PurePosixPath

PIN = '130d1ed6577e15aa379884b1a43bc6f53574cfe1'
AUDIT_SHA = '4b1bccd7780f7df5d37c4ec56bdd01c544645687df5cf28ab90bcdfb7a5dd994'
CONFIG_SHA = '66abcbdc255de79fe23ae3f0559ead0b6c6f115aedb928c1a8e51a09d539a8cf'
OWRT_CONFIG_SHA = '8f13cf6f727eb2a001a6d0ca141a376fa628005e0c38f019dfae3056e779e82b'
BTF_SHA = 'ce67f10fcaf9beee2b6547bd4640a2dc981a7862d7d46787998e6865dc6d60f3'
ABI = '7f38d6580edcb2bc3d6da411c29e1504'
KERNEL = '6.12.94'
KERNEL_APK = f'{KERNEL}~{ABI}-r1'
VERSION = f'{KERNEL}-r100'
ARCH = 'aarch64_cortex-a53'
VERMAGIC = f'{KERNEL} SMP mod_unload aarch64'
GROUPS = {
    'kmod-nf-socket': ('nf_socket_ipv4', 'nf_socket_ipv6'),
    'kmod-nf-tproxy': ('nf_tproxy_ipv4', 'nf_tproxy_ipv6'),
    'kmod-nft-socket': ('nft_socket',),
    'kmod-nft-tproxy': ('nft_tproxy',),
}
MODULES = tuple(m for group in GROUPS.values() for m in group)
DEPS = {
    'kmod-nf-socket': [f'kernel={KERNEL_APK}', f'kmod-nf-conntrack={KERNEL}-r1'],
    'kmod-nf-tproxy': [f'kernel={KERNEL_APK}', f'kmod-nf-conntrack={KERNEL}-r1'],
    'kmod-nft-socket': [f'kernel={KERNEL_APK}', f'kmod-nft-core={KERNEL}-r1',
                        f'kmod-nf-socket={VERSION}'],
    'kmod-nft-tproxy': [f'kernel={KERNEL_APK}', f'kmod-nft-core={KERNEL}-r1',
                        f'kmod-nf-conntrack={KERNEL}-r1', f'kmod-nf-tproxy={VERSION}'],
}
WANT = {'CONFIG_PACKAGE_dnsmasq': 'n', 'CONFIG_PACKAGE_dnsmasq-dhcpv6': 'n',
        'CONFIG_PACKAGE_dnsmasq-full': 'y', 'CONFIG_PACKAGE_dnsmasq_full_dhcp': 'y',
        'CONFIG_PACKAGE_dnsmasq_full_dhcpv6': 'n', 'CONFIG_PACKAGE_dnsmasq_full_dnssec': 'n',
        'CONFIG_PACKAGE_dnsmasq_full_auth': 'n', 'CONFIG_PACKAGE_dnsmasq_full_ipset': 'n',
        'CONFIG_PACKAGE_dnsmasq_full_nftset': 'y', 'CONFIG_PACKAGE_dnsmasq_full_conntrack': 'n',
        'CONFIG_PACKAGE_dnsmasq_full_noid': 'y', 'CONFIG_PACKAGE_dnsmasq_full_broken_rtc': 'n',
        'CONFIG_PACKAGE_dnsmasq_full_tftp': 'y'}


class GateError(RuntimeError):
    pass


def need(condition, message):
    if not condition:
        raise GateError(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    path = Path(path)
    need(not path.is_symlink() and path.is_file() and path.stat().st_size > 0,
         f'Missing/empty/non-regular input: {path.name}')
    return path


def checksum_rows(text):
    rows = []
    for line in text.splitlines():
        match = re.fullmatch(r'([0-9a-f]{64}) [ *](.+)', line)
        need(match is not None, 'Malformed SHA256 manifest')
        digest, name = match.groups()
        need(not any(c in name for c in '\r\n\x00\\'), 'Unsafe manifest path')
        rows.append((digest, name))
    need(rows and len({name for _, name in rows}) == len(rows), 'Empty/duplicate manifest')
    return rows


def verify_payloads(directory, manifest, names):
    rows = checksum_rows(regular(manifest).read_text())
    mapped = {PurePosixPath(name).name: digest for digest, name in rows}
    need(len(mapped) == len(rows) and set(mapped) == set(names), 'Unexpected payload manifest set')
    for name, digest in mapped.items():
        need(sha(regular(directory / name).read_bytes()) == digest, f'Payload checksum mismatch: {name}')
    return mapped


def config_values(text):
    values = {}
    for line in text.splitlines():
        match = re.fullmatch(r'(CONFIG_[\w-]+)=(.*)', line)
        if match:
            values[match[1]] = match[2]
        match = re.fullmatch(r'# (CONFIG_[\w-]+) is not set', line)
        if match:
            values[match[1]] = 'n'
    return values


def btf_header(data):
    need(len(data) >= 24, 'Missing/truncated BTF')
    magic, version, flags, size, toff, tlen, soff, slen = struct.unpack_from('<HBBIIIII', data)
    need(magic == 0xeb9f and version == 1 and flags == 0 and size >= 24,
         'Invalid BTF header')
    need(tlen > 0 and slen > 0 and size + toff + tlen <= len(data)
         and size + soff + slen <= len(data), 'Invalid BTF bounds')


def elf_sections(data, module=False):
    need(len(data) >= 64 and data[:6] == b'\x7fELF\x02\x01', 'Expected little-endian ELF64')
    kind, machine, version = struct.unpack_from('<HHI', data, 16)
    need(machine == 183 and version == 1 and kind in ((1,) if module else (2, 3)),
         'Unexpected ELF architecture/type')
    offset = struct.unpack_from('<Q', data, 40)[0]
    stride, count, names_idx = struct.unpack_from('<HHH', data, 58)
    need(stride == 64 and 0 < count < 8192 and names_idx < count
         and offset + stride * count <= len(data), 'Invalid ELF section table')
    entries = [struct.unpack_from('<IIQQQQIIQQ', data, offset + i * stride) for i in range(count)]
    names_entry = entries[names_idx]
    names = data[names_entry[4]:names_entry[4] + names_entry[5]]
    result = {}
    for entry in entries:
        index, stype, _, _, pos, length, _, _, _, _ = entry
        need(index < len(names), 'Invalid ELF section name')
        end = names.find(b'\x00', index)
        need(end >= index, 'Unterminated ELF section name')
        name = names[index:end].decode('ascii')
        if stype != 8:
            need(pos + length <= len(data), f'Invalid ELF section bounds: {name}')
        if name in ('.BTF', '.modinfo'):
            need(name not in result and stype != 8, f'Duplicate/invalid ELF section: {name}')
            result[name] = data[pos:pos + length]
    return result


def module_details(data, name):
    sections = elf_sections(data, module=True)
    need('.BTF' in sections and '.modinfo' in sections, f'Missing module sections: {name}')
    btf_header(sections['.BTF'])
    info = {}
    for item in sections['.modinfo'].split(b'\x00'):
        if b'=' in item:
            key, value = item.decode('utf-8').split('=', 1)
            info.setdefault(key, []).append(value)
    need(info.get('name') == [name], f'Module name mismatch: {name}')
    need([v.strip() for v in info.get('vermagic', [])] == [VERMAGIC],
         f'Module vermagic mismatch: {name}')
    deps = {d for value in info.get('depends', []) for d in value.split(',') if d}
    allowed = set(MODULES) | {'nf_tables', 'nf_conntrack', 'nf_defrag_ipv4', 'nf_defrag_ipv6'}
    need(deps <= allowed, f'Unreviewed module dependency: {name}')
    return {'sha256': sha(data), 'btf_sha256': sha(sections['.BTF']),
            'vermagic': VERMAGIC, 'depends': sorted(deps)}


def walk(value):
    yield value
    if isinstance(value, dict):
        for child in value.values():
            yield from walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from walk(child)


def package_root(document):
    matches = [x for x in walk(document) if isinstance(x, dict)
               and isinstance(x.get('info'), dict) and 'name' in x['info'] and 'paths' in x]
    need(len(matches) == 1, 'Expected exactly one APK package metadata object')
    return matches[0]


def dependency_name(value):
    return re.split(r'[<>=~@]', value.lstrip('!'), maxsplit=1)[0]


def dns_info(info):
    need(info.get('name') == 'dnsmasq-full' and info.get('arch') == ARCH
         and info.get('version') == '2.93-r1', 'Unexpected DNS package identity')
    deps = info.get('depends', [])
    need(isinstance(deps, list) and all(isinstance(x, str) for x in deps), 'Invalid DNS dependencies')
    names = {dependency_name(dep) for dep in deps}
    need(not any('conntrack' in x or 'nfnetlink' in x for x in names),
         'DNS package pulls conntrack/netlink dependencies')
    need(any(re.fullmatch(r'(?:nftables-json|libnftables(?:-json)?[0-9]*)', x) for x in names),
         'DNS package lacks nftables dependency')
    need('dnsmasq=2.93-r1' in info.get('provides', []), 'DNS variant lacks versioned dnsmasq provide')
    return {'name': info['name'], 'version': info['version'], 'arch': info['arch'],
            'depends': deps, 'provides': info.get('provides', [])}


def owned_files(pkg):
    return sorted(f'/lib/modules/{KERNEL}/{name}.ko' for name in GROUPS[pkg])


def input_gates(root):
    modules, dns = root / 'module-probe', root / 'dnsmasq-probe'
    baseline = json.loads(regular(root / 'baseline-inputs.json').read_text())
    need(baseline.get('source_commit') == PIN and baseline.get('audit_manifest_sha256') == AUDIT_SHA,
         'Original source/audit anchor mismatch')
    need(regular(root / 'OFFLINE-ONLY.txt').read_text().strip()
         == 'OFFLINE BUILD COMPLETE - NOT INSTALLED OR RUNTIME VALIDATED', 'Incomplete compile result')
    need(regular(modules / 'RESULT.txt').read_text()
         == 'OFFLINE_BUILD_ONLY\nNo runtime compatibility claim. No install/load/flash performed.\n',
         'Incomplete module probe')
    base = regular(modules / 'baseline-vmlinux.BTF')
    need(sha(base.read_bytes()) == BTF_SHA, 'Base BTF differs from live-kernel anchor')
    btf_header(base.read_bytes())
    before = checksum_rows(regular(modules / 'baseline-before.sha256').read_text())
    sources = checksum_rows(regular(modules / 'sources-before.sha256').read_text())
    need({PurePosixPath(n).name for _, n in before}
         == {'.config', '.vermagic', 'Module.symvers', 'vmlinux', 'autoconf.h', 'auto.conf', 'kernel.release'}
         and len(before) == 7, 'Incomplete baseline manifest')
    need({PurePosixPath(n).name for _, n in sources} == {f'{m}.c' for m in MODULES}
         and len(sources) == 6, 'Incomplete source manifest')
    anchored = {'.config': CONFIG_SHA, '.vermagic': sha((ABI + '\n').encode()),
                'kernel.release': sha((KERNEL + '\n').encode())}
    for digest, name in before:
        leaf = PurePosixPath(name).name
        if leaf in anchored:
            need(digest == anchored[leaf], f'Baseline anchor mismatch: {leaf}')
    integrity = regular(modules / 'baseline-integrity.log').read_text().splitlines()
    need(sorted(integrity) == sorted(f'{name}: OK' for _, name in before + sources),
         'Producer baseline/source integrity check failed')
    buildlog = regular(modules / 'build.log').read_text(errors='replace')
    need(not re.search(r'ERROR:|WARNING:.*modpost|undefined!', buildlog, re.I),
         'Module compile/export diagnostic requires review')
    hashes = verify_payloads(modules, modules / 'modules.sha256', [f'{m}.ko' for m in MODULES])
    need(sha(regular(dns / 'config.before').read_bytes()) == OWRT_CONFIG_SHA, 'DNS baseline config mismatch')
    after = config_values(regular(dns / 'config.after-defconfig').read_text())
    need(all(after.get(k, 'n') == value for k, value in WANT.items()), 'DNS selectors do not match nftset-only probe')
    before_config = config_values(regular(dns / 'config.before').read_text())
    changes = {k: [before_config.get(k, 'n'), after.get(k, 'n')]
               for k in before_config.keys() | after.keys() if before_config.get(k, 'n') != after.get(k, 'n')}
    need(set(changes) <= set(WANT)
         and json.loads(regular(dns / 'config.diff.json').read_text()) == changes,
         'Unexpected DNS build config changes')
    for name in ('config-audit.before-build.txt', 'config-audit.after-build.txt'):
        need(regular(dns / name).read_text().strip().startswith('PASS:'), 'DNS compile audit incomplete')
    candidates = list(dns.glob('dnsmasq-full-*.apk'))
    need(len(candidates) == 1, 'Expected exactly one compiled DNS APK')
    original_dns = regular(candidates[0])
    verify_payloads(dns, dns / 'SHA256SUMS', [original_dns.name])
    return modules, original_dns, base, hashes


def self_test():
    def rejected(function, *args):
        try:
            function(*args)
        except (GateError, UnicodeError, struct.error):
            return
        raise AssertionError('Unsafe input accepted')
    good = {'name': 'dnsmasq-full', 'version': '2.93-r1', 'arch': ARCH,
            'depends': ['libc', 'libnftables1', 'nftables-json'], 'provides': ['dnsmasq=2.93-r1']}
    assert dns_info(good)['name'] == 'dnsmasq-full'
    rejected(dns_info, {**good, 'depends': good['depends'] + ['libnetfilter-conntrack3']})
    rejected(dns_info, {**good, 'depends': ['libc']})
    rejected(dns_info, {**good, 'provides': ['dnsmasq']})
    rejected(dns_info, {**good, 'arch': 'aarch64'})
    rejected(checksum_rows, 'not a manifest')
    rejected(checksum_rows, f'{"0" * 64}  x\n{"1" * 64}  x\n')
    rejected(btf_header, bytes(24))
    rejected(elf_sections, b'not ELF')
    sample = {'info': good, 'paths': []}
    assert package_root({'wrapper': [sample]}) is sample
    rejected(package_root, [sample, sample])
    all_files = [p for pkg in GROUPS for p in owned_files(pkg)]
    assert len(all_files) == len(set(all_files)) == 6
    assert all(p.startswith('/lib/modules/6.12.94/') for p in all_files)
    assert all(f'kernel={KERNEL_APK}' in deps for deps in DEPS.values())
    assert not any('force' in dep or dep.startswith('kernel=') and dep != f'kernel={KERNEL_APK}'
                   for deps in DEPS.values() for dep in deps)
    print('PASS: embedded metadata/checksum/BTF/ownership guards; no files written')


def main(args):
    need(hasattr(os, 'geteuid') and os.geteuid() == 0,
         'Run packaging as root in disposable CI so payload ownership is root:root')
    root = Path(args.proof).resolve(strict=True)
    modules, original_dns, base, original_hashes = input_gates(root)
    out = Path(args.out).absolute()
    need(not out.exists() and not out.is_symlink(), 'Output must not exist')
    out = out.resolve()
    need(out.parent.is_dir() and not out.is_relative_to(root), 'Output must be outside probe inputs')
    os.umask(0o077)
    env = {**os.environ, 'APK_CONFIG': '/dev/null', 'LC_ALL': 'C', 'LANG': 'C'}

    def run(*argv, check=True):
        result = subprocess.run([str(x) for x in argv], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
        if check and result.returncode:
            raise GateError(f'{Path(str(argv[0])).name} failed: '
                            + result.stderr.decode('utf-8', 'replace')[:1200])
        return result

    apk = str(Path(args.apk).resolve(strict=True))
    need(run(apk, '--version').stdout.decode().startswith('apk-tools 3.0.5'), 'Use full host apk-tools 3.0.5')
    for app in ('mkpkg', 'mkndx', 'adbsign'):
        helptext = run(apk, app, '--help', check=False).stdout.decode('utf-8', 'replace')
        need(f'Usage: apk {app}' in helptext, f'Host APK lacks {app}')
    for tool in (args.openssl, args.readelf, args.pahole):
        need(shutil.which(tool) is not None, f'Missing tool: {tool}')

    def dump(path):
        return json.loads(run(apk, 'adbdump', '--format', 'json', path).stdout)

    dns_root = package_root(dump(original_dns))
    dns_summary = dns_info(dns_root['info'])
    checked_modules = {}
    for name in MODULES:
        source = regular(modules / f'{name}.ko')
        checked_modules[name] = module_details(source.read_bytes(), name)
        # Read/decode only: no -J/--btf_encode and never rely on the host kernel BTF.
        decoded = run(args.pahole, '-F', 'btf', '--btf_base', base, source)
        need(not re.search(rb'error|failed|invalid', decoded.stderr, re.I), f'Module BTF decode diagnostic: {name}')
        checked_modules[name]['base_btf_decode_sha256'] = sha(decoded.stdout)

    out.mkdir(mode=0o755)
    out.chmod(0o755)
    repo = out / 'repo'
    repo.mkdir(mode=0o755)
    repo.chmod(0o755)
    # ponytail: one ephemeral signing identity for this fixed five-package repo.
    # Nothing in this work directory is ever included in the allowlisted archive.
    with tempfile.TemporaryDirectory(prefix='pw2-pack-') as temp:
        work = Path(temp)
        key, public = work / 'private.pem', work / 'public.pem'
        keys, empty_keys = work / 'keys', work / 'empty-keys'
        keys.mkdir(); empty_keys.mkdir()
        run(args.openssl, 'genpkey', '-algorithm', 'EC', '-pkeyopt', 'ec_paramgen_curve:P-256', '-out', key)
        run(args.openssl, 'pkey', '-in', key, '-pubout', '-out', public)
        shutil.copyfile(public, keys / 'pw2-compat-public.pem')
        public_der = run(args.openssl, 'pkey', '-pubin', '-in', public, '-outform', 'DER').stdout

        def verified(path):
            run(apk, '--keys-dir', keys, 'verify', path)
            # Fail closed if ambient configuration or an unsigned file bypasses signatures.
            need(run(apk, '--keys-dir', empty_keys, 'verify', path, check=False).returncode != 0,
                 f'Empty trust store unexpectedly accepted {path.name}')

        packages = []
        summaries = []
        for pkg, names in GROUPS.items():
            stage = work / pkg
            moddir = stage / 'lib' / 'modules' / KERNEL
            moddir.mkdir(parents=True)
            for name in names:
                shutil.copyfile(modules / f'{name}.ko', moddir / f'{name}.ko')
                (moddir / f'{name}.ko').chmod(0o644)
            package_list = stage / 'lib' / 'apk' / 'packages' / f'{pkg}.list'
            package_list.parent.mkdir(parents=True)
            # Same native format as include/package-pack.mk: sorted absolute payload
            # paths, no own .list entry. This package actually owns every listed KO.
            package_list.write_text(''.join(p + '\n' for p in owned_files(pkg)))
            package_list.chmod(0o644)
            # Never let the private signing umask change shared /lib directories.
            for directory in (stage, *(p for p in stage.rglob('*') if p.is_dir())):
                directory.chmod(0o755)
            target = repo / f'{pkg}-{VERSION}.apk'
            run(apk, 'mkpkg', '--compat', '3.0.5', '--compression', 'deflate', '--sign-key', key,
                '--info', f'name:{pkg}', '--info', f'version:{VERSION}', '--info', f'arch:{ARCH}',
                '--info', 'license:GPL-2.0-only', '--info', 'origin:local/pw2-compat-external',
                '--info', f'description:Local external {pkg}; exact original kernel; no automatic loading',
                '--info', 'depends:' + ' '.join(DEPS[pkg]), '--files', stage, '--output', target)
            verified(target)
            metadata = package_root(dump(target))
            info = metadata['info']
            need((info.get('name'), info.get('version'), info.get('arch')) == (pkg, VERSION, ARCH)
                 and info.get('origin') == 'local/pw2-compat-external'
                 and set(info.get('depends', [])) == set(DEPS[pkg]), 'Signed module metadata mismatch')
            need(not metadata.get('scripts') and not metadata.get('triggers') and not info.get('provides'),
                 'Unexpected module scripts/triggers/provides')
            extracted = work / f'{pkg}-verify'
            extracted.mkdir()
            run(apk, '--keys-dir', keys, 'extract', '--destination', extracted, target)
            actual = {p.relative_to(extracted).as_posix() for p in extracted.rglob('*') if p.is_file()}
            expected = {p.lstrip('/') for p in owned_files(pkg)} | {package_list.relative_to(stage).as_posix()}
            need(not any(p.is_symlink() for p in extracted.rglob('*')) and actual == expected,
                 'Signed package file ownership mismatch')
            for entry in extracted.rglob('*'):
                stat = entry.stat()
                need(stat.st_uid == 0 and stat.st_gid == 0
                     and stat.st_mode & 0o7777 == (0o755 if entry.is_dir() else 0o644),
                     'Signed module payload ownership/mode mismatch')
            for name in names:
                need(sha((extracted / 'lib' / 'modules' / KERNEL / f'{name}.ko').read_bytes())
                     == original_hashes[f'{name}.ko'], 'Module bytes changed during packaging')
            need((extracted / package_list.relative_to(stage)).read_bytes() == package_list.read_bytes(),
                 'Owned package list mismatch')
            packages.append(target)
            summaries.append({k: info[k] for k in ('name', 'version', 'arch', 'origin', 'depends')})

        dns_target = repo / original_dns.name
        shutil.copyfile(original_dns, dns_target)
        # Only this checksum-proven own-build input may initially be unsigned.
        # The flag is confined to signing; never pass it to verify/extract/index/add.
        # adbsign may return zero after a per-file error: verified() is mandatory.
        run(apk, '--allow-untrusted', 'adbsign', '--reset-signatures', '--sign-key', key, dns_target)
        verified(dns_target)
        need(package_root(dump(dns_target)) == dns_root, 'Signing changed DNS metadata')
        dns_stage = work / 'dns-extract'
        dns_stage.mkdir()
        run(apk, '--keys-dir', keys, 'extract', '--destination', dns_stage, dns_target)
        binary = regular(dns_stage / 'usr' / 'sbin' / 'dnsmasq')
        elf_sections(binary.read_bytes())
        dynamic = run(args.readelf, '-d', binary).stdout.decode('utf-8', 'replace')
        libs = re.findall(r'Shared library: \[([^]]+)\]', dynamic)
        need(any(x.startswith('libnftables') for x in libs)
             and not any('conntrack' in x or 'nfnetlink' in x for x in libs), 'DNS ELF library gate failed')
        packages.append(dns_target)
        summaries.append(dns_summary)
        index = repo / 'packages.adb'
        run(apk, '--keys-dir', keys, 'mkndx', '--sign-key', key, '--compression', 'deflate',
            '--hash', 'sha256', '--pkgname-spec', '${name}-${version}.apk', '--output', index, *packages)
        verified(index)
        indexed = [(x['name'], x['version'], x['arch']) for x in walk(dump(index))
                   if isinstance(x, dict) and all(isinstance(x.get(k), str) for k in ('name', 'version', 'arch'))]
        need(sorted(indexed) == sorted((x['name'], x['version'], x['arch']) for x in summaries),
             'Signed repository package set differs from reviewed set')
        shutil.copyfile(public, out / 'pw2-compat-public.pem')
        (out / 'pw2-compat-public.pem').chmod(0o644)

    need(sha(original_dns.read_bytes()) == verify_payloads(original_dns.parent,
         original_dns.parent / 'SHA256SUMS', [original_dns.name])[original_dns.name], 'DNS input mutated')
    proof = {'status': 'SIGNED_REPOSITORY_ONLY_NOT_INSTALLED_OR_RUNTIME_VALIDATED',
             'source_commit': PIN, 'audit_manifest_sha256': AUDIT_SHA, 'base_btf_sha256': BTF_SHA,
             'kernel_dependency': KERNEL_APK, 'module_package_version': VERSION, 'arch': ARCH,
             'exports_gate': 'successful producer fatal-modpost result and unchanged baseline/source manifest',
             'public_key_spki_sha256': sha(public_der), 'modules': checked_modules,
             'packages': summaries, 'dns_original_apk_sha256': sha(original_dns.read_bytes()),
             'dns_shared_libraries': libs, 'dns_metadata_and_scripts_unchanged': True,
             'module_autoload_init_scripts': False, 'signature_positive_and_empty_store_negative_tests': 'passed'}
    (out / 'proof.json').write_text(json.dumps(proof, indent=2, sort_keys=True) + '\n')
    files = [*packages, index, out / 'pw2-compat-public.pem', out / 'proof.json']
    (out / 'SHA256SUMS').write_text(''.join(f'{sha(p.read_bytes())}  {p.relative_to(out).as_posix()}\n'
                                           for p in sorted(files)))
    files.append(out / 'SHA256SUMS')
    # Public artifacts must remain readable by the unprivileged CI uploader.
    for path in files:
        path.chmod(0o644)
    archive = out / 'pw2-compat-signed-repo.tar.gz'
    allowed = {p.relative_to(out).as_posix() for p in files}
    with tarfile.open(archive, 'w:gz') as tar:
        for path in sorted(files):
            regular(path)
            entry = tar.gettarinfo(str(path), arcname=path.relative_to(out).as_posix())
            need(entry.isfile(), 'Archive accepts regular allowlisted files only')
            entry.uid = entry.gid = 0
            entry.uname = entry.gname = 'root'
            entry.mode = 0o644
            with path.open('rb') as data:
                tar.addfile(entry, data)
    with tarfile.open(archive, 'r:gz') as tar:
        entries = tar.getmembers()
        need(len(entries) == len(allowed) and {e.name for e in entries} == allowed
             and all(e.isfile() for e in entries), 'Unexpected archive member')
    archive.chmod(0o644)
    print(f'PASS: signed five-package repository prepared locally: {archive}')
    print(f'ARCHIVE_SHA256={sha(archive.read_bytes())}')
    print('NO INSTALL, LOAD, FLASH, ROUTER CONTACT OR REMOTE PUBLISH PERFORMED')


parser = argparse.ArgumentParser(description='Local-only guarded PW2 compatibility repository packaging')
parser.add_argument('--apk', help='Absolute path to full host apk-tools 3.0.5')
parser.add_argument('--proof', help='Completed probe root containing module-probe and dnsmasq-probe')
parser.add_argument('--out', help='New output directory outside probe root')
parser.add_argument('--openssl', default='openssl')
parser.add_argument('--readelf', default='readelf')
parser.add_argument('--pahole', default='pahole')
parser.add_argument('--self-test', action='store_true')
args = parser.parse_args()
try:
    if args.self_test:
        self_test()
    else:
        if not all((args.apk, args.proof, args.out)):
            parser.error('--apk, --proof and --out are required')
        main(args)
except (GateError, OSError, ValueError, UnicodeError, struct.error) as error:
    print(f'STOP: {error}', file=sys.stderr)
    sys.exit(1)
PY
