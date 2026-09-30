"""Host tests of the legacy compatibility pack (docs/design/legacy-compat-pack.md):

1. manifest validation (tools/addons/legacy_manifest.py validate);
2. USOSADD's pure C parts (INI, versions, detection table, variables,
   builtins, checks, state) built for the host with zig cc and run;
3. the plan resolver: C (plan.c) and Python must agree for every system,
   language, NT service pack level and a set of option choices;
4. expected presets (what "Pełny pakiet zgodności" contains per system);
5. the staging tool on a synthetic user folder (hash matching, zip unpack,
   8.3 names, SELECT.INI, ANSI manifest);
6. the target build (OpenWatcom) when its snapshot is available.

  python tools/tests/addons/test_legacy_pack.py
"""
from __future__ import annotations

import hashlib
import io
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/addons'))
sys.path.insert(0, str(ROOT / 'tools'))
import legacy_manifest as lm  # noqa: E402
import stage_legacy_pack as stage  # noqa: E402

SRC = ROOT / 'src/platform/win32_legacy/usosadd'
PURE = ('str.c', 'ini.c', 'detect.c', 'plan.c', 'cmd.c', 'state.c')
failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print('[FAIL]', msg)


def build_host() -> Path:
    zig = ROOT / 'tools/zig/zig.exe'
    if not zig.is_file():
        zig = Path('zig')
    out_dir = ROOT / 'tools/tests/artifacts/addons'
    out_dir.mkdir(parents=True, exist_ok=True)
    exe = out_dir / ('usosadd_host.exe' if os.name == 'nt' else 'usosadd_host')
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(ROOT / 'tools/cache/zig'))
    cmd = [str(zig), 'cc', '-std=c99', '-Wall', '-Wextra', '-Werror', '-Wno-unused-parameter', '-O1',
           '-fsanitize=undefined', '-fno-sanitize-trap=undefined', '-I', str(SRC), '-o', str(exe),
           str(Path(__file__).with_name('usosadd_host.c'))] + [str(SRC / f) for f in PURE]
    r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if r.returncode:
        # the UB sanitizer runtime is not available for every host target
        cmd = [c for c in cmd if not c.startswith('-fsanitize') and not c.startswith('-fno-sanitize')]
        r = subprocess.run(cmd, env=env, capture_output=True, text=True)
    if r.returncode:
        raise SystemExit('host build failed:\n' + r.stdout + r.stderr)
    return exe


def c_plan(exe: Path, manifest: Path, os_: str, lang: str, ntsp: str, full: bool, options: list[str],
           exclude: list[str] | None = None):
    r = subprocess.run([str(exe), 'plan', str(manifest), os_, lang, ntsp or '-', '1' if full else '0',
                        ','.join(options) or '-', ','.join(exclude or []) or '-'], capture_output=True, text=True)
    if r.returncode:
        raise RuntimeError(r.stdout + r.stderr)
    order, why, unmet, eff = [], {}, {}, ''
    for line in r.stdout.splitlines():
        parts = line.split(' ')
        if parts[0] == 'IN':
            order.append(parts[1])
        elif parts[0] == 'WHY':
            why[parts[1]] = parts[2]
            if len(parts) > 3 and parts[3]:
                unmet[parts[1]] = parts[3]
        elif parts[0] == 'EFF':
            eff = parts[1] if len(parts) > 1 else ''
    return order, why, unmet, eff


def test_validate(m: lm.Manifest) -> None:
    for e in lm.validate(m):
        fail('manifest: ' + e)


