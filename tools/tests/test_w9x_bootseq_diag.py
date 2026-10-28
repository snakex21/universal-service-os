"""Boot-sequence diagnostics and progress box (host-only, no QEMU, no disk).

X470 98 FE PL 2026-10-28: a package boot (the first after IE 6 SP1 and its
WININIT renames) died in Windows startup with no record; BOOTLOG.TXT/.PRV
held only the two boots before the first WININIT boot although MSDOS.SYS
kept BootLog=1. .NET 2.0 ran for minutes with a still USOSADD box.
Real-mode DOS behaviour stays X470 evidence; these tests check the generated
batch, a small model of its counter chain, and the sources.
"""
from pathlib import Path
import re,shutil,subprocess,sys,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]
OUT=ROOT/'artifacts/firstboot/host-tests';OUT.mkdir(parents=True,exist_ok=True)
sys.path.insert(0,str(ROOT/'tools/addons'))

def generate(version):
    target=Path(tempfile.mkdtemp(dir=OUT))
    (target/'USOSFB.EXE').write_bytes(b'own helper fixture')
    r=subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-c','. "$1"; w9x_firstboot_write "$2" "$3"','test',
                      str(ROOT/'tools/w9x_firstboot.sh').replace('\\','/'),str(target).replace('\\','/'),version],
                     capture_output=True,timeout=60)
    return target,r

