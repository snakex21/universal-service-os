"""usosnvme for Windows 95 OSR2 / 98 / 98 SE / Me (usosnvme.mpd, USOSNVME_W9X;
docs/research/nvme-9x-2026-10-13.md, docs/nvme-9x-2026-10-14.md): the
committed SCSIPORT.PDR miniport image, its 9x INF, tools/w9x_nvme.sh against a
fake sysfs (Git sh) and the 9x flow wiring. No VM, no disk."""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_nt52_driver_imports import pe  # noqa: E402

DRV = ROOT / 'tools/nt/usosnvme'
MPD = DRV / 'bin/W9X/usosnvme.mpd'
SRC = (DRV / 'src/usosnvme.c').read_text(encoding='latin-1')
HDR = (DRV / 'src/usosnvme.h').read_text(encoding='latin-1')
INF = (DRV / 'usosnvme9x.inf').read_bytes()
NVME_SH = (ROOT / 'tools/w9x_nvme.sh').as_posix()

# What SCSIPORT.PDR 4.x resolves for a PE miniport (98 SE CABs, study section 2).
PDR_EXPORTS = {
    'ScsiPortCompleteRequest', 'ScsiPortConvertPhysicalAddressToUlong', 'ScsiPortConvertUlongToPhysicalAddress',
    'ScsiPortFlushDma', 'ScsiPortFreeDeviceBase', 'ScsiPortGetBusData', 'ScsiPortGetDeviceBase',
    'ScsiPortGetLogicalUnit', 'ScsiPortGetPhysicalAddress', 'ScsiPortGetSrb', 'ScsiPortGetUncachedExtension',
    'ScsiPortGetVirtualAddress', 'ScsiPortInitialize', 'ScsiPortIoMapTransfer', 'ScsiPortLogError',
    'ScsiPortMoveMemory', 'ScsiPortNotification', 'ScsiPortReadPortUchar', 'ScsiPortReadPortUshort',
    'ScsiPortReadPortUlong', 'ScsiPortReadRegisterUchar', 'ScsiPortReadRegisterUshort', 'ScsiPortReadRegisterUlong',
    'ScsiPortWritePortUchar', 'ScsiPortWritePortUshort', 'ScsiPortWritePortUlong', 'ScsiPortWriteRegisterUchar',
    'ScsiPortWriteRegisterUshort', 'ScsiPortWriteRegisterUlong', 'ScsiPortSetBusDataByOffset',
    'ScsiPortStallExecution', 'ScsiPortValidateRange', 'ScsiDebugPrint'}


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def sh(script, env=None):
    r = subprocess.run([shell(), '-c', script], capture_output=True, text=True, env=dict(os.environ, **(env or {})))
    return r.returncode, r.stdout, r.stderr


class Image(unittest.TestCase):
    def test_imports_only_scsiport(self):
        imps = pe(MPD)[1]
        self.assertTrue(imps)
        self.assertEqual({m.upper() for m, _ in imps}, {'SCSIPORT.SYS'})
        self.assertLessEqual({n for _, n in imps}, PDR_EXPORTS)
        self.assertNotIn(b'ntoskrnl', MPD.read_bytes().lower())

    def test_pe_layout(self):
        b = MPD.read_bytes()
        off = int.from_bytes(b[0x3C:0x40], 'little')
        self.assertEqual(b[off:off + 4], b'PE\0\0')
        self.assertEqual(int.from_bytes(b[off + 4:off + 6], 'little'), 0x14C)
        opt = off + 24
        self.assertEqual(int.from_bytes(b[opt + 28:opt + 32], 'little'), 0x10000)   # ImageBase
        self.assertEqual(struct.unpack_from('<HH', b, opt + 40), (4, 0))             # OS version
        self.assertEqual(struct.unpack_from('<HH', b, opt + 48), (4, 0))             # subsystem version
        self.assertEqual(int.from_bytes(b[opt + 68:opt + 70], 'little'), 1)          # native
        reloc_rva, reloc_size = struct.unpack_from('<II', b, opt + 96 + 5 * 8)
        self.assertGreater(reloc_size, 0)
        self.assertIn(b'USOSNVME 1.0', b)