def test_cross_check(exe: Path, m: lm.Manifest) -> int:
    options_sets = [[], [p.id for p in m.packages if p.tier == 'option'], ['kernelex', 'rdp51-pl', 'nosuch-id'],
                    ['dotnet20-pl'], ['hf98-q831167']]
    options_sets += [lm.selection(m, {'preset': pr})[2] for pr in lm.list_items(m.get('presets', 'order'))]
    exclude_sets = [[], ['msi20-9x', 'ie6sp1-pl-9x', 'msi20-nt4']]
    n = 0
    for os_ in m.os_tokens():
        for lang in ('PL', 'EN', 'XX'):
            for ntsp in (['0', '3', '5', '6', '6a'] if os_ == 'NT4' else ['']):
                for full in (True, False):
                    for opts, excl in [(o, e) for o in options_sets for e in exclude_sets]:
                        py = lm.resolve(m, os_, lang, ntsp, full, opts, excl)
                        order, why, unmet, eff = c_plan(exe, lm.MANIFEST, os_, lang, ntsp, full, opts, excl)
                        n += 1
                        where = f'{os_}/{lang}/sp{ntsp or "-"}/full={int(full)}/opts={",".join(opts) or "-"}/excl={",".join(excl) or "-"}'
                        if order != py.order:
                            fail(f'plan differs {where}:\n  C  {order}\n  py {py.order}')
                        if why != py.why:
                            diff = {k: (why.get(k), py.why.get(k)) for k in set(why) | set(py.why) if why.get(k) != py.why.get(k)}
                            fail(f'reasons differ {where}: {diff}')
                        if unmet != py.unmet:
                            fail(f'unmet differs {where}: C {unmet} py {py.unmet}')
                        if eff != py.eff_ntsp:
                            fail(f'effective SP differs {where}: C {eff} py {py.eff_ntsp}')
    return n


EXPECTED_FULL = {
    ('98SE', 'PL', ''): ['dcom98', 'dun14-98se-pl', 'q243199-98se-pl', 'ie6sp1-pl-9x', 'msi20-9x', 'dx9c',
                         'mdac28sp1-pl', 'vbrun6sp6', 'vcredist6sp6', 'mslu', 'wmp9-pl', 'dotnet20', 'dotnet20-pl',
                         'nusb33-pl', 'hf98-jet40sp8', 'hf98-q238453', 'hf98-q245729', 'hf98-q256015',
                         'hf98-q273991', 'hf98-q323172', 'hf98-q323255', 'hf98-q329115', 'hf98-q811630',
                         'hf98-q823559', 'hf98-js56', 'hf98-q313829', 'hf98-q831167', 'hf98-wmp9-kb819639',
                         'hotfixes-98-pl'],
    ('ME', 'PL', ''): ['ie6sp1-pl-9x', 'msi20-9x', 'dx9c', 'mdac28sp1-pl', 'vbrun6sp6', 'vcredist6sp6', 'mslu',
                       'wmp9-pl', 'dotnet20', 'dotnet20-pl'],
    ('95OSR21', 'PL', ''): ['dcom95', 'ie55sp2-pl', 'ie55sp2-q810847-pl', 'msi20-9x', 'dx80-pl', 'vbrun6sp6',
                            'vcredist6sp6', 'mslu'],
    ('NT4', 'PL', '3'): ['nt4-sp6a-pl', 'nt4-srp-pl', 'ie6sp1-pl-nt4', 'msi20-nt4', 'mdac28sp1-pl', 'vbrun6sp6',
                         'vcredist6sp6', 'dotnet11', 'dotnet11-pl', 'dotnet11-sp1'],
    # English NT4: no English IE 6 set locally, so MDAC/.NET (need IE 5.01) stay out
    ('NT4', 'EN', '6a'): ['msi20-nt4', 'vbrun6sp6', 'vcredist6sp6'],
}


