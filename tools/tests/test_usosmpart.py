"""usosmpart (USB multi-partition disk filter), host-only, no Microsoft files:

- tools/nt/usosmpart/bin: both builds are native drivers of the right
  machine, import only the kernel / HAL functions listed here (all exported
  by the Windows 2000 SP4 kernel, checked once against its ntoskrnl.exe),
  no CRT;
- tools/nt5_usosmpart_stage.sh: TXTSETUP.SIF rows ([SourceDisksFiles] +
  [HiveInfs.Fresh]), the hive INF (service + disk class LowerFilters),
  DOSNET rows, a second run refused, apply on a stand-in target (i386 and
  amd64), SKIP without the package file;
- tools/windows_x86_csmwrap.cmd: the :mpart step is called after Setup and
  skips NT 6.0 and Windows 10 1703+;
- the micro-Linux and WinPE packagers carry the files.
"""
from pathlib import Path
import os, shutil, struct, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
SH = next((p for p in (r'C:\msys64\usr\bin\sh.exe', r'C:\Program Files\Git\usr\bin\sh.exe', shutil.which('sh') or '')
           if p and Path(p).exists() and any((Path(p).parent / n).exists() for n in ('cmp.exe', 'cmp'))), None)
SH_ENV = dict(os.environ)
if SH:
    SH_ENV['PATH'] = str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', '')
STAGE = ROOT / 'tools/nt5_usosmpart_stage.sh'

IMPORTS = {
    'ExAllocatePoolWithTag', 'ExFreePoolWithTag', 'IoAcquireRemoveLockEx', 'IoAllocateIrp', 'IoAllocateMdl',
    'IoAttachDeviceToDeviceStack', 'IoCreateDevice', 'IoDeleteDevice', 'IoDetachDevice', 'IoFreeIrp', 'IoFreeMdl',
    'IoGetDeviceProperty', 'IoInitializeRemoveLockEx', 'IoReleaseRemoveLockAndWaitEx', 'IoReleaseRemoveLockEx',
    'IoReuseIrp', 'IofCallDriver', 'IofCompleteRequest', 'KeClearEvent', 'KeInitializeEvent', 'KeSetEvent',
    'KeWaitForSingleObject', 'MmBuildMdlForNonPagedPool', 'PoCallDriver', 'PoStartNextPowerIrp', 'PsGetVersion',
    'RtlAppendUnicodeStringToString', 'RtlAppendUnicodeToString', 'RtlCompareMemory', 'RtlQueryRegistryValues',
    'memcpy', 'memset', 'KeGetCurrentIrql'}


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def sh(command: str, stdin: bytes = b'') -> subprocess.CompletedProcess:
    return subprocess.run([SH, '-c', '. "%s"; %s' % (posix(STAGE), command)], input=stdin, capture_output=True, env=SH_ENV)


def imports(data: bytes):
    """(machine, {dll: [names]}) of a PE image, by hand (no pefile needed)."""
    pe = struct.unpack_from('<I', data, 60)[0]
    machine, nsec = struct.unpack_from('<HH', data, pe + 4)
    opt = pe + 24
    magic = struct.unpack_from('<H', data, opt)[0]
    dirs = opt + (96 if magic == 0x10b else 112)
    rva = struct.unpack_from('<I', data, dirs + 8)[0]
    sec = opt + struct.unpack_from('<H', data, pe + 20)[0]
    sections = [struct.unpack_from('<IIII', data, sec + 40 * i + 8) for i in range(nsec)]

    def off(r):
        for vsize, va, rsize, raw in sections:
            if va <= r < va + max(vsize, rsize):
                return r - va + raw
        raise ValueError(hex(r))

    def cstr(o):
        return data[o:data.index(b'\0', o)].decode()
    out, d = {}, off(rva)
    ptr = 8 if magic == 0x20b else 4
    while True:
        ilt, _, _, name, iat = struct.unpack_from('<IIIII', data, d)
        if not name:
            break
        names, t = [], off(ilt or iat)
        while True:
            v = int.from_bytes(data[t:t + ptr], 'little')
            if not v:
                break
            names.append(cstr(off(v & 0x7FFFFFFF) + 2))
            t += ptr
        out[cstr(off(name)).lower()] = names
        d += 20
    return machine, out