class Source(unittest.TestCase):
    def test_w9x_switch(self):
        self.assertIn('#if defined(USOSNVME_W9X) && !defined(USOSNVME_NT4)\n#define USOSNVME_NT4', HDR.replace('\r\n', '\n'))
        self.assertIn('#if defined(USOSNVME_NT351) || defined(USOSNVME_W9X)\n#define USOSNVME_CF8', HDR.replace('\r\n', '\n'))
        # SeaBIOS (CSMWrap) created I/O queue 1 before Windows: 9x uses queue 2,
        # so a stray BIOS doorbell cannot replay entries of our ring.
        self.assertIn('#define NVME_IO_QID 2', HDR)
        src = SRC.replace('\r\n', '\n')
        for want in ('init.HwAdapterState = NvmeAdapterState;', 'ext->Regs = (PUCHAR)NvmeMapPhys(bar.LowPart, mapSize);',
                     '_emit 06Ch', 'if (bar.HighPart != 0) {', 'return SP_RETURN_NOT_FOUND;',
                     'NvmeWr(Ext, NVME_REG_CC, (cc & ~(3UL << 14)) | NVME_CC_SHN_NORMAL);',
                     'if (!SaveState) NvmeShutdown(ext);', 'uncached extension not contiguous',
                     'NvmeE9 = (v == 0xE9) ? 1 : 0;', 'c.Cdw11 = ((NVME_IO_QID - 1UL) << 16) | (NVME_IO_QID - 1UL);'):
            self.assertIn(want, src)
        # the NT builds keep queue 1 and MmMapIoSpace
        self.assertIn('#ifndef USOSNVME_W9X\n__declspec(dllimport) PVOID __stdcall MmMapIoSpace', src)

    def test_build_target(self):
        cmd = (DRV / 'build.cmd').read_text(encoding='latin-1')
        self.assertIn('if /i "%VARIANT%"=="w9x"   set "DIR=W9X" & set "OUT=W9X" & set "PEVER=4.00"', cmd)
        self.assertIn(r'"%HERE%bin\W9X\usosnvme.mpd"', cmd)
        sources = (DRV / 'src/W9X/sources').read_text(encoding='latin-1')
        self.assertIn('-DUSOSNVME_W9X', sources)
        self.assertNotIn('ntoskrnl.lib', sources)


class Inf(unittest.TestCase):
    def test_inf(self):
        self.assertNotIn(b'\n', INF.replace(b'\r\n', b''))
        t = INF.decode('ascii')
        for want in ('Signature="$CHICAGO$"', 'Class=SCSIAdapter', 'DefaultDestDir=12',
                     '%USOSNVME.DeviceDesc%=USOSNVME, PCI\\CC_010802', 'HKR,,DevLoader,,*IOS',
                     'HKR,,PortDriver,,usosnvme.mpd', 'usosnvme.mpd=1', 'CopyFiles=USOSNVME.Copy'):
            self.assertIn(want, t)
        self.assertNotIn('DoubleBuffer', t)


