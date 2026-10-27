"""tools/w9x_pid95.sh: Windows 95 MSBATCH.INF ProductID vs SUWIN's batch path
(host sh). The SUWIN model below follows the 4.00.950 layout described in the
helper: a 24-byte product ID buffer seeded from WINSETUP's /U: value, the
batch ProductID copied 6 bytes into it, the batch file path right after."""
from pathlib import Path
import os
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/w9x_pid95.sh').as_posix()
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'
# Made-up test IDs in the documented formats (not real keys).
OEM_ID = '12345-OEM-0000007-54321'
RETAIL_ID = '111-1111111'
TEMPLATE = b'\x15 /U:' + b'x' * 17 + b'\x00'
BATCH = 'C:\\WIN95\\MSBATCH.INF'


def suwin_model(u_value, product_id, batch_path):
    """The bytes SUWIN ends up with: [0x6998] 24-byte PID buffer, then the
    batch path at [0x69b0]. lstrcpy has no bound, the INF read stops at 23."""
    mem = bytearray(24 + 260)
    path = batch_path.encode() + b'\0'
    mem[24:24 + len(path)] = path
    u = u_value.encode() + b'\0'
    mem[0:len(u)] = u
    if product_id:
        p = product_id[:23].encode() + b'\0'
        mem[6:6 + len(p)] = p
    pid = bytes(mem[0:24]).split(b'\0')[0].decode()
    batch = bytes(mem[24:]).split(b'\0')[0].decode()
    return pid, batch


