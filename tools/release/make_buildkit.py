"""Pack the USOS build kit (USOS-<version>-buildkit.zip) offline.

  python tools/release/make_buildkit.py --out zig-out/release-1.0/USOS-1.0.0-buildkit.zip [--epoch N]

The kit holds everything a clean clone of the repository needs to run
build.bat without network (docs/BUILDING.md):

  MANIFEST.json                       every file: path, SHA-256, size, component
  toolchains/zig-x86_64-windows-0.16.0.zip, go1.26.2.windows-amd64.zip (official archives)
  toolchains/7zip/                    7-Zip x64 (7z.exe, 7z.dll, License.txt) of this PC
  python/pillow-*.whl                 the one non-stdlib Python package the build imports
  go-mod/cache/download/              GOPROXY=file:// tree for installer/go.mod
  inputs/<repo path>                  pinned inputs outside git: tools/cache/alpine
                                      (micro-Linux), tools/cache/efifs, tools/cache/freedos,
                                      git-ignored vendor archives, Windows 7 MSUs, the frozen
                                      Vista v11 payload folder
  csmwrap-vm/apk/<branch>/...         partial Alpine mirror for tools/build_csmwrap.ps1 -OfflineMirror

Inputs come from tools/cache/buildkit-downloads (tools/release/fetch_buildkit_inputs.py)
and the working tree; nothing is downloaded here. Split into .zip.001, .002
... when the zip would reach the 2 GiB release-asset limit.
"""
from pathlib import Path
import argparse, hashlib, json, os, subprocess, sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from assemble_release import Zip, sha256, GITHUB_ASSET_LIMIT  # noqa: E402

CACHE = ROOT / 'tools/cache/buildkit-downloads'
SEVEN_ZIP_DIR = Path('C:/Program Files/7-Zip')
VISTA_FROZEN = 'artifacts/vista/hardware-success-v11-20260920-235629'


def git_ignored(paths):
    out = subprocess.run(['git', 'ls-files', '--others', '--ignored', '--exclude-standard', '-z', '--', *paths],
                         cwd=ROOT, capture_output=True, check=True).stdout.decode('utf-8')
    return sorted(p for p in out.split('\0') if p and '__pycache__' not in p)


