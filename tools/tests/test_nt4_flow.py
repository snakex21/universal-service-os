"""Windows NT 4.0 through the UEFI flow (tools/nt4_csmwrap_target.sh,
tools/nt4_qemu_install.sh, the NT4 branch of tools/w9x_csmwrap_prepare.sh).
Host only: Git sh, stubs, temp folders; no VM, no disk.
"""
from pathlib import Path
import re
import shutil
import tempfile
import unittest

from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
VM = (ROOT / 'tools/w9x_phase1_qemu.sh').as_posix()
NT4 = (ROOT / 'tools/nt4_qemu_install.sh').as_posix()
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'


def function_text(path: Path, name: str) -> str:
    """The shell function `name` of `path` (from its line to the first '}' at column 0)."""
    lines = path.read_text(encoding='utf-8').splitlines()
    start = next(i for i, line in enumerate(lines) if line.startswith(f'{name}() {{'))
    end = next(i for i in range(start, len(lines)) if lines[i] == '}')
    return '\n'.join(lines[start:end + 1])


class Nt4Vm(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_vm_args(self):
        rc, out, err = sh(f'. "{VM}"; . "{NT4}"; W9X_VM_RUN=/r; nt4_vm_args /dev/sdz tcg')
        self.assertEqual(rc, 0, err)
        args = out.split('\n')
        self.assertIn('pentium3', args)
        self.assertIn('-no-reboot', args)
        self.assertIn('none', args)  # -nic none / -display none
        drive = next(a for a in args if a.startswith('file=/dev/sdz'))
        self.assertIn('size=4294967296', drive)
        self.assertIn('cache=none', drive)
        self.assertIn('if=ide', drive)
        self.assertNotIn('acpi=off', ' '.join(args))

    def test_boot_ini_options(self):
        ini = '[boot loader]\r\ntimeout=30\r\ndefault=multi(0)disk(0)rdisk(0)partition(1)\\WINNT\r\n[operating systems]\r\n' \
              'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="Windows NT Workstation 4.0"\r\n' \
              'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="Windows NT Workstation 4.0 [VGA]" /basevideo /sos\r\n' \
              'C:\\ = "Nierozpoznany system operacyjny na dysku C"\r\n'
        (self.tmp / 'boot.ini').write_bytes(ini.encode('ascii'))
        rc, out, err = sh(f'. "{VM}"; . "{NT4}"; nt4_boot_ini < "{(self.tmp / "boot.ini").as_posix()}" > "{(self.tmp / "out.ini").as_posix()}"')
        self.assertEqual(rc, 0, err)
        text = (self.tmp / 'out.ini').read_bytes().decode('ascii')
        self.assertIn('timeout=5\r\n', text)
        self.assertIn('"Windows NT Workstation 4.0" /NUMPROC=2 /MAXMEM=1024\r\n', text)
        self.assertIn('/basevideo /sos /NUMPROC=2 /MAXMEM=1024\r\n', text)
        # default= is not an ARC line with options.
        self.assertIn('default=multi(0)disk(0)rdisk(0)partition(1)\\WINNT\r\n', text)
        # Diagnostic /SOS entry right after the default one; Setup's VGA entry kept, not doubled.
        lines = text.split('\r\n')
        first = lines.index('multi(0)disk(0)rdisk(0)partition(1)\\WINNT="Windows NT Workstation 4.0" /NUMPROC=2 /MAXMEM=1024')
        self.assertEqual(lines[first + 1],
                         'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="Windows NT Workstation 4.0 [USOS /SOS]" /SOS /NUMPROC=2 /MAXMEM=1024')
        self.assertEqual(text.count('/basevideo'), 1)
        self.assertEqual(text.count('/NUMPROC'), 3)
        # The C:\ entry (BOOTSECT.DOS = the syslinux boot sector) is dropped.
        self.assertNotIn('C:\\', text)

    def test_boot_ini_adds_vga_entry_when_missing(self):
        ini = '[boot loader]\r\ntimeout=30\r\ndefault=multi(0)disk(0)rdisk(0)partition(1)\\WINNT\r\n[operating systems]\r\n' \
              'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="NT Server"\r\n'
        (self.tmp / 'boot.ini').write_bytes(ini.encode('ascii'))
        rc, out, err = sh(f'. "{VM}"; . "{NT4}"; nt4_boot_ini < "{(self.tmp / "boot.ini").as_posix()}" > "{(self.tmp / "out.ini").as_posix()}"')
        self.assertEqual(rc, 0, err)
        lines = (self.tmp / 'out.ini').read_bytes().decode('ascii').split('\r\n')
        self.assertEqual(lines[-4:], [
            'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="NT Server" /NUMPROC=2 /MAXMEM=1024',
            'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="NT Server [USOS /SOS]" /SOS /NUMPROC=2 /MAXMEM=1024',
            'multi(0)disk(0)rdisk(0)partition(1)\\WINNT="NT Server [VGA mode]" /basevideo /sos /NUMPROC=2 /MAXMEM=1024',
            ''])

    def test_boot_ini_drops_the_enterprise_maxmem(self):
        ini = '[operating systems]\r\nmulti(0)disk(0)rdisk(0)partition(1)\\WINNT="Windows NT Server Version 4.00" /maxmem=256\r\n'
        (self.tmp / 'boot.ini').write_bytes(ini.encode('ascii'))
        rc, out, err = sh(f'. "{VM}"; . "{NT4}"; nt4_boot_ini < "{(self.tmp / "boot.ini").as_posix()}" > "{(self.tmp / "out.ini").as_posix()}"')
        self.assertEqual(rc, 0, err)
        text = (self.tmp / 'out.ini').read_bytes().decode('ascii')
        self.assertIn('"Windows NT Server Version 4.00" /NUMPROC=2 /MAXMEM=1024\r\n', text)
        self.assertNotIn('maxmem=256', text)

    def test_ci_path_finds_lower_case_nt_names(self):
        root = self.tmp / 'c'
        (root / 'winnt' / 'system32').mkdir(parents=True)
        (root / 'winnt' / 'system32' / 'ntoskrnl.exe').write_bytes(b'')
        (root / 'boot.ini').write_bytes(b'')
        r = root.as_posix()
        rc, out, err = sh(f'. "{VM}"; . "{NT4}"; nt4_ci_path "{r}" WINNT/SYSTEM32/NTOSKRNL.EXE; nt4_ci_path "{r}" BOOT.INI; '
                          f'nt4_ci_path "{r}" NTLDR || echo none')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.split(), [f'{r}/winnt/system32/ntoskrnl.exe', f'{r}/boot.ini', 'none'])

    def install(self, done_after):
        logs = (self.tmp / 'logs').as_posix()
        script = f'''. "{VM}"; . "{NT4}"
runs=0
w9x_phase1_run() {{ runs=$((runs + 1)); W9X_VM_ELAPSED=10; return 0; }}
w9x_phase1_keep_logs() {{ mkdir -p "$1"; }}
nt4_vm_marker() {{ [ "$runs" -ge {done_after} ]; }}
nt4_vm_install /dev/sdz "{logs}" tcg; rc=$?
echo "rc=$rc runs=$runs elapsed=$NT4_VM_ELAPSED fn=$W9X_VM_ARGS_FN"
'''
        return sh(script)

    def test_install_runs_until_done(self):
        rc, out, err = self.install(3)
        self.assertEqual(rc, 0, err)
        self.assertIn('rc=0 runs=3 elapsed=30 fn=nt4_vm_args', out)
        self.assertEqual(len((self.tmp / 'logs/runs.txt').read_text().splitlines()), 3)

    def test_install_gives_up(self):
        rc, out, err = self.install(99)
        self.assertIn('rc=4 runs=6', out)

    def test_install_stops_on_vm_failure(self):
        script = f'''. "{VM}"; . "{NT4}"
w9x_phase1_run() {{ return 3; }}
w9x_phase1_keep_logs() {{ :; }}
nt4_vm_install /dev/sdz "{(self.tmp / 'l').as_posix()}" tcg; echo "rc=$?"
'''
        rc, out, err = sh(script)
        self.assertIn('rc=3', out)

    def test_install_turns_on_the_stall_rule(self):
        # NT 4.0 has no key to type; a Setup page that waits must still end the
        # run (X470 2026-10-07: Server sat 40 minutes at 15 MB).
        script = f'''. "{VM}"; . "{NT4}"
w9x_phase1_run() {{ echo "any=$W9X_VM_STALL_ANY stall=$W9X_VM_STALL answer=$W9X_VM_ANSWER"; W9X_VM_STALLED=905; return 3; }}
w9x_phase1_keep_logs() {{ mkdir -p "$1"; }}
nt4_vm_install /dev/sdz "{(self.tmp / 'l').as_posix()}" tcg; echo "rc=$? nt4_stalled=$NT4_VM_STALLED"
'''
        rc, out, err = sh(script)
        self.assertIn('any=1 stall=900 answer=alt-n', out, err)
        self.assertIn('rc=3 nt4_stalled=905', out)
        self.assertIn('stalled=905', (self.tmp / 'l/runs.txt').read_text())

    def test_vm_available_for_nt4(self):
        share = self.tmp / 'share'
        share.mkdir()
        for name in ('bios-256k.bin', 'vgabios-stdvga.bin'):
            (share / name).write_bytes(b'x')
        (self.tmp / 'qemu').write_text('#!/bin/sh\n')
        (self.tmp / 'qemu').chmod(0o755)
        (self.tmp / 'meminfo').write_text('MemTotal:       16000000 kB\n')
        env = {'W9X_VM_QEMU': (self.tmp / 'qemu').as_posix(), 'W9X_VM_DATADIR': share.as_posix(),
               'W9X_VM_MEMINFO': (self.tmp / 'meminfo').as_posix(), 'W9X_VM_FLAGS': (self.tmp / 'flags').as_posix()}
        for tag in ('NT4', 'NT4S'):
            rc, out, err = sh(f'. "{VM}"; w9x_vm_available {tag}', env)
            self.assertEqual(rc, 0, out + err)


