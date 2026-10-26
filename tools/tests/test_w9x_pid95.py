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

    def run_prepare(self, mode='split'):
        rc, out, err = sh(f'. "{LIB}"\nw9x_pid95_prepare "$I" "$B" {mode}',
                          {'I': self.inf.as_posix(), 'B': self.bin.as_posix()})
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

    def test_oem_id_is_split_and_reassembles_without_overflow(self):
        self.stage(OEM_ID)
        before = self.bin.read_bytes()
        rc, out, err = self.run_prepare()
        self.assertEqual((rc, out), (0, 'oem-split'), err)
        tail = self.setup_pid()
        self.assertEqual(tail, OEM_ID[6:])
        self.assertEqual(len(tail), 17)
        after = self.bin.read_bytes()
        self.assertEqual(len(after), len(before))
        at = before.index(TEMPLATE) + 5
        self.assertEqual(after[at:at + 17], OEM_ID[:6].encode() + b'x' * 11)
        self.assertEqual(after[:at], before[:at])
        self.assertEqual(after[at + 17:], before[at + 17:])
        u_value = after[at:at + 17].decode()
        pid, batch = suwin_model(u_value, tail, BATCH)
        self.assertEqual(pid, OEM_ID)
        self.assertEqual(batch, BATCH)

    def test_only_setup_productid_changes_and_crlf_stays(self):
        self.stage(OEM_ID)
        self.run_prepare()
        text = self.inf.read_bytes()
        self.assertEqual(text.count(b'\n'), text.count(b'\r\n'))
        self.assertIn(b'ProductID="not-in-setup"\r\n', text)   # [NameAndOrg] untouched
        self.assertIn(b'Express=1\r\nEBD=0\r\n', text)
        self.assertNotIn(OEM_ID.encode(), text)

    def test_retail_and_missing_ids_are_kept(self):
        for value in (RETAIL_ID, None):
            self.stage(value)
            inf, binary = self.inf.read_bytes(), self.bin.read_bytes()
            rc, out, _ = self.run_prepare()
            self.assertEqual((rc, out), (0, 'kept'), value)
            self.assertEqual(self.inf.read_bytes(), inf)
            self.assertEqual(self.bin.read_bytes(), binary)

    def test_no_unique_template_drops_the_id(self):
        for template, copies in ((b'\x15 /U:' + b'y' * 17, 1), (TEMPLATE, 2)):
            self.stage(OEM_ID, template, copies)
            binary = self.bin.read_bytes()
            rc, out, _ = self.run_prepare()
            self.assertEqual((rc, out), (0, 'dropped'))
            self.assertEqual(self.setup_pid(), '')
            self.assertEqual(self.bin.read_bytes(), binary)

    def test_without_split_mode_long_ids_are_dropped(self):
        self.stage(OEM_ID)
        binary = self.bin.read_bytes()
        rc, out, _ = self.run_prepare(mode='')
        self.assertEqual((rc, out), (0, 'dropped'))
        self.assertEqual(self.setup_pid(), '')
        self.assertEqual(self.bin.read_bytes(), binary)

    def test_second_run_keeps_the_split(self):
        self.stage(OEM_ID)
        self.run_prepare()
        inf, binary = self.inf.read_bytes(), self.bin.read_bytes()
        rc, out, _ = self.run_prepare()
        self.assertEqual((rc, out), (0, 'kept'))
        self.assertEqual((self.inf.read_bytes(), self.bin.read_bytes()), (inf, binary))

    def test_target_block_runs(self):
        text = TARGET.read_text()
        block = text[text.index('# Windows 95 with a native phase 1: SUWIN'):text.index("# Display: the answer's")]
        cases = (('95', '4 0 0 950', '0', 'PROFILE', 'oem-split', OEM_ID[6:]),
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
            if kind == 'USER':
                self.assertIn('warning: the answer file ProductID has 18+ characters', out)

    def test_target_wiring(self):
        text = TARGET.read_text()
        self.assertIn('if [ "$SYSTEM_TAG" = 95 ] && [ "$VM_PHASE1" != 1 ]; then', text)
        self.assertIn('[ "${setup_version:-}" != \'4 0 0 950\' ] || pid_mode=split', text)
        self.assertIn('w9x_pid95_prepare "$work/c/USOS9X/MSBATCH.INF" "$work/c/$SETUP_FOLDER/WINSETUP.BIN" $pid_mode', text)
        # After the answer copy, before INSTALL.BAT copies it next to SETUP.EXE.
        self.assertLess(text.index('cp "$ANSWER_INF" "$work/c/USOS9X/MSBATCH.INF"'), text.index('w9x_pid95_prepare'))
        self.assertIn('("tools/w9x_pid95.sh", "usr/lib/usos/w9x_pid95.sh")', (ROOT / 'tools/build_micro_linux.py').read_text())


if __name__ == '__main__':
    unittest.main()