def input_files():
    """(repo-relative path, component) of every pinned build input outside git."""
    items = []
    lock = json.loads((ROOT / 'tools/micro_linux.lock.json').read_text(encoding='utf-8'))
    for rec in [lock['alpine_iso'], *lock['alpine_lts'].values()]:
        items.append((rec['file'], 'alpine-3.24.1'))
    for rec in lock['packages']:
        items.append(('tools/cache/alpine/packages/' + rec['file'], 'alpine-3.24.1'))
    items.append(('tools/cache/efifs/ntfs_x64.efi', 'efifs-1.12'))
    items.append(('tools/cache/freedos/FD14-LiteUSB.zip', 'freedos-1.4'))
    for rel in git_ignored(['tools/vendor']):
        items.append((rel, 'vendor-archives'))
    for rel in git_ignored(['media/Systems/Windows/Windows 7/Updates']):
        if rel.lower().endswith('.msu'):
            items.append((rel, 'microsoft-win7-updates'))
    for p in sorted((ROOT / VISTA_FROZEN).rglob('*')):
        if p.is_file():
            items.append((p.relative_to(ROOT).as_posix(), 'vista-v11-frozen-payload'))
    return items


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--version', required=True)
    p.add_argument('--build-id', required=True)
    p.add_argument('--epoch', required=True)
    a = p.parse_args()
    lock = json.loads((ROOT / 'tools/release/buildkit.lock.json').read_text(encoding='utf-8'))
    prefix = f'USOS-{a.version}-buildkit/'
    files = []  # (kit path, source path, component, licence)

    def add(kit_path, source, component, licence):
        source = Path(source)
        if not source.is_file():
            raise SystemExit(f'build kit input missing: {source} (run tools/release/fetch_buildkit_inputs.py)')
        files.append((kit_path, source, component, licence))

    fixed = {item['id']: item for item in lock['fixed']}
    add('toolchains/' + fixed['zig']['file'], CACHE / fixed['zig']['file'], 'zig-0.16.0', 'MIT')
    add('toolchains/' + fixed['go']['file'], CACHE / fixed['go']['file'], 'go-1.26.2', 'BSD-3-Clause')
    add('python/' + fixed['pillow']['file'], CACHE / fixed['pillow']['file'], 'pillow-10.4.0', 'MIT-CMU')
    add('inputs/tools/cache/efifs/ntfs_x64.efi', CACHE / fixed['efifs-ntfs']['file'], 'efifs-1.12', 'GPL-3.0-or-later')
    seven = subprocess.run([str(SEVEN_ZIP_DIR / '7z.exe')], capture_output=True, text=True).stdout.splitlines()
    seven_version = next((l.strip() for l in seven if l.strip().startswith('7-Zip')), '7-Zip')
    for name in ('7z.exe', '7z.dll', 'License.txt', 'readme.txt'):
        add('toolchains/7zip/' + name, SEVEN_ZIP_DIR / name, seven_version, 'LGPL-2.1-or-later AND BSD-3-Clause AND LicenseRef-unRAR')
    for f in sorted((CACHE / 'go-mod/cache/download').rglob('*')):
        if f.is_file() and not f.name.endswith('.lock'):
            add('go-mod/' + f.relative_to(CACHE / 'go-mod').as_posix(), f, 'golang.org/x/sys v0.47.0', 'BSD-3-Clause')
    for item in lock['alpine_mirror']['indexes'] + lock['alpine_mirror']['packages']:
        rel = item['file']
        if sha256(CACHE / rel) != item['sha256']:
            raise SystemExit('Alpine mirror file differs from buildkit.lock.json: ' + rel)
        add('csmwrap-vm/' + rel, CACHE / rel, 'alpine-v3.24-mirror (CSMWrap build VM)', item.get('license') or 'see APKINDEX')
    for rel, component in input_files():
        if rel == 'tools/cache/efifs/ntfs_x64.efi':
            continue
        licence = 'LicenseRef-Microsoft-redistributed-by-maintainer' if component in ('microsoft-win7-updates', 'vista-v11-frozen-payload') else 'see docs/LICENSES-AUDIT.md'
        add('inputs/' + rel, ROOT / rel, component, licence)

    manifest = {
        'usos_version': a.version, 'usos_build': a.build_id,
        'python': '3.13 x64 (CPython, stdlib + the Pillow wheel)',
        'layout': 'see docs/BUILDING.md',
        'files': [{'path': k, 'sha256': sha256(s), 'size': s.stat().st_size, 'component': c, 'license': l}
                  for k, s, c, l in files],
    }
    readme = f"""USOS {a.version} build kit (build {a.build_id})

Exact toolchains and pinned inputs to rebuild USOS {a.version} offline from
the repository. Extract this zip, then in the repository:

  set USOS_BUILDKIT=<extracted folder>\\USOS-{a.version}-buildkit
  build.bat

build.bat then runs tools\\release\\use_buildkit.ps1, which checks every file
against MANIFEST.json, restores the inputs into the repository and uses the
kit's Go, Zig and 7-Zip with the network disabled (USOS_OFFLINE=1).
Details, the CSMWrap VM rebuild and the licences: docs/BUILDING.md.
Microsoft files in inputs/ (Windows 7 update MSUs, the frozen Vista payload)
are kept for preservation, redistributed at the maintainer's own risk and
removed on request.
"""
    out = a.out.resolve()
    out.parent.mkdir(parents=True, exist_ok=True)
    z = Zip(out, a.epoch)
    for k, s, _, _ in files:
        z.add_file(prefix + k, s)
    z.add_text(prefix + 'MANIFEST.json', json.dumps(manifest, indent=2) + '\n')
    z.add_text(prefix + 'README.txt', readme)
    z.close()
    size = out.stat().st_size
    if size >= GITHUB_ASSET_LIMIT:
        part, n = GITHUB_ASSET_LIMIT - (1 << 20), 0
        with open(out, 'rb') as f:
            while chunk := f.read(part):
                n += 1
                Path(f'{out}.{n:03d}').write_bytes(chunk)
        out.unlink()
        print(f'BUILDKIT split into {n} parts (join with: copy /b {out.name}.001+{out.name}.002 {out.name})')
    print(f'BUILDKIT {out.name}: {len(files)} files, {size} bytes')


if __name__ == '__main__':
    main()
