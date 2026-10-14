"""Windows NT 3.51, 3.5 and 3.1 through the UEFI flow: the NT 4.0 VM flow with
NT_MAJOR=3 (tools/nt4_csmwrap_target.sh, tools/nt4_qemu_install.sh, the NT 3.x
branch of tools/w9x_csmwrap_prepare.sh, tools/build_micro_linux.py;
docs/nt351-2026-10-08.md, docs/nt35-2026-10-09.md, docs/nt31-2026-10-09.md). Host only: Git sh, temp
folders; no VM, no disk.
"""
from pathlib import Path
import json
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
        self.assertIn('.{ .system_id = "windows-nt-3-5", .file = "NT35.SIF" }', zig)
        self.assertIn('.{ .system_id = "windows-nt-3-5-server", .file = "NT35S.SIF" }', zig)


class Nt3Target(unittest.TestCase):
    def test_target_handles_nt3(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('[ -z "${NT_MAJOR:-}" ] || [ "$NT_MAJOR" = "$major" ]', text)
        self.assertIn('[ -z "$nt3" ] || mbr_code=$LIB/nt3-e820-mbr-440.bin', text)
        # winnt.exe's ~BT\SYSTEM32 (0x6B C000003A without it).
        self.assertIn('cp "$bt_dir/USETUP.EXE" "$bt_dir/SYSTEM32/SMSS.EXE"', text)
        self.assertIn('cp "$bt_dir/NTDLL.DLL" "$bt_dir/SYSTEM32/NTDLL.DLL"', text)
        self.assertIn('for file in AHCINT.SYS USOSUSB.SYS USOSNT3.EXE; do', text)
        self.assertIn('cp "$drv/$rst" "$usos/USOSRST.SYS"', text)
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
        # NT 3.5 Setup on IDE leaves the disk class driver at Start 1 (0x7B with AHCINT).
        self.assertIn('set_dword("Scsidisk", NULL, "Start", 0);', (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8'))

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

    def test_nt35_cd_accepted(self):
        # NT 3.5 (MinorVersion 50): the NT 3.51 layout, its own usosrst build;
        # NT 3.1 (TXTSETUP.INF, its own branch) and other minors are refused.
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('    yes:51|yes:50|yes:10|:*) ;;\n', text)
        self.assertIn('[ -z "${NT_MINOR:-}" ] || [ "$NT_MINOR" = "$minor" ]', text)
        self.assertIn('[ "$nt3:$minor" != yes:50 ] || rst=USOSRST35.SYS', text)
        self.assertIn('for file in USOSNT3.EXE USOSACHK.EXE $rst; do', text)

    def test_standard_pc_hal_for_the_nt35_mps_row(self):
        # NT 3.5 names its MPS HAL row mps11_mp (halmps.dll).
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt35-hal-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        sif = tmp / 'TXTSETUP.SIF'
        sif.write_bytes(b'[hal]\r\ne_isa_up    = hal.dll     ,2,hal.dll\r\nmps11_mp    = halmps.dll  ,2,hal.dll\r\n'
                        b'ncr3x_mp    = halncr.dll  ,2,hal.dll\r\n')
        script = tmp / 'run.sh'
        script.write_bytes((function_text(TARGET, 'nt3_standard_hal') +
                            f'\nnt3_standard_hal < "{sif.as_posix()}" > "{(tmp / "out.sif").as_posix()}"\n').encode('utf-8'))
        rc, _, err = sh(f'. "{script.as_posix()}"')
        self.assertEqual(rc, 0, err)
        self.assertEqual((tmp / 'out.sif').read_bytes(),
                         b'[hal]\r\ne_isa_up    = hal.dll     ,2,hal.dll\r\nmps11_mp = hal.dll    ,2,hal.dll\r\n'
                         b'ncr3x_mp    = halncr.dll  ,2,hal.dll\r\n')
        self.assertIn("grep -aiEq '^mps[0-9]*_(up|mp) *= *hal\\.dll'", TARGET.read_text(encoding='utf-8'))

    def test_install_vm_for_nt35(self):
        # NT 3.5 GUI Setup knows no CPU newer than a Pentium; its CD has no
        # amsint.sys, and its atdisk.sys works on QEMU IDE.
        text = QEMU_INSTALL.read_text(encoding='utf-8')
        self.assertIn('-cpu "${NT4_VM_CPU:-pentium3}"', text)
        self.assertIn("mtype -i \"$target@@$NT4_PART_OFFSET\" ::/USOS/NT3/SOURCE.TXT 2>/dev/null | grep -q '^version=3\\.50'", text)
        self.assertIn('NT4_VM_CPU=${NT35_VM_CPU:-pentium}', text)
        self.assertIn('NT4_VM_HBA=${NT35_VM_HBA:-}', text)
        self.assertIn('[ -z "$nt3" ] || boots=${NT3_VM_BOOTS:-12}', text)
        # More than 128 MiB: STOP 0x7B on NT 3.5 (QEMU 2026-10-09).
        self.assertIn('NT35_BOOT_OPTIONS=${NT35_BOOT_OPTIONS:-/NUMPROC=2 /MAXMEM=128}', text)
        self.assertIn("grep -aq '^version=3\\.50' \"$src\"; then\n        NT4_BOOT_OPTIONS=$NT35_BOOT_OPTIONS", text)

    def test_qemu_install_answers_the_autochk_prompt(self):
        text = QEMU_INSTALL.read_text(encoding='utf-8')
        self.assertIn('W9X_VM_TEXT_ANSWER=${NT3_VM_TEXT_ANSWER:-ret}', text)
        self.assertIn('::/USOS/NT3', text)


class Nt3Prepare(unittest.TestCase):
    def test_prepare_routes_nt3(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('windows-nt-3-51) tag=NT351', text)
        self.assertIn('windows-nt-3-51-server) tag=NT351S', text)
        self.assertIn("NT351|NT351S) nt4=yes nt_major=3 nt_minor=51 nt_name='Windows NT 3.51'", text)
        self.assertIn("NT4|NT4S) nt4=yes nt_major=4 nt_name='Windows NT 4.0'", text)
        self.assertIn('NT_MAJOR="$nt_major" NT_MINOR="$nt_minor" sh /usr/lib/usos/nt4_csmwrap_target.sh', text)
        self.assertIn('windows-nt-3-5) tag=NT35', text)
        self.assertIn('windows-nt-3-5-server) tag=NT35S', text)
        self.assertIn("NT35|NT35S) nt4=yes nt_major=3 nt_minor=50 nt_name='Windows NT 3.5'", text)
        self.assertIn('windows-nt-3-1) tag=NT31', text)
        self.assertIn('windows-nt-3-1-server) tag=NT31S', text)
        self.assertIn("NT31|NT31S) nt4=yes nt_major=3 nt_minor=10 nt_name='Windows NT 3.1'", text)
        # The staged profile files go in every profile arm (NT, 9x and, since
        # the POSReady entry, POSR), and the SP6a lookup only for NT 4.0.
        self.assertEqual(text.count('/mnt/esp/EFI/USOS/answer/NT351.SIF /mnt/esp/EFI/USOS/answer/NT351S.SIF'
                                    ' /mnt/esp/EFI/USOS/answer/NT35.SIF /mnt/esp/EFI/USOS/answer/NT35S.SIF'
                                    ' /mnt/esp/EFI/USOS/answer/NT31.SIF /mnt/esp/EFI/USOS/answer/NT31S.SIF'), 3)
        self.assertIn('NT351|NT351S|NT35|NT35S|NT31|NT31S|', (ROOT / 'tools/w9x_phase1_qemu.sh').read_text(encoding='utf-8'))
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
            ('tools/w2k/usosrst/bin/nt35/i386/usosrst.sys', 'usr/lib/usos/nt3/USOSRST35.SYS'),
            ('tools/nt4/usosusb/bin/i386/usosusb.sys', 'usr/lib/usos/nt3/USOSUSB.SYS'),
            ('tools/nt3/usosnt3/bin/i386/usosnt3.exe', 'usr/lib/usos/nt3/USOSNT3.EXE'),
            ('tools/nt3/usosachk/bin/i386/usosachk.exe', 'usr/lib/usos/nt3/USOSACHK.EXE'),
        ):
            self.assertIn(f'("{pair[0]}", "{pair[1]}")', text)
            self.assertTrue((ROOT / pair[0]).is_file(), pair[0])
        self.assertIn('nt3_e820_mbr = root / "zig-out/xp-geometry-fix-mbr/nt3-e820-mbr-440.bin"', text)
        # Required inputs (the ELCR MBR joined the tuple with the ReactOS entry)
        # and both NT 3.x sectors shipped in the initramfs.
        self.assertIn('xp_geometry_fix_mbr, nt3_e820_mbr, nt3_e820_hook', text)
        self.assertIn('"usr/lib/usos/nt3-e820-hook-512.bin"', text)
        self.assertIn('"usr/lib/usos/nt3-e820-mbr-440.bin"', text)


class Nt3Mbr(unittest.TestCase):
    """The NT 3.x MBR clears HPET LegacyReplacement before NTLDR (X470: no
    clock interrupt for the 3.51 kernel otherwise, hang after the banner)."""

    def test_hpet_legacy_off(self):
        text = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        for want in ('mov ebx, 0xFED00000', 'and dword ptr fs:[ebx + 0x10], 0xFFFFFFFD',
                     '.byte 0xFF, 0xFF, 0x00, 0x00, 0x00, 0x92, 0xCF, 0x00',
                     '#ifdef NT3_HPET_SET_LEGACY'):
            self.assertIn(want, text)
        # The HPET write sits inside the cli window of the INT 15h hook install.
        cli = text.index('    cli\n    /* FS: flat')
        self.assertLess(cli, text.index('and dword ptr fs:'))
        self.assertLess(text.index('and dword ptr fs:'), text.index('    and word ptr [0x15 * 4], 0'))

    def test_pci_bios_hidden_only_past_bus_7(self):
        # NTDETECT caps the PCI bus count at 8 and the 3.51 HAL bridge scan
        # loops when a bridge leads past it (X470): with a last bus >= 8 the
        # MBR turns INT 1Ah B101h into B1FFh (unsupported).
        text = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        check = text.index('    mov ax, 0xB101\n    int 0x1A\n    jc boot_partition\n    cmp cl, 8\n    jb boot_partition\n')
        install = text.index('    mov word ptr [0x1A * 4], offset H1A')
        self.assertLess(check, install)
        hook = text[text.index('hook_1a:'):text.index('hook_end:')]
        for want in ('cmp ax, 0xB101', 'mov al, 0xFF', '.word OLD1A'):
            self.assertIn(want, hook)
        # The boot drive survives the PCI BIOS call (EDX = "PCI ") in BP.
        self.assertIn('    mov bp, dx\n', text)
        self.assertEqual(text.count('    mov dx, bp\n'), 3)


    def test_hook_sector(self):
        # The resident hooks are sector 1 (.hook section, "U3" signature);
        # without the signature the MBR boots without hooks.
        text = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        self.assertIn('.section .hook, "ax"', text)
        self.assertIn('    mov eax, 1\n    call read_sector\n    jc 2f\n    cmp word ptr es:[510], 0x3355\n    je 3f\n2:\n    inc word ptr [0x0413]\n', text)
        ld = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.ld').read_text(encoding='utf-8')
        self.assertIn('.hook 0 : AT(0x10000)', ld)
        ps1 = (ROOT / 'tools/build_xp_geometry_fix_mbr.ps1').read_text(encoding='utf-8')
        for want in ("$hookbin = Join-Path $out 'nt3-e820-hook-512.bin'", '-j .hook $nt3elf $hookraw',
                     '$padded[510] = 0x55', '$padded[511] = 0x33'):
            self.assertIn(want, ps1)
        target = TARGET.read_text(encoding='utf-8')
        self.assertIn('[ -z "$nt3" ] || mbr_hook=$LIB/nt3-e820-hook-512.bin', target)
        self.assertIn('dd if="$mbr_hook" of="$TARGET_DEVICE" bs=512 seek=1 count=1 conv=notrunc,fsync', target)
        self.assertLess(target.index('cannot write the MBR\''), target.index('cannot write the MBR hook sector'))
        build = BUILD.read_text(encoding='utf-8')
        self.assertIn('nt3_e820_hook = root / "zig-out/xp-geometry-fix-mbr/nt3-e820-hook-512.bin"', build)
        self.assertIn('"usr/lib/usos/nt3-e820-hook-512.bin"', build)

    def test_old_memory_size_calls(self):
        # NT 3.1 sizes memory with AH=88h / AX=E801h only (no E820): both get
        # the same low size (BIOS E801h AX) and E801h BX/DX = the E820 RAM
        # entry over 16 MiB (OVMF + CSMWrap: 8128 KB -> 57152 KB, QEMU 2026-10-10).
        text = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        hook = text[text.index('hook_start:'):text.index('hook_1a:')]
        for want in ('    cmp ah, 0x88\n    je mem_sizes\n    cmp ax, 0xE801\n    je mem_sizes\n',
                     '    mov ax, 0xE801\n', '    mov word ptr [bp - 6], ax\n', '    mov edx, 0x534D4150\n',
                     '    cmp eax, 0x1000000\n    ja 3f\n', '    mov ax, 0xFF00', '    mov ax, word ptr [bp - 6]\n',
                     '    cmp byte ptr [bp - 1], 0x88\n', '    mov cx, ax\n    mov bx, word ptr [bp - 4]\n    mov dx, bx\n'):
            self.assertIn(want, hook)
        # The saved registers are popped before the results are loaded.
        self.assertLess(hook.index('    pop si\n    jc 7f\n'), hook.index('    mov ax, word ptr [bp - 6]\n'))


class Nt3DriversWithoutPciBios(unittest.TestCase):
    """With the PCI BIOS hidden the 3.51 HAL has no PCI bus handler: the NT 3.51
    builds of AHCINT and usosrst read PCI configuration space via CF8h/CFCh."""

    def test_ahcint_nt351_direct_config(self):
        src = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcimain.c').read_text(encoding='latin-1')
        for want in ('static PUCHAR AhciCfgPorts;', 'ScsiPortWritePortUlong((PULONG)AhciCfgPorts,',
                     'initData.AdapterInterfaceType = Isa;', 'ConfigInfo->AdapterInterfaceType = PCIBus;',
                     'AhciCfgWrite16(targetBus, targetSlot, 0x04, pciCmd);', '*Again = TRUE;'):
            self.assertIn(want, src)
        manifest = json.loads((ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/manifest.json').read_text(encoding='utf-8'))
        self.assertIn('patches/0009-usos6-nt351-direct-pci-config.patch', manifest['patches'])

    def test_nt35_imports(self):
        # Our NT 3.x binaries against the NT 3.5 exports (names only,
        # tools/tests/data/nt35_exports.txt): usosrst has its own NT 3.5 build.
        from check_nt52_driver_imports import pe
        from check_nt4_driver_imports import parse
        tables = parse((ROOT / 'tools/tests/data/nt35_exports.txt').read_text(encoding='utf-8'))
        for rel in ('tools/vendor/ahcint/1.3.0.0-usos4/bin/NT351/i386/ahcint.sys',
                    'tools/w2k/usosrst/bin/nt35/i386/usosrst.sys', 'tools/nt4/usosusb/bin/i386/usosusb.sys'):
            _, imports = pe(ROOT / rel)
            for kernel, hal in (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'halmps.dll')):
                view = {'ntoskrnl.exe': tables[kernel], 'hal.dll': tables[hal], 'scsiport.sys': tables['scsiport.sys']}
                missing = [f'{m}!{n}' for m, n in imports if n not in view[m.lower()]]
                self.assertEqual(missing, [], f'{rel} on {kernel}+{hal}')
        src = (ROOT / 'tools/w2k/usosrst/src/usosrst.c').read_text(encoding='latin-1')
        self.assertIn('#define USOSRST_VERSION "usosrst 1.6-nt35"', src)
        self.assertIn('-DUSOSRST_NT35', (ROOT / 'tools/w2k/usosrst/build-nt35.cmd').read_text(encoding='utf-8'))

    def test_usosrst_nt351_direct_config(self):
        src = (ROOT / 'tools/w2k/usosrst/src/usosrst.c').read_text(encoding='latin-1')
        self.assertIn('#define USOSRST_VERSION "usosrst 1.6-nt351"', src)
        self.assertIn('got = PciCfgHeader351(bus, slot.u.AsULONG, &cfg);', src)
        self.assertIn('WRITE_PORT_ULONG((PULONG)0xCF8, base | (i * 4));', src)


class Nt31(unittest.TestCase):
    """NT 3.1 (docs/nt31-2026-10-09.md): TXTSETUP.INF Setup from the local
    source on C:, text mode answered by its page text, GUI Setup from a
    patched INITIAL.INF / HARDWARE.INF, the NT 3.1 driver builds."""

    # Synthetic stand-ins with the anchors the patch needs (no Microsoft text).
    INITIAL = ('[UiVars]\r\n    DoPartial   = $(Chosen)\r\n    DoNetwork   = $(Chosen)\r\n'
               '    DoPrinter   = $(Chosen)\r\n    DoAppSetup  = $(Chosen)\r\n'
               '[Shell Commands]\r\n'
               '    RunProgram STATUS "" "" $(!STF_WINDOWSSYSPATH)"\\control.exe" main.cpl $(Applet) setup\r\n'
               '    shell "repair.inf" "CreateRepairDiskette"\r\n'
               'setupdone =+\r\n    EndWait\r\n'
               '[DoLicense]\r\n    set Status = STATUS_FAILED\r\n'
               '[DoComputerName]\r\n    set Status = STATUS_FAILED\r\n'
               '[DoAccountSetup]\r\n    set Status = STATUS_FAILED\r\n'
               '[DoAdminAccountSetup]\r\n    set Status = STATUS_SUCCESSFUL\r\n')
    HARDWARE = ('[InitialHardwareInstall]\r\n    StartWait\r\nsystem = +\r\n    ui start "System"\r\n'
                'install_system = +\r\n    Return\r\n')

    def run_fn(self, script, name, args, data):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt31-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'in.inf').write_bytes(data.encode('ascii'))
        # Sourced, not passed as text: the awk program's backslashes next to
        # quotes would not survive the Windows command line.
        rc, _, err = sh(f'. "{script.as_posix()}"\n{name} {args} < "{(tmp / "in.inf").as_posix()}" > "{(tmp / "out.inf").as_posix()}"')
        return rc, err, (tmp / 'out.inf').read_bytes().decode('ascii')

    def test_initial_inf_patch(self):
        rc, err, out = self.run_fn(QEMU_INSTALL, 'nt31_initial_inf', '"Jan Kowalski" "USOS" USOS-NT31', self.INITIAL)
        self.assertEqual(rc, 0, err)
        self.assertNotIn('\n', out.replace('\r\n', ''))
        for want in ('    DoNetwork   = $(NotChosen)\r\n', '    DoPrinter   = $(NotChosen)\r\n',
                     '    DoAppSetup  = $(NotChosen)\r\n', '    DoPartial   = $(Chosen)\r\n',
                     '; USOS: no Emergency Repair Disk\r\n',
                     'setupdone =+\r\n    shell "" UsosNt31Post\r\n    set Exit_Code = $(!SETUP_ERROR_SUCCESS)\r\n    goto rebootend\r\n',
                     '[DoLicense]\r\n    set !FullName = "Jan Kowalski"\r\n    set !OrgName = "USOS"\r\n    Return STATUS_SUCCESSFUL\r\n',
                     '[DoComputerName]\r\n    Return STATUS_SUCCESSFUL "USOS-NT31"\r\n',
                     '[DoAdminAccountSetup]\r\n    Return STATUS_SUCCESSFUL ""\r\n',
                     '[DoAccountSetup]\r\n    Return STATUS_USERCANCEL "" ""\r\n',
                     '[UsosNt31Post]\r\n',
                     '    OpenRegKey $(!REG_H_LOCAL) "" "system\\CurrentControlSet\\services" 33554432 UsosSvc\r\n',
                     '{{ahcint,0,33554432}} {{Type,0,$(!REG_VT_DWORD),1},{Start,0,$(!REG_VT_DWORD),0}',
                     '{{usosrst,0,33554432},{Parameters,0,33554432}} {{HpetLegacyOff,0,$(!REG_VT_DWORD),1},{RtcFix,0,$(!REG_VT_DWORD),1}}',
                     '{{Scsidisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),0}}',
                     '{{Atdisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),4}}',
                     '{{Winlogon,0,33554432}}',
                     '$(!STF_WINDOWSSYSPATH)"\\cmd.exe" /c C:\\USOS\\NT3\\POST.CMD\r\n'):
            self.assertIn(want, out)
        self.assertIn('main.cpl', out)
        # Another INITIAL.INF (an anchor missing): refused.
        rc, _, _ = self.run_fn(QEMU_INSTALL, 'nt31_initial_inf', 'a b c', self.INITIAL.replace('[DoLicense]', '[DoLicence]'))
        self.assertNotEqual(rc, 0)

    def test_advanced_server_keeps_the_network(self):
        # 3.1 AS is always a domain controller: without the network no logon
        # (netlogon), so its Setup keeps DoNetwork and installs the Loopback.
        rc, err, out = self.run_fn(QEMU_INSTALL, 'nt31_initial_inf', 'a b c net', self.INITIAL)
        self.assertEqual(rc, 0, err)
        self.assertIn('    DoNetwork   = $(Chosen)\r\n', out)
        self.assertIn('    DoPrinter   = $(NotChosen)\r\n', out)
        self.assertIn('    DoAppSetup  = $(NotChosen)\r\n', out)
        lanman = ('[InitialAdapterInstall]\r\n    Set DtAnyFound = NO\r\n    Set !STF_NCDETINFO = {}\r\n'
                  '    Shell $(NcParamInf) Param_ControlDetection DTSTART\r\ndetectbypass = +\r\n    Return\r\n')
        rc, err, out = self.run_fn(QEMU_INSTALL, 'nt31_ntlanman_inf', '', lanman)
        self.assertEqual(rc, 0, err)
        self.assertIn('    Set !STF_NCDETINFO = {}\r\n; USOS: the MS Loopback Adapter during Setup (docs/nt31-2026-10-09.md)\r\n'
                      '    Ifstr(i) $(!NTN_Origination) == "install"\r\n        Set !STF_NCOPTION = LOOP\r\n'
                      '        Goto detectbypass\r\n    Endif\r\n    Shell $(NcParamInf)', out)
        rc, _, _ = self.run_fn(QEMU_INSTALL, 'nt31_ntlanman_inf', '', lanman.replace('NCDETINFO', 'NCDETINF'))
        self.assertNotEqual(rc, 0)
        loop = '[InstallOption]\r\nadapteroptions = +\r\n    ui start "InputDlg"\r\nskipoptions = +\r\n'
        rc, err, out = self.run_fn(QEMU_INSTALL, 'nt31_oemnadlb_inf', '', loop)
        self.assertEqual(rc, 0, err)
        self.assertIn('adapteroptions = +\r\n; USOS: no media type page during Setup (docs/nt31-2026-10-09.md)\r\n'
                      '    Ifstr(i) $(!NTN_Origination) == "install"\r\n        goto skipoptions\r\n    Endif\r\n'
                      '    ui start "InputDlg"\r\n', out)
        install = QEMU_INSTALL.read_text(encoding='utf-8')
        self.assertIn("! grep -qi '^[[:space:]]*STF_PRODUCT[[:space:]]*=[[:space:]]*LanmanNT' \"$inf\" || NT31_NET=net", install)
        self.assertIn('nt31_vm_patch_file "$img" NTLANMAN.INF nt31_ntlanman_inf &&', install)
        self.assertIn('nt31_vm_patch_file "$img" OEMNADLB.INF nt31_oemnadlb_inf', install)
        # Domain Settings first (controller of the new domain USOSDOMAIN), then Date/Time.
        self.assertIn('W9X_VM_ANSWER=${NT31_AS_VM_ANSWER:-alt-c tab ${NT31_DOMAIN_KEYS:-shift-u shift-s shift-o shift-s '
                      'shift-d shift-o shift-m shift-a shift-i shift-n} ret;ret}', install)

    def test_hardware_inf_patch(self):
        rc, err, out = self.run_fn(QEMU_INSTALL, 'nt31_hardware_inf', '', self.HARDWARE)
        self.assertEqual(rc, 0, err)
        self.assertIn('system = +\r\n; USOS: the default language (locale), no page\r\n    goto install_system\r\n', out)
        rc, _, _ = self.run_fn(QEMU_INSTALL, 'nt31_hardware_inf', '', self.HARDWARE.replace('install_system', 'x'))
        self.assertNotEqual(rc, 0)

    def test_text_mode_pages(self):
        fn = function_text(QEMU_INSTALL, 'nt31_vm_tick')
        for page, key in (("'Welcome to Setup.'", 'key=ret'), ("'Express Setup (recommended)'", 'key=ret'),
                          ("'select the partition where you would like to install'", 'key=ret'),
                          ("'select a file system option'", 'key=ret'), ("'Choose the location'", 'key=ret'),
                          ("'Press CTRL+ALT+DELETE to restart'", 'key=ctrl-alt-delete')):
            self.assertIn(page, fn)
            self.assertIn(key, fn[fn.index(page):fn.index(page) + 120])
        # HMP parses the size as an expression: an unquoted "4000 /run/..." is
        # a division (X470 2026-10-10: no dump, Welcome page never answered).
        self.assertIn('pmemsave 0xb8000 4000 \\"$W9X_VM_RUN/vga.bin\\"', fn)
        install = QEMU_INSTALL.read_text(encoding='utf-8')
        self.assertIn("grep -q '^version=3\\.10'", install)
        self.assertIn('W9X_VM_TICK_FN=nt31_vm_tick', install)
        self.assertIn('W9X_VM_ANSWER=${NT31_VM_ANSWER:-ret}', install)
        self.assertIn('NT4_BOOT_OPTIONS=$NT31_BOOT_OPTIONS', install)
        self.assertIn('[ -z "${W9X_VM_TICK_FN:-}" ] || "$W9X_VM_TICK_FN" "$elapsed" || true',
                      (ROOT / 'tools/w9x_phase1_qemu.sh').read_text(encoding='utf-8'))

    def test_target_layout(self):
        text = TARGET.read_text(encoding='utf-8')
        for want in ('for name in TXTSETUP.INF txtsetup.inf; do', 'for name in SETUPLDR setupldr; do',
                     '[ -z "$nt31" ] || { major=3; minor=10; }',
                     "printf '\\r\\n[MsDosInitiated]\\r\\n'",
                     '[ -z "$nt31" ] || { rst=USOSRST31.SYS ahci=AHCINT31.SYS usb=USOSUSB31.SYS; }',
                     'PART_SECTORS=${NT31_PART_SECTORS:-1024000}', 'ROOTLIST.TXT', 'NAMES.TXT'):
            self.assertIn(want, text)

    def test_nt31_drivers(self):
        from check_nt52_driver_imports import pe
        from check_nt4_driver_imports import parse
        tables = parse((ROOT / 'tools/tests/data/nt31_exports.txt').read_text(encoding='utf-8'))
        for rel in ('tools/vendor/ahcint/1.3.0.0-usos4/bin/NT31/i386/ahcint.sys',
                    'tools/w2k/usosrst/bin/nt31/i386/usosrst.sys', 'tools/nt4/usosusb/bin/nt31/i386/usosusb.sys'):
            _, imports = pe(ROOT / rel)
            for kernel in ('ntoskrnl.exe', 'ntkrnlmp.exe'):
                view = {'ntoskrnl.exe': tables[kernel], 'hal.dll': tables['hal.dll'], 'scsiport.sys': tables['scsiport.sys']}
                missing = [f'{m}!{n}' for m, n in imports if n not in view[m.lower()]]
                self.assertEqual(missing, [], f'{rel} on {kernel}')
        src = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcimain.c').read_text(encoding='latin-1')
        self.assertIn('initData.HwInitializationDataSize = 0x40;', src)
        self.assertIn('ConfigInfo->AdapterInterfaceType = Eisa;', src)
        build = BUILD.read_text(encoding='utf-8')
        for pair in (('tools/vendor/ahcint/1.3.0.0-usos4/bin/NT31/i386/ahcint.sys', 'usr/lib/usos/nt3/AHCINT31.SYS'),
                     ('tools/w2k/usosrst/bin/nt31/i386/usosrst.sys', 'usr/lib/usos/nt3/USOSRST31.SYS'),
                     ('tools/nt4/usosusb/bin/nt31/i386/usosusb.sys', 'usr/lib/usos/nt3/USOSUSB31.SYS')):
            self.assertIn(f'("{pair[0]}", "{pair[1]}")', build)


class Nt3AnswerProfile(unittest.TestCase):
    """Answer-profile values NT 3.x Setup has no key for
    (docs/nt3-polish-2026-10-14.md): nt3.zig ;USOS-* lines -> ACCOUNT.TXT /
    INTL.TXT (nt4_csmwrap_target.sh) -> usosnt3.exe (/service, NT 3.1 /polish)."""

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-nt3-profile-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_profile_files(self):
        sif = self.tmp / 'WINNT.SIF'
        sif.write_bytes(b'[GuiUnattended]\r\n!SetupNetwork = NO\r\n;USOS-USER=Jan\r\n;USOS-PASSWORD=a b;c=d\r\n'
                        b';USOS-AUTOLOGON=1\r\n;USOS-LOCALE=00000415\r\n;USOS-KEYBOARD=00000415\r\n\r\n[UserData]\r\n!FullName = "x"\r\n')
        fn = function_text(TARGET, 'nt3_profile_files')
        rc, out, err = sh(f'{fn}\nnt3_profile_files "{sif.as_posix()}" "{self.tmp.as_posix()}"')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), 'account=yes user=Jan password=set autologon=yes locale=00000415 keyboard=00000415')
        self.assertNotIn('a b;c=d', out)
        self.assertEqual((self.tmp / 'ACCOUNT.TXT').read_bytes(), b'user=Jan\r\npassword=a b;c=d\r\nautologon=1\r\n')
        self.assertEqual((self.tmp / 'INTL.TXT').read_bytes(), b'locale=00000415\r\nkeyboard=00000415\r\n')
        # The account lines (password) leave WINNT.SIF; the rest stays.
        self.assertEqual(sif.read_bytes(), b'[GuiUnattended]\r\n!SetupNetwork = NO\r\n;USOS-LOCALE=00000415\r\n'
                         b';USOS-KEYBOARD=00000415\r\n\r\n[UserData]\r\n!FullName = "x"\r\n')

    def test_no_profile_values(self):
        sif = self.tmp / 'WINNT.SIF'
        sif.write_bytes(GOLDEN.read_bytes())
        fn = function_text(TARGET, 'nt3_profile_files')
        rc, out, err = sh(f'{fn}\nnt3_profile_files "{sif.as_posix()}" "{self.tmp.as_posix()}"')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), 'account=no user=Administrator password=blank autologon=no locale=CD keyboard=CD')
        self.assertFalse((self.tmp / 'ACCOUNT.TXT').exists())
        self.assertFalse((self.tmp / 'INTL.TXT').exists())
        self.assertEqual(sif.read_bytes(), GOLDEN.read_bytes())

    def test_ui_locale_only_when_missing(self):
        fn = function_text(PREPARE, 'w9x_nt3_ui_locale')
        sif = self.tmp / 'a.sif'
        sif.write_bytes(b'[UserData]\r\n;USOS-KEYBOARD=00010415\r\n')
        rc, _, err = sh(f'{fn}\nw9x_nt3_ui_locale "{sif.as_posix()}" 00000415 00000415')
        self.assertEqual(rc, 0, err)
        self.assertEqual(sif.read_bytes(), b'[UserData]\r\n;USOS-KEYBOARD=00010415\r\n;USOS-LOCALE=00000415\r\n')
        rc, _, err = sh(f'{fn}\nw9x_nt3_ui_locale "{sif.as_posix()}" "" bad')
        self.assertEqual(rc, 0, err)
        self.assertEqual(sif.read_bytes(), b'[UserData]\r\n;USOS-KEYBOARD=00010415\r\n;USOS-LOCALE=00000415\r\n')
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('w9x_nt3_ui_locale "$answer_inf" "$ui_locale" "$ui_keyboard"', text)

    def test_wiring(self):
        text = TARGET.read_text(encoding='utf-8')
        for want in ('profile_values=$(nt3_profile_files "$work/WINNT.SIF" "$work")',
                     'cp "$drv/USOSNT3.EXE" "$usos/USOSNT3.EXE"', 'C:\\USOS\\NT3\\USOSNT3.EXE /polish',
                     'for file in $ahci $rst $usb USOSNT3.EXE; do'):
            self.assertIn(want, text)
        self.assertEqual(text.count('    nt3_stage_profile\n') + text.count('\nnt3_stage_profile\n'), 2)
        self.assertIn('USOS/NT3/ACCOUNT.TXT', QEMU_INSTALL.read_text(encoding='utf-8'))
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
        for want in ('wipe_file("ACCOUNT.TXT", size);', 'GraphicsDrivers\\\\DetectDisplay', '"NetLocalGroupAddMember"',
                     'RegSaveKeyA(def, hive, NULL)', 'lstrcmpA(opt, "polish") == 0'):
            self.assertIn(want, src)

    def test_stage_intl(self):
        i386 = self.tmp / 'i386'
        usos = self.tmp / 'usos'
        i386.mkdir()
        usos.mkdir()
        for name in ('KBDPL1.DLL', 'C_1250.NL_', 'C_852.NL_', 'VGASYSE.FO_', 'KBDCZ.DLL'):
            (i386 / name).write_bytes(b'x')
        (usos / 'INTL.TXT').write_bytes(b'locale=00000415\r\nkeyboard=00000415\r\n')
        txt = self.tmp / 'TXTSETUP.SIF'
        txt.write_bytes(b'[Files.KeyboardLayout]\r\n00000405 = KBDCZ.DLL,2\r\n00000415 = KBDPL1.DLL,2\r\n[Other]\r\n')
        fn = function_text(TARGET, 'nt3_stage_intl')
        rc, out, err = sh(f'log() {{ echo "$*"; }}\nfail() {{ echo "FAIL $*"; exit 1; }}\n{fn}\n'
                          f'i386="{i386.as_posix()}" usos="{usos.as_posix()}" txtsetup="{txt.as_posix()}"\nnt3_stage_intl')
        self.assertEqual(rc, 0, err + out)
        self.assertIn('(KBDPL1.DLL): 4 CD files', out)
        self.assertEqual(sorted(f.name for f in (usos / 'INTL').iterdir()), ['C_1250.NLS', 'C_852.NLS', 'KBDPL1.DLL', 'VGASYSE.FON'])
        self.assertTrue((usos / 'INTL.TXT').read_bytes().endswith(b'keyboard_dll=kbdpl1.dll\r\n'))

    def test_usosnt3_imports_exist_on_nt31(self):
        # Every static import of usosnt3.exe is exported by the kernel32 /
        # advapi32 of NT 3.1 (checked against the 3.1, 3.5 and 3.51 CDs'
        # DLLs on 2026-10-14); newer calls go through GetProcAddress.
        from check_nt52_driver_imports import pe
        nt31 = {
            'kernel32.dll': {'CloseHandle', 'CopyFileA', 'CreateFileA', 'DeleteFileA', 'ExitProcess', 'FlushFileBuffers',
                             'FindClose', 'FindFirstFileA', 'FindNextFileA', 'CreateProcessA', 'WaitForSingleObject', 'GetExitCodeProcess',
                             'FreeLibrary', 'GetCommandLineA', 'GetCurrentProcess', 'GetFileAttributesA', 'GetLastError',
                             'GetModuleHandleA', 'GetProcAddress', 'GetSystemDirectoryA', 'GetWindowsDirectoryA',
                             'LoadLibraryA', 'MoveFileA', 'MultiByteToWideChar', 'ReadFile', 'SetFilePointer', 'Sleep', 'WriteFile',
                             'WritePrivateProfileStringA', 'WriteProfileStringA', 'lstrcatA', 'lstrcmpA', 'lstrcmpiA',
                             'lstrcpyA'},
            'advapi32.dll': {'AdjustTokenPrivileges', 'InitiateSystemShutdownA', 'LookupAccountNameA',
                             'LookupPrivilegeValueA', 'OpenProcessToken', 'RegCloseKey', 'RegCreateKeyExA', 'RegDeleteKeyA',
                             'RegLoadKeyA', 'RegOpenKeyExA', 'RegSaveKeyA', 'RegQueryValueExA', 'RegSetValueExA', 'RegUnLoadKeyA',
                             'RegisterServiceCtrlHandlerA', 'SetServiceStatus', 'StartServiceCtrlDispatcherA'},
        }
        _, imports = pe(ROOT / 'tools/nt3/usosnt3/bin/i386/usosnt3.exe')
        missing = [f'{m}!{n}' for m, n in imports if n not in nt31.get(m.lower(), set())]
        self.assertEqual(missing, [])


if __name__ == '__main__':
    unittest.main()