class Nt4ServerAnswer(unittest.TestCase):
    """NT 4.0 Server / Enterprise Server GUI pages (nt4_server_answer)."""

    def run_fn(self, product, text):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-srv-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'in.sif').write_bytes(text.encode('ascii'))
        fn = function_text(TARGET, 'nt4_server_answer')
        rc, out, err = sh(f'{fn}\nnt4_server_answer "{product}" < "{(tmp / "in.sif").as_posix()}" > "{(tmp / "out.sif").as_posix()}"')
        self.assertEqual(rc, 0, err)
        return (tmp / 'out.sif').read_bytes().decode('ascii')

    SIF = '[UserData]\r\nFullName = "USOS"\r\n\r\n[GuiUnattended]\r\nOemSkipWelcome = 1\r\nOEMBlankAdminPassword = 1\r\n\r\n[Display]\r\nXResolution = 640\r\n'

    def test_workstation_cd_unchanged(self):
        self.assertEqual(self.run_fn('0', self.SIF), self.SIF)
        self.assertEqual(self.run_fn('', self.SIF), self.SIF)

    def test_server_cd_gets_role_and_licensing(self):
        out = self.run_fn('1', self.SIF)
        self.assertIn('[GuiUnattended]\r\nAdvServerType = SERVERNT\r\nOemSkipWelcome = 1\r\n', out)
        self.assertTrue(out.endswith('[Display]\r\nXResolution = 640\r\n\r\n[LicenseFilePrintData]\r\nAutoMode = PerServer\r\nAutoUsers = 5\r\n'))
        self.assertEqual(out.count('AdvServerType'), 1)
        self.assertNotIn('\r\r', out)

    def test_server_keys_already_present_are_kept(self):
        text = '[GuiUnattended]\r\nAdvServerType = LANMANNT\r\n[LicenseFilePrintData]\r\nAutoMode = PerSeat\r\n'
        self.assertEqual(self.run_fn('1', text), text)

    def test_server_without_gui_section(self):
        out = self.run_fn('1', '[UserData]\nFullName = "A"\n')
        self.assertIn('[GuiUnattended]\r\nAdvServerType = SERVERNT\r\n', out)
        self.assertIn('[LicenseFilePrintData]\r\nAutoMode = PerServer\r\nAutoUsers = 5\r\n', out)

    def test_target_pipes_the_answer_through_it(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('| nt4_server_answer "${product:-0}" > "$work/WINNT.SIF"', text)


class Nt4Target(unittest.TestCase):
    def resolve(self, lang, text):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-tz-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'in.sif').write_bytes(text.encode('ascii'))
        fn = function_text(TARGET, 'nt4_resolve_time_zone')
        rc, out, err = sh(f'{fn}\nnt4_resolve_time_zone "{lang}" < "{(tmp / "in.sif").as_posix()}" > "{(tmp / "out.sif").as_posix()}"')
        self.assertEqual(rc, 0, err)
        return (tmp / 'out.sif').read_bytes().decode('ascii')

    def test_polish_cd_time_zone(self):
        out = self.resolve('0415', '[GuiUnattended]\r\nOemSkipWelcome = 1\r\n;USOS-TZ=Central European\r\n\r\n[Display]\r\n')
        self.assertIn('TimeZone = "(GMT+01:00) Warszawa, Praga, Budapeszt"\r\n', out)
        self.assertNotIn('USOS-TZ', out)
        self.assertTrue(out.endswith('[Display]\r\n'))

    def test_english_cd_time_zone(self):
        out = self.resolve('0409', ';USOS-TZ=Central European\r\n')
        self.assertEqual(out, 'TimeZone = "(GMT+01:00) Prague, Warsaw, Budapest"\r\n')

    def test_unknown_language_or_zone_drops_the_marker(self):
        for lang, zone in (('0407', 'Central European'), ('0415', 'Pacific SA')):
            out = self.resolve(lang, f'[GuiUnattended]\n;USOS-TZ={zone}\n')
            self.assertNotIn('TimeZone', out)
            self.assertNotIn('USOS-TZ', out)

    def test_target_layout_and_post_script(self):
        text = TARGET.read_text(encoding='utf-8')
        # FAT16 C: as in the 2026-10-07 QEMU lab: LBA 63, 2000 MiB, 32 KiB clusters, type 06, active.
        self.assertIn('PART_START=63', text)
        self.assertIn('PART_SECTORS=4096000', text)
        self.assertIn('mkfs.fat -F 16 -s 64', text)
        self.assertIn(r"printf '\200\001\001\000\006\366\067\376'", text)
        self.assertIn('APPEND boot ntldr=/$LDR$', text)
        self.assertIn('CMDLINES.TXT', text)
        self.assertIn('start /wait C:\\USOS\\NT4\\SP6I386.EXE -u -z', text)
        self.assertIn('C:\\USOS\\NT4\\USOSOFF.EXE /r', text)
        self.assertIn('"AutoAdminLogon"="0"', text)
        # NT 4.0 COPY has no /Y (syntax error, the drivers were not copied).
        self.assertNotIn('copy /y', text.lower())
        self.assertIn(r'CSD.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Windows', text)
        # Never the CSMWrap ESP before the VM: it is written after the install.
        self.assertNotIn('xp_csmwrap_esp.sh', text)

    def _crypto(self, schannel: bytes | None) -> str:
        text = TARGET.read_text(encoding='utf-8')
        start = text.index('crypto=standard\n')
        end = text.index('\ndone\n', start) + len('\ndone\n')
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-crypto-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'I386').mkdir()
        if schannel is not None:
            (tmp / 'I386/SCHANNEL.DLL').write_bytes(b'MZ\0\0' + schannel + b'\0\0')
        script = f'set -eu\ni386={tmp.as_posix()}/I386\n' + text[start:end] + 'echo "$crypto"\n'
        rc, out, err = sh(script)
        self.assertEqual(rc, 0, err)
        return out.strip()

    def test_cd_encryption_strength(self):
        # English Enterprise Server CD: "PCT / SSL Security Provider (US/Canada
        # Only, Not for Export)" in UTF-16; SP6a export: "(Export Version)".
        self.assertEqual(self._crypto('PCT / SSL Security Provider (US/Canada Only, Not for Export)'.encode('utf-16le')), 'high')
        self.assertEqual(self._crypto('TLS / SSL Security Provider (Export Version)'.encode('utf-16le')), 'standard')
        self.assertEqual(self._crypto(None), 'standard')
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('"$ANSWER_KIND" "$crypto" > "$usos/SOURCE.TXT"', text)

    def test_finish_names_the_high_encryption_service_pack(self):
        nt4 = Path(NT4).read_text(encoding='utf-8')
        self.assertIn('USOSRST.REG USOSVBE.REG VERSION.TXT DRIVERS.TXT SETUP.LOG DONE.TXT SOURCE.TXT; do', nt4)
        self.assertIn("grep -aq 'crypto=high' \"$logs/SOURCE.TXT\"", nt4)
        self.assertIn('(high-encryption CD);', nt4)
        prepare = PREPARE.read_text(encoding='utf-8')
        # The encryption message comes before the generic language one.
        self.assertLess(prepare.index("*'high-encryption CD'*)"), prepare.index("*'no Service Pack 6'*)"))
        self.assertIn('128-bit (High Encryption) SP6I386.EXE', prepare)

    def test_post_script_removes_the_enterprise_installer_before_sp6a(self):
        # Enterprise Server CD: NHSETUP.CMD puts NHLOADER (SP3 from the CD's
        # \SP3) in the All Users Startup group; it hung without the CD and
        # must never put SP3 over SP6a.
        text = TARGET.read_text(encoding='utf-8')
        post = text[text.index('crlf > "$usos/POST.CMD"'):]
        name = r'Startup\Windows NT Server, Enterprise Edition Installer.cmd'
        self.assertIn(r'set NHI=%SystemRoot%\Profiles\All Users\Start Menu\Programs' + '\\' + name, post)
        self.assertIn('del "%NHI%"', post)
        self.assertLess(post.index('del "%NHI%"'), post.index('SP6I386.EXE -u -z'))
        self.assertLess(post.index('del "%NHI%"'), post.index('USOSOFF.EXE /r'))

    def test_post_script_switches_a_128_bit_cd_for_the_export_sp6a(self):
        # The export SP6a on the 128-bit English Enterprise CD: update.exe
        # refuses silently. POST.CMD extracts the SP (sfxcab -x:dir -q), runs
        # update.exe, and only with CRYPTOHI.TXT and no CSDVersion 0x600 puts
        # the SP's own schannel.dll in place, renames rsaenh.dll and retries.
        text = TARGET.read_text(encoding='utf-8')
        post = text[text.index('crlf > "$usos/POST.CMD"'):]
        post = post[:post.index('\nEOF\n')]
        order = [
            r'SP6I386.EXE -x:C:\USOS\NT4\SP6X -q',
            r'start /wait C:\USOS\NT4\SP6X\update\update.exe -u -z',
            r'if not exist C:\USOS\NT4\CRYPTOHI.TXT goto nosp',
            r'CSD1.REG HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Control\Windows',
            'findstr /i /c:"dword:00000600"',
            'if not errorlevel 1 goto nosp',
            'echo crypto: high to standard for SP6a',
            r'copy %SystemRoot%\system32\schannel.dll C:\USOS\NT4\SCHAN128.DLL',
            r'ren %SystemRoot%\system32\schannel.dll schannel.128',
            r'copy C:\USOS\NT4\SP6X\schannel.dll %SystemRoot%\system32\schannel.dll',
            r'ren %SystemRoot%\system32\rsaenh.dll rsaenh.128',
            'echo sp start (standard)',
            ':spsfx',
            r'start /wait C:\USOS\NT4\SP6I386.EXE -u -z',
            ':nosp',
        ]
        positions = [post.index(item) for item in order]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(post.count(r'SP6X\update\update.exe -u -z'), 2)
        # cmd: '>' in an echo text is a redirection (QEMU 2026-10-07: "->"
        # wrote a file named "standard" and cut the log line).
        for line in post.splitlines():
            if line.startswith('echo '):
                text_part = line.split('>>')[0] if '>>' in line else line.split('>')[0]
                self.assertNotIn('>', text_part[5:], line)
        # The flag is written only for a 128-bit CD.
        self.assertIn('if [ "$crypto" = high ]; then printf \'high\\r\\n\' > "$usos/CRYPTOHI.TXT"; fi', text)

    def test_finish_removes_the_extracted_service_pack(self):
        nt4 = Path(NT4).read_text(encoding='utf-8')
        self.assertIn("for leftover in '$WIN_NT$.~BT' '$WIN_NT$.~LS' USOS/NT4/SP6X; do", nt4)

    def test_chs_end_matches_the_partition(self):
        # 255 heads, 63 sectors: LBA 63 + 4096000 - 1.
        lba = 63 + 4096000 - 1
        c, h, s = lba // (255 * 63), (lba // 63) % 255, lba % 63 + 1
        self.assertEqual((h, s | ((c >> 2) & 0xC0), c & 0xFF), (0o366, 0o067, 0o376))


class Nt4Prepare(unittest.TestCase):
    def test_prepare_routes_nt4(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('windows-nt-4) tag=NT4', text)
        # A run that stopped writing gets its own message, not the generic one.
        self.assertIn('stopped writing to the disk for $((NT4_VM_STALLED / 60)) minutes', text)
        self.assertIn('windows-nt-4-server) tag=NT4S', text)
        self.assertIn('nt4_vm_install "$TARGET_DEVICE"', text)
        self.assertIn('nt4_vm_finish "$TARGET_DEVICE"', text)
        self.assertRegex(text, re.compile(r'nt4_vm_finish.*\n(.*\n){0,25}.*xp_csmwrap_esp\.sh', re.M))
        self.assertIn('-iname \'sp6i386.exe\'', text)


if __name__ == '__main__':
    unittest.main()
