"""Scan a release folder for content that must never be published.

  python tools/release/scan_release.py zig-out/release-1.0 [--also FILE ...]

Looks into every file, into zip entries (recursively) and into gzip streams
(initramfs, cpio.gz), and fails on:
  - private keys: PEM "BEGIN ... PRIVATE KEY" blocks, and key-store files
    (*.pfx, *.p12, *.key, *.pvk, *.snk, *.jks), anywhere;
  - Windows product keys (5x5 groups of the product-key alphabet);
  - ISO / disk images other than the allowlisted ones (by SHA-256), by name
    (*.iso, *.img, *.vhd, *.vhdx, *.wim, *.esd, *.vdi, *.vmdk) or by an
    ISO 9660 / UDF volume descriptor;
  - filled answer profiles: user names, passwords or product keys in
    answer files (autounattend.xml, unattend.xml, winnt.sif, *.sif, usos-xp.ini,
    answer profile *.ini) and the USOS signing folder path.
"""
from pathlib import Path
import argparse, gzip, hashlib, io, re, sys, tarfile, zipfile

# Product-key alphabet (no A E I L N O S U Z 0 1 5).
PRODUCT_KEY = re.compile(rb'(?<![A-Z0-9])[BCDFGHJKMPQRTVWXY2346789]{5}(?:-[BCDFGHJKMPQRTVWXY2346789]{5}){4}(?![A-Z0-9])')
PRIVATE_KEY = re.compile(rb'-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----')
KEY_STORE = re.compile(r'(?i)\.(pfx|p12|key|pvk|snk|jks)$')
IMAGE = re.compile(r'(?i)\.(iso|img|vhd|vhdx|wim|esd|vdi|vmdk|qcow2)$')
ANSWER_NAME = re.compile(r'(?i)(^|/)(autounattend\.xml|unattend\.xml|winnt\.sif|[^/]+\.sif|usos-xp\.ini|[^/]*profiles?/[^/]+\.ini)$')
SIGNING_PATH = re.compile(rb'(?i)USOS[\\/]+signing[\\/]+[^\s"\']+\.(?:key|pem|pfx)')
# Filled fields in answer files; empty values and USOS placeholders are fine.
ANSWER_FIELDS = [
    re.compile(rb'(?im)^[ \t]*(?:productkey|product_key|productid|adminpassword|password)[ \t]*=[ \t]*"?[^\s";]+'),
    re.compile(rb'(?is)<(?:ProductKey|Key)>\s*<Key>\s*[^<\s]+|<ProductKey>\s*[A-Z0-9][^<]*</ProductKey>'),
    re.compile(rb'(?is)<Password>\s*<Value>\s*[^<\s]+'),
]
# Upstream key files that are part of a published third-party source tree
# (shipped for GPL compliance), by SHA-256.
ALLOWED_KEY_FILES = {
    # ImDisk 2.1.2 source (tools/vendor/imdisk/2.1.2/source.zip): the .NET
    # strong-name key the upstream author publishes with the ImDiskNet sources.
    '935a6b64b29882e2da9030975630eab0ae23048ff647f2ceb16faa91dfab694c': 'ImDiskNet.snk (upstream ImDisk source)',
    # wimboot 2.9.0 source (tools/vendor/wimboot/2.9.0/source.tar.gz): the
    # throw-away test certificate key of the upstream test suite.
    '6d92996e7cfc3a1f07747ea2801bdaff2752d7f6c8f02229e3af9aef83e2f836': 'wimboot test/testcert.key (upstream test key)',
}
ISO_MAGIC = (0x8001, b'CD001')
UDF_MAGIC = (b'BEA01', b'NSR02', b'NSR03')
MAX_SCAN = 1 << 30  # bytes of one member kept in memory for scanning


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def is_disk_image(head):
    if len(head) > ISO_MAGIC[0] + 5 and head[ISO_MAGIC[0]:ISO_MAGIC[0] + 5] == ISO_MAGIC[1]:
        return True
    return any(head[0x8001 + i * 0x800:0x8001 + i * 0x800 + 5] in UDF_MAGIC for i in range(4))


