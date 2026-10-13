"""Target disk wait and "no target disk" diagnostics (tools/target_disk_wait.sh).

X470 2026-10-13 (B261013-184439): after a Windows 7 x86 run on the Micron
NVMe stopped in WinPE, the Vista x86 preparation logged only "DISK /dev/sda
REJECT USOS stick" and stopped with "no target disk". The disk pickers of
steps 600 / 610 / 620 now wait up to 60 s while an NVMe controller has no
disk yet, log lsblk / PCI storage controllers / dmesg to the ESP log, and
say whether the NVMe controller is missing from PCI. Diagnostics only: no
disk is chosen or changed by this helper.

Runs the helper under sh with a fake sysfs and stubbed lsblk / mdev / sleep.
"""
import json
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'tools'
LIB = TOOLS / 'target_disk_wait.sh'
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'

STUBS = r'''
SLEPT=0
mdev() { :; }
sleep() { SLEPT=$((SLEPT + 1)); }
dmesg() { printf '%s\n' '[    1.0] nvme nvme0: pci function 0000-01-00.0' '[    1.1] usb 1-1: new device' '[    2.0] ahci 0000-02-00.1: AHCI 0001.0301'; }
modprobe() { printf 'MODPROBE %s\n' "$1" >> "$T/events"; }
usos_ui_stage() { printf 'STAGE %s %s %s|%s\n' "$1" "$2" "$3" "$4" >> "$T/events"; }
log() { printf 'LOG %s\n' "$*" >> "$T/events"; }
lsblk() {
    case "$*" in
        *NAME,TYPE,MODEL*) printf '/dev/sda disk SanDisk 3.2Gen1 01014c 61530000000 0\n' ;;
        *) printf '/dev/sda disk\n'; [ -n "${APPEAR_AT:-}" ] && [ "$SLEPT" -ge "$APPEAR_AT" ] && printf '/dev/nvme0n1 disk\n'; return 0 ;;
    esac
}
'''


def pci(root, bdf, cls):
    d = root / 'pci' / bdf
    d.mkdir(parents=True)
    (d / 'class').write_text(cls + '\n')
    (d / 'vendor').write_text('0x1344\n')
    (d / 'device').write_text('0x5411\n')
    (d / 'modalias').write_text('pci:v00001344d00005411sv*\n')


def run(setup, body, appear_at=None):
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        (root / 'pci').mkdir()
        (root / 'block').mkdir()
        setup(root)
        script = (f'T="{root.as_posix()}"; : > "$T/events"\n'
                  f'USOS_DISK_WAIT_PCI="$T/pci"; USOS_DISK_WAIT_BLOCK="$T/block"\n'
                  + (f'APPEAR_AT={appear_at}\n' if appear_at is not None else '')
                  + STUBS + f'. "{LIB.as_posix()}"\n' + body + '\nprintf "SLEPT=%s\\n" "$SLEPT"\n')
        out = subprocess.run([SH, '-c', script], capture_output=True, text=True, encoding='utf-8', timeout=60)
        events = (root / 'events').read_text(encoding='utf-8')
        return out.returncode, out.stdout, events


def catalog():
    data = json.loads((ROOT / 'installer/internal/i18n/locales/en.json').read_text(encoding='utf-8'))
    return {v for k, v in data.items() if k.startswith('boot.lx.')}


def in_catalog(text, values):
    return text in values or any('{' in v and re.fullmatch(re.sub(r'\\{\d\\}', '.+', re.escape(v)), text) for v in values)


class TargetDiskWait(unittest.TestCase):
    def test_other_disk_present_returns_at_once(self):
        code, out, events = run(lambda r: None, 'usos_target_disk_wait /dev/sdb log 3 5; echo RC=$?')
        self.assertIn('RC=0', out)
        self.assertIn('SLEPT=0', out)
        self.assertNotIn('STAGE', events)

    def test_no_nvme_controller_waits_10_s_and_says_power_off(self):
        code, out, events = run(lambda r: pci(r, '0000-02-00.1', '0x010601'),
                                'usos_target_disk_wait /dev/sda log 3 5; echo RC=$?; usos_target_disk_stop')
        self.assertIn('RC=1', out)
        self.assertIn('SLEPT=10', out)
        self.assertNotIn('STAGE', events)
        self.assertIn('no NVMe controller is visible on PCI', out)
        self.assertIn('power off, not restart', out)
        self.assertIn('LOG DISK WAIT no disk other than /dev/sda after 10 s', events)

    def test_nvme_controller_without_disk_waits_60_s_with_countdown(self):
        code, out, events = run(lambda r: pci(r, '0000-01-00.0', '0x010802'),
                                'usos_target_disk_wait /dev/sda log 3 5; echo RC=$?; usos_target_disk_stop')
        self.assertIn('RC=1', out)
        self.assertIn('SLEPT=60', out)
        self.assertIn('MODPROBE pci:v00001344d00005411sv*', events)
        self.assertIn('STAGE 3 5 Detecting disks|Waiting for the NVMe disk to appear: 50 s left.', events)
        self.assertIn('STAGE 3 5 Detecting disks|Waiting for the NVMe disk to appear: 1 s left.', events)
        self.assertIn('LOG DISK WAIT NVMe controller(s) 0000-01-00.0 present', events)
        self.assertIn('the NVMe controller is on PCI, but its disk did not appear within 60 s', out)

    def test_nvme_disk_appearing_late_is_taken(self):
        code, out, events = run(lambda r: pci(r, '0000-01-00.0', '0x010802'),
                                'usos_target_disk_wait /dev/sda log 3 5; echo RC=$?', appear_at=15)
        self.assertIn('RC=0', out)
        self.assertIn('SLEPT=15', out)
        self.assertIn('LOG DISK WAIT another disk appeared after 15 s', events)

    def test_nvme_namespace_present_gives_plain_stop(self):
        def setup(r):
            pci(r, '0000-01-00.0', '0x010802')
            (r / 'block' / 'nvme0n1').mkdir()
            (r / 'block' / 'nvme0n1p1').mkdir()
        code, out, events = run(setup, 'echo "N=$(usos_nvme_block_count)"; usos_target_disk_stop')
        self.assertIn('N=1', out)
        self.assertIn('No target disk found (only the USOS stick). No disk was changed.', out)

    def test_report(self):
        def setup(r):
            pci(r, '0000-01-00.0', '0x010802')
            pci(r, '0000-02-00.1', '0x010601')
            pci(r, '0000-03-00.0', '0x030000')
        code, out, events = run(setup, 'usos_target_disk_report')
        self.assertIn('--- lsblk -bdnpo NAME,TYPE,MODEL,SERIAL,SIZE,RO ---', out)
        self.assertIn('/dev/sda disk SanDisk', out)
        self.assertIn('PCI 0000-01-00.0 class=0x010802', out)
        self.assertIn('PCI 0000-02-00.1 class=0x010601', out)
        self.assertNotIn('0000-03-00.0', out)
        self.assertIn('driver=none', out)
        self.assertIn('PCI storage controllers=2 nvme_controllers=1 nvme_block_devices=0', out)
        self.assertIn('nvme nvme0: pci function', out)  # dmesg stub
        self.assertIn('ahci 0000-02-00.1', out)
        self.assertNotIn('usb 1-1', out)


