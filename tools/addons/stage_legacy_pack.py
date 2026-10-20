"""Stage the legacy compatibility pack for one target system
(docs/design/legacy-compat-pack.md sections 2.4 and 2.5).

Reference implementation of what the installer does on the host: find every
manifest file among the user's files by size + SHA-256 (in any folder
layout, also inside .zip archives, with 7-Zip inside .iso images and with
innoextract inside Inno Setup installers such as WinSPatcher),
and write the target tree:

  <target>\\USOSADD.EXE, LEGACY.INI (ANSI), SELECT.INI, PKG\\<dir>\\<8.3 files>

Nothing is downloaded. Copyright (C) 2026 Maksymilian and the USOS Authors,
GPL-3.0-or-later.

  python tools/addons/stage_legacy_pack.py --source <user folder> [--source ...]
      --target <dir> --os 98SE --lang PL [--ntsp 3] [--preset praca|retro|minimal]
      [--options kernelex,rdp51-pl] [--exclude dotnet20] [--runner zig-out/legacy-pack/USOSADD.EXE]
"""
from __future__ import annotations

import argparse
import hashlib
import io
import os
import shutil
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import legacy_manifest as lm  # noqa: E402

SEVEN_ZIP = [Path(r'C:\Program Files\7-Zip\7z.exe'), Path(r'C:\Program Files (x86)\7-Zip\7z.exe')]
NESTED_LIMIT = 700 * 1024 * 1024


INNOEXTRACT_ZIP = ('innoextract-1.9-windows.zip', '6989342c9b026a00a72a38f23b62a8e6a22cc5de69805cf47d68ac2fec993065')


def innoextract_tool() -> Path | None:
    """tools/cache/innoextract/innoextract.exe, unpacked from the pinned build
    kit zip (tools/release/buildkit.lock.json) when needed."""
    root = Path(__file__).resolve().parents[2] / 'tools/cache'
    exe = root / 'innoextract/innoextract.exe'
    if exe.is_file():
        return exe
    for folder in (root / 'innoextract', root / 'buildkit-downloads'):
        z = folder / INNOEXTRACT_ZIP[0]
        if z.is_file() and hashlib.sha256(z.read_bytes()).hexdigest() == INNOEXTRACT_ZIP[1]:
            with zipfile.ZipFile(z) as zf:
                exe.parent.mkdir(parents=True, exist_ok=True)
                exe.write_bytes(zf.read('innoextract.exe'))
            return exe
    return None


def seven_zip() -> Path | None:
    for p in SEVEN_ZIP:
        if p.is_file():
            return p
    found = shutil.which('7z')
    return Path(found) if found else None


def candidates(m: lm.Manifest, os_: str, lang: str, ntsp: str, full: bool, options: list[str],
               exclude: list[str] | None = None) -> list[lm.Package]:
    """Every package the runner may plan on the target: for a group (95) the
    union over its members, for NT4 over the SP levels before/after SP6a."""
    tokens = [os_]
    group = m.get('pack', 'group_' + os_)
    if group:
        tokens = lm.list_items(group)
    ids: dict[str, None] = {}
    for t in tokens:
        levels = [ntsp] if ntsp or t != 'NT4' else ['0', '6a']
        for level in levels:
            for pid in lm.resolve(m, t, lang, level if t == 'NT4' else '', full, options, exclude).order:
                ids[pid] = None
    return [m.find(pid) for pid in ids]


