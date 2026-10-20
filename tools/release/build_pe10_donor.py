"""Build a PE10 donor ISO (WinPE 10 with Setup, no install image) from a
Windows 10 Setup ISO. Local, read-only on the source: no mounting, no DISM,
no servicing, no USB access. The result is a release asset only and is never
committed to git (artifacts/ is git-ignored).

  python -I tools/release/build_pe10_donor.py --arch x86 \
      --source "C:/.../Windows 10 22H2 19045.6396 PL x86.iso" \
      --out artifacts/pe10-x86

The x64 donor (PE10_x64_19041_USOS.iso, 2026-09-15) was made the same way by
a one-off script; this tool generalises it to both architectures:

* the members are copied byte for byte with 7-Zip (sources/boot.wim is NOT
  re-exported or trimmed, so its signature-relevant content is unchanged);
* x64: boot/bcd, boot/boot.sdi, sources/boot.wim, sources/setup.exe;
  x86: the same plus the root `bootmgr` (the 32-bit Windows 7 / Vista / 2008
  path, win-nt6-x86-uefi-csmwrap, boots the donor in BIOS mode through
  CSMWrap and stages the donor's own BIOS boot manager, see
  tools/vista_csmwrap_target.sh, and src/windows7_iso.zig inspectX86Donor
  requires it);
* boot.wim must have two images, boot index 2 = "Microsoft Windows Setup"
  of the requested architecture, version 10.0.<build> (the name uses that
  build: 22H2 media still carry a 10.0.19041 boot.wim);
* the image is UDF 1.02 without El Torito, written by Windows IMAPI2FS
  (pe10_donor_udf.ps1), then listed and extracted again with 7-Zip and every
  member compared by size and SHA-256 with the source.

A verification.json with every hash is written next to the ISO.
"""
from pathlib import Path
import argparse, hashlib, json, os, struct, subprocess, sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

HERE = Path(__file__).resolve().parent
SEVEN = Path(r'C:\Program Files\7-Zip\7z.exe')
COMMON = ('boot/bcd', 'boot/boot.sdi', 'sources/boot.wim', 'sources/setup.exe')
MEMBERS = {'x64': COMMON, 'x86': ('bootmgr',) + COMMON}
WIM_ARCH = {'x64': 9, 'x86': 0}
CHUNK = 4 << 20


def donor_name(arch, build):
    return f'PE10_{arch}_{build}_USOS.iso'