def scan_bytes(name, data, allowed, findings, depth=0):
    """Scan one file's content (name is the display path)."""
    lower = name.lower()
    base = lower.rsplit('/', 1)[-1]
    if KEY_STORE.search(base) and sha256(data) not in ALLOWED_KEY_FILES:
        findings.append(f'{name}: key-store file name')
    digest = None
    if IMAGE.search(base) or is_disk_image(data[:0x9000]):
        digest = sha256(data)
        if digest not in allowed:
            findings.append(f'{name}: disk/ISO image not on the allowlist (sha256 {digest})')
            return
    if PRIVATE_KEY.search(data) and sha256(data) not in ALLOWED_KEY_FILES:
        findings.append(f'{name}: PEM private key block')
    if SIGNING_PATH.search(data):
        findings.append(f'{name}: path into the USOS signing key folder')
    for m in PRODUCT_KEY.finditer(data):
        if len(set(m.group(0).replace(b'-', b''))) == 1:
            continue  # a format placeholder such as XXXXX-XXXXX-...
        findings.append(f'{name}: product-key pattern at offset {m.start()}')
    if ANSWER_NAME.search(lower):
        for rx in ANSWER_FIELDS:
            m = rx.search(data)
            if m:
                findings.append(f'{name}: filled answer field {m.group(0)[:40]!r}')
    if depth > 4:
        return
    if data[:4] == b'PK\x03\x04':
        try:
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                scan_zip(name, z, allowed, findings, depth + 1)
        except zipfile.BadZipFile:
            pass
    elif data[:2] == b'\x1f\x8b':
        try:
            inner = gzip.GzipFile(fileobj=io.BytesIO(data)).read(MAX_SCAN)
        except (OSError, EOFError):
            inner = b''
        if inner[:6] in (b'070701', b'070702'):
            for entry, content in cpio_members(inner):
                scan_bytes(name + '!' + entry, content, allowed, findings, depth + 1)
        elif inner[257:262] == b'ustar':
            for entry, content in tar_members(inner):
                scan_bytes(name + '!' + entry, content, allowed, findings, depth + 1)
        elif inner:
            scan_bytes(name + '!gunzip', inner, allowed, findings, depth + 1)


def cpio_members(data):
    """newc cpio members (initramfs); stops quietly on anything else."""
    pos = 0
    while pos + 110 <= len(data) and data[pos:pos + 6] in (b'070701', b'070702'):
        try:
            size = int(data[pos + 54:pos + 62], 16)
            namesize = int(data[pos + 94:pos + 102], 16)
        except ValueError:
            return
        name = data[pos + 110:pos + 110 + namesize - 1].decode('utf-8', 'replace')
        start = (pos + 110 + namesize + 3) & ~3
        if name == 'TRAILER!!!':
            return
        yield name, data[start:start + size]
        pos = (start + size + 3) & ~3


def tar_members(data):
    with tarfile.open(fileobj=io.BytesIO(data)) as t:
        for member in t:
            if member.isfile():
                yield member.name, t.extractfile(member).read()


def scan_zip(name, z, allowed, findings, depth):
    for info in z.infolist():
        if info.is_dir():
            continue
        with z.open(info) as f:
            data = f.read(MAX_SCAN)
        scan_bytes(name + '!' + info.filename, data, allowed, findings, depth)


def scan(folder, extra=(), allowed_iso_sha256=()):
    allowed = {h.lower() for h in allowed_iso_sha256}
    findings = []
    paths = sorted(p for p in Path(folder).rglob('*') if p.is_file()) + [Path(p) for p in extra]
    for path in paths:
        display = path.relative_to(folder).as_posix() if Path(folder) in path.parents else str(path)
        if path.stat().st_size > MAX_SCAN and path.suffix.lower() != '.zip':
            findings.append(f'{display}: too large to scan ({path.stat().st_size} bytes)')
            continue
        if path.suffix.lower() == '.zip':
            if KEY_STORE.search(path.name):
                findings.append(f'{display}: key-store file name')
            with zipfile.ZipFile(path) as z:
                scan_zip(display, z, allowed, findings, 1)
        else:
            scan_bytes(display, path.read_bytes(), allowed, findings)
    return findings


def main():
    p = argparse.ArgumentParser()
    p.add_argument('folder', type=Path)
    p.add_argument('--also', type=Path, action='append', default=[])
    p.add_argument('--allow-iso-sha256', action='append', default=[])
    a = p.parse_args()
    findings = scan(a.folder, a.also, a.allow_iso_sha256)
    for f in findings:
        print('SCAN FAIL:', f)
    print('SCAN', 'FAIL' if findings else 'PASS', len(findings), 'finding(s)')
    sys.exit(1 if findings else 0)


if __name__ == '__main__':
    main()