def test_selection(exe: Path, m: lm.Manifest) -> None:
    cases = [{}, {'preset': 'retro'}, {'preset': 'minimal', 'options': 'kernelex'},
             {'preset': 'praca', 'full': '0', 'options': 'rdp51-pl,kernelex', 'exclude': 'dotnet20, wmp9-pl'},
             {'options': 'dx9c'}]
    with tempfile.TemporaryDirectory() as t:
        for i, case in enumerate(cases):
            f = Path(t) / f's{i}.ini'
            f.write_text('[select]\n' + ''.join(f'{k}={v}\n' for k, v in case.items()), encoding='ascii')
            r = subprocess.run([str(exe), 'select', str(lm.MANIFEST), str(f)], capture_output=True, text=True)
            got = {}
            for line in r.stdout.splitlines():
                k, _, v = line.partition(' ')
                got[k] = v
            preset, full, options, exclude = lm.selection(m, case)
            want = {'PRESET': preset, 'FULL': str(int(full)), 'OPTIONS': ','.join(options), 'EXCLUDE': ','.join(exclude)}
            if got != want:
                fail(f'selection {case}: C {got} py {want}')
    if lm.selection(m)[:2] != ('praca', True):
        fail('the default preset must be "praca" with the full pack')
    # excluding a dependency drops its dependents instead of pulling it back
    plan = lm.resolve(m, '98SE', 'PL', '', True, [], ['msi20-9x'])
    if 'msi20-9x' in plan.order or 'dotnet20' in plan.order or plan.why.get('dotnet20') != 'out-needs':
        fail(f'exclude msi20-9x: {plan.order}')


def test_presets(m: lm.Manifest) -> None:
    for (os_, lang, sp), want in EXPECTED_FULL.items():
        got = lm.resolve(m, os_, lang, sp, True, []).order
        if [x for x in got] != sorted(want, key=got.index) or set(got) != set(want):
            fail(f'full pack {os_} {lang} sp{sp}: got {got}')
    # an option pulls in what it needs; an option for another system stays out
    plan = lm.resolve(m, '98SE', 'PL', '', False, ['dsclient9x'])
    if plan.order != ['msi20-9x', 'dsclient9x']:
        fail(f'dsclient9x alone: {plan.order}')
    plan = lm.resolve(m, 'ME', 'PL', '', False, ['nusb33-pl', 'winmedos'])
    if plan.order != ['winmedos'] or plan.why.get('nusb33-pl') != 'out-system':
        fail(f'Me options: {plan.order} {plan.why}')
    plan = lm.resolve(m, '98SE', 'PL', '', False, ['usb-nt4-ionetworks', 'speechsdk51'])
    if plan.order:
        fail(f'status/other-system options must stay out: {plan.order}')


def make_user_folder(tmp: Path, m: lm.Manifest, ids: list[str]) -> dict[str, bytes]:
    """Synthetic stand-ins: the manifest is rewritten to their hashes."""
    blobs: dict[str, bytes] = {}
    for pid in ids:
        p = m.find(pid)
        for f in p.files():
            data = f'{pid}:{f["stage"]}'.encode() * 7
            if p.get('unpack') == 'zip':
                buf = io.BytesIO()
                with zipfile.ZipFile(buf, 'w') as z:
                    z.writestr('Root Folder/IE6SETUP.EXE', b'setup' * 9)
                    z.writestr('Root Folder/IE_S1.CAB', b'cab1' * 9)
                    z.writestr('Root Folder/Ten folder można bezpiecznie usunąć.txt', b'x')
                data = buf.getvalue()
            name = f['original'].split('!')[-1].split('/')[-1]
            sub = tmp / 'user' / 'Some Folder' / pid
            sub.mkdir(parents=True, exist_ok=True)
            (sub / name).write_bytes(data)
            blobs[f'{pid}|{f["stage"]}'] = data
    return blobs


