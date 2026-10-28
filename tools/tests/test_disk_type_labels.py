"""Disk type in the micro-Linux pickers (tools/target_disk_identity.sh).

Host only: lsblk, smartctl, timeout and readlink are shell stubs and sysfs is
a temporary tree, so no disk is touched. Covers bus detection (lsblk TRAN, the
SCSI host driver and the sysfs path fallback: NVMe, SATA, IDE, SCSI, SAS, USB,
eMMC/SD, VirtIO), SSD/HDD/SSHD from ATA IDENTIFY and queue/rotational, the
picker items (model, size, S/N as text; bus and media as badge= chip lines for
src/platform/linux/fb_disk_badge.zig) and the "Type:" confirmation line.
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

    def host(self, number, driver):
        host = self.sysfs / 'class/scsi_host' / f'host{number}'
        host.mkdir(parents=True, exist_ok=True)
        (host / 'proc_name').write_text(f'{driver}\n')

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

    def badges(self, name):
        return self.run_shell(f'usos_disk_badges /dev/{name}')

    def test_nvme_is_always_ssd(self):
        self.disk('nvme0n1', tran='nvme')
        self.assertEqual(self.kind('nvme0n1'), 'NVMe SSD')
        self.assertEqual(self.badges('nvme0n1'), 'badge=nvme\nbadge=ssd\n')

    def test_sata_media_from_identify(self):
        self.disk('sda', tran='sata', rotational=1)
        self.ata_identify('sda', '0001')
        self.assertEqual(self.kind('sda'), 'SATA SSD')
        self.ata_identify('sda', '1c20')
        self.assertEqual(self.kind('sda'), 'SATA HDD')
        self.ata_identify('sda', '1c20', w78='0200')
        self.assertEqual(self.kind('sda'), 'SATA SSHD')
        self.assertEqual(self.badges('sda'), 'badge=sata\nbadge=sshd\n')

    def test_sata_falls_back_to_rotational_and_never_guesses(self):
        self.disk('sdb', tran='sata', rotational=0)
        self.assertEqual(self.kind('sdb'), 'SATA SSD')
        self.disk('sdc', tran='sata', rotational=1)
        self.assertEqual(self.kind('sdc'), 'SATA HDD')
        self.disk('sdd', tran='sata')
        self.assertEqual(self.kind('sdd'), 'SATA')
        self.assertEqual(self.badges('sdd'), 'badge=sata\n')
        # IDENTIFY without a rotation rate: rotational decides.
        self.disk('sde', tran='sata', rotational=0)
        self.ata_identify('sde', '0000')
        self.assertEqual(self.kind('sde'), 'SATA SSD')

    def test_ide_from_pata_link_and_legacy_ide_drivers(self):
        self.disk('sdf', tran='ata', rotational=1)
        self.assertEqual(self.kind('sdf'), 'IDE HDD')
        # QEMU i440fx or a board in IDE mode: ata_piix, even when lsblk says sata.
        self.host(2, 'ata_piix')
        self.disk('sdj', tran='sata', rotational=1, link='/sys/devices/pci0000:00/0000:00:01.1/ata3/host2/target2:0:0/2:0:0:0/block/sdj')
        self.ata_identify('sdj', '0001')
        self.assertEqual(self.badges('sdj'), 'badge=ide\nbadge=ssd\n')
        self.host(3, 'pata_atiixp')
        self.disk('sdk', rotational=1, link='/sys/devices/pci0000:00/0000:00:14.1/ata5/host3/target3:0:0/3:0:0:0/block/sdk')
        self.assertEqual(self.kind('sdk'), 'IDE HDD')
        # AHCI (also in RAID mode) stays SATA.
        self.host(4, 'ahci')
        self.disk('sdl', rotational=0, link='/sys/devices/pci0000:00/0000:00:17.0/ata6/host4/target4:0:0/4:0:0:0/block/sdl')
        self.assertEqual(self.kind('sdl'), 'SATA SSD')

    def test_sas_and_scsi_hosts(self):
        self.host(5, 'mpt3sas')
        self.disk('sdm', rotational=1, link='/sys/devices/pci0000:00/0000:00:03.0/0000:02:00.0/host5/port-5:0/end_device-5:0/target5:0:0/5:0:0:0/block/sdm')
        self.assertEqual(self.badges('sdm'), 'badge=sas\nbadge=hdd\n')
        self.disk('sdn', tran='sas', rotational=0)
        self.assertEqual(self.kind('sdn'), 'SAS SSD')
        self.host(6, 'sym53c8xx')
        self.disk('sdo', tran='spi', rotational=1, link='/sys/devices/pci0000:00/0000:00:05.0/host6/target6:0:0/6:0:0:0/block/sdo')
        self.assertEqual(self.kind('sdo'), 'SCSI HDD')
        # A RAID volume behind megaraid_sas: honest "SCSI", media only from rotational.
        self.host(7, 'megaraid_sas')
        self.disk('sdp', link='/sys/devices/pci0000:00/0000:00:02.0/0000:03:00.0/host7/target7:2:0/7:2:0:0/block/sdp')
        self.assertEqual(self.badges('sdp'), 'badge=scsi\n')
        # virtio-scsi is VirtIO, without media.
        self.host(8, 'virtio_scsi')
        self.disk('sdq', rotational=1, link='/sys/devices/pci0000:00/0000:00:06.0/virtio2/host8/target8:0:0/8:0:0:0/block/sdq')
        self.assertEqual(self.badges('sdq'), 'badge=virtio\n')

    def test_mmc_kinds(self):
        self.disk('mmcblk0', link='/sys/devices/pci0000:00/0000:00:1c.0/mmc_host/mmc0/mmc0:0001/block/mmcblk0')
        device = self.sysfs / 'class/block/mmcblk0/device'
        device.mkdir(parents=True)
        (device / 'type').write_text('MMC\n')
        self.assertEqual(self.badges('mmcblk0'), 'badge=emmc\n')
        self.assertEqual(self.kind('mmcblk0'), 'eMMC')
        (device / 'type').write_text('SD\n')
        self.assertEqual(self.kind('mmcblk0'), 'SD')

    def test_usb_shows_the_bus_only(self):
        self.disk('sdg', tran='usb', rotational=1)
        self.ata_identify('sdg', '0001')
        self.assertEqual(self.kind('sdg'), 'USB')
        self.assertEqual(self.badges('sdg'), 'badge=usb\n')

    def test_sysfs_path_fallback(self):
        self.disk('sdh', rotational=0, link='/sys/devices/pci0000:00/0000:00:01.3/0000:03:00.1/ata2/host1/target1:0:0/1:0:0:0/block/sdh')
        self.assertEqual(self.kind('sdh'), 'SATA SSD')
        self.disk('sdi', rotational=0, link='/sys/devices/pci0000:00/0000:00:08.1/0000:05:00.3/usb4/4-1/4-1:1.0/host6/target6:0:0/6:0:0:0/block/sdi')
        self.assertEqual(self.kind('sdi'), 'USB')
        self.disk('nvme1n1', link='/sys/devices/pci0000:00/0000:00:01.1/0000:01:00.0/nvme/nvme1/nvme1n1')
        self.assertEqual(self.kind('nvme1n1'), 'NVMe SSD')
        self.disk('vda', rotational=1, link='/sys/devices/pci0000:00/0000:00:04.0/virtio1/block/vda')
        self.assertEqual(self.kind('vda'), 'VirtIO')

    def test_unknown_bus_prints_nothing(self):
        self.disk('sdz', link='/sys/devices/platform/somewhere/block/sdz')
        self.assertEqual(self.run_shell('usos_disk_type /dev/sdz && echo yes || echo no'), 'no\n')
        self.assertEqual(self.run_shell('usos_disk_picker_name /dev/sdz'), 'Model X')
        self.assertEqual(self.badges('sdz'), '')
        self.assertEqual(self.run_shell('usos_disk_type_line /dev/sdz'), '')
        self.disk('sdy', model='')
        self.assertEqual(self.run_shell('usos_disk_picker_name /dev/sdy'), 'sdy')

    def test_picker_items_carry_chips_not_type_text(self):
        self.disk('nvme0n1', tran='nvme', model='Micron 3400 512GB', serial='22283A7B', size=512110190592)
        self.disk('sda', tran='sata', rotational=1, model='ST2000DM008', serial='ZFL1', size=2000398934016)
        self.ata_identify('sda', '1c20', w78='0200')
        candidates = self.root / 'candidates'
        candidates.write_text('1|/dev/nvme0n1\n2|/dev/sda\n')
        # usos_xp_choose_disk writes /run/xp-disk-menu.state; run its loop
        # body here instead of touching /run.
        lines = (ROOT / 'tools/xp_menu_ui.sh').read_text().splitlines()
        start = next(i for i, text in enumerate(lines) if text.lstrip().startswith("while IFS='|' read -r index candidate"))
        end = next(i for i in range(start, len(lines)) if lines[i].lstrip().startswith('done < "$CANDIDATES"'))
        body = '\n'.join(lines[start:end]) + f'\ndone < "{candidates.as_posix()}"\n'
        out = self.run_shell(body)
        self.assertEqual(out, 'item=Micron 3400 512GB (476 GiB)|S/N: 22283A7B\nbadge=nvme\nbadge=ssd\n'
                              'item=ST2000DM008 (1863 GiB)|S/N: ZFL1\nbadge=sata\nbadge=sshd\n')
        self.assertEqual(self.run_shell('usos_disk_type_line /dev/sda'), 'Type: SATA SSHD\n')


if __name__ == '__main__':
    unittest.main()
