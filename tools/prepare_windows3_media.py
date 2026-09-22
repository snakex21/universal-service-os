"""Flatten supplied Windows 3.x diskette ZIPs into an ISO for the BIOS loader."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import zipfile
from dos_media_fat12 import files as floppy_files
from flat_iso9660 import build

def convert(source: Path, output: Path):
    payloads = {}
    manifest = []
    with zipfile.ZipFile(source) as archive:
        members = [entry for entry in archive.infolist() if
                   not entry.filename.startswith('__MACOSX/') and
                   re.search(r'(^|/)DISK[1-9][0-9]*\.(IMG|IMA)$', entry.filename, re.IGNORECASE)]
        if not 1 <= len(members) <= 20:
            raise ValueError('Expected 1 to 20 DISK<number>.IMG disk images')
        members.sort(key=lambda item: int(re.search(r'DISK([0-9]+)', item.filename, re.IGNORECASE)[1]))
        for entry in members:
            if entry.file_size != 1474560:
                raise ValueError('Expected a 1.44 MiB diskette: ' + entry.filename)
            data = archive.read(entry)
            for name, content in floppy_files(data):
                if name in payloads and payloads[name] != content:
                    raise ValueError('Diskettes contain conflicting files: ' + name)
                payloads[name] = content
                manifest.append({'disk': entry.filename, 'name': name, 'size': len(content), 'sha256': hashlib.sha256(content).hexdigest()})
    if not {'SETUP.EXE', 'SETUP.INF'}.issubset(payloads) or not payloads['SETUP.EXE'].startswith(b'MZ'):
        raise ValueError('The archive does not contain a Windows 3.x installer')
    image = build(payloads)
    if output.exists() and output.read_bytes() != image:
        raise FileExistsError('Refusing to replace an existing different ISO: ' + str(output))
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(image)
    report = {'source': str(source.resolve()), 'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
              'output': str(output.resolve()), 'output_sha256': hashlib.sha256(image).hexdigest(),
              'size': len(image), 'files': manifest}
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
