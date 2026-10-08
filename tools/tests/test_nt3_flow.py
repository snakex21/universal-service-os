"""Windows NT 3.51 through the UEFI flow: the NT 4.0 VM flow with NT_MAJOR=3
(tools/nt4_csmwrap_target.sh, tools/nt4_qemu_install.sh, the NT 3.51 branch
of tools/w9x_csmwrap_prepare.sh, tools/build_micro_linux.py;
docs/nt351-2026-10-08.md). Host only: Git sh, temp folders; no VM, no disk.
"""
from pathlib import Path
import shutil
import tempfile
import unittest

from test_nt4_flow import function_text
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
QEMU_INSTALL = ROOT / 'tools/nt4_qemu_install.sh'
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'
BUILD = ROOT / 'tools/build_micro_linux.py'
GOLDEN = ROOT / 'src/flow/answer/testdata/golden/default.windows-nt-3-51.WINNT.SIF'
RENDERER = ROOT / 'src/flow/answer/nt3.zig'


class Nt3DefaultAnswer(unittest.TestCase):
    """The micro-Linux default WINNT.SIF (no profile) is the UEFI renderer's
    default-profile output byte for byte (nt3.zig tests the same golden)."""

    def run_default(self, zone=''):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt3-sif-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        fn = function_text(PREPARE, 'w9x_nt3_default_sif')
        out = tmp / 'out.sif'
        rc, _, err = sh(f'{fn}\nw9x_nt3_default_sif "{zone}" > "{out.as_posix()}"')
        self.assertEqual(rc, 0, err)
        return out.read_bytes()

    def test_golden_bytes(self):
        golden = GOLDEN.read_bytes()
        self.assertEqual(self.run_default(), golden)
        text = golden.decode('ascii')
        self.assertTrue(text.startswith('; WINNT.SIF rendered by USOS for Windows NT 3.51 (docs/nt351-2026-10-08.md)\r\n'))
        self.assertNotIn('\n', text.replace('\r\n', ''))
        for want in ('[Data]\r\nMsDosInitiated = 1\r\nFloppyless = 1\r\n',
                     '[Unattended]\r\nMethod = express\r\nConfirmHardware = no\r\nNtUpgrade = no\r\nWin31Upgrade = no\r\n'
                     'TargetPath = \\WINNT\r\nOverwriteOemFilesOnUpgrade = no\r\n',
                     '[GuiUnattended]\r\n!SetupNetwork = NO\r\n!SetupApplications = NO\r\n',
                     '[UserData]\r\n!FullName = "USOS"\r\n!OrgName = "USOS"\r\n!ComputerName = USOS-NT351\r\n',
                     '[LicenseFilePrintData]\r\n\r\n[NetworkAdapterData]\r\n\r\n[TransportData]\r\n\r\n[DomainData]\r\n'):
            self.assertIn(want, text)
        # NT 3.51: no key, no $OEM$, no HAL pin, VGA only.
        for absent in ('ProductId', 'OemPreinstall', 'ComputerType', '[Display]'):
            self.assertNotIn(absent, text)

    def test_time_zone_marker(self):
        out = self.run_default('Central European').decode('ascii')
        self.assertIn('!SetupApplications = NO\r\n;USOS-TZ=Central European\r\n\r\n[UserData]', out)

    def test_renderer_mirrors_the_text(self):
        zig = RENDERER.read_text(encoding='utf-8')
        self.assertIn('@embedFile("testdata/golden/default.windows-nt-3-51.WINNT.SIF")', zig)
        self.assertIn('.{ .system_id = "windows-nt-3-51", .file = "NT351.SIF" }', zig)
        self.assertIn('.{ .system_id = "windows-nt-3-51-server", .file = "NT351S.SIF" }', zig)


