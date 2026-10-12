"""Disk type labels in the micro-Linux pickers (tools/target_disk_identity.sh).

Host only: lsblk, smartctl, timeout and readlink are shell stubs and sysfs is
a temporary tree, so no disk is touched. Covers bus detection (lsblk TRAN and
the sysfs path fallback), SSD/HDD/SSHD from ATA IDENTIFY and queue/rotational,
the XP/Vista/9x picker line and the "Type:" confirmation line.
"""
from pathlib import Path
import os, shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
BASH = r'C:\Program Files\Git\bin\bash.exe' if os.name == 'nt' else shutil.which('bash')

# smartctl --identify=w rows (format of smartmontools 7.x ataidentify.cpp).
IDENTIFY = '''smartctl 7.5 2025-04-30 r5714 [x86_64-linux] (local build)

ATA IDENTIFY DEVICE data:
Word     Value   Description
   0      0x{w0}   General configuration
  57-58   0x00fc   Current capacity in sectors (DWord) [OBS-6]
  78      0x{w78}   Serial ATA features supported
  78      9       {hybrid}   Hybrid Information supported
 217      0x{w217}   Nominal media rotation rate
'''

HARNESS = r'''
set -eu
. "$IDENTITY"
lsblk() {
    # lsblk -b -dno COLUMN DEVICE
    printenv "FIX_$(basename "$4")_$3" || true
}
readlink() { printenv "LINK_$(basename "$2")" || printf '%s' "$2"; }
timeout() { shift; "$@"; }
smartctl() {
    for last; do :; done
    file="$IDENTIFY_DIR/$(basename "$last")"
    [ -f "$file" ] || return 2
    cat "$file"
}
'''