def test_staging(m: lm.Manifest) -> None:
    with tempfile.TemporaryDirectory() as t:
        tmp = Path(t)
        ids = ['dcom98', 'ie6sp1-pl-9x', 'msi20-9x', 'mslu']
        blobs = make_user_folder(tmp, m, ids)
        text = lm.MANIFEST.read_text(encoding='utf-8')
        for key, data in blobs.items():
            pid, stage_name = key.split('|')
            f = next(x for x in m.find(pid).files() if x['stage'] == stage_name)
            text = text.replace(f'{f["sha256"]}|{f["size"]}', f'{hashlib.sha256(data).hexdigest()}|{len(data)}')
        manifest = tmp / 'legacy-pack.ini'
        manifest.write_text(text, encoding='utf-8')
        target = tmp / 'C' / 'USOS' / 'ADDONS'
        exe = tmp / 'USOSADD.EXE'
        exe.write_bytes(b'MZ fake')
        report = stage.stage(manifest, [tmp / 'user'], target, os_='98SE', lang='PL', preset='praca',
                             options=['kernelex'], runner=exe)
        for pid in ids:
            if report['packages'].get(pid) != 'staged':
                fail(f'staging: {pid} -> {report["packages"].get(pid)}')
        if report['packages'].get('dx9c') != 'missing':
            fail(f'staging: dx9c should be missing, got {report["packages"].get("dx9c")}')
        if not (target / 'PKG/IE6SP1/IE6SETUP.EXE').is_file() or not (target / 'PKG/IE6SP1/IE_S1.CAB').is_file():
            fail('staging: zip not unpacked into PKG\\IE6SP1')
        if any(len(p.name.split('.')[0]) > 8 for p in (target / 'PKG').rglob('*')):
            fail('staging: a non-8.3 name was written')
        if not (target / 'PKG/MSLU/UNICOWS.EXE').is_file():
            fail('staging: MSLU not staged under its 8.3 name')
        sel = (target / 'SELECT.INI').read_text(encoding='ascii')
        if 'preset=praca' not in sel or 'options=kernelex' not in sel or 'expect=98SE' not in sel:
            fail('staging: SELECT.INI ' + repr(sel))
        ansi = (target / 'LEGACY.INI').read_bytes()
        try:
            ansi.decode('cp1250')
        except UnicodeDecodeError:
            fail('staging: LEGACY.INI is not cp1250')
        if 'Pełny'.encode('cp1250') not in ansi and 'ł'.encode('cp1250') not in ansi:
            fail('staging: Polish names not converted to cp1250')
        if not (target / 'USOSADD.EXE').is_file():
            fail('staging: runner not copied')
        # a file with the right name but a wrong hash is not taken
        bad = tmp / 'user2'
        bad.mkdir()
        (bad / 'DCOM98.EXE').write_bytes(b'not the real file')
        report = stage.stage(manifest, [bad], tmp / 'T2', os_='98SE', lang='PL', options=[], runner=exe)
        if report['packages'].get('dcom98') != 'missing':
            fail('staging: a wrong-hash file was accepted')


def test_target_build() -> None:
    ow = ROOT / 'tools/cache/openwatcom/ow-snapshot-2026-09-01.tar.xz'
    if not ow.is_file() and not (ROOT / 'tools/cache/buildkit-downloads/ow-snapshot-2026-09-01.tar.xz').is_file():
        print('[SKIP] target build (no OpenWatcom snapshot in tools/cache)')
        return
    import build_usosadd
    exe = build_usosadd.build(ROOT / 'tools/tests/artifacts/addons/target')
    if exe.stat().st_size > 64 * 1024:
        fail(f'USOSADD.EXE is {exe.stat().st_size} bytes (static tables in the file?)')


def main() -> int:
    m = lm.Manifest.load()
    test_validate(m)
    exe = build_host()
    r = subprocess.run([str(exe), 'selftest'], capture_output=True, text=True)
    print(r.stdout.strip())
    if r.returncode:
        fail('C selftest')
    n = test_cross_check(exe, m)
    test_selection(exe, m)
    test_presets(m)
    test_staging(m)
    test_target_build()
    if failures:
        print(f'[FAIL] legacy pack: {len(failures)} failure(s)')
        return 1
    print(f'[PASS] legacy pack: manifest ({len(m.packages)} packages), C selftest, {n} C/Python plan comparisons, presets, staging')
    return 0


if __name__ == '__main__':
    sys.exit(main())
