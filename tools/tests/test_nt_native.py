"""Native NT 3.51 install without the install VM (docs/nt-native-plan.md):
nt3_native_txtsetup in tools/nt4_csmwrap_target.sh and the nt3-native.flag
routing in tools/w9x_csmwrap_prepare.sh. Host only: Git sh, temp folders; no
VM, no disk, no Microsoft file (the TXTSETUP.SIF below is a synthetic
fixture with the section shapes of the NT 3.51 CD).
"""
from pathlib import Path
import shutil
import tempfile
import unittest

from test_w9x_phase1_qemu import sh
from test_nt4_flow import function_text

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'

SIF = (
    '[ScsiClass.Load]\r\ndisk   = scsidisk.sys\r\n'
    '[SCSI.Load]\r\ncpqarray = cpqarray.sys,4\r\naha154x = aha154x.sys,4\r\n'
    'wd33c93 = wd33c93.sys,4,noload\r\namsint = amsint.sys,4\r\n\r\n'
    '[SCSI]\r\naha154x  = "Adaptec 154x"\r\namsint   = "AMD PCI SCSI/NET Adapter"\r\n'
    '[SetupData]\r\nProductType = 0\r\nMajorVersion = 3\r\nMinorVersion = 51\r\n'
    'OsLoadOptions = "/nodebug"\r\nAllowFloppySetup = 1\r\n'
    '[Files]\r\nscsidisk.sys = dx,d7,_3,4,0,0\r\namsint.sys   = dx,d7,_3,4,1\r\n'
)


class NativeTxtsetup(unittest.TestCase):
    def run_fn(self, ports, opts, text):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt-native-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'in.sif').write_bytes(text.encode('ascii'))
        fn = function_text(TARGET, 'nt3_native_txtsetup')
        rc, _, err = sh(f'{fn}\nnt3_native_txtsetup "{ports}" "{opts}" < "{(tmp / "in.sif").as_posix()}" > "{(tmp / "out.sif").as_posix()}"')
        return rc, (tmp / 'out.sif').read_bytes().decode('ascii'), err

    def section(self, text, name):
        out, inside = [], False
        for line in text.split('\r\n'):
            if line.startswith('['):
                inside = line.lower() == name.lower()
                continue
            if inside and line:
                out.append(line)
        return out

    def test_only_the_usos_miniports_load(self):
        rc, out, err = self.run_fn('ahcint', '/nodebug /NUMPROC=2 /MAXMEM=1024', SIF)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.section(out, '[SCSI.Load]'), ['ahcint = ahcint.sys,4'])
        self.assertIn('ahcint = "USOS AHCI (SATA)"', self.section(out, '[SCSI]'))
        self.assertIn('amsint   = "AMD PCI SCSI/NET Adapter"', self.section(out, '[SCSI]'))
        files = self.section(out, '[Files]')
        self.assertIn('ahcint.sys = dx,d7,_3,4,1', files)
        self.assertIn('amsint.sys   = dx,d7,_3,4,1', files)
        self.assertEqual(self.section(out, '[ScsiClass.Load]'), ['disk   = scsidisk.sys'])
        self.assertNotIn('\r\r', out)
        self.assertTrue(out.endswith('\r\n'))

    def test_load_options_replace_the_cd_ones(self):
        _, out, _ = self.run_fn('ahcint', '/nodebug /NUMPROC=2 /MAXMEM=1024', SIF)
        setup = self.section(out, '[SetupData]')
        self.assertEqual([l for l in setup if l.lower().startswith('osloadoptions')], ['OsLoadOptions = "/nodebug /NUMPROC=2 /MAXMEM=1024"'])
        self.assertIn('MinorVersion = 51', setup)

    def test_nvme_target_adds_usosnvme(self):
        _, out, _ = self.run_fn('ahcint usosnvme', '/nodebug', SIF)
        self.assertEqual(self.section(out, '[SCSI.Load]'), ['ahcint = ahcint.sys,4', 'usosnvme = usosnvme.sys,4'])
        self.assertIn('usosnvme = "USOS NVMe"', self.section(out, '[SCSI]'))
        self.assertIn('usosnvme.sys = dx,d7,_3,4,1', self.section(out, '[Files]'))

    def test_without_the_amsint_row_nothing_is_written(self):
        rc, out, _ = self.run_fn('ahcint', '/nodebug', SIF.replace('amsint.sys   = dx,d7,_3,4,1\r\n', ''))
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, '')


class NativeWiring(unittest.TestCase):
    def test_target_refuses_other_versions_before_the_disk(self):
        text = TARGET.read_text(encoding='utf-8')
        gate = text.index('if [ "$NATIVE" = 1 ]; then\n    [ "$nt3:$minor" = yes:51 ]')
        self.assertLess(gate, text.index('dd if=/dev/zero of="$TARGET_DEVICE"'))
        self.assertIn('No disk was changed', text[gate:gate + 300])
        # The miniports go next to SETUPLDR (~BT) and into the local source.
        block = text[text.index('nt3_native_txtsetup "$ports"'):]
        self.assertIn('for dir in "$bt_dir" "$ls_src"; do', block[:1200])
        self.assertIn("log 'NT351 LAN skipped: native install", text)

    def test_prepare_flag_is_nt351_only_and_skips_the_vm(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('NT351|NT351S) [ ! -e /mnt/esp/EFI/USOS/win9x/nt3-native.flag ] || nt_native=yes ;;', text)
        self.assertEqual(text.count('nt_native=yes'), 1)
        self.assertIn('NT_NATIVE="$([ "$nt_native" = yes ] && echo 1 || echo 0)"', text)
        native = text.index('if [ -n "$nt4" ] && [ "$nt_native" = yes ]; then\n        # Native')
        vm = text.index('nt4_vm_install "$TARGET_DEVICE"')
        self.assertLess(native, vm)
        self.assertIn('xp_csmwrap_esp.sh', text[native:vm])
        # The VM gate is not consulted for a native start.
        gate = text.index('elif [ -n "$nt4" ] && [ "$nt_native" = yes ]; then')
        self.assertLess(gate, text.index('elif [ -n "$nt4" ]; then\n        . /usr/lib/usos/w9x_phase1_qemu.sh'))


if __name__ == '__main__':
    unittest.main()
