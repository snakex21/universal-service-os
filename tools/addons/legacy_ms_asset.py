"""Release asset USOS-<version>-Legacy-pack-MS.zip: the Microsoft
redistributables of the legacy compatibility pack (manifest packages with
source=release), shipped under the maintainer decision of 2026-09-30
(docs/LICENSES-AUDIT.md section 8, docs/design/legacy-compat-pack.md 2.4).

The files come from the maintainer's local copy (--source, any layout; they
are found by size + SHA-256 like the staging does) and are never committed
to git. Layout inside the zip, extracted by the installer to USOS_DATA:

  Addons/USOS/MS/<dir>/<8.3 name>      one folder per package
  Addons/USOS/MS/legacy-ms.json        index: version, package, file, sha256
  Addons/USOS/MS/README.txt

The full installer embeds the zip, the online installer downloads it from
the release (SHA-256 pinned in the installer and in SHA256SUMS).
Copyright (C) 2026 Maksymilian and the USOS Authors, GPL-3.0-or-later.

  python tools/addons/legacy_ms_asset.py --source <folder> --out <zip> [--version 1.1.0]
"""
from __future__ import annotations

import argparse
import json
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import legacy_manifest as lm  # noqa: E402
from stage_legacy_pack import Finder  # noqa: E402

PREFIX = 'Addons/USOS/MS'
DATE = (2026, 9, 30, 0, 0, 0)


def release_packages(m: lm.Manifest) -> list[lm.Package]:
    return [p for p in m.packages if p.get('source') == 'release']


def readme(version: str, entries: list[dict]) -> str:
    lines = [f'USOS {version} - legacy compatibility pack, Microsoft redistributables',
             '',
             'Microsoft runtime redistributables for Windows 95/98/Me/NT 4.0 (DirectX,',
             'Windows Installer, MDAC, VB6/VC6 runtimes, MSLU, .NET Framework), unmodified.',
             'They remain Microsoft property and are not covered by any USOS licence;',
             'they are redistributed by the USOS maintainer at the maintainer\'s own risk',
             '(maintainer decision of 2026-09-30, preservation) and are removed on',
             'request of the rights holder.',
             '',
             'The USOS installer puts this folder on USOS_DATA (Addons\\USOS\\MS); the',
             'legacy pack takes the files from here by SHA-256 when it prepares a',
             'Windows 95/98/Me/NT 4.0 installation.',
             '',
             'Files:']
    lines += [f'  {e["sha256"]}  {e["dir"]}/{e["file"]}  ({e["package"]}, original name {e["original"]})' for e in entries]
    return '\r\n'.join(lines) + '\r\n'


def build(sources: list[Path], out: Path, version: str, manifest: Path = lm.MANIFEST) -> dict:
    m = lm.Manifest.load(manifest)
    pkgs = release_packages(m)
    wanted = {}
    for p in pkgs:
        for f in p.files():
            wanted[(f['size'], f['sha256'])] = f'{p.id}|{f["stage"]}'
    finder = Finder(wanted)
    for s in sources:
        finder.scan(s)
    missing = sorted(set(wanted.values()) - set(finder.data))
    if missing:
        raise SystemExit('legacy MS asset: not found by SHA-256 in the source folder: ' + ', '.join(missing))
    entries = []
    out.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(out, 'w', allowZip64=True) as z:
        for p in pkgs:
            for f in p.files():
                data = finder.data[f'{p.id}|{f["stage"]}']
                info = zipfile.ZipInfo(f'{PREFIX}/{p.get("dir")}/{f["stage"]}', DATE)
                info.external_attr = 0o644 << 16
                info.compress_type = zipfile.ZIP_STORED  # already compressed installers
                z.writestr(info, data)
                entries.append({'package': p.id, 'dir': p.get('dir'), 'file': f['stage'], 'original': f['original'],
                                'sha256': f['sha256'], 'size': f['size']})
        index = {'format': 1, 'version': version, 'decision': 'maintainer-2026-09-30', 'files': entries}
        for name, text in (('legacy-ms.json', json.dumps(index, indent=1) + '\n'), ('README.txt', readme(version, entries))):
            info = zipfile.ZipInfo(f'{PREFIX}/{name}', DATE)
            info.external_attr = 0o644 << 16
            info.compress_type = zipfile.ZIP_DEFLATED
            z.writestr(info, text.encode('utf-8'))
    return index


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--source', type=Path, action='append', required=True)
    ap.add_argument('--out', type=Path, required=True)
    ap.add_argument('--version', default=(Path(__file__).resolve().parents[2] / 'VERSION').read_text().strip())
    a = ap.parse_args()
    index = build(a.source, a.out, a.version)
    print(f'[PASS] {a.out.name}: {len(index["files"])} files, {a.out.stat().st_size} bytes')
    return 0


if __name__ == '__main__':
    sys.exit(main())