class Finder:
    """Size-filtered SHA-256 search through folders, zips and ISOs."""

    def __init__(self, wanted: dict[tuple[int, str], str]):
        self.wanted = wanted                      # (size, sha) -> key
        self.sizes = {size for size, _ in wanted}
        self.found: dict[str, tuple] = {}         # key -> source description
        self.data: dict[str, bytes] = {}
        self.seven = seven_zip()

    def _offer(self, size: int, read) -> None:
        if size not in self.sizes:
            return
        data = read()
        key = self.wanted.get((len(data), hashlib.sha256(data).hexdigest()))
        if key and key not in self.data:
            self.data[key] = data

    def scan_zip(self, zf: zipfile.ZipFile, depth: int) -> None:
        for info in zf.infolist():
            if info.is_dir():
                continue
            self._offer(info.file_size, lambda: zf.read(info))
            low = info.filename.lower()
            if depth < 2 and low.endswith('.zip') and info.file_size < NESTED_LIMIT and len(self.data) < len(self.wanted):
                try:
                    self.scan_zip(zipfile.ZipFile(io.BytesIO(zf.read(info))), depth + 1)
                except zipfile.BadZipFile:
                    pass
            elif low.endswith('.exe') and info.file_size > (8 << 20) and len(self.data) < len(self.wanted):
                with zf.open(info) as src:
                    inno = b'Inno Setup' in src.read(4 << 20)
                if inno:
                    fd, name = tempfile.mkstemp(suffix='.exe')
                    os.close(fd)
                    tmp = Path(name)
                    with open(tmp, 'wb') as out, zf.open(info) as src:
                        shutil.copyfileobj(src, out, 1 << 20)
                    try:
                        self.scan_inno(tmp)
                    finally:
                        tmp.unlink(missing_ok=True)
            elif depth < 2 and low.endswith('.iso') and self.seven and len(self.data) < len(self.wanted):
                fd, name = tempfile.mkstemp(suffix='.iso')
                os.close(fd)
                tmp = Path(name)
                with open(tmp, 'wb') as out, zf.open(info) as src:
                    shutil.copyfileobj(src, out, 1 << 20)
                try:
                    self.scan_iso(tmp)
                finally:
                    tmp.unlink(missing_ok=True)

    def scan_iso(self, iso: Path) -> None:
        r = subprocess.run([str(self.seven), 'l', '-slt', str(iso)], capture_output=True, text=True, errors='replace')
        path, entries = None, []
        for line in r.stdout.splitlines():
            if line.startswith('Path = '):
                path = line[7:]
            elif line.startswith('Size = ') and path is not None:
                size = line[7:].strip()
                if size.isdigit():
                    entries.append((path, int(size)))
                path = None
        for member, size in entries:
            if size in self.sizes:
                self._offer(size, lambda: subprocess.run([str(self.seven), 'e', '-so', str(iso), member],
                                                         capture_output=True).stdout)

    def scan_inno(self, exe: Path) -> None:
        """Inno Setup containers (WinSPatcher 98/NT) through innoextract."""
        tool = innoextract_tool()
        if tool is None:
            return
        with open(exe, 'rb') as f:
            if b'Inno Setup' not in f.read(4 << 20):
                return
        work = Path(tempfile.mkdtemp(prefix='usos-inno-'))
        try:
            if subprocess.run([str(tool), '-q', '-s', '-e', '-d', str(work), str(exe)], capture_output=True).returncode == 0:
                for f in work.rglob('*'):
                    if f.is_file():
                        self._offer(f.stat().st_size, f.read_bytes)
        finally:
            shutil.rmtree(work, ignore_errors=True)

    def scan(self, root: Path) -> None:
        for f in sorted(root.rglob('*')):
            if not f.is_file() or len(self.data) == len(self.wanted):
                continue
            size = f.stat().st_size
            self._offer(size, f.read_bytes)
            low = f.name.lower()
            if low.endswith('.zip') or (low.endswith('.exe') and zipfile.is_zipfile(f)):
                # .exe: WinZip self-extractors (Speech SDK) are zips too
                try:
                    with zipfile.ZipFile(f) as zf:
                        self.scan_zip(zf, 1)
                except zipfile.BadZipFile:
                    pass
            elif low.endswith('.iso') and self.seven:
                self.scan_iso(f)
            elif low.endswith('.exe') and size > (8 << 20) and len(self.data) < len(self.wanted):
                self.scan_inno(f)


def unpack_zip(data: bytes, dest: Path) -> int:
    """Zip members into dest, a single root folder stripped, 8.3 names only."""
    zf = zipfile.ZipFile(io.BytesIO(data))
    names = [i for i in zf.infolist() if not i.is_dir()]
    roots = {n.filename.replace('\\', '/').split('/')[0] for n in names}
    strip = len(roots) == 1 and all('/' in n.filename.replace('\\', '/') for n in names)
    count = 0
    for info in names:
        parts = info.filename.replace('\\', '/').split('/')
        if strip:
            parts = parts[1:]
        if not parts or not all(lm.NAME83.fullmatch(p.upper()) for p in parts):
            continue
        out = dest.joinpath(*[p.upper() for p in parts])
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(zf.read(info))
        count += 1
    return count


