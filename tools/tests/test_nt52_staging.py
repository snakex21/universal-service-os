"""NT 5.2 (Server 2003 x86, XP x64) staging pieces, host-only, no Microsoft files:

- tools/nt5_storage_stage.sh usos_nt5_storage_sif: the four GenAHCI rows go
  into the first block of each section, CRLF kept, a second run is refused.
- tools/xp_dosnet_aliases.awk: aliases relative to the Setup source directory
  (I386 unchanged, AMD64 for XP x64, other directories refused).
- tools/nt5_profile.sh: one row per system (source dir, install dir, setup dir).
"""
from pathlib import Path
import os, shutil, subprocess, unittest

ROOT = Path(__file__).resolve().parents[2]
SH = next((p for p in (r'C:\msys64\usr\bin\sh.exe', r'C:\Program Files\Git\usr\bin\sh.exe', shutil.which('sh') or '') if p and Path(p).exists()), None)
# The shell's own coreutils (awk) first: PowerShell runs lack them on PATH.
if SH:
    os.environ['PATH'] = str(Path(SH).parent) + os.pathsep + os.environ.get('PATH', '')


def posix(path: Path) -> str:
    s = str(path.resolve()).replace('\\', '/')
    return '/' + s[0].lower() + s[2:] if s[1:2] == ':' else s


def sh(command: str, stdin: bytes = b'') -> subprocess.CompletedProcess:
    return subprocess.run([SH, '-c', command], input=stdin, capture_output=True)


TXTSETUP = (b'[SetupData]\r\nMajorVersion = 5\r\n[SourceDisksFiles]\r\nstorport.sys = 1,,,,,,3_,4,0,0,,1,4\r\n'
            b'[SourceDisksFiles.x86]\r\n[SourceDisksFiles]\r\nfoo.sys = 1\r\n[HardwareIdsDatabase]\r\nPCI\\VEN_8086&DEV_2922 = "iastor"\r\n'
            b'[SCSI.Load]\r\natapi = atapi.sys,4\r\n[SCSI]\r\natapi = "IDE"\r\n')
DOSNET = (b'[Directories]\r\nd1 = \\{top}\r\nd2 = \\I386\r\n[Files]\r\nd1,usetup.exe,system32\\smss.exe\r\n'
          b'd1,ntdll.dll,system32\\ntdll.dll\r\nd2,wntdll.dll\r\n')


@unittest.skipIf(SH is None, 'sh not found')
class Nt52Staging(unittest.TestCase):
    def test_storage_rows(self):
        lib = posix(ROOT / 'tools' / 'nt5_storage_stage.sh')
        r = sh(f". '{lib}'; usos_nt5_storage_sif", TXTSETUP)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout.decode()
        # BusyBox awk keeps the CR of the input lines, MSYS awk drops it: compare
        # the text; the inserted rows always end in CRLF.
        lines = [l.rstrip('\r') for l in out.split('\n')]
        self.assertTrue(all(l.endswith('\r') for l in out.split('\n') if l.startswith('genahci') or l.startswith('PCI\\CC_010601')))
        self.assertEqual(lines[lines.index('[SourceDisksFiles]') + 1], 'genahci.sys = 1,,,,,,4_,4,1,,,1,4')
        self.assertEqual(out.count('genahci.sys = 1'), 1)
        self.assertEqual(lines[lines.index('[HardwareIdsDatabase]') + 1], 'PCI\\CC_010601 = "genahci"')
        self.assertEqual(lines[lines.index('[SCSI.Load]') + 1], 'genahci = genahci.sys,4')
        self.assertTrue(lines[lines.index('[SCSI]') + 1].startswith('genahci = "'))
        self.assertEqual(sh(f". '{lib}'; usos_nt5_storage_sif", r.stdout).returncode, 3)
        self.assertEqual(sh(f". '{lib}'; usos_nt5_storage_sif", b'[SetupData]\r\n').returncode, 3)

    def test_aliases_follow_the_source_directory(self):
        awk = posix(ROOT / 'tools' / 'xp_dosnet_aliases.awk')
        want = 'USETUP.EXE|SYSTEM32/SMSS.EXE\nNTDLL.DLL|SYSTEM32/NTDLL.DLL\n'
        for top, src in (('I386', ''), ('I386', 'I386'), ('amd64', 'AMD64')):
            r = sh(f"awk -v src_dir='{src}' -f '{awk}'", DOSNET.replace(b'{top}', top.encode()))
            self.assertEqual((r.returncode, r.stdout.decode()), (0, want), (top, src, r.stderr))
        self.assertEqual(sh(f"awk -v src_dir=I386 -f '{awk}'", DOSNET.replace(b'{top}', b'amd64')).returncode, 1)

    def test_profile_rows(self):
        lib = posix(ROOT / 'tools' / 'nt5_profile.sh')
        rows = {'windows-xp': 'I386 WINDOWS XP', 'windows-2000': 'I386 WINNT W2K',
                'windows-server-2003': 'I386 WINDOWS W2K3', 'windows-xp-x64': 'AMD64 WINDOWS XP64'}
        for system, want in rows.items():
            r = sh(f"NT5_SYSTEM={system}; . '{lib}'; usos_nt5_profile && printf '%s %s %s' \"$NT5_SOURCE_DIR\" \"$NT5_INSTALL_DIR\" \"$NT5_SETUP_DIR\"")
            self.assertEqual(r.stdout.decode(), want, system)
        for profile, generic in (('xp-x86-sp3-uefi-csm', 1), ('w2k3-x86-sp2-uefi-csm', 0), ('xp-x64-sp2-uefi-csm', 0), ('nt5-staging', 1)):
            r = sh(f"USOS_PLAN_PROFILE={profile}; . '{lib}'; usos_nt5_uefi_generic_profile")
            self.assertEqual(r.returncode, generic, profile)


if __name__ == '__main__':
    unittest.main()
