"""How to log on after the installation (docs/logon-after-install.md).

The UEFI menu writes EFI/USOS/answer/logon.ini (src/flow/answer/logon.zig,
no password); micro-Linux (tools/micro_linux_ui.sh usos_logon_*) shows its
line on the last pages and writes last-install-login.txt to the system's
DATA folder.
"""
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UI = ROOT / 'tools/micro_linux_ui.sh'
SH = shutil.which('sh') or r'C:\Program Files\Git\usr\bin\sh.exe'

INI = (
    '; USOS: how to log on after this installation (docs/logon-after-install.md). Never holds a password.\r\n'
    '[logon]\r\nsystem=windows-nt-3-1-server\r\nkind=account\r\nuser=Jan\r\ndomain=USOSDOMAIN\r\n'
    'password=profile\r\nautologon=no\r\nfile=\r\n'
    'line=After the installation log on to the domain USOSDOMAIN as Jan with the password set in the answer profile.\r\n'
    'line_local=Po instalacji zaloguj się do domeny USOSDOMAIN jako Jan hasłem ustawionym w profilu odpowiedzi.\r\n'
)


class LogonHint(unittest.TestCase):
    def run_sh(self, tmp, script, ini=INI):
        esp = Path(tmp) / 'esp'
        (esp / 'EFI/USOS/answer').mkdir(parents=True, exist_ok=True)
        if ini is not None:
            (esp / 'EFI/USOS/answer/logon.ini').write_bytes(ini.encode('utf-8'))
        data = Path(tmp) / 'data'
        (data / 'Systems/Windows/Windows NT 3.1 Server/Images').mkdir(parents=True, exist_ok=True)
        mounts = Path(tmp) / 'mounts'
        mounts.write_text(f'/dev/sdb2 {data.as_posix()} ntfs3 rw,noatime 0 0\n', encoding='ascii', newline='\n')
        env = dict(os.environ, USOS_UI_TTY=(Path(tmp) / 'tty').as_posix(), USOS_FB_ACTIVE='no',
                   USOS_LOGON_RUN=(Path(tmp) / 'logon.run').as_posix(), USOS_LOGON_MOUNTS=mounts.as_posix(),
                   ESP=esp.as_posix(), DATA=data.as_posix())
        body = f'. "{UI.as_posix()}"\nusos_ui_log() {{ :; }}\n' + script
        return subprocess.run([SH, '-c', body], capture_output=True, text=True, encoding='utf-8', env=env), data

    def test_take_save_and_dir(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, data = self.run_sh(tmp, '\n'.join([
                'usos_logon_take "$ESP" windows-nt-3-1-server || echo TAKE-FAIL',
                'printf "LINE=%s\\n" "$USOS_UI_LOGON"',
                'dir=$(usos_logon_dir_of "Systems/Windows/Windows NT 3.1 Server/Images/nt31as.iso")',
                'printf "DIR=%s\\n" "$dir"',
                'usos_logon_save "$DATA" "$dir" || echo SAVE-FAIL',
            ]))
            self.assertNotIn('FAIL', result.stdout, result.stderr)
            self.assertIn('LINE=After the installation log on to the domain USOSDOMAIN as Jan with the password set in the answer profile.', result.stdout)
            self.assertIn('DIR=Systems/Windows/Windows NT 3.1 Server\n', result.stdout)
            note = (data / 'Systems/Windows/Windows NT 3.1 Server/last-install-login.txt').read_bytes().decode('utf-8')
            self.assertIn('\r\nuser=Jan\r\ndomain=USOSDOMAIN\r\npassword=set in the answer profile (not stored here)\r\nautologon=no\r\n', note)
            self.assertIn('Po instalacji zaloguj się do domeny USOSDOMAIN', note)
            self.assertFalse((data / 'Systems/Windows/Windows NT 3.1 Server/last-install-login.txt.tmp').exists())

    def test_other_system_and_missing_file_are_ignored(self):
        with tempfile.TemporaryDirectory() as tmp:
            result, _ = self.run_sh(tmp, 'usos_logon_take "$ESP" windows-xp && echo TAKEN; printf "LINE=[%s]\\n" "$USOS_UI_LOGON"')
            self.assertIn('LINE=[]', result.stdout)
            self.assertNotIn('TAKEN', result.stdout)
        with tempfile.TemporaryDirectory() as tmp:
            result, data = self.run_sh(tmp, 'usos_logon_take "$ESP" windows-nt-3-51 || echo NONE; usos_logon_save "$DATA" "Systems/Windows/Windows NT 3.1 Server"; echo RC=$?', ini=None)
            self.assertIn('NONE', result.stdout)
            self.assertIn('RC=0', result.stdout)
            self.assertFalse((data / 'Systems/Windows/Windows NT 3.1 Server/last-install-login.txt').exists())

    def test_edition_entries_match_their_family(self):
        ini = INI.replace('system=windows-nt-3-1-server', 'system=windows-xp-mce')
        with tempfile.TemporaryDirectory() as tmp:
            result, _ = self.run_sh(tmp, 'usos_logon_take "$ESP" windows-xp && echo TAKEN', ini=ini)
            self.assertIn('TAKEN', result.stdout)

    def test_state_file_carries_the_line(self):
        with tempfile.TemporaryDirectory() as tmp:
            state = (Path(tmp) / 'state').as_posix()
            result, _ = self.run_sh(tmp, '\n'.join([
                'usos_logon_take "$ESP"',
                f'USOS_FB_ACTIVE=yes USOS_FB_UI=true USOS_FB_STATE="{state}"',
                'usos_ui_render_state done 5 5 T "" "" 100 0 0 0',
            ]))
            self.assertIn('logon=After the installation log on to the domain USOSDOMAIN as Jan', Path(state).read_text(encoding='utf-8'), result.stderr)

    def test_every_windows_flow_takes_the_hint_before_data_is_unmounted(self):
        for rel, unmount in (
            ('tools/legacy_xp_staging.sh', "umount /mnt/data || stop 'cannot unmount USOS_DATA after XP preparation'"),
            ('tools/w9x_csmwrap_prepare.sh', "umount /mnt/data 2>/dev/null || true\n    sync\n    w9x_csmwrap_log 'DONE; waiting for the restart'"),
            ('tools/vista_csmwrap_prepare.sh', "umount /mnt/data 2>/dev/null || true\n    sync\n    vista_csmwrap_log 'DONE; waiting for the restart'"),
            ('tools/micro_linux_init.sh', "umount /mnt/data || stop 'cannot unmount DATA'"),
        ):
            text = (ROOT / rel).read_text(encoding='utf-8')
            end = text.index(unmount)
            take = text.rfind('usos_logon_take /mnt/esp', 0, end)
            save = text.rfind('usos_logon_save /mnt/data', 0, end)
            self.assertTrue(0 <= take < save < end, rel)


if __name__ == '__main__':
    unittest.main()
