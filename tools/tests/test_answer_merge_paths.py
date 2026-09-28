"""Every enabled tweak survives the installers' answer merges (docs/answer-profiles.md).

    python tools/tests/test_answer_merge_paths.py      (USOS_UPDATE_GOLDEN=1 rewrites the goldens)

The profile answer rendered by usos-answer is not what Setup reads on the
PE10 paths: the installers merge it with their own servicing answer first.
This test runs the real merge code on the rendered tweaks profile
(testdata/tweaks.profile.ini, every tweak on):

  - Vista / Server 2008 x64 without CSM (CSMWrap): windows_vista_install.c
    merge_user_answer itself (tools/tests/vista_answer_merge_host.c includes
    the installer source), i.e. vista-answer.xml;
  - Windows 7 x64 PE10 donor (windows7_modern_startup.cmd): the optional
    NVMe/SHA-2 servicing merge (usos-win7-unattend.exe) and the DriverPaths
    merge (usos-unattend-drivers.exe), i.e. usos-driver-unattend.xml;
  - Vista on UEFI with CSM: the startup script refuses a user answer (the
    menu offers only a manual installation there), so no profile setting can
    be dropped silently.

Every path also runs with the profile's commands wrapped for
usos-run-hidden.exe (tools/windows_hidden_commands.h: no console windows;
the startup scripts wrap before the merges, the Vista installer inside):
the "-hidden" goldens, and the wrapped answer differs from the rendered one
only by the runner prefix of each RunSynchronousCommand Path.

Checks: golden bytes of each merged file; every settings pass of the rendered
answer is in the merged file unchanged (element by element); each enabled
tweak's setting is present in the merged specialize pass; the specialize
commands keep their order (hive load first, unload last).
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DATA = ROOT / 'src' / 'flow' / 'answer' / 'testdata'
GOLDEN = DATA / 'golden' / 'merged'
OUT = ROOT / 'zig-out' / 'answer-merge-tests'
ZIG = ROOT / 'tools' / 'zig' / 'zig.exe'
TOOL = ROOT / 'zig-out' / 'bin' / 'usos-answer.exe'
UPDATE = os.environ.get('USOS_UPDATE_GOLDEN') == '1'
NS = '{urn:schemas-microsoft-com:unattend}'
# As in the PE: the installer's base folder (X:\Windows\System32\).
CAB = r'X:\Windows\System32\Windows6.0-KB2864202-x64.cab'
DRIVERS = r'X:\Windows\System32\usos-win7-drivers'
SOURCE_DISK = '1'
RUNNER = OUT / 'windows-source-mount' / 'usos-run-hidden.exe'
PREFIX = b'<Path>usos-run-hidden.exe '

# Each tweak's setting in the specialize pass, per system: a command
# substring, or (component, element, text) for a component setting.
VISTA = {
    'no_autorun': 'NoDriveTypeAutoRun /t REG_DWORD /d 255',
    'no_sidebar': 'Sidebar" /v TurnOffSidebar /t REG_DWORD /d 1',
    'disable_uac': 'Policies\\System" /v EnableLUA /t REG_DWORD /d 0',
    'no_hibernation': 'powercfg.exe -h off',
    'skip_games': 'pkgmgr.exe /uu:InboxGames',
    'show_extensions': '/v HideFileExt /t REG_DWORD /d 0',
    'show_hidden': '/v Hidden /t REG_DWORD /d 1',
    'no_welcome_center': 'Run" /v WindowsWelcomeCenter /f',
}
SEVEN = {
    'no_autorun': VISTA['no_autorun'],
    'no_sidebar': VISTA['no_sidebar'],
    'disable_uac': ('Microsoft-Windows-LUA-Settings', 'EnableLUA', 'false'),
    'no_hibernation': VISTA['no_hibernation'],
    'skip_games': 'dism.exe /Online /NoRestart /Disable-Feature /FeatureName:InboxGames',
    'show_extensions': VISTA['show_extensions'],
    'show_hidden': VISTA['show_hidden'],
    'theme': 'Ease of Access Themes\\classic.theme',
}
# Server 2008 (the same CSMWrap installer): UAC and file view only.
SERVER_2008 = {k: VISTA[k] for k in ('no_autorun', 'disable_uac', 'show_extensions', 'show_hidden')}


def build_vista_merge(output: Path) -> None:
    """The installer source with stand-in payload tables (the merge does not
    use them), built like tools/build_windows_vista_support.py builds it."""
    generated = OUT / 'vista-headers'
    generated.mkdir(parents=True, exist_ok=True)
    (generated / 'vista_deploy_files.h').write_text(
        'static const struct { const WCHAR *source, *target; BYTE sha256[32]; } vista_files[] = {{L"x",L"x",{0}}};\n', encoding='ascii')
    (generated / 'vista_boot_files.h').write_text(
        'static const struct { const WCHAR *name; BYTE sha256[32]; } vista_boot_files[] = {{0,{0}}};\n', encoding='ascii')
    temp = OUT / 'tmp'
    temp.mkdir(exist_ok=True)
    env = dict(os.environ, TEMP=str(temp), TMP=str(temp), ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'),
               ZIG_LOCAL_CACHE_DIR=str(OUT / 'zig-cache'))
    subprocess.run([str(ZIG), 'cc', '-target', 'x86_64-windows.win10-gnu', '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin',
                    '-I' + str(ROOT / 'tools/zig/lib/libc/include/any-windows-any'), '-I' + str(generated), '-I' + str(ROOT / 'tools'),
                    str(ROOT / 'tools/tests/vista_answer_merge_host.c'), '-Wl,--entry,entry', '-lkernel32', '-ladvapi32', '-lversion',
                    '-luser32', '-o', str(output)], env=env, check=True)


def settings(root: ET.Element) -> dict[str, ET.Element]:
    return {s.get('pass'): s for s in root.findall(NS + 'settings')}


def shape(e: ET.Element) -> tuple:
    return (e.tag, tuple(sorted(e.attrib.items())), (e.text or '').strip(), tuple(shape(c) for c in e))


def commands(specialize: ET.Element) -> list[str]:
    return [p.text or '' for p in specialize.iter(NS + 'Path')]


class MergePaths(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        subprocess.run([str(ZIG), 'build', '--cache-dir', str(ROOT / 'tools' / 'cache' / 'zig'), 'answer-tool'],
                       cwd=ROOT, check=True)
        OUT.mkdir(parents=True, exist_ok=True)
        cls.vista_merge = OUT / 'vista_answer_merge_host.exe'
        build_vista_merge(cls.vista_merge)
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_windows7_uefi import build
        from build_windows7_nvme import build_helpers
        cls.win7 = OUT / 'windows7-uefi'
        build(ROOT, cls.win7)
        cls.nvme = OUT / 'windows7-nvme'
        build_helpers(ROOT, cls.nvme)
        from build_windows_source_mount import build as build_source_helpers
        build_source_helpers(ROOT, RUNNER.parent)

    def render(self, system: str, profile: str = 'tweaks') -> Path:
        out = OUT / f'{profile}.{system}.amd64.xml'
        r = subprocess.run([str(TOOL), 'render', str(DATA / f'{profile}.profile.ini'), system, 'amd64', str(out), '-'],
                           capture_output=True)
        self.assertEqual(0, r.returncode, r.stderr)
        return out

    def golden(self, name: str, data: bytes) -> None:
        path = GOLDEN / name
        # The NVMe servicing merge writes absolute cab paths of the checkout;
        # keep the goldens independent of where the tree (or worktree) lives.
        data = data.replace(str(ROOT).encode(), b'@ROOT@')
        if UPDATE:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        self.assertTrue(path.exists(), f'missing golden {path} (USOS_UPDATE_GOLDEN=1)')
        self.assertEqual(path.read_bytes(), data, f'golden {name} differs (USOS_UPDATE_GOLDEN=1 after review)')

    def survives(self, rendered: Path, merged: Path, markers: dict, added: set[str]) -> None:
        before, after = ET.parse(rendered).getroot(), ET.parse(merged).getroot()
        b, a = settings(before), settings(after)
        # Every pass of the profile answer, unchanged; the merge may only add
        # its own servicing / offlineServicing content.
        for name, element in b.items():
            self.assertIn(name, a, f'pass {name} dropped')
            self.assertEqual(shape(element), shape(a[name]), f'pass {name} changed by the merge')
        self.assertLessEqual(set(a) - set(b), added, 'unexpected pass added by the merge')
        specialize = a['specialize']
        paths = commands(specialize)
        self.assertEqual(commands(b['specialize']), paths)
        orders = [int(o.text) for o in specialize.iter(NS + 'Order')]
        self.assertEqual(list(range(1, len(orders) + 1)), orders)
        bare = [p.removeprefix('usos-run-hidden.exe ') for p in paths]
        loads = [i for i, p in enumerate(bare) if p.startswith('reg.exe load ')]
        unloads = [i for i, p in enumerate(bare) if p.startswith('reg.exe unload ')]
        hive = [i for i, p in enumerate(paths) if 'HKU\\USOSDefault\\' in p]
        if hive:
            self.assertEqual(1, len(loads))
            self.assertEqual(1, len(unloads))
            self.assertTrue(loads[0] < min(hive) and max(hive) < unloads[0])
        for tweak, marker in markers.items():
            if isinstance(marker, tuple):
                component, element, text = marker
                found = [e.text for c in specialize.findall(NS + 'component') if c.get('name') == component
                         for e in c.iter(NS + element)]
                self.assertEqual([text], found, f'{tweak} lost in the merge')
            else:
                self.assertTrue(any(marker in p for p in paths), f'{tweak} lost in the merge: {marker}')
        # oobeSystem keeps the account (the auto-logon of an empty password
        # relies on it) and there is exactly one servicing block.
        self.assertTrue(a['oobeSystem'].iter(NS + 'LocalAccount'))

    def wrap(self, rendered: Path) -> Path:
        """usos-run-hidden.exe --wrap, as the startup scripts call it."""
        out = rendered.with_name(rendered.stem + '.hidden.xml')
        out.unlink(missing_ok=True)
        r = subprocess.run([str(RUNNER), '--wrap', str(rendered), str(out)], capture_output=True)
        self.assertEqual(0, r.returncode, r.stdout)
        self.wrapped_only(rendered.read_bytes(), out.read_bytes())
        return out

    def wrapped_only(self, original: bytes, wrapped: bytes) -> None:
        # Every RunSynchronousCommand Path carries the runner, nothing else changed.
        self.assertEqual(original, wrapped.replace(PREFIX, b'<Path>'))
        root = ET.fromstring(wrapped)
        paths = [p.text or '' for c in root.iter(NS + 'RunSynchronousCommand') for p in c.iter(NS + 'Path')]
        self.assertTrue(paths)
        for path in paths:
            self.assertTrue(path.startswith('usos-run-hidden.exe '), path)
            self.assertLessEqual(len(path), 259)
        self.assertEqual(len(paths), wrapped.count(PREFIX))

    def test_wrap_leaves_other_answers(self):
        # A DATA answer file (no renderer marker) is not changed: exit 10.
        rendered = self.render('windows-7')
        plain = OUT / 'plain.windows-7.xml'
        plain.write_bytes(rendered.read_bytes().replace(b'<!-- USOS answer profile rendered for', b'<!-- a file rendered for'))
        out = OUT / 'plain.hidden.xml'
        out.unlink(missing_ok=True)
        r = subprocess.run([str(RUNNER), '--wrap', str(plain), str(out)], capture_output=True)
        self.assertEqual(10, r.returncode)
        self.assertFalse(out.exists())

    def merge_vista(self, name: str, data: bytes, hidden: bool = False) -> tuple[int, Path]:
        """The harness in a folder of its own (its base, like the PE's System32)."""
        work = OUT / f'vista-{name}'
        work.mkdir(exist_ok=True)
        for old in work.iterdir():
            old.unlink()
        shutil.copyfile(self.vista_merge, work / 'harness.exe')
        (work / 'usos-unattend.xml').write_bytes(data)
        r = subprocess.run([str(work / 'harness.exe')] + (['--hidden'] if hidden else []), cwd=work, capture_output=True)
        self.assertEqual(data, (work / 'usos-unattend.xml').read_bytes())
        return r.returncode, work / 'vista-answer.xml'

    def vista_csmwrap(self, system: str, markers: dict) -> None:
        rendered = self.render(system)
        code, merged = self.merge_vista(system, rendered.read_bytes())
        self.assertEqual(0, code)
        data = merged.read_bytes()
        original = rendered.read_bytes()
        # Only the servicing block is inserted, right after <unattend ...>.
        self.assertEqual(1, data.count(b'<servicing>'))
        start, end = data.index(b'<servicing>'), data.index(b'</servicing>') + len(b'</servicing>')
        self.assertEqual(original, data[:start] + data[end:])
        self.assertTrue(data[:start].rstrip().endswith(b'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">'))
        self.assertIn(b'Package_for_KB2864202', data[start:end])
        self.assertIn(CAB.encode(), data[start:end])
        self.golden(f'tweaks.vista-csmwrap.{system}.amd64.xml', data)
        self.survives(rendered, merged, markers, set())

    def test_vista_csmwrap(self):
        self.vista_csmwrap('windows-vista', VISTA)

    def vista_hidden(self, system: str, markers: dict) -> None:
        rendered = self.render(system)
        code, merged = self.merge_vista(system + '-hidden', rendered.read_bytes(), hidden=True)
        self.assertEqual(0, code)
        wrapped = merged.with_name('usos-hidden-unattend.xml')
        self.wrapped_only(rendered.read_bytes(), wrapped.read_bytes())
        data = merged.read_bytes()
        start, end = data.index(b'<servicing>'), data.index(b'</servicing>') + len(b'</servicing>')
        self.assertEqual(wrapped.read_bytes(), data[:start] + data[end:])
        self.golden(f'tweaks.vista-csmwrap-hidden.{system}.amd64.xml', data)
        self.survives(wrapped, merged, markers, set())

    def test_vista_hidden(self):
        self.vista_hidden('windows-vista', VISTA)

    def test_server_2008_hidden(self):
        self.vista_hidden('windows-server-2008', SERVER_2008)

    def test_server_2008_csmwrap(self):
        self.vista_csmwrap('windows-server-2008', SERVER_2008)

    def test_vista_csmwrap_refusals(self):
        rendered = self.render('windows-vista')
        text = rendered.read_text(encoding='utf-8')
        # Refused, never passed on without the profile: the installer stops.
        for name, content in [
            ('servicing', text.replace('<settings pass="windowsPE">', '<servicing/><settings pass="windowsPE">', 1).encode()),
            ('no-root', ('<?xml version="1.0"?><other/>\n' + ' ' * 16).encode()),
            ('utf16', text.encode('utf-16')),
        ]:
            code, merged = self.merge_vista('refuse-' + name, content)
            self.assertEqual(1, code, name)
            self.assertFalse(merged.exists(), name)

    def win7_donor(self, nvme: bool, hidden: bool = False) -> None:
        rendered = self.render('windows-7')
        if hidden:
            rendered = self.wrap(rendered)
        answer = rendered
        tag = ('win7-pe10-nvme' if nvme else 'win7-pe10') + ('-hidden' if hidden else '')
        work = OUT / tag
        work.mkdir(exist_ok=True)
        for old in work.glob('*.xml'):
            old.unlink()
        if nvme:
            answer = work / 'usos-nvme-unattend.xml'
            r = subprocess.run([str(self.nvme / 'usos-win7-unattend.exe'), str(rendered), str(answer), SOURCE_DISK], capture_output=True)
            self.assertEqual(0, r.returncode, r.stdout)
        merged = work / 'usos-driver-unattend.xml'
        r = subprocess.run([str(self.win7 / 'usos-unattend-drivers.exe'), str(answer), str(merged), DRIVERS, SOURCE_DISK], capture_output=True)
        self.assertEqual(0, r.returncode, r.stdout)
        root = ET.parse(merged).getroot()
        paths = [p.text for p in root.iter(NS + 'Path') if p.text == DRIVERS]
        self.assertEqual(1, len(paths))
        self.golden(f'tweaks.{tag}.windows-7.amd64.xml', merged.read_bytes())
        self.survives(rendered, merged, SEVEN, {'offlineServicing'})

    def test_win7_pe10_donor(self):
        self.win7_donor(False)

    def test_win7_pe10_donor_nvme(self):
        self.win7_donor(True)

    def test_win7_pe10_donor_hidden(self):
        self.win7_donor(False, hidden=True)

    def test_win7_pe10_donor_nvme_hidden(self):
        self.win7_donor(True, hidden=True)

    def test_windows_11_modern_hidden(self):
        # windows_modern_uefi_startup.cmd: wrap, then the DriverPaths merge.
        # The windowsPE LabConfig checks and the specialize commands carry the runner.
        # full.profile.ini: the Windows 11 checks and BypassNRO are on.
        rendered = self.render('windows-11', 'full')
        wrapped = self.wrap(rendered)
        work = OUT / 'modern-uefi-hidden'
        work.mkdir(exist_ok=True)
        merged = work / 'usos-driver-unattend.xml'
        merged.unlink(missing_ok=True)
        r = subprocess.run([str(self.win7 / 'usos-unattend-drivers.exe'), str(wrapped), str(merged), DRIVERS, SOURCE_DISK], capture_output=True)
        self.assertEqual(0, r.returncode, r.stdout)
        root = ET.parse(merged).getroot()
        pe = [p.text for s in root.findall(NS + 'settings') if s.get('pass') == 'windowsPE' for p in s.iter(NS + 'Path')
              if 'LabConfig' in (p.text or '')]
        self.assertTrue(pe)
        self.assertTrue(all(p.startswith('usos-run-hidden.exe reg.exe add ') for p in pe))
        self.golden('full.modern-uefi-hidden.windows-11.amd64.xml', merged.read_bytes())
        self.survives(wrapped, merged, {'no_network_oobe': 'OOBE" /v BypassNRO /t REG_DWORD /d 1'}, {'offlineServicing'})

    def test_vista_uefi_refuses_a_user_answer(self):
        # Vista with CSM (UEFI path): answers are not handed on (the menu
        # shows only the manual installation, answer_screen.answersUnsupported);
        # the startup script stops instead of dropping a profile silently.
        script = (ROOT / 'tools/windows_vista_modern_startup.cmd').read_text()
        csmwrap = script.index('if exist "%~dp0usos-vista-csmwrap.flag" goto csmwrap')
        refuse = script.index('if exist "%~dp0usos-unattend.xml" (')
        self.assertLess(csmwrap, refuse)
        self.assertIn('exit /b 2', script[refuse:script.index(')', refuse + 40) + 1])
        screen = (ROOT / 'src/flow/answer_screen.zig').read_text()
        self.assertIn('pub fn answersUnsupported', screen)


if __name__ == '__main__':
    unittest.main()
