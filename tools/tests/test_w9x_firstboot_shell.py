"""Source950 package boots with USOSFB as the Windows shell (host-only).

X470 95 OSR1 EN (2026-10-27, SHELL32 4.00.951): Explorer stopped waiting for
the RunOnce coordinator ~6 s into the second package run (FIRSTBT.LOG
tray=1). Package boots now run with SYSTEM.INI [boot] shell=USOSFB.EXE, the
final boot under Explorer again. Real Windows 95 behaviour is X470 evidence.
"""
from pathlib import Path
import shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
SRC=ROOT/'src/platform/win32_legacy/usosfb.c'
OUT=ROOT/'artifacts/firstboot/host-tests';OUT.mkdir(parents=True,exist_ok=True)
# 950 SYSTEM.INI head as Setup writes it (OSR1 EN run, 2026-10-27), shortened
INI=('[boot]\r\nsystem.drv=system.drv\r\ndrivers=mmsystem.dll power.drv\r\nuser.exe=user.exe\r\n'
     'comm.drv=comm.drv\r\nshell=Explorer.exe\r\nkeyboard.drv=keyboard.drv\r\n'
     '[boot.description]\r\nkeyboard.typ=Standard 101/102-Key\r\n[386Enh]\r\nmouse=*vmouse\r\n'
     'device=C:\\USOS9X\\USOSVMD.VXD\r\n[NonWindowsApp]\r\n')

def section(src,start,end):return src[src.index(start):src.index(end,src.index(start))]

class Generator(unittest.TestCase):
    def batch(self):
        target=Path(tempfile.mkdtemp(dir=OUT));self.addCleanup(shutil.rmtree,target)
        (target/'USOSFB.EXE').write_bytes(b'own helper fixture')
        script='. "$1"; w9x_firstboot_write "$2" "$3"'
        r=subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-c',script,'test',str(ROOT/'tools/w9x_firstboot.sh').replace('\\','/'),
                          str(target).replace('\\','/'),'4 0 0 950'],capture_output=True)
        self.assertEqual(r.returncode,0,r.stderr)
        return target,(target/'FIRSTBT.BAT').read_bytes().decode('ascii').split('\r\n')

    def test_header_and_restore_block_first(self):
        target,lines=self.batch()
        self.assertEqual((target/'SHELLHDR.INI').read_bytes(),b'[boot]\r\nshell=Explorer.exe\r\n')
        done=lines.index(r'IF EXIST C:\USOS9X\FIRSTBT.OK GOTO END')
        self.assertEqual(lines[1],r'IF NOT EXIST C:\USOS9X\SHELL.ON GOTO SHLEND')
        self.assertLess(lines.index(':SHLEND'),done)
        block=lines[1:lines.index(':SHLEND')]
        # restore when finished, failed, program gone, or a shell boot died
        for need in (r'IF EXIST C:\USOS9X\FIRSTBT.OK GOTO SHLFIX',r'IF EXIST C:\USOS9X\FIRSTBT.ERR GOTO SHLFIX',
                     r'IF NOT EXIST C:\USOS9X\USOSFB.EXE GOTO SHLFIX',r'IF NOT EXIST C:\USOS9X\SHELLRUN.FLG GOTO SHLEND'):
            self.assertIn(need,block)
        died=block.index(r'IF NOT EXIST C:\USOS9X\SHELLRUN.FLG GOTO SHLEND')
        self.assertEqual(block[died+1],r'ECHO USOSFB shell boot ended without its own restart> C:\USOS9X\SHELL.BAD')
        # 950 COPY sets no reliable ERRORLEVEL: never test one after COPY
        for i,l in enumerate(block):
            if l.startswith('COPY '):self.assertFalse(block[i+1].startswith('IF ERRORLEVEL') or block[i+1].startswith('IF NOT ERRORLEVEL'),l)
        # FIND reads stdin only (a file argument prints a "----------" header)
        for l in block:
            if 'FIND.EXE' in l:self.assertIn(' < ',l)
        self.assertLessEqual(max(map(len,lines)),127)

    def test_restore_rebuilds_explorer_shell(self):
        """Run the block's FIND/COPY steps with DOS FIND semantics on a 950 SYSTEM.INI."""
        target,lines=self.batch()
        header=(target/'SHELLHDR.INI').read_bytes().decode()
        shelled=INI.replace('shell=Explorer.exe','shell=C:\\USOS9X\\USOSFB.EXE')
        def find_v(text,needle):
            return ''.join(l for l in text.splitlines(True) if needle.lower() not in l.lower())
        block='\n'.join(lines)
        self.assertIn(r'FIND.EXE /V /I "[boot]" < C:\WINDOWS\SYSTEM.INI > C:\USOS9X\SYSTEM.SH1',block)
        self.assertIn(r'FIND.EXE /V /I "SHELL=C:\USOS9X\USOSFB.EXE" < C:\USOS9X\SYSTEM.SH1 > C:\USOS9X\SYSTEM.SH2',block)
        self.assertIn(r'COPY /B C:\USOS9X\SHELLHDR.INI + C:\USOS9X\SYSTEM.SH2 C:\USOS9X\SYSTEM.SHN > NUL',block)
        rebuilt=header+find_v(find_v(shelled,'[boot]'),'SHELL=C:\\USOS9X\\USOSFB.EXE')
        self.assertNotIn('USOSFB',rebuilt)
        self.assertTrue(rebuilt.startswith('[boot]\r\nshell=Explorer.exe\r\nsystem.drv=system.drv\r\n'))
        self.assertIn('[boot.description]\r\n',rebuilt)  # "[boot]" is not a substring of it
        self.assertEqual(sorted(rebuilt.splitlines()),sorted(INI.splitlines()))