class BootSeq(unittest.TestCase):
    def batch(self,version):
        target,r=generate(version);self.addCleanup(shutil.rmtree,target)
        self.assertEqual(r.returncode,0,r.stderr)
        return target,(target/'FIRSTBT.BAT').read_bytes().decode('ascii').split('\r\n')

    def test_98_only_keeps_bootlog_marker(self):
        t98,_=self.batch('4 10 0 1998');t95,_=self.batch('4 0 0 950')
        self.assertTrue((t98/'BOOTLOG.ON').is_file());self.assertFalse((t95/'BOOTLOG.ON').exists())
        self.assertEqual((t98/'FIRSTBT.BAT').read_bytes(),(t95/'FIRSTBT.BAT').read_bytes())
        target=(ROOT/'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('"$work/c/USOS9X/SHELLHDR.INI" "$work/c/USOS9X/BOOTLOG.ON"',target)

    def test_block_place_and_dos_rules(self):
        _,lines=self.batch('4 10 0 1998')
        shl=lines.index(':SHLEND');done=lines.index(r'IF EXIST C:\USOS9X\FIRSTBT.OK GOTO END')
        self.assertEqual(lines[shl+1],r'IF EXIST C:\USOS9X\LOGS\BOOTSEQ.END GOTO BSDONE')
        self.assertEqual(lines[done-1],':BSDONE')
        block=lines[shl:done]
        self.assertLessEqual(max(map(len,lines)),127)
        labels=[l[1:].upper() for l in lines if l.startswith(':')]
        self.assertEqual(len(labels),len(set(labels)))
        self.assertEqual(len({l[:8] for l in labels}),len(labels))   # DOS: 8 significant chars
        for i,l in enumerate(block):
            if l.startswith('C:\\WINDOWS\\COMMAND\\FIND.EXE'):self.assertIn(' < ',l)
            if l.startswith('COPY '):self.assertFalse(block[i+1].startswith(('IF ERRORLEVEL','IF NOT ERRORLEVEL')),l)
        # BOOTLOG.TXT may be hidden: read by TYPE, never COPY / ATTRIB
        self.assertIn(r'TYPE C:\BOOTLOG.TXT> C:\USOS9X\LOGS\BOOT%U9BN%.TXT',block)
        self.assertFalse([l for l in block if 'BOOTLOG.TXT' in l and (l.startswith('COPY') or 'ATTRIB' in l)])
        for need in (r'IF EXIST C:\WINDOWS\WININIT.INI ECHO',r'IF EXIST C:\USOS9X\FIRSTBT.STA TYPE C:\USOS9X\FIRSTBT.STA>> C:\USOS9X\LOGS\BOOTSEQ.TXT'):
            self.assertTrue([l for l in block if l.startswith(need)],need)
        # MSDOS.SYS is only written when BootLog=1 is missing (98) or for the restore
        writes=[i for i,l in enumerate(block) if l.endswith(r'C:\MSDOS.SYS > NUL') and l.startswith('COPY')]
        self.assertEqual(len(writes),2)
        self.assertLess(block.index(r'IF NOT EXIST C:\USOS9X\BOOTLOG.ON GOTO BLDONE'),min(writes))
        self.assertLess(block.index(r'IF NOT EXIST C:\USOS9X\LOGS\BOOTLOG.FRC GOTO BLDONE'),writes[1])
        self.assertEqual(block[block.index(':BLLOCK')+1],r'C:\WINDOWS\COMMAND\ATTRIB.EXE +H +S +R C:\MSDOS.SYS')

    def run_chain(self,lines,present):
        """Model of the counter: IF EXIST/GOTO/REN/SET/DEL up to :BNGO."""
        files=set(present);env={};i=lines.index(':SHLEND')+1;steps=0
        while lines[i]!=':BNGO' and lines[i]!=':BSDONE':
            steps+=1;self.assertLess(steps,500);l=lines[i]
            m=re.fullmatch(r'IF (NOT )?EXIST (\S+) (.*)',l)
            if m:
                hit=(m.group(2).upper() in files)!=bool(m.group(1))
                if m.group(2).upper().endswith(r'\NUL'):hit=not m.group(1)   # LOGS exists
                if not hit:i+=1;continue
                l=m.group(3)
            if l.startswith('GOTO '):i=lines.index(':'+l[5:]);continue
            if l.startswith('REN '):
                src,new=l[4:].split(' ');files.remove(src.upper());files.add((src.rsplit('\\',1)[0]+'\\'+new).upper())
            elif l.startswith('SET '):k,v=l[4:].split('=',1);env[k]=v
            elif l.startswith('DEL '):files.discard(l[4:].upper())
            elif l.startswith('ECHO ') and '> ' in l:files.add(l.rsplit('> ',1)[1].upper())
            i+=1
        return lines[i],env.get('U9BN'),files

    def test_counter_counts_and_keeps_twelve_copies(self):
        _,lines=self.batch('4 10 0 1998')
        logs='C:\\USOS9X\\LOGS\\'
        files=set()
        for boot in range(1,41):
            end,n,files=self.run_chain(lines,files)
            self.assertEqual((end,n),(':BNGO','%02d'%boot))
            files.add(f'{logs}BOOT{n}.TXT')          # the TYPE copy of this boot
            copies=sorted(f for f in files if re.search(r'\\BOOT\d\d\.TXT$',f))
            self.assertEqual(len(copies),min(boot,12))
            self.assertEqual([f for f in files if 'BOOTNUM' in f],[f'{logs}BOOTNUM.{n}'])
        end,_,_=self.run_chain(lines,files)
        self.assertEqual(end,':BSDONE')               # boot 41+: nothing more recorded
        end,_,_=self.run_chain(lines,{f'{logs}BOOTSEQ.END'})
        self.assertEqual(end,':BSDONE')

class Sources(unittest.TestCase):
    def test_usosfb_first_line_before_any_work(self):
        src=(ROOT/'src/platform/win32_legacy/usosfb.c').read_text(encoding='ascii')
        body=src[src.index('void __cdecl fb_start(void)'):]
        self.assertLess(body.index('start_line();'),body.index('shell_mode=usos_shell();'))
        self.assertLess(body.index('start_line();'),body.index('session_window();'))
        fn=src[src.index('static void start_line(void)'):src.index('void __cdecl fb_start(void)')]
        self.assertIn('"USOSFB start, phase %s"',fn);self.assertIn('log_line(line)',fn)
        # log_line writes and flushes each line
        self.assertIn('WriteFile(journal,line,length(line),&n,0);FlushFileBuffers(journal);',src)

    def test_usosans_chain_state_from_firstbt_markers(self):
        src=(ROOT/'src/platform/bios/win9x/usosans.c').read_text(encoding='ascii')
        start=src.index('pending = addons_pending();');msg=src[start:src.index('say(line);',start)]
        for need in ('!beside("FIRSTBT.ON") ? (pending ? "pending" : "over")','beside("FIRSTBT.OK") ? "over (USOSFB: FIRSTBT.OK)"',
                     'beside("FIRSTBT.ERR") ? "stopped (USOSFB: FIRSTBT.ERR)"','"pending (USOSFB: no FIRSTBT.OK / ERR yet)"'):
            self.assertIn(need,msg)
        self.assertIn('an_remove_now(g_boots, g_desk, pending, chain_open())',src)   # decision unchanged

    def test_usosadd_elapsed_timer_and_slow_note(self):
        src=(ROOT/'src/platform/win32_legacy/usosadd/main.c').read_text(encoding='ascii')
        self.assertIn('SetTimer(g_wnd, UA_TICK_TIMER, 1000, 0)',src)
        self.assertIn('if (msg == WM_TIMER && wp == UA_TICK_TIMER)',src)
        self.assertIn(r'"Up\263yn\352\263o: " : "Elapsed: "',src)
        self.assertIn(r'"\r\nTo mo\277e potrwa\346 kilka minut." : "\r\nThis may take several minutes."',src)
        run=src[src.index('static void run_chain(void)'):]
        self.assertLess(run.index('status_package(line);'),run.index('ok = run_one(p, cmd);'))
        self.assertLess(run.index('ok = run_one(p, cmd);'),run.index('timing_off();'))
        # every other status() line stops the clock
        st=src[src.index('static void status(const char *text)'):]
        self.assertLess(st.index('timing_off();'),st.index('status_draw();'))

    def test_slow_packages_flagged_and_validated(self):
        import legacy_manifest as lm
        m=lm.Manifest.load()
        slow={p.id for p in m.packages if p.get('slow')=='1'}
        for pid in ('dotnet20','dotnet20-pl','dx9c','mdac28sp1-pl','ie6sp1-pl-9x'):self.assertIn(pid,slow)
        self.assertEqual(lm.validate(m),[])
        m.find('dx9c').keys['slow']='yes'
        self.assertTrue(any("slow 'yes'" in e for e in lm.validate(m)))

if __name__=='__main__':unittest.main()