class Binaries(unittest.TestCase):
    def test_builds(self):
        for arch, machine in (('i386', 0x14c), ('amd64', 0x8664)):
            data = (ROOT / 'tools/nt/usosmpart/bin' / arch / 'usosmpart.sys').read_bytes()
            got, imp = imports(data)
            self.assertEqual(got, machine, arch)
            self.assertLessEqual(set(imp), {'ntoskrnl.exe', 'hal.dll'}, arch)
            names = {n for v in imp.values() for n in v}
            self.assertLessEqual(names, IMPORTS, arch)
            self.assertIn('IoGetDeviceProperty', names)

    def test_source_rules(self):
        src = (ROOT / 'tools/nt/usosmpart/src/usosmpart.c').read_text()
        self.assertIn('SPDX-License-Identifier: GPL-3.0-or-later', src)
        self.assertIn('DevicePropertyEnumeratorName', src)   # USBSTOR disks only
        self.assertIn('d->BusType == BusTypeUsb && d->RemovableMedia', src)
        self.assertIn('ext->Partitions > 1', src)            # single-partition sticks unchanged
        # GPT stick on 2000 / XP x86: pure protective MBR -> hidden (fixed) + writes blocked
        self.assertIn('*GptHidden = (BOOLEAN)(count == 0);', src)
        self.assertIn('ext->Partitions > 1 ? MpFlip : gptHidden ? MpHide : MpKeep', src)
        self.assertIn('Drv->MajorFunction[IRP_MJ_SCSI] = MpScsiRequest;', src)
        self.assertIn('ext->Decision == MpHide && srb && srb->Function == SRB_FUNCTION_EXECUTE_SCSI', src)
        for op in ('0x0A', '0x2A', '0xAA', '0x8A', '0x2E', '0xAE', '0x8E', '0x41', '0x93'):
            self.assertIn('Op == %s' % op, src)
        self.assertIn('sense[2] = 0x07;', src)
        self.assertIn('sense[12] = 0x27;', src)


TXTSETUP = (b'[SetupData]\r\nMajorVersion = 5\r\n[SourceDisksFiles]\r\nstorport.sys = 1,,,,,,3_,4,0,0,,1,4\r\n'
            b'[HiveInfs.Fresh]\r\nAddReg = hivedef.inf,AddReg\r\n[SourceDisksFiles]\r\nfoo.sys = 1\r\n')
DOSNET = b'[Directories]\r\nd1 = \\I386\r\n[Files]\r\nd1,usetup.exe,system32\\smss.exe\r\n'


