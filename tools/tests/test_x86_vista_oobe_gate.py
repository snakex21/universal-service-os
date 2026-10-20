"""32-bit Vista / Server 2008 SP2 without CSM: the Vista OOBE gate
(tools/windows_vista_oobe_gate.c, x86 build with USOS_GATE_NATIVE_DEPLOY) is
armed by usos-x86-csmwrap.cmd (design doc csmwrap-integration 12.5).

X470 2026-10-11: OOBE "Sprawdzanie wydajnosci komputera" (WinSAT moobe) hung
in the "mem" assessment; after a hard reset OOBE ran again and a second
account was created. The gate sets WinSAT\\MOOBE=2 and resumes an
interrupted OOBE without a second account.
"""
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ZIG = ROOT / 'tools/zig/zig.exe'
CMD = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text(encoding='ascii')


def build_gate(out: Path, target: str, native: bool) -> bytes:
    env = dict(os.environ, ZIG_GLOBAL_CACHE_DIR=str(ROOT / 'tools/cache/zig-global'), ZIG_LOCAL_CACHE_DIR=str(out.parent / 'zig-cache'))
    args = [str(ZIG), 'cc', '-target', target, '-Os', '-nostdlib', '-fno-stack-protector', '-fno-builtin']
    if native:
        args.append('-DUSOS_GATE_NATIVE_DEPLOY')
    args += ['-I' + str(ROOT / 'tools/zig/lib/libc/include/any-windows-any'), str(ROOT / 'tools/windows_vista_oobe_gate.c'),
             '-Wl,--entry,entry', '-Wl,--subsystem,windows', '-lkernel32', '-ladvapi32', '-lnetapi32', '-luser32', '-lcrypt32', '-o', str(out)]
    subprocess.run(args, env=env, check=True)
    return out.read_bytes()


class X86VistaOobeGate(unittest.TestCase):
    def test_hidden_console_chain_retains_stdout(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary)
            env=dict(os.environ,ZIG_GLOBAL_CACHE_DIR=str(folder/'global'),ZIG_LOCAL_CACHE_DIR=str(folder/'local'))
            common=[str(ZIG),'cc','-target','x86_64-windows.win10-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-I'+str(ROOT/'tools/zig/lib/libc/include/any-windows-any'),'-Wl,--entry,entry','-lkernel32','-luser32']
            subprocess.run(common+[str(ROOT/'tools/tests/vista_console_child.c'),str(ROOT/'tools/nt6/usoswm/runtime.c'),'-Wl,--subsystem,console','-o',str(folder/'console-child.exe')],env=env,check=True)
            subprocess.run(common+[str(ROOT/'tools/tests/vista_console_harness.c'),str(ROOT/'tools/nt6/usoswm/runtime.c'),'-Wl,--subsystem,windows','-ladvapi32','-lnetapi32','-o',str(folder/'quiet-parent.exe')],env=env,check=True)
            subprocess.run([str(folder/'quiet-parent.exe')],env=env,check=True,timeout=30)

    def test_gate_variants(self):
        with tempfile.TemporaryDirectory() as tmp:
            x86 = build_gate(Path(tmp) / 'x86.exe', 'x86-windows.vista-gnu', True)
            x64 = build_gate(Path(tmp) / 'x64.exe', 'x86_64-windows.vista-gnu', False)
        windeploy = '\\System32\\oobe\\windeploy.exe'.encode('utf-16-le')
        usb = 'C:\\USOS\\usb.exe'.encode('utf-16-le')
        moobe = 'MOOBE'.encode('utf-16-le')
        pe = int.from_bytes(x86[0x3c:0x40], 'little')
        self.assertEqual(x86[pe + 4:pe + 6], b'\x4c\x01')  # IMAGE_FILE_MACHINE_I386
        for data in (x86,x64):
            header=int.from_bytes(data[0x3c:0x40],'little')
            self.assertEqual(2,int.from_bytes(data[header+24+68:header+24+70],'little')) # WINDOWS_GUI, no console
        self.assertIn(moobe, x86)
        self.assertIn(windeploy, x86)
        self.assertNotIn(usb, x86)
        self.assertIn(usb, x64)  # the x64 USB v11 path is unchanged
        self.assertNotIn(b'WM_SETUP_GATE_DESKTOP', x86)
        self.assertNotIn(b'WM_SETUP_GATE_DESKTOP', x64)

    def test_cmd_arms_gate_for_nt60_sp2_only(self):
        self.assertIn('call :usb3\ncall :nt60_gate\n', CMD)
        gate = CMD.split('\n:nt60_gate\n', 1)[1].split('\n:nt60_usb\n', 1)[0]
        self.assertIn('if not "%USOS_NT%"=="6.0" exit /b 0', gate)
        self.assertIn('if not "%USOS_BUILD%"=="6002"', gate)
        self.assertIn('Microsoft\\Windows NT\\CurrentVersion\\WinSAT" /v MOOBE /t REG_DWORD /d 2', gate)
        self.assertIn('if /i "%USOS_CMDLINE%"=="oobe\\windeploy.exe"', gate)
        self.assertIn('/v CmdLine /t REG_SZ /d "%USOS_SYSDRIVE%\\USOS\\oobe.exe"', gate)
        self.assertIn('copy /y "%~dp0usos-vista-oobe-x86.exe" "%USOS_T%\\USOS\\oobe.exe"', gate)
        self.assertEqual(gate.count('reg load'), gate.count('reg unload'))

    def test_helper_reports_build_and_stick(self):
        source = (ROOT / 'tools/windows_x86_csmwrap.c').read_text(encoding='utf-8')
        self.assertIn('decimal(d, file_build)', source)
        self.assertIn('FSCTL_IS_VOLUME_DIRTY', source)
        self.assertEqual(CMD.count('usos-x86-csmwrap.exe" stick'), 2)

    def test_support_archive_carries_gate(self):
        build = (ROOT / 'tools/build_windows_native_support.py').read_text(encoding='utf-8')
        self.assertIn("writer.add_file('usos-vista-oobe-x86.exe'", build)
        self.assertIn("'-DUSOS_GATE_NATIVE_DEPLOY'", build)


if __name__ == '__main__':
    unittest.main()