def unpack_iso(data: bytes, dest: Path) -> int:
    """The ISO's root files with 8.3 names into dest (7-Zip)."""
    seven = seven_zip()
    if not seven:
        raise SystemExit('7-Zip is needed to unpack an ISO package')
    fd, name = tempfile.mkstemp(suffix='.iso')
    os.close(fd)
    iso, out = Path(name), Path(tempfile.mkdtemp(prefix='usos-iso-'))
    try:
        iso.write_bytes(data)
        subprocess.run([str(seven), 'e', '-y', f'-o{out}', str(iso), '*', '-x!*/*'], check=True, capture_output=True)
        count = 0
        for f in out.iterdir():
            if f.is_file() and lm.NAME83.fullmatch(f.name.upper()):
                shutil.copyfile(f, dest / f.name.upper())
                count += 1
        return count
    finally:
        iso.unlink(missing_ok=True)
        shutil.rmtree(out, ignore_errors=True)


def stage(manifest: Path, sources: list[Path], target: Path, os_: str, lang: str, preset: str = '',
          options: list[str] | None = None, runner: Path | None = None, ntsp: str = '',
          exclude: list[str] | None = None) -> dict:
    m = lm.Manifest.load(manifest)
    select = {'preset': preset, 'options': ','.join(options or []), 'exclude': ','.join(exclude or [])}
    preset, full, all_options, all_exclude = lm.selection(m, select)
    pkgs = candidates(m, os_, lang, ntsp, full, all_options, all_exclude)
    wanted: dict[tuple[int, str], str] = {}
    for p in pkgs:
        for f in p.files():
            if f['sha256'] and f['size']:
                wanted[(f['size'], f['sha256'])] = f'{p.id}|{f["stage"]}'
    finder = Finder(wanted)
    for s in sources:
        finder.scan(s)
    report: dict = {'packages': {}, 'target': str(target)}
    (target / 'PKG').mkdir(parents=True, exist_ok=True)
    for p in pkgs:
        if p.tier == 'group':
            report['packages'][p.id] = 'group'
            continue
        if p.get('status'):
            report['packages'][p.id] = p.get('status')
            continue
        files = p.files()
        keys = [f'{p.id}|{f["stage"]}' for f in files]
        if not all(k in finder.data for k in keys):
            report['packages'][p.id] = 'missing'
            continue
        dest = target / 'PKG' / p.get('dir')
        dest.mkdir(parents=True, exist_ok=True)
        for f, k in zip(files, keys):
            if p.get('unpack') == 'zip':
                unpack_zip(finder.data[k], dest)
            elif p.get('unpack') == 'iso':
                unpack_iso(finder.data[k], dest)
            else:
                (dest / f['stage']).write_bytes(finder.data[k])
        report['packages'][p.id] = 'staged'
    encoding = 'cp1250' if lang.upper() == 'PL' else 'cp1252'
    text = manifest.read_text(encoding='utf-8').replace('\r\n', '\n').replace('\n', '\r\n')
    (target / 'LEGACY.INI').write_bytes(text.encode(encoding, errors='replace'))
    select = ['; USOS legacy pack selection (tools/addons/stage_legacy_pack.py)', '[select]',
              f'preset={preset}', 'options=' + ','.join(options or []), 'exclude=' + ','.join(exclude or []),
              f'expect={os_}', f'lang={lang}']
    (target / 'SELECT.INI').write_bytes(('\r\n'.join(select) + '\r\n').encode('ascii'))
    if runner:
        shutil.copyfile(runner, target / 'USOSADD.EXE')
    return report


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--source', type=Path, action='append', required=True)
    ap.add_argument('--target', type=Path, required=True)
    ap.add_argument('--os', required=True)
    ap.add_argument('--lang', required=True)
    ap.add_argument('--ntsp', default='')
    ap.add_argument('--preset', default='')
    ap.add_argument('--exclude', default='')
    ap.add_argument('--options', default='')
    ap.add_argument('--manifest', type=Path, default=lm.MANIFEST)
    ap.add_argument('--runner', type=Path)
    a = ap.parse_args(argv)
    report = stage(a.manifest, a.source, a.target, a.os, a.lang, a.preset, lm.list_items(a.options),
                   a.runner, a.ntsp, lm.list_items(a.exclude))
    for pid, st in report['packages'].items():
        print(f'{st:<10} {pid}')
    missing = [p for p, s in report['packages'].items() if s == 'missing']
    print(f'[{"PASS" if not missing else "PART"}] staged into {a.target}; missing: {", ".join(missing) or "none"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