class Pid95(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-pid95-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.inf = self.tmp / 'MSBATCH.INF'
        self.bin = self.tmp / 'WINSETUP.BIN'

    def stage(self, product_id, template=TEMPLATE, copies=1):
        setup = ['[Setup]', 'Express=1', 'EBD=0']
        if product_id is not None:
            setup.append(f'ProductID="{product_id}"')
        lines = ['[Version]', 'Signature="$CHICAGO$"', ''] + setup + ['TimeZone="Lisbon Warsaw"', '',
                 '[NameAndOrg]', 'Name="ja"', 'ProductID="not-in-setup"', '']
        self.inf.write_bytes(('\r\n'.join(lines) + '\r\n').encode())
        self.bin.write_bytes(os.urandom(4096).replace(b'\x15', b'\x16') + template * copies + b'\x01' * 300)

    def run_prepare(self):
        rc, out, err = sh(f'. "{LIB}"\nw9x_pid95_prepare "$I"', {'I': self.inf.as_posix()})
        return rc, out.strip(), err

    def setup_pid(self):
        rc, out, _ = sh(f'. "{LIB}"\nw9x_pid95_value "$I"', {'I': self.inf.as_posix()})
        self.assertEqual(rc, 0)
        return out.strip()

    def test_model_reproduces_the_lost_batch_file(self):
        # The X470 950 / 2026-10-20 OSR2 failure: 23 characters overwrite the
        # path start with the last 5 digits, a retail key fits.
        pid, batch = suwin_model('x' * 17, OEM_ID, BATCH)
        self.assertEqual(batch, OEM_ID[-5:])
        _, batch = suwin_model('x' * 17, RETAIL_ID, BATCH)
        self.assertEqual(batch, BATCH)
        _, batch = suwin_model('x' * 17, None, BATCH)
        self.assertEqual(batch, BATCH)

    def test_oem_id_is_dropped_and_winsetup_untouched(self):
        # X470 95 RTM PL native (2026-10-26): the former split loaded the
        # batch but never filled the Product ID page and put 5 key digits
        # into SETUPLOG's CmdLine. Now the OEM ID goes; the batch path stays.
        self.stage(OEM_ID)
        binary = self.bin.read_bytes()
        rc, out, err = self.run_prepare()
        self.assertEqual((rc, out), (0, 'dropped'), err)
        self.assertEqual(self.setup_pid(), '')
        self.assertEqual(self.bin.read_bytes(), binary)
        self.assertNotIn(b'ProductID="OEM', self.inf.read_bytes())
        _, batch = suwin_model('x' * 17, None, BATCH)
        self.assertEqual(batch, BATCH)
        lib = Path(LIB).read_text(encoding='utf-8')
        for gone in ('WINSETUP.BIN"', 'dd of=', 'template_offset', 'oem-split\n'):
            self.assertNotIn(gone, lib)

    def test_only_setup_productid_changes_and_crlf_stays(self):
        self.stage(OEM_ID)
        self.run_prepare()
        text = self.inf.read_bytes()
        self.assertEqual(text.count(b'\n'), text.count(b'\r\n'))
        self.assertIn(b'ProductID="not-in-setup"\r\n', text)   # [NameAndOrg] untouched
        self.assertIn(b'Express=1\r\nEBD=0\r\n', text)
        self.assertNotIn(OEM_ID.encode(), text)
        self.assertNotIn(OEM_ID[6:].encode(), text)

    def test_retail_and_missing_ids_are_kept(self):
        for value in (RETAIL_ID, None):
            self.stage(value)
            inf, binary = self.inf.read_bytes(), self.bin.read_bytes()
            rc, out, _ = self.run_prepare()
            self.assertEqual((rc, out), (0, 'kept'), value)
            self.assertEqual(self.inf.read_bytes(), inf)
            self.assertEqual(self.bin.read_bytes(), binary)

    def test_other_long_ids_are_dropped(self):
        for value in ('x' * 18, '12345-OEM-0000007-5432', OEM_ID.lower()):
            self.stage(value)
            rc, out, _ = self.run_prepare()
            self.assertEqual((rc, out), (0, 'dropped'), value)
            self.assertEqual(self.setup_pid(), '')

    def test_second_run_keeps_the_result(self):
        self.stage(OEM_ID)
        self.run_prepare()
        inf = self.inf.read_bytes()
        rc, out, _ = self.run_prepare()
        self.assertEqual((rc, out), (0, 'kept'))
        self.assertEqual(self.inf.read_bytes(), inf)

    def test_target_block_runs(self):
        text = TARGET.read_text()
        block = text[text.index('# Windows 95 with a native phase 1: SUWIN'):text.index("# Display: the answer's")]
        cases = (('95', '4 0 0 950', '0', 'PROFILE', 'dropped', ''),
                 ('95', '4 0 0 1111', '0', 'PROFILE', 'dropped', ''),
                 ('95', '4 0 0 950', '1', 'PROFILE', None, OEM_ID),       # VM phase 1: unchanged
                 ('95', '4 0 0 950', '0', 'USER', None, OEM_ID),          # user's file: 1:1
                 ('98SE', '', '0', 'PROFILE', None, OEM_ID))
        for tag, version, vm, kind, result, want in cases:
            work = Path(tempfile.mkdtemp(prefix='usos-w9x-pidblock-'))
            self.addCleanup(shutil.rmtree, work, ignore_errors=True)
            (work / 'c/USOS9X').mkdir(parents=True)
            (work / 'c/WIN95').mkdir()
            self.stage(OEM_ID)
            shutil.copy(self.inf, work / 'c/USOS9X/MSBATCH.INF')
            shutil.copy(self.bin, work / 'c/WIN95/WINSETUP.BIN')
            binary = self.bin.read_bytes()
            script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\nfail() { exit 9; }\n'
                      f'SYSTEM_TAG={tag}\nsetup_version="$V"\nVM_PHASE1={vm}\nANSWER_KIND={kind}\nSETUP_FOLDER=WIN95\n'
                      f'LIB="{(ROOT / "tools").as_posix()}"\nwork="{work.as_posix()}"\n' + block)
            rc, out, err = sh(script, {'V': version})
            self.assertEqual(rc, 0, (tag, version, vm, kind, err))
            self.assertNotIn(OEM_ID, out)                                # the key is never logged
            self.assertNotIn(OEM_ID[6:], out)
            if result:
                self.assertIn(f'product id: {result}', out)
            else:
                self.assertNotIn('product id:', out)
            rc, got, _ = sh(f'. "{LIB}"\nw9x_pid95_value "$I"', {'I': (work / 'c/USOS9X/MSBATCH.INF').as_posix()})
            self.assertEqual(got.strip(), want, (tag, version, vm, kind))
            self.assertEqual((work / 'c/WIN95/WINSETUP.BIN').read_bytes(), binary)   # never patched
            if kind == 'USER':
                self.assertIn('warning: the answer file ProductID has 18+ characters', out)

    def test_stage_key_only_for_an_oem_id(self):
        key = self.tmp / 'USOSPID.KEY'
        for value, result in ((OEM_ID, 'staged'), (OEM_ID.lower(), 'staged'), (RETAIL_ID, 'none'), (None, 'none'),
                              ('12345-OEM-0000007-5432', 'none'), ('12345-OEM-000000a-54321', 'none'), ('x' * 23, 'none')):
            with self.subTest(value=value):
                key.write_bytes(b'old')
                self.stage(value)
                rc, out, err = sh(f'. "{LIB}"\nw9x_pid95_stage_key "$I" "$K"', {'I': self.inf.as_posix(), 'K': key.as_posix()})
                self.assertEqual((rc, out.strip()), (0, result), err)
                self.assertNotIn(OEM_ID[6:], out + err)
                if result == 'staged':
                    self.assertEqual(key.read_bytes(), OEM_ID.encode() + b'\r\n')   # OEM upper case
                else:
                    self.assertFalse(key.exists())

    def target_block(self, tag, version, vm, kind, with_driver):
        text = TARGET.read_text()
        block = text[text.index('# Windows 95 with a native phase 1: SUWIN'):text.index("# Display: the answer's")]
        work = Path(tempfile.mkdtemp(prefix='usos-w9x-pidblock-'))
        self.addCleanup(shutil.rmtree, work, ignore_errors=True)
        (work / 'c/USOS9X').mkdir(parents=True)
        self.stage(OEM_ID)
        shutil.copy(self.inf, work / 'c/USOS9X/MSBATCH.INF')
        if with_driver:
            (work / 'c/USOS9X/USOSPID.DRV').write_bytes(b'MZ')
        script = ('set -eu\nlog() { printf "%s\\n" "$*"; }\nfail() { exit 9; }\n'
                  f'SYSTEM_TAG={tag}\nsetup_version="$V"\nVM_PHASE1={vm}\nANSWER_KIND={kind}\nSETUP_FOLDER=WIN95\n'
                  f'LIB="{(ROOT / "tools").as_posix()}"\nwork="{work.as_posix()}"\n' + block)
        rc, out, err = sh(script, {'V': version})
        self.assertEqual(rc, 0, err)
        self.assertNotIn(OEM_ID[6:], out + err)                          # the key is never logged
        return work / 'c/USOS9X', out

    def test_target_block_stages_the_key_for_950_only(self):
        # 950 native, USOS answer, USOSPID.DRV on the stick: key file, driver kept.
        d, out = self.target_block('95', '4 0 0 950', '0', 'PROFILE', True)
        self.assertEqual((d / 'USOSPID.KEY').read_bytes(), OEM_ID.encode() + b'\r\n')
        self.assertTrue((d / 'USOSPID.DRV').exists())
        self.assertIn('product id: dropped', out)
        self.assertIn('product id: staged for the Product ID page', out)
        rc, got, _ = sh(f'. "{LIB}"\nw9x_pid95_value "$I"', {'I': (d / 'MSBATCH.INF').as_posix()})
        self.assertEqual(got.strip(), '')
        # OSR2, the VM phase 1, a user's file, 98 SE, or no driver: no key, no driver.
        for case in (('95', '4 0 0 1111', '0', 'PROFILE', True), ('95', '4 0 0 950', '1', 'PROFILE', True),
                     ('95', '4 0 0 950', '0', 'USER', True), ('98SE', '', '0', 'PROFILE', True),
                     ('95', '4 0 0 950', '0', 'PROFILE', False)):
            with self.subTest(case=case):
                d, out = self.target_block(*case)
                self.assertFalse((d / 'USOSPID.KEY').exists())
                self.assertFalse((d / 'USOSPID.DRV').exists())
                self.assertNotIn('staged for the Product ID page', out)

    def test_key_leaves_the_disk_without_the_mini_windows_helper(self):
        text = TARGET.read_text()
        a = text.index('# The staged Product ID (above) only with USOSPID.DRV')
        block = text[a:text.index('\nfi\n', text.index("log 'product id: no mini-Windows helper")) + 4]
        for bridge, mini, kept in (('1', 'pid=on\r\nbridge=on\r\n', True), ('1', 'pid=off\r\nbridge=on\r\n', False),
                                   ('0', 'pid=on\r\nbridge=on\r\n', False), ('1', None, False)):
            with self.subTest(bridge=bridge, mini=mini):
                work = Path(tempfile.mkdtemp(prefix='usos-w9x-pidmini-'))
                self.addCleanup(shutil.rmtree, work, ignore_errors=True)
                d = work / 'c/USOS9X'
                d.mkdir(parents=True)
                (d / 'USOSPID.KEY').write_bytes(OEM_ID.encode() + b'\r\n')
                (d / 'USOSPID.DRV').write_bytes(b'MZ')
                if mini is not None:
                    (d / 'USOSMINI.TXT').write_bytes(mini.encode())
                rc, out, err = sh('log() { printf "%s\\n" "$*"; }\n' f'mini_bridge={bridge}\nwork="{work.as_posix()}"\n' + block)
                self.assertEqual(rc, 0, err)
                self.assertEqual((d / 'USOSPID.KEY').exists(), kept)
                self.assertEqual((d / 'USOSPID.DRV').exists(), kept)
                self.assertNotIn(OEM_ID[6:], out)

    def test_target_wiring(self):
        text = TARGET.read_text()
        self.assertIn('if [ "$SYSTEM_TAG" = 95 ] && [ "$VM_PHASE1" != 1 ]; then', text)
        self.assertNotIn('pid_mode', text)
        self.assertIn('pid_result=$(w9x_pid95_prepare "$work/c/USOS9X/MSBATCH.INF") ||', text)
        # The key is taken before the drop, the mini-Windows step comes after both.
        self.assertLess(text.index('w9x_pid95_stage_key "$work/c/USOS9X/MSBATCH.INF"'), text.index('pid_result=$(w9x_pid95_prepare'))
        self.assertLess(text.index('pid_result=$(w9x_pid95_prepare'), text.index('usos-fb-ui --w9x-setup-mini'))
        self.assertLess(text.index('usos-fb-ui --w9x-setup-mini'), text.index("grep -qx 'pid=on'"))
        # After the answer copy, before INSTALL.BAT copies it next to SETUP.EXE.
        self.assertLess(text.index('cp "$ANSWER_INF" "$work/c/USOS9X/MSBATCH.INF"'), text.index('w9x_pid95_prepare'))
        self.assertIn('("tools/w9x_pid95.sh", "usr/lib/usos/w9x_pid95.sh")', (ROOT / 'tools/build_micro_linux.py').read_text())


if __name__ == '__main__':
    unittest.main()