class TargetDiskWaitWiring(unittest.TestCase):
    FLOWS = ('vista_csmwrap_prepare.sh', 'vista_disk_prepare.sh', 'w9x_csmwrap_prepare.sh')

    def test_flows_use_the_helper(self):
        for name in self.FLOWS:
            text = (TOOLS / name).read_text(encoding='utf-8')
            self.assertIn('. /usr/lib/usos/target_disk_wait.sh', text, name)
            self.assertIn('usos_target_disk_wait "$USOS_DISK_DEVICE"', text, name)
            self.assertNotIn('for attempt in 1 2 3 4 5 6 7 8 9 10', text, name)
            self.assertIn('stop "$(usos_target_disk_stop)"', text, name)
            report = [l for l in text.splitlines() if 'usos_target_disk_report' in l]
            self.assertEqual(len(report), 1, name)
            if name.startswith('vista'):
                self.assertIn('usos_stick_write usos_esp_append', report[0], name)
            else:
                self.assertIn('"$W9X_LOG/prepare.log"', report[0], name)  # flushed by stop()
            self.assertRegex(text, r'mv -f [^\n]*prepare\.log[^\n]*prepare\.log\.previous', name)
        build = (TOOLS / 'build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/target_disk_wait.sh", "usr/lib/usos/target_disk_wait.sh")', build)

    def test_user_texts_are_translated(self):
        values = catalog()
        lib = LIB.read_text(encoding='utf-8')
        texts = re.findall(r"printf '%s' '([^']*)'", lib)
        self.assertEqual(len(texts), 3)
        stage = re.search(r'"Waiting for the NVMe disk to appear: \$\(\(usos_tw_max - usos_tw_n\)\) s left\."', lib)
        self.assertIsNotNone(stage)
        texts.append('Waiting for the NVMe disk to appear: 7 s left.')
        for t in texts:
            self.assertTrue(in_catalog(t, values), t)
        for locale in (ROOT / 'installer/internal/i18n/locales').glob('*.json'):
            data = json.loads(locale.read_text(encoding='utf-8'))
            for key in ('boot.lx.disk_wait_nvme_countdown', 'boot.lx.no_target_disk_no_nvme_controller', 'boot.lx.no_target_disk_nvme_no_disk'):
                self.assertIn(key, data, locale.name)
            self.assertIn('{0}', data['boot.lx.disk_wait_nvme_countdown'], locale.name)


class X86CsmwrapDiskReport(unittest.TestCase):
    def test_find_disk_logs_and_cmd_reports(self):
        c = (TOOLS / 'windows_x86_csmwrap.c').read_text(encoding='utf-8')
        body = c[c.index('static BOOL find_disk(BOOL verbose)'):c.index('static BOOL mbr_io(')]
        for want in ('logx("expected MBR signature=", signature)', 'describe_disk(n, h)', 'open failed, error=',
                     'not present='):
            self.assertIn(want, body)
        describe = c[c.index('static void describe_disk('):c.index('static BOOL find_disk(')]
        for want in (' bus=', ' removable=', ' size_mib=', ' style=MBR signature=0x', 'style=GPT', 'serial='):
            self.assertIn(want, describe)
        # Read-only: the inventory never opens a disk for writing.
        self.assertNotIn('GENERIC_WRITE', describe + body)
        self.assertIn('find_disk(verbose) && (verbose || !find_disk(TRUE))', c)
        cmd = (TOOLS / 'windows_x86_csmwrap.cmd').read_text(encoding='utf-8')
        self.assertIn('if "%USOS_BEFORE_RESULT%"=="4" call :disk_report', cmd)
        start = cmd.index('\n:disk_report\n')
        report = cmd[start:cmd.index('exit /b 0', start)]
        for want in ('echo list disk', 'echo list volume', 'diskpart /s', '/enum-devices /class %%C', '/enum-devices /problem', 'usos-log-x86.exe'):
            self.assertIn(want, report)
        # The diskpart script holds the two list commands only.
        script = [l for l in report.splitlines() if 'USOS_DP_SCRIPT%"' in l and 'echo' in l]
        self.assertEqual([l.split(' echo ', 1)[1] for l in script], ['list disk', 'list volume'])


if __name__ == '__main__':
    unittest.main()