class DiskTypeLabels(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sysfs = self.root / 'sys'
        self.identify = self.root / 'identify'
        self.identify.mkdir()
        self.env = {}

    def disk(self, name, tran='', rotational=None, link=None, model='Model X', serial='SN1', size=500107862016):
        self.env.update({f'FIX_{name}_TRAN': tran, f'FIX_{name}_MODEL': model,
                         f'FIX_{name}_SERIAL': serial, f'FIX_{name}_SIZE': str(size)})
        queue = self.sysfs / 'class/block' / name / 'queue'
        queue.mkdir(parents=True, exist_ok=True)
        if rotational is not None:
            (queue / 'rotational').write_text(f'{rotational}\n')
        if link:
            self.env[f'LINK_{name}'] = link

    def ata_identify(self, name, w217, w78='0000'):
        hybrid = (int(w78, 16) >> 9) & 1
        (self.identify / name).write_text(IDENTIFY.format(w0='0040', w78=w78, w217=w217, hybrid=hybrid))

    def run_shell(self, command):
        env = os.environ | self.env | {
            'IDENTITY': (ROOT / 'tools/target_disk_identity.sh').as_posix(),
            'USOS_SYSFS': self.sysfs.as_posix(),
            'IDENTIFY_DIR': self.identify.as_posix(),
        }
        result = subprocess.run([BASH, '--noprofile', '--norc', '-c', HARNESS + command],
                                env=env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout

    def kind(self, name):
        return self.run_shell(f'usos_disk_type /dev/{name} || true')

    def test_nvme_is_always_ssd(self):
        self.disk('nvme0n1', tran='nvme')
        self.assertEqual(self.kind('nvme0n1'), 'M.2 NVMe SSD')

    def test_sata_media_from_identify(self):
        self.disk('sda', tran='sata', rotational=1)
        self.ata_identify('sda', '0001')
        self.assertEqual(self.kind('sda'), 'SATA SSD')
        self.ata_identify('sda', '1c20')
        self.assertEqual(self.kind('sda'), 'SATA HDD')
        self.ata_identify('sda', '1c20', w78='0200')
        self.assertEqual(self.kind('sda'), 'SATA SSHD')

    def test_sata_falls_back_to_rotational_and_never_guesses(self):
        self.disk('sdb', tran='sata', rotational=0)
        self.assertEqual(self.kind('sdb'), 'SATA SSD')
        self.disk('sdc', tran='sata', rotational=1)
        self.assertEqual(self.kind('sdc'), 'SATA HDD')
        self.disk('sdd', tran='sata')
        self.assertEqual(self.kind('sdd'), 'SATA')
        # IDENTIFY without a rotation rate: rotational decides.
        self.disk('sde', tran='sata', rotational=0)
        self.ata_identify('sde', '0000')
        self.assertEqual(self.kind('sde'), 'SATA SSD')

    def test_pata_controller_says_ata(self):
        self.disk('sdf', tran='ata', rotational=1)
        self.assertEqual(self.kind('sdf'), 'ATA HDD')

    def test_usb_shows_the_bus_only(self):
        self.disk('sdg', tran='usb', rotational=1)
        self.ata_identify('sdg', '0001')
        self.assertEqual(self.kind('sdg'), 'USB')

    def test_sysfs_path_fallback(self):
        self.disk('sdh', rotational=0, link='/sys/devices/pci0000:00/0000:00:01.3/0000:03:00.1/ata2/host1/target1:0:0/1:0:0:0/block/sdh')
        self.assertEqual(self.kind('sdh'), 'SATA SSD')
        self.disk('sdi', rotational=0, link='/sys/devices/pci0000:00/0000:00:08.1/0000:05:00.3/usb4/4-1/4-1:1.0/host6/target6:0:0/6:0:0:0/block/sdi')
        self.assertEqual(self.kind('sdi'), 'USB')
        self.disk('nvme1n1', link='/sys/devices/pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme1/nvme1n1')
        self.assertEqual(self.kind('nvme1n1'), 'M.2 NVMe SSD')
        self.disk('vda', link='/sys/devices/pci0000:00/0000:00:04.0/virtio1/block/vda')
        self.assertEqual(self.kind('vda'), 'VirtIO')

    def test_unknown_bus_prints_nothing(self):
        self.disk('sdz', link='/sys/devices/platform/somewhere/block/sdz')
        self.assertEqual(self.run_shell('usos_disk_type /dev/sdz && echo yes || echo no'), 'no\n')
        self.assertEqual(self.run_shell('usos_disk_type_model /dev/sdz'), 'Model X')
        self.assertEqual(self.run_shell('usos_disk_type_line /dev/sdz'), '')

    def test_picker_line_and_confirmation_line(self):
        self.disk('nvme0n1', tran='nvme', model='Micron 3400 512GB', serial='22283A7B', size=512110190592)
        self.disk('sda', tran='sata', rotational=1, model='ST2000DM008', serial='ZFL1', size=2000398934016)
        self.ata_identify('sda', '1c20', w78='0200')
        candidates = self.root / 'candidates'
        candidates.write_text('1|/dev/nvme0n1\n2|/dev/sda\n')
        # usos_xp_choose_disk writes /run/xp-disk-menu.state; render the item
        # lines with the same printf instead of touching /run.
        line = (ROOT / 'tools/xp_menu_ui.sh').read_text().splitlines()
        item = next(text for text in line if text.lstrip().startswith("printf 'item=%s (%s GiB)"))
        self.assertIn('usos_disk_type_model', item)
        out = self.run_shell(f'''
            while IFS='|' read -r index candidate; do
            {item.strip()}
            done < "{candidates.as_posix()}"
        ''')
        self.assertEqual(out, 'item=M.2 NVMe SSD - Micron 3400 512GB (476 GiB)|S/N: 22283A7B\n'
                              'item=SATA SSHD - ST2000DM008 (1863 GiB)|S/N: ZFL1\n')
        self.assertEqual(self.run_shell('usos_disk_type_line /dev/sda'), 'Type: SATA SSHD\n')


if __name__ == '__main__':
    unittest.main()