@unittest.skipIf(SH is None, 'sh not found')
class Stage(unittest.TestCase):
    def test_sif(self):
        r = sh('usos_nt5_usosmpart_sif', TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout
        self.assertTrue(out.endswith(b'\r\n'))
        self.assertIn(b'[SourceDisksFiles]\r\nusosmpart.sys = 1,,,,,,,4,0,0\r\nusosmpt.inf = 1,,,,,,_x,20,3,3\r\nstorport', out)
        self.assertIn(b'[HiveInfs.Fresh]\r\nAddReg = usosmpt.inf,AddReg\r\nAddReg = hivedef', out)
        self.assertEqual(out.count(b'usosmpart.sys'), 1)
        self.assertEqual(sh('usos_nt5_usosmpart_sif', out).returncode, 3)
        self.assertEqual(sh('usos_nt5_usosmpart_sif', b'[SourceDisksFiles]\r\n').returncode, 3)

    def test_hive_inf(self):
        out = sh('usos_nt5_usosmpart_hive_inf').stdout
        self.assertIn(b'[AddReg]\r\n', out)
        for row in (b'Services\\usosmpart",Start,0x00010001,0\r\n', b'Services\\usosmpart",Type,0x00010001,1\r\n',
                    b'Services\\usosmpart",Group,0x00000000,"Filter"\r\n',
                    b'Services\\usosmpart",ImagePath,0x00020000,"system32\\DRIVERS\\usosmpart.sys"\r\n',
                    b'Class\\{4D36E967-E325-11CE-BFC1-08002BE10318}",LowerFilters,0x00010000,"usosmpart"\r\n'):
            self.assertIn(row, out)

    def test_dosnet(self):
        out = sh('usos_nt5_usosmpart_dosnet', DOSNET).stdout
        self.assertIn(b'[Files]\r\nd1,usosmpart.sys\r\nd1,usosmpt.inf\r\nd1,usetup', out)
        self.assertEqual(sh('usos_nt5_usosmpart_dosnet', out).returncode, 3)

    def test_apply(self):
        for src_dir, arch in (('I386', 'i386'), ('AMD64', 'amd64')):
            with tempfile.TemporaryDirectory() as tmp:
                t = Path(tmp)
                pkg = t / 'pkg' / arch
                pkg.mkdir(parents=True)
                (pkg / 'usosmpart.sys').write_bytes(b'MZ' + arch.encode())
                bt, ls = t / 'vol' / '$WIN_NT$.~BT', t / 'vol' / '$WIN_NT$.~LS' / src_dir
                bt.mkdir(parents=True)
                ls.mkdir(parents=True)
                for d in (bt, ls):
                    (d / 'TXTSETUP.SIF').write_bytes(TXTSETUP)
                (ls / 'DOSNET.INF').write_bytes(DOSNET)
                (ls / 'USOSMPART.SY_').write_bytes(b'old')
                r = subprocess.run([SH, '-c', 'XP_TARGET_ROOT="%s" NT5_SOURCE_DIR=%s USOS_NT5_MPART_DIR="%s" sh "%s" apply'
                                    % (posix(t / 'vol'), src_dir, posix(t / 'pkg'), posix(STAGE))], capture_output=True, env=SH_ENV)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn(b'[NT5_MPART] APPLIED PASS usosmpart.sys (' + arch.encode() + b')', r.stdout)
                self.assertEqual((ls / 'usosmpart.sys').read_bytes(), b'MZ' + arch.encode())
                self.assertFalse((ls / 'USOSMPART.SY_').exists())
                for d in (bt, ls):
                    self.assertIn(b'AddReg = usosmpt.inf,AddReg', (d / 'TXTSETUP.SIF').read_bytes())
                    self.assertIn(b'LowerFilters', (d / 'usosmpt.inf').read_bytes())
                self.assertIn(b'd1,usosmpt.inf', (ls / 'DOSNET.INF').read_bytes())
                # no package file: SKIP, nothing written
                (pkg / 'usosmpart.sys').unlink()
                (ls / 'TXTSETUP.SIF').write_bytes(TXTSETUP)
                r = subprocess.run([SH, '-c', 'XP_TARGET_ROOT="%s" NT5_SOURCE_DIR=%s USOS_NT5_MPART_DIR="%s" sh "%s" apply'
                                    % (posix(t / 'vol'), src_dir, posix(t / 'pkg'), posix(STAGE))], capture_output=True, env=SH_ENV)
                self.assertEqual(r.returncode, 0)
                self.assertIn(b'SKIP', r.stdout)
                self.assertEqual((ls / 'TXTSETUP.SIF').read_bytes(), TXTSETUP)


class Wiring(unittest.TestCase):
    def test_nt5_prepare_calls_stage(self):
        text = (ROOT / 'tools/prepare_xp_ntfs_target.sh').read_text()
        self.assertIn('sh "$SCRIPT_DIR/nt5_usosmpart_stage.sh" apply', text)
        self.assertLess(text.index('nt52_usb_stage.sh" apply'), text.index('nt5_usosmpart_stage.sh" apply'))

    def test_packagers(self):
        ml = (ROOT / 'tools/build_micro_linux.py').read_text()
        for entry in ('usr/lib/usos/nt5_usosmpart_stage.sh', 'usr/lib/usos/nt5-usosmpart/i386/usosmpart.sys',
                      'usr/lib/usos/nt5-usosmpart/amd64/usosmpart.sys'):
            self.assertIn(entry, ml)
        self.assertIn("'usosmpart-x86.sys'", (ROOT / 'tools/build_windows_native_support.py').read_text())

    def test_x86_cmd_step(self):
        cmd = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text()
        lines = cmd.splitlines()
        self.assertLess(lines.index('call :nvme'), lines.index('call :mpart'))
        self.assertLess(cmd.index('call :mpart'), cmd.index('phase=finalize-target-boot'))
        step = cmd[cmd.index('\n:mpart'):]
        self.assertIn('if not "%USOS_NT%"=="6.1" if not "%USOS_NT%"=="6.2" if not "%USOS_NT%"=="6.3" if not "%USOS_NT%"=="10.0" exit /b 0', step)
        self.assertIn('GEQ 15063', step)
        self.assertIn('%USOS_LF%\\0usosmpart', step)   # appended, existing filters kept
        self.assertIn('/v Start /t REG_DWORD /d 0', step)


if __name__ == '__main__':
    unittest.main()
