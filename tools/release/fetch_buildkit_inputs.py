"""Download the pinned inputs of the USOS build kit into tools/cache/buildkit-downloads.

  python tools/release/fetch_buildkit_inputs.py            verify / fetch what the lock lists
  python tools/release/fetch_buildkit_inputs.py --update-lock   (re)resolve the Alpine mirror and pin it

This is the only step of the build kit that uses the network. Every file is
checked against tools/release/buildkit.lock.json (SHA-256); make_buildkit.py
then packs the kit offline.

Pinned here:
  - Zig 0.16.0 and Go 1.26.2 official Windows x64 archives (hashes published
    by ziglang.org and go.dev);
  - the Go module cache of installer/go.mod (golang.org/x/sys), as a
    GOPROXY=file:// tree;
  - Pillow 10.4.0 for CPython 3.13 win_amd64 (tools/generate_legacy_icons.py);
  - EfiFs 1.12 ntfs_x64.efi (tools/fetch_ntfs_driver.ps1);
  - a partial Alpine v3.24 x86_64 mirror for the CSMWrap build VM
    (tools/csmwrap_build): the signed APKINDEX.tar.gz of main and community
    and every package of the dependency closure of lock.json apk_packages.
"""
from pathlib import Path
import argparse, base64, gzip, hashlib, io, json, os, shutil, subprocess, sys, tarfile, urllib.request

ROOT = Path(__file__).resolve().parents[2]
LOCK = ROOT / 'tools/release/buildkit.lock.json'
CACHE = ROOT / 'tools/cache/buildkit-downloads'

FIXED = [
    {'id': 'zig', 'file': 'zig-x86_64-windows-0.16.0.zip', 'url': 'https://ziglang.org/download/0.16.0/zig-x86_64-windows-0.16.0.zip',
     'sha256': '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e', 'license': 'MIT', 'version': '0.16.0'},
    {'id': 'go', 'file': 'go1.26.2.windows-amd64.zip', 'url': 'https://go.dev/dl/go1.26.2.windows-amd64.zip',
     'sha256': '98eb3570bade15cb826b0909338df6cc6d2cf590bc39c471142002db3832b708', 'license': 'BSD-3-Clause', 'version': '1.26.2'},
    {'id': 'pillow', 'file': 'pillow-10.4.0-cp313-cp313-win_amd64.whl',
     'url': 'https://files.pythonhosted.org/packages/01/6a/30ff0eef6e0c0e71e55ded56a38d4859bf9d3634a94a88743897b5f96936/pillow-10.4.0-cp313-cp313-win_amd64.whl',
     'sha256': '030abdbe43ee02e0de642aee345efa443740aa4d828bfe8e2eb11922ea6a21ea', 'license': 'MIT-CMU (HPND)', 'version': '10.4.0'},
    {'id': 'efifs-ntfs', 'file': 'ntfs_x64.efi', 'url': 'https://github.com/pbatard/efifs/releases/download/v1.12/ntfs_x64.efi',
     'sha256': '59c37d5026ca14553a158939e3f2cf20286b6135a713a62c08b569ac9caedcb7', 'license': 'GPL-3.0-or-later', 'version': '1.12'},
]
GO_MODULES = ['golang.org/x/sys@v0.47.0']