class Script(unittest.TestCase):
    """tools/w9x_nvme.sh against a fake sysfs."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-nvme-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def sysfs(self, lbs=512, bar='0x00000000fe800000', cls='0x010802'):
        pci = self.tmp / 'devices/0000_01_00.0'
        pci.mkdir(parents=True, exist_ok=True)
        (pci / 'class').write_text(cls + '\n')
        (pci / 'vendor').write_text('0x1344\n')
        (pci / 'device').write_text('0x5411\n')
        (pci / 'resource').write_text(f'{bar} 0x00000000fe803fff 0x0000000000140204\n')
        blk = self.tmp / 'class/block/nvme0n1'
        (blk / 'queue').mkdir(parents=True, exist_ok=True)
        (blk / 'queue/logical_block_size').write_text(f'{lbs}\n')
        ctrl = blk / 'device'
        (ctrl / 'device').mkdir(parents=True, exist_ok=True)
        for name in ('class', 'vendor', 'device', 'resource'):
            (ctrl / 'device' / name).write_text((pci / name).read_text())
        return self.tmp.as_posix()

    def run_fn(self, call, root):
        return sh(f'. "{NVME_SH}"; {call}', {'W9X_NVME_SYSFS': root})

    def test_accept(self):
        rc, out, err = self.run_fn('w9x_nvme_check /dev/nvme0n1 && echo OK && w9x_nvme_hwid /dev/nvme0n1', self.sysfs())
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.split(), ['OK', 'PCI\\VEN_1344&DEV_5411'])

    def test_refuse_high_bar(self):
        rc, out, _ = self.run_fn('w9x_nvme_check /dev/nvme0n1', self.sysfs(bar='0x0000007c00000000'))
        self.assertEqual(rc, 1)
        self.assertIn('above 4 GiB', out)

    def test_refuse_4kn(self):
        rc, out, _ = self.run_fn('w9x_nvme_check /dev/nvme0n1', self.sysfs(lbs=4096))
        self.assertEqual(rc, 1)
        self.assertIn('4096-byte sectors', out)

    def test_refuse_sata(self):
        rc, out, _ = self.run_fn('w9x_nvme_check /dev/sda', self.sysfs())
        self.assertEqual(rc, 1)

    def test_inf_id(self):
        inf = self.tmp / 'u.inf'
        inf.write_bytes(INF)
        script = f'. "{NVME_SH}"; w9x_nvme_inf_add_id "$(printf %s ' + "'PCI\\VEN_1344&DEV_5411')\"" + f' < "{inf.as_posix()}"'
        r = subprocess.run([shell(), '-c', script], capture_output=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        # (Git for Windows' awk drops the input CRs; busybox awk keeps them.)
        self.assertIn(b'%USOSNVME.DeviceDesc%=USOSNVME, PCI\\CC_010802\n'
                      b'%USOSNVME.DeviceDesc%=USOSNVME, PCI\\VEN_1344&DEV_5411\n', r.stdout.replace(b'\r\n', b'\n'))
        self.assertEqual(r.stdout.count(b'PCI\\VEN_1344&DEV_5411\r\n'), 1)


class Flow(unittest.TestCase):
    def test_prepare_gate(self):
        prep = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        gate = prep[prep.index('    nvme9x=0\n'):]
        self.assertIn('[ -f "/mnt/data/Systems/Windows/$folder/Unattended/nvme-experimental.txt" ]', gate)
        self.assertLess(gate.index('nvme9x=1'), gate.index('W9X_NVME_DRIVER="$nvme9x"'))
        inject = prep[prep.index('PHASE1 PASS $vm_check'):]
        self.assertIn('w9x_nvme_inject "$nvme_loop"', inject)
        self.assertIn('losetup -o 1048576 "$nvme_loop" "$TARGET_DEVICE"', inject)

    def test_target_script(self):
        t = (ROOT / 'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('NVME_DRIVER=${W9X_NVME_DRIVER:-0}', t)
        self.assertIn('elif ! nvme_reason=$(w9x_nvme_check "$TARGET_DEVICE"); then', t)
        self.assertIn("SET U9NVME=1", t)
        self.assertIn('[ "$nvme_ok" = 1 ] || rm -f "$work/c/USOS9X/USOSNVME.MPD" "$work/c/USOS9X/USOSNVME.INF"', t)
        # the helpers (with the usosnvme pair) are copied first, U9ENV.BAT exists
        self.assertLess(t.index('for file in "$HELPERS"/*; do'), t.index('nvme_ok=0'))
        self.assertLess(t.index('> "$work/c/USOS9X/U9ENV.BAT"'), t.index('nvme_ok=0'))

    def test_install_bat(self):
        bat = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1')
        self.assertIn('IF NOT "%U9NVME%"=="1" GOTO NVMEDONE', bat)
        self.assertIn(r'FOR %%F IN (USOSNVME.INF USOSNVME.MPD) DO COPY /Y %U9T%\%%F C:\%U9SRC% >NUL', bat)

    def test_staged(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support as b
        self.assertIn('USOSNVME.MPD', b.STAGED)
        self.assertIn('USOSNVME.INF', b.STAGED)
        self.assertNotIn('USOSNVME.MPD', b.FILES)
        go = (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text(encoding='utf-8')
        self.assertIn('`EFI/USOS/dos-native/win9x/USOSNVME.MPD`', go)
        ml = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/w9x_nvme.sh", "usr/lib/usos/w9x_nvme.sh")', ml)


if __name__ == '__main__':
    unittest.main()