class Nt3Target(unittest.TestCase):
    def test_target_handles_nt3(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('[ -z "${NT_MAJOR:-}" ] || [ "$NT_MAJOR" = "$major" ]', text)
        self.assertIn('[ -z "$nt3" ] || mbr_code=$LIB/nt3-e820-mbr-440.bin', text)
        # winnt.exe's ~BT\SYSTEM32 (0x6B C000003A without it).
        self.assertIn('cp "$bt_dir/USETUP.EXE" "$bt_dir/SYSTEM32/SMSS.EXE"', text)
        self.assertIn('cp "$bt_dir/NTDLL.DLL" "$bt_dir/SYSTEM32/NTDLL.DLL"', text)
        self.assertIn('for file in AHCINT.SYS USOSRST.SYS USOSUSB.SYS USOSNT3.EXE; do', text)
        self.assertIn('| nt4_server_answer "${product:-0}" yes | nt3_detached_answer', text)
        # Flat local source (DOSNET d1 = \), renamed [FloppyFiles] entries, SIZE.SIF.
        self.assertIn('[ -z "$nt3" ] || ls_src=$ls_dir', text)
        self.assertIn(r'/^\[floppyfiles\./', text)
        self.assertIn('> "$ls_src/SIZE.SIF"', text)
        # The autochk stand-in in the local source, the CD's AUTOCHK.EXE kept.
        self.assertIn('mv "$ls_src/AUTOCHK.EXE" "$usos/AUTOCHK.EXE"', text)
        self.assertIn('cp "$drv/USOSACHK.EXE" "$ls_src/AUTOCHK.EXE"', text)
        self.assertIn('autochk.exe restored', QEMU_INSTALL.read_text(encoding='utf-8'))
        # INITIAL.INF reads $(!SetupNetWork) (capital W).
        self.assertIn('printf "!SetupNetWork = %s', text)

    def test_install_vm_uses_a_scsi_disk_for_nt3(self):
        text = QEMU_INSTALL.read_text(encoding='utf-8')
        self.assertIn('NT4_VM_HBA=${NT3_VM_HBA:-am53c974}', text)
        self.assertIn('-device "$NT4_VM_HBA,id=hba" -device scsi-hd,drive=target,bus=hba.0,bootindex=0', text)
        self.assertIn('$(nt4_vm_disk_args "$1")', text)
        self.assertIn('nt4_vm_dirty_only "$loop" "$logs/fsck.txt"', text)
        self.assertIn('set_dword("amsint", NULL, "Start", 4);', (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8'))

    def test_detached_program_keeps_backslashes(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt3-det-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        fn = function_text(TARGET, 'nt3_detached_answer')
        # From a script file: Git sh -c on Windows loses the awk program's
        # backslashes on the command line (a host artifact, not the script's).
        script = tmp / 'run.sh'
        script.write_bytes((fn + f'\nnt3_detached_answer < "{GOLDEN.as_posix()}" > "{(tmp / "out.sif").as_posix()}"\n').encode('utf-8'))
        rc, _, err = sh(f'. "{script.as_posix()}"')
        self.assertEqual(rc, 0, err)
        out = (tmp / 'out.sif').read_bytes().decode('ascii')
        self.assertIn('[GuiUnattended]\r\n!DetachedProgram = "C:\\USOS\\NT3\\USOSNT3.EXE"\r\n!Arguments = "/setup"\r\n'
                      '!SetupNetwork = NO\r\n', out)
        self.assertEqual(out.count('DetachedProgram'), 1)

    def test_standard_pc_hal_for_the_mps_machine_types(self):
        # X470 2026-10-08: halapic.dll (mps_up, picked in the install VM)
        # hung after the banner; the finished system gets the 8259 hal.dll.
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt3-hal-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        sif = tmp / 'TXTSETUP.SIF'
        sif.write_bytes(b'[Map.Computer]\r\nmps_up = "MPS Uniprocessor PC"\r\n'
                        b'[hal]\r\ne_isa_up    = hal.dll     ,2,hal.dll\r\n'
                        b'mps_up      = halapic.dll ,2,hal.dll\r\nmps_mp      = halmps.dll  ,2,hal.dll\r\n'
                        b'[Hal.Load]\r\nmps_up      = halapic.dll\r\n')
        script = tmp / 'run.sh'
        script.write_bytes((function_text(TARGET, 'nt3_standard_hal') +
                            f'\nnt3_standard_hal < "{sif.as_posix()}" > "{(tmp / "out.sif").as_posix()}"\n').encode('utf-8'))
        rc, _, err = sh(f'. "{script.as_posix()}"')
        self.assertEqual(rc, 0, err)
        out = (tmp / 'out.sif').read_bytes()
        self.assertEqual(out, b'[Map.Computer]\r\nmps_up = "MPS Uniprocessor PC"\r\n'
                              b'[hal]\r\ne_isa_up    = hal.dll     ,2,hal.dll\r\n'
                              b'mps_up = hal.dll    ,2,hal.dll\r\nmps_mp = hal.dll    ,2,hal.dll\r\n'
                              b'[Hal.Load]\r\nmps_up      = halapic.dll\r\n')
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('nt3_standard_hal < "$sif" > "$work/txtsetup.hal"', text)
        self.assertIn('for sif in "$work/c/TXTSETUP.SIF" "$bt_dir/TXTSETUP.SIF" "$ls_src/TXTSETUP.SIF"; do', text)

    def test_server_cd_gets_licensing_in_the_empty_section(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt3-srv-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        fn = function_text(TARGET, 'nt4_server_answer')
        rc, _, err = sh(f'{fn}\nnt4_server_answer 1 yes < "{GOLDEN.as_posix()}" > "{(tmp / "out.sif").as_posix()}"')
        self.assertEqual(rc, 0, err)
        out = (tmp / 'out.sif').read_bytes().decode('ascii')
        self.assertIn('[GuiUnattended]\r\n!AdvServerType = SERVERNT\r\n', out)
        self.assertIn('!AutoMode = PerServer\r\n', out)
        self.assertIn('!AutoUsers = 5\r\n', out)

    def test_qemu_install_answers_the_autochk_prompt(self):
        text = QEMU_INSTALL.read_text(encoding='utf-8')
        self.assertIn('W9X_VM_TEXT_ANSWER=${NT3_VM_TEXT_ANSWER:-ret}', text)
        self.assertIn('::/USOS/NT3', text)


class Nt3Prepare(unittest.TestCase):
    def test_prepare_routes_nt3(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('windows-nt-3-51) tag=NT351', text)
        self.assertIn('windows-nt-3-51-server) tag=NT351S', text)
        self.assertIn("NT351|NT351S) nt4=yes nt_major=3 nt_name='Windows NT 3.51'", text)
        self.assertIn("NT4|NT4S) nt4=yes nt_major=4 nt_name='Windows NT 4.0'", text)
        self.assertIn('NT_MAJOR="$nt_major" sh /usr/lib/usos/nt4_csmwrap_target.sh', text)
        # The staged profile files and the SP6a lookup only for NT 4.0.
        self.assertIn('/mnt/esp/EFI/USOS/answer/NT351.SIF /mnt/esp/EFI/USOS/answer/NT351S.SIF', text)
        self.assertIn('if [ "$nt_major" = 4 ]; then', text)
        self.assertIn('3:none)', text)
        self.assertIn('w9x_nt3_default_sif "$time_zone" > "$answer_inf"', text)

    def test_messages_match_the_translations(self):
        # The micro-Linux UI translates by the English text (linux_strings.zig).
        text = PREPARE.read_text(encoding='utf-8')
        lx = (ROOT / 'src/i18n/linux_strings.zig').read_text(encoding='utf-8')
        for nt_name in ('Windows NT 4.0', 'Windows NT 3.51'):
            self.assertIn(f'"{nt_name} installs only in the VM on this PC, which is not available: {{0}}"', lx)
            self.assertIn(f'"The {nt_name} installation did not finish. The computer was not restarted; logs: EFI/USOS/win9x/nt4"', lx)
        self.assertIn('"$nt_name installs only in the VM on this PC, which is not available: $vm_reason"', text)
        self.assertIn('"The $nt_name installation did not finish. The computer was not restarted; logs: EFI/USOS/win9x/nt4"', text)


class Nt3AutochkStandIn(unittest.TestCase):
    """tools/nt3/usosachk: native, PE 3.10, only ntdll!NtTerminateProcess."""

    def test_image(self):
        import struct
        data = (ROOT / 'tools/nt3/usosachk/bin/i386/usosachk.exe').read_bytes()
        pe = struct.unpack_from('<I', data, 0x3C)[0]
        self.assertEqual(data[pe:pe + 4], b'PE\0\0')
        opt = pe + 24
        self.assertEqual(struct.unpack_from('<H', data, opt + 68)[0], 1)  # IMAGE_SUBSYSTEM_NATIVE
        self.assertEqual(struct.unpack_from('<HH', data, opt + 40), (3, 10))
        self.assertEqual(struct.unpack_from('<HH', data, opt + 48), (3, 10))
        self.assertIn(b'NtTerminateProcess', data)
        self.assertIn(b'ntdll.dll', data.lower())


class Nt3MicroLinux(unittest.TestCase):
    def test_file_list(self):
        text = BUILD.read_text(encoding='utf-8')
        for pair in (
            ('tools/vendor/ahcint/1.3.0.0-usos4/bin/NT351/i386/ahcint.sys', 'usr/lib/usos/nt3/AHCINT.SYS'),
            ('tools/w2k/usosrst/bin/nt351/i386/usosrst.sys', 'usr/lib/usos/nt3/USOSRST.SYS'),
            ('tools/nt4/usosusb/bin/i386/usosusb.sys', 'usr/lib/usos/nt3/USOSUSB.SYS'),
            ('tools/nt3/usosnt3/bin/i386/usosnt3.exe', 'usr/lib/usos/nt3/USOSNT3.EXE'),
            ('tools/nt3/usosachk/bin/i386/usosachk.exe', 'usr/lib/usos/nt3/USOSACHK.EXE'),
        ):
            self.assertIn(f'("{pair[0]}", "{pair[1]}")', text)
            self.assertTrue((ROOT / pair[0]).is_file(), pair[0])
        self.assertIn('nt3_e820_mbr = root / "zig-out/xp-geometry-fix-mbr/nt3-e820-mbr-440.bin"', text)
        self.assertIn('xp_geometry_fix_mbr, nt3_e820_mbr):', text)
        self.assertIn('"usr/lib/usos/nt3-e820-mbr-440.bin"', text)


class Nt3Mbr(unittest.TestCase):
    """The NT 3.x MBR clears HPET LegacyReplacement before NTLDR (X470: no
    clock interrupt for the 3.51 kernel otherwise, hang after the banner)."""

    def test_hpet_legacy_off(self):
        text = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        for want in ('mov ebx, 0xFED00000', 'btr dword ptr fs:[ebx + 0x10], 1',
                     '.byte 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00',
                     '#ifdef NT3_HPET_SET_LEGACY'):
            self.assertIn(want, text)
        # The HPET write sits inside the cli window of the INT 15h hook install.
        cli = text.index('    cli\n    /* FS: flat')
        self.assertLess(cli, text.index('btr dword ptr'))
        self.assertLess(text.index('btr dword ptr'), text.index('    mov word ptr [0x15 * 4], 4'))


if __name__ == '__main__':
    unittest.main()