def sha256(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def fetch(url, dest, expected=None):
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.is_file() and (expected is None or sha256(dest) == expected):
        return dest
    print('[BUILDKIT] download', url, flush=True)
    tmp = dest.with_suffix(dest.suffix + '.part')
    with urllib.request.urlopen(url) as r, open(tmp, 'wb') as f:
        shutil.copyfileobj(r, f, 1 << 20)
    if expected is not None and sha256(tmp) != expected:
        tmp.unlink()
        raise SystemExit(f'SHA-256 mismatch: {url}')
    tmp.replace(dest)
    return dest


def parse_apkindex(data):
    with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as t:
        text = t.extractfile('APKINDEX').read().decode('utf-8')
    records = []
    for block in text.split('\n\n'):
        rec = {}
        for line in block.splitlines():
            if len(line) > 2 and line[1] == ':':
                rec[line[0]] = line[2:]
        if 'P' in rec:
            records.append(rec)
    return records


def resolve(indexes, wanted):
    """Dependency closure of `wanted` (name or name=version) over the indexes.

    Generous on purpose (apk picks the provider itself): every package that
    provides a needed name is taken, and so is every install_if package whose
    conditions are all in the set."""
    by_name, provides, records = {}, {}, []
    for repo, recs in indexes.items():
        for rec in recs:
            rec['repo'] = repo
            records.append(rec)
            by_name.setdefault(rec['P'], rec)
            for p in rec.get('p', '').split():
                provides.setdefault(p.split('=')[0], []).append(rec)

    def base(token):
        for op in ('>=', '<=', '~', '=', '>', '<'):
            token = token.split(op)[0]
        return token

    chosen, todo = {}, list(wanted)
    while True:
        while todo:
            token = todo.pop()
            if token.startswith('!'):
                continue
            name = base(token)
            candidates = [by_name[name]] if name in by_name else provides.get(name, [])
            if not candidates:
                raise SystemExit('Alpine: nothing provides ' + token)
            if token.startswith(name + '=') and name in by_name and token != name + '=' + by_name[name]['V']:
                raise SystemExit(f'Alpine: pinned {token} but the index has {name}-{by_name[name]["V"]}: update tools/csmwrap_build/lock.json')
            for rec in candidates:
                if rec['P'] not in chosen:
                    chosen[rec['P']] = rec
                    todo.extend(rec.get('D', '').split())
        names = set(chosen)
        for rec in chosen.values():
            names.update(p.split('=')[0] for p in rec.get('p', '').split())
        extra = [rec for rec in records if rec.get('i') and rec['P'] not in chosen
                 and all(base(c) in names for c in rec['i'].split() if not c.startswith('!'))]
        if not extra:
            return [chosen[k] for k in sorted(chosen)]
        todo.extend(rec['P'] for rec in extra)


def update_lock():
    csm = json.loads((ROOT / 'tools/csmwrap_build/lock.json').read_text(encoding='utf-8'))
    mirror, branch = csm['alpine_mirror'], csm['alpine_branch']
    indexes, index_files = {}, []
    for repo in ('main', 'community'):
        url = f'{mirror}/{branch}/{repo}/x86_64/APKINDEX.tar.gz'
        rel = f'apk/{branch}/{repo}/x86_64/APKINDEX.tar.gz'
        dest = CACHE / rel
        if dest.exists():
            dest.unlink()
        fetch(url, dest)
        indexes[repo] = parse_apkindex(dest.read_bytes())
        index_files.append({'file': rel, 'url': url, 'sha256': sha256(dest)})
    packages = []
    for rec in resolve(indexes, csm['apk_packages']):
        name = f'{rec["P"]}-{rec["V"]}.apk'
        rel = f'apk/{branch}/{rec["repo"]}/x86_64/{name}'
        dest = CACHE / rel
        fetch(f'{mirror}/{branch}/{rec["repo"]}/x86_64/{name}', dest)
        sha1 = base64.b64decode(rec['C'][2:]).hex()
        packages.append({'file': rel, 'package': rec['P'], 'version': rec['V'], 'license': rec.get('L', ''),
                         'apk_control_sha1': sha1, 'sha256': sha256(dest), 'url': f'{mirror}/{branch}/{rec["repo"]}/x86_64/{name}'})
    lock = {'comment': 'Pinned build kit downloads (tools/release/fetch_buildkit_inputs.py).',
            'fixed': FIXED, 'go_modules': GO_MODULES,
            'alpine_mirror': {'branch': branch, 'for': 'tools/csmwrap_build (CSMWrap build VM)', 'indexes': index_files, 'packages': packages}}
    LOCK.write_text(json.dumps(lock, indent=2) + '\n', encoding='utf-8', newline='\n')
    print(f'[BUILDKIT] lock updated: {len(packages)} Alpine packages')


def go_modules():
    env = dict(os.environ, GOMODCACHE=str(CACHE / 'go-mod'), GOFLAGS='-modcacherw')
    subprocess.run(['go', 'mod', 'download', *GO_MODULES], cwd=ROOT / 'installer', env=env, check=True)


def verify_or_fetch(lock):
    for item in lock['fixed']:
        fetch(item['url'], CACHE / item['file'], item['sha256'])
    for item in lock['alpine_mirror']['indexes'] + lock['alpine_mirror']['packages']:
        fetch(item['url'], CACHE / item['file'], item['sha256'])
    go_modules()
    print('[BUILDKIT] all pinned downloads present and verified in', CACHE)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--update-lock', action='store_true')
    a = p.parse_args()
    for item in FIXED:
        fetch(item['url'], CACHE / item['file'], item['sha256'])
    if a.update_lock or not LOCK.exists():
        update_lock()
    verify_or_fetch(json.loads(LOCK.read_text(encoding='utf-8')))


if __name__ == '__main__':
    main()