def file_hash(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        while data := f.read(CHUNK):
            digest.update(data)
    return digest.hexdigest()


def run(command, log):
    with open(log, 'wb') as out:
        result = subprocess.run([str(x) for x in command], stdout=out, stderr=subprocess.STDOUT, timeout=1800)
    if result.returncode:
        raise SystemExit(f'command failed ({result.returncode}), see {log}')
    return Path(log).read_text(encoding='utf-8-sig', errors='replace')


def member_hash(archive, member, log):
    digest, count = hashlib.sha256(), 0
    with open(log, 'wb') as err:
        p = subprocess.Popen([str(SEVEN), 'x', '-so', '-bd', '-y', str(archive), member.replace('/', '\\')], stdout=subprocess.PIPE, stderr=err)
        try:
            while data := p.stdout.read(CHUNK):
                count += len(data)
                digest.update(data)
        finally:
            p.stdout.close()
        if p.wait() != 0:
            raise SystemExit(f'streaming extraction failed: {archive} / {member}')
    return {'bytes': count, 'sha256': digest.hexdigest()}


def exact_files(directory, members):
    actual = sorted(p.relative_to(directory).as_posix().lower() for p in directory.rglob('*') if p.is_file())
    if actual != sorted(members):
        raise SystemExit(f'unexpected payload: {actual}')


def wim_images(path):
    """Header fields and the XML image list of a WIM (read only)."""
    with open(path, 'rb') as f:
        header = f.read(124)
        if header[:8] != b'MSWIM\0\0\0':
            raise SystemExit('boot.wim: WIM signature missing')
        count = struct.unpack_from('<I', header, 44)[0]
        boot_index = struct.unpack_from('<I', header, 120)[0]
        xml_size = struct.unpack_from('<Q', header, 72)[0] & 0x00FFFFFFFFFFFFFF
        xml_offset = struct.unpack_from('<Q', header, 80)[0]
        if not (0 < xml_size < 1 << 20):
            raise SystemExit('boot.wim: unexpected XML resource')
        f.seek(xml_offset)
        xml = f.read(xml_size)
    root = ET.fromstring(xml.decode('utf-16').rstrip('\0'))
    images = []
    for image in root.findall('IMAGE'):
        images.append({'index': int(image.attrib['INDEX']), 'name': image.findtext('NAME') or '',
                       'arch': int(image.findtext('WINDOWS/ARCH')),
                       'major': int(image.findtext('WINDOWS/VERSION/MAJOR')),
                       'minor': int(image.findtext('WINDOWS/VERSION/MINOR')),
                       'build': int(image.findtext('WINDOWS/VERSION/BUILD')),
                       'spbuild': int(image.findtext('WINDOWS/VERSION/SPBUILD') or 0)})
    return count, boot_index, images, xml


def check_wim(arch, count, boot_index, images):
    """The gate the USOS scanner applies (detectX64Setup / detectX86Setup,
    isWindows10Donor: 10.0 build 10240..21999), plus the PE image."""
    by_index = {i['index']: i for i in images}
    setup, pe = by_index.get(2), by_index.get(1)
    if count != 2 or boot_index != 2 or setup is None or pe is None:
        raise SystemExit(f'boot.wim: need 2 images with boot index 2, got count={count} boot={boot_index}')
    if 'Setup' not in setup['name'] or 'PE' not in pe['name']:
        raise SystemExit(f'boot.wim: unexpected image names {images}')
    for image in (pe, setup):
        if image['arch'] != WIM_ARCH[arch] or (image['major'], image['minor']) != (10, 0) or not 10240 <= image['build'] < 22000:
            raise SystemExit(f'boot.wim: not a {arch} PE 10.0 donor: {image}')
    return setup['build']


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--arch', choices=sorted(MEMBERS), required=True)
    ap.add_argument('--source', type=Path, required=True, help='Windows 10 Setup ISO (read only)')
    ap.add_argument('--out', type=Path, required=True, help='new or empty output folder')
    args = ap.parse_args(argv)
    members = MEMBERS[args.arch]
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if any(out.iterdir()):
        raise SystemExit(f'{out} is not empty')
    os.environ['TEMP'] = os.environ['TMP'] = str(out / 'temp')
    (out / 'temp').mkdir()
    source = args.source.resolve()
    before = source.stat()
    paths = [m.replace('/', '\\') for m in members]
    run([SEVEN, 'l', '-slt', '-sccUTF-8', source, *paths], out / 'source-listing.log')
    payload = out / 'payload'
    payload.mkdir()
    run([SEVEN, 'x', '-y', '-bd', '-sccUTF-8', f'-o{payload}', source, *paths], out / 'source-extract.log')
    exact_files(payload, members)
    report = {'source': {'path': str(source), 'bytes': before.st_size}, 'arch': args.arch,
              'purpose': 'PE10 Setup donor; NOT a full Windows 10 installer (no install image)', 'files': {}}
    for member in members:
        streamed = member_hash(source, member, out / 'source-member.log')
        local = {'bytes': (payload / member).stat().st_size, 'sha256': file_hash(payload / member)}
        if streamed != local:
            raise SystemExit(f'source/extraction mismatch: {member}')
        report['files'][member] = local
    count, boot_index, images, xml = wim_images(payload / 'sources/boot.wim')
    (out / 'boot-wim-metadata.xml').write_bytes(xml)
    build = check_wim(args.arch, count, boot_index, images)
    report['wim'] = {'image_count': count, 'boot_index': boot_index, 'images': images, 'byte_preserved': True}
    report['source']['sha256'] = file_hash(source)
    iso = out / donor_name(args.arch, build)
    run(['powershell.exe', '-NoProfile', '-NonInteractive', '-Sta', '-ExecutionPolicy', 'Bypass', '-File', HERE / 'pe10_donor_udf.ps1',
         '-Payload', payload, '-OutputIso', iso, '-WorkDirectory', out / 'com-work', '-VolumeName', f'USOS_PE10_{args.arch.upper()}'], out / 'imapi-create.log')
    listing = run([SEVEN, 'l', '-slt', '-sccUTF-8', iso], out / 'donor-listing.log')
    if 'Type = Udf' not in listing or 'Version = 1.02' not in listing:
        raise SystemExit('result is not UDF 1.02')
    with open(iso, 'rb') as f:
        f.seek(16 * 2048)
        descriptors = f.read(16 * 2048)
    if any(descriptors[o:o + 7] == b'\x00CD001\x01' for o in range(0, len(descriptors), 2048)):
        raise SystemExit('unexpected El Torito boot record')
    roundtrip = out / 'roundtrip'
    roundtrip.mkdir()
    run([SEVEN, 'x', '-y', '-bd', '-sccUTF-8', f'-o{roundtrip}', iso], out / 'donor-extract.log')
    exact_files(roundtrip, members)
    for member in members:
        again = {'bytes': (roundtrip / member).stat().st_size, 'sha256': file_hash(roundtrip / member)}
        if again != report['files'][member]:
            raise SystemExit(f'donor roundtrip mismatch: {member}')
    after = source.stat()
    if (after.st_size, after.st_mtime_ns) != (before.st_size, before.st_mtime_ns):
        raise SystemExit('source ISO changed during processing')
    report['donor'] = {'name': iso.name, 'bytes': iso.stat().st_size, 'sha256': file_hash(iso),
                       'filesystem': 'UDF 1.02', 'el_torito': False, 'file_count': len(members),
                       'created': datetime.now(timezone.utc).isoformat()}
    (out / 'verification.json').write_text(json.dumps(report, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
    print(json.dumps(report['donor']))


if __name__ == '__main__':
    main()