class Coordinator(unittest.TestCase):
    src=SRC.read_text()

    def test_shell_mode_entry_is_guarded_and_verified(self):
        s=self.src;self.assertTrue(s.isascii())
        body=section(s,'static int shell_set(int usos){','static void leave(')
        self.assertIn('if(lstrcmpiA(value,"Explorer.exe"))',body)
        self.assertIn('if(!exists("SHELLHDR.INI"))',body)
        self.assertIn('!ini_text()||!boot_first()',body)
        # SHELL.ON before SYSTEM.INI changes: real mode can always undo it
        self.assertLess(body.index('save("SHELL.ON"'),body.index('WritePrivateProfileStringA("boot","shell",fbexe,sysini)'))
        self.assertIn('return ini_text()&&contains(text,"shell=C:\\\\USOS9X\\\\USOSFB.EXE");',body)
        self.assertIn('WritePrivateProfileStringA("boot","shell","Explorer.exe",sysini)',body)
        self.assertIn('drop("SHELL.ON");return 1;',body)
        # the profile cache is flushed before the file is read
        self.assertIn('WritePrivateProfileStringA(0,0,0,sysini);',section(s,'static int ini_text(','static int usos_shell('))

    def test_final_restart_restores_explorer_and_package_restarts_keep_shell(self):
        body=section(self.src,'static void reboot(','static DWORD child(const char*command){')
        self.assertIn('int last=!lstrcmpA(phase,"reboot\\r\\n");',body)
        self.assertIn('if(!shell_set(0))fail("cannot restore SYSTEM.INI shell=Explorer.exe before the final restart");',body)
        self.assertIn('else if(!exists("SHELL.BAD")){',body)
        self.assertIn('shell_set(1)&&save("SHELL.TRY",phase)',body)
        # arm() after the shell choice; the run flag goes right before the restart
        self.assertLess(body.index('shell_set(1)'),body.index('arm()'))
        self.assertLess(body.index('drop("SHELLRUN.FLG");'),body.index('ExitWindowsEx(EWX_REBOOT|EWX_FORCE,0)'))

    def test_failure_restores_explorer_before_the_box(self):
        body=section(self.src,'static void fail(','static int setup_done(')
        self.assertLess(body.index('shell_set(0)'),body.index('MessageBoxA('))
        self.assertLess(body.index('drop("SHELLRUN.FLG");'),body.index('MessageBoxA('))
        self.assertIn('leave(2);}',body)
        leave=section(self.src,'static void leave(','static void fail(')
        self.assertIn('if(shell_mode){',leave)
        self.assertIn('ExitWindowsEx(EWX_REBOOT,0)',leave)
        self.assertIn('child("C:\\\\WINDOWS\\\\EXPLORER.EXE")',leave)

    def test_start_handoff_and_runonce_order(self):
        s=self.src;start=s[s.index('void __cdecl fb_start(void){'):]
        self.assertLess(start.index('shell_mode=usos_shell();'),start.index('journal=CreateFileA'))
        self.assertIn('if(journal==INVALID_HANDLE_VALUE)leave(2);',start)
        self.assertIn('save("SHELLRUN.FLG"',start);self.assertIn('drop("SHELL.TRY");',start)
        self.assertIn('else if(exists("SHELL.TRY")){',start)  # shell= set but Explorer came: no loop
        self.assertIn('log_line("already complete");leave(0);',start)
        self.assertIn('automatic retry refused (FIRSTBT.ERR present)");leave(2);',start)
        handoff=start.index('if(shell_mode)run_once_values();')
        self.assertLess(start.index('if(!setup_done())'),handoff)
        self.assertLess(start.index('read_local("FIRSTBT.STA"'),handoff)
        self.assertIn('reboot(phase[0]?phase:"late\\r\\n","restart: package boots continue with USOSFB as the Windows shell");',start)
        # no mouse INF, display or package work before the handoff
        for later in ('finish_mouse();','USOSRES.EXE /setup','USOSADD.EXE /setup','finish_runonceex();'):
            self.assertLess(handoff,start.index(later),later)

    def test_runonce_like_explorer(self):
        body=section(self.src,'static void run_once_values(void){','static DWORD ex_sections(')
        self.assertIn('RegEnumValueA(key,index,',body)
        # each value deleted before its command, then waited for
        self.assertLess(body.index('RegDeleteValueA(key,name)'),body.index('code=child(cmd);'))
        self.assertIn('if(!lstrcmpiA(name,"USOSVmd")){RegCloseKey(key);index++;continue;}',body)
        self.assertIn('if(!lstrcmpiA(name,"USOSFirstBoot")){',body)
        self.assertIn('while(done<64){',body)
        self.assertIn('if(code!=ERROR_SUCCESS){wsprintfA(line,"RunOnce %s not deleted',body)
        self.assertNotIn('HKEY_CURRENT_USER',body)

    def test_osr2_scope_display_and_mouse(self):
        """95 OSR2 under the coordinator (X470 OSR2.1 PL native 2026-10-27):
        builds 1111 / 1212 / 1214 / 1216 next to 950; no VESALATE on OSR2,
        so VESA95's one attempt is the display boundary; the REG95 USOSVmd
        RunOnce value still queued counts as the mouse's late command."""
        s=self.src
        build=section(s,'static int coordinated_build(DWORD minor,DWORD build){','static int vmd_queued(')
        self.assertIn('if(minor==0)return build==950||build==1111||build==1212||build==1214||build==1216;',build)
        start=s[s.index('void __cdecl fb_start(void){'):]
        self.assertIn('!coordinated_build(version.dwMinorVersion,version.dwBuildNumber)',start)
        self.assertNotIn('!=950',start)
        disp=section(s,'static int display_ready(void){','static int coordinated_build(')
        self.assertIn('if(exists("VESALATE.BAT"))return exists("VLATE.OK");',disp)
        self.assertIn('return exists("VESA95.OK")||exists("VESA95.BAD")||!exists("VESA95.BAT");',disp)
        self.assertNotIn('exists("VLATE.OK")||',start)
        self.assertIn('if(!display_ready()||!tz_ready()){',start)
        late=section(s,'static int late_ready(void){','static void run_once_values(')
        self.assertIn('if(!display_ready()||!tz_ready()||(!win98&&!exists("REG95.OK")))',late)
        self.assertIn('exists("VLATE.ERR")',late)
        # The OSR2 network markers are the 950 ones (NET95L.BAT writes NET95.OK there).
        self.assertIn('if(!win98&&exists("NET\\\\NET95.REG")&&(!exists("NET\\\\NET95.OK")||!exists("NET\\\\NLATE.OK")||!exists("NET\\\\NFILES.OK"))',late)
        mouse=section(s,'static void finish_mouse(void){','static int tz_ready(')
        self.assertIn('if(!(exists("VMDLATE.RUN")||(!exists("VMDLATE.BAT")&&vmd_queued()))||exists("VMDLATE.ERR")||',mouse)
        queued=section(s,'static int vmd_queued(void){','static int mouse_configured(')
        self.assertIn('RegQueryValueExA(key,"USOSVmd",0,&type,',queued)
        self.assertIn('contains(text,"C:\\\\USOS9X\\\\USOSVMD.INF")',queued)

    def test_98_scope_and_gates(self):
        r"""98 FE (4.10.1998) / 98 SE (4.10.2222) under the coordinator: 95's
        gates stay for 4.00; 98 has no REG95.OK / NET95 step / Network\Logon
        fix, nine package restarts, and a first start that tolerates a
        taskbar and waits out RunOnce\Setup without FIRSTBT.ERR."""
        s=self.src
        build=section(s,'static int coordinated_build(DWORD minor,DWORD build){','static int vmd_queued(')
        self.assertIn('return minor==10&&(build==1998||build==2222);}',build)
        self.assertNotIn('3000',build)    # Me: no AUTOEXEC.BAT, stays out
        start=s[s.index('void __cdecl fb_start(void){'):]
        self.assertIn('win98=version.dwMinorVersion==10;',start)
        self.assertLess(start.index('win98=version.dwMinorVersion==10;'),start.index('coordinator entered before desktop'))
        first=start[start.index('if(win98&&!shell_mode&&!exists("FIRSTBT.STA")){'):start.index('if(shell_mode)run_once_values();')]
        self.assertIn('if(!setup_done()){log_line("98: original RunOnce Setup not finished; the coordinator starts again at the next boot");leave(0);}',first)
        self.assertNotIn('fail(',first.split('else if')[0])
        # 95 keeps both hard checks in their old order
        self.assertIn('else if(FindWindowA("Shell_TrayWnd",0))fail("ordinary RunOnce started after desktop");',first)
        self.assertLess(first.index('else if(FindWindowA'),first.index('if(!setup_done())fail("original RunOnce Setup has not completed");'))
        self.assertLess(first.index('if(!setup_done())fail('),first.index('read_local("FIRSTBT.STA"'))
        logon=section(s,'static void windows_logon(void){','static int mid_limit(void)')
        self.assertLess(logon.index('if(win98){'),logon.index('RegOpenKeyExA'))
        self.assertIn('static int mid_limit(void){return win98?9:4;}',s)
        self.assertIn("phase[3]>='1'&&phase[3]-'0'<=mid_limit()&&",s)
        self.assertIn('if(mid>=mid_limit())fail(',s)

    def test_install_phase_resumes(self):
        """A restart or Retry inside the package boundary (FIRSTBT.STA
        "install", OSR2.1 X470 2026-10-27) runs the boundary again instead of
        "unknown phase"; under Explorer it goes to a shell boot like late."""
        start=self.src[self.src.index('void __cdecl fb_start(void){'):]
        self.assertIn('!lstrcmpA(phase,"late\\r\\n")||!lstrcmpA(phase,"install\\r\\n")||mid_phase(phase))){',start)
        self.assertIn('if(phase[0]&&lstrcmpA(phase,"late\\r\\n")&&lstrcmpA(phase,"install\\r\\n")&&!mid)fail("unknown phase',start)
        # the install boundary itself: journal, USOSRES (DISPLAY.DONE ends it), USOSADD (STATE.INI)
        tail=start[start.index('resume: package boundary (install) runs again'):]
        self.assertLess(tail.index('save("FIRSTBT.STA","install\\r\\n")'),tail.index('USOSRES.EXE /setup'))
        self.assertLess(tail.index('USOSRES.EXE /setup'),tail.index('USOSADD.EXE /setup")'))

    def test_child_logs_a_taskbar_and_long_commands_fit(self):
        body=section(self.src,'static DWORD child(const char*command){','static int legacy_absent(')
        self.assertIn('MsgWaitForMultipleObjects(1,&pi.hProcess,FALSE,500,QS_ALLINPUT)',body)
        self.assertIn('WARNING: desktop taskbar (Shell_TrayWnd) appeared while this child runs',body)
        self.assertIn('lstrcpynA(cmd,command,sizeof cmd)',body)
        self.assertIn('char line[1100];',section(self.src,'static void log_line(','static int save('))

if __name__=='__main__':unittest.main()
