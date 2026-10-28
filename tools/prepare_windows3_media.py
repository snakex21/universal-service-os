"""Flatten supplied Windows 1.0x-3.x diskette images into an ISO for USOS.

--source is a ZIP with the diskette images or a folder holding them
(*.IMG / *.IMA; 360 KiB, 720 KiB, 1.2 MiB or 1.44 MiB FAT12). Every file of
every diskette lands unchanged in one ISO (one directory level kept, for
Windows 1.0x's PIF directory); the original images are only read. The ISO goes
to DATA as Systems\\Windows\\<system>\\Images\\<name>.iso (MEDIA_LAYOUT.md).
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
from dos_media_fat12 import FORMATS, files as floppy_files
from flat_iso9660 import build

IMAGE = re.compile(r'\.(IMG|IMA)$', re.IGNORECASE)


def natural(name: str):
    return [int(part) if part.isdigit() else part.lower() for part in re.split(r'(\d+)', name)]


def diskettes(source: Path):
    """[(name, bytes)] in disk order (natural sort of the file names)."""
    if source.is_dir():
        found = [(path.name, path.read_bytes()) for path in source.iterdir() if path.is_file() and IMAGE.search(path.name)]
    else:
        with zipfile.ZipFile(source) as archive:
            found = [(entry.filename, archive.read(entry)) for entry in archive.infolist()
                     if not entry.filename.startswith('__MACOSX/') and IMAGE.search(entry.filename)]
    if not 1 <= len(found) <= 20:
        raise ValueError('Expected 1 to 20 diskette images (*.IMG)')
    found.sort(key=lambda item: natural(item[0]))
    return found


def convert(source: Path, output: Path):
    payloads = {}
    manifest = []
    members = diskettes(source)
    for disk, data in members:
        if len(data) not in FORMATS:
            raise ValueError('Expected a 360 KiB, 720 KiB, 1.2 MiB or 1.44 MiB diskette: ' + disk)
        for name, content in floppy_files(data):
            if name in payloads and payloads[name] != content:
                raise ValueError('Diskettes contain conflicting files: ' + name)
            payloads[name] = content
            manifest.append({'disk': disk, 'name': name, 'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
    if 'SETUP.EXE' not in payloads or not payloads['SETUP.EXE'].startswith(b'MZ'):
        raise ValueError('The diskettes do not contain a Windows installer (SETUP.EXE)')
    image = build(payloads)
    if output.exists() and output.read_bytes() != image:
        raise FileExistsError('Refusing to replace an existing different ISO: ' + str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(image)
    report = {'source': str(source.resolve()),
              'output': str(output.resolve()), 'output_sha256': hashlib.sha256(image).hexdigest(),
              'size': len(image), 'files': manifest}
    if source.is_file():
        report['source_sha256'] = hashlib.sha256(source.read_bytes()).hexdigest()
    output.with_suffix('.manifest.json').write_text(json.dumps(report, indent=2) + '\n')
    print(f'PASS: {len(members)} diskettes, {len(payloads)} unchanged files, ISO {len(image)} bytes')
    print('SHA256:', report['output_sha256'])
    return report


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    convert(args.source, args.output)
