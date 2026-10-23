"""Host checks for 950 network-file staging before static registry binding."""
from pathlib import Path
import re, shutil, sys, tempfile, unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh, scratch
from test_w9x_reg95 import ANSWER_95, REG95
ROOT=Path(__file__).resolve().parents[2]
NET=(ROOT/'tools/network_setup.sh').as_posix()

class NetworkFiles(unittest.TestCase):
    def create(self, version='4 0 0 950', net=True):
        tmp=scratch('netfiles-');self.addCleanup(shutil.rmtree,tmp,ignore_errors=True)
        out=tmp/'USOS9X';(out/'NET').mkdir(parents=True)
        inf=tmp/'MSBATCH.INF';inf.write_bytes(ANSWER_95.encode('ascii'))
        reg=out/'NET/NET95.REG'
        script=f'. "{NET}"\n. "{REG95}"\n'
        if net:script+=f"usos_net_w95_reg 'PCI\\VEN_8086&DEV_10C9' 'BUS_00&DEV_03&FUNC_00' '82576' USOSNET82576.ndi 03 > '{reg.as_posix()}'\n"
        script+=f"w9x_reg95_write '{out.as_posix()}' '{inf.as_posix()}' '' '' '{reg.as_posix() if net else ''}' '{version}'\n"
        rc,so,err=sh(script,{})
        self.assertEqual(rc,0,so+err)
        batch=(out/'REG95.BAT').read_bytes()
        files=(out/'NET/NFILES.BAT').read_bytes() if (out/'NET/NFILES.BAT').exists() else None
        return batch,files

    def test_only_original_950_with_static_network(self):
        self.assertIsNotNone(self.create()[1])
        for version,net in [('4 0 0 1068',True),('4 0 0 1111',True),('',True),('4 0 0 950',False)]:
            batch,files=self.create(version,net)
            self.assertIsNone(files,(version,net))
            self.assertNotIn(b'NFILES',batch)

    def test_preparation_precedes_marker_and_registry(self):
        batch,_=self.create();s=batch.decode('ascii')
        call=s.index('CALL C:\\USOS9X\\NET\\NFILES.BAT')
        self.assertLess(s.index('IF NOT EXIST C:\\WINDOWS\\SYSTEM.DAT'),call)
        self.assertLess(call,s.index('ECHO run> C:\\USOS9X\\REG95.RUN'))
        self.assertLess(call,s.index('ATTRIB.EXE -S -R -H SYSTEM.DAT'))
        self.assertIn('IF NOT EXIST C:\\USOS9X\\NET\\NFILES.OK GOTO PREPERR',s)

    def test_existing_files_are_skipped_and_core_is_preserved(self):
        _,files=self.create();s=files.decode('ascii')
        extracts=re.findall(r'^C:\\WIN95\\EXTRACT.EXE .*$',s,re.M)
        self.assertGreater(len(extracts),40)
        for line in extracts:
            match=re.search(r'/L (\S+) C:\\WIN95\\(\S+) (\S+) >>',line)
            self.assertIsNotNone(match,line)
            dest,cab,name=match.groups()
            self.assertRegex(s,rf'IF EXIST {re.escape(dest)}\\{re.escape(name)} GOTO F[0-9]+\r\n{re.escape(line)}')
        self.assertNotIn('ndis.vxd',s.lower())
        self.assertNotIn('vmm32.vxd',s.lower())
        self.assertIn(r'COPY /Y C:\USOS9X\NET\USOSNET.SYS C:\WINDOWS\SYSTEM\USOSNET.SYS > NUL',s)
        self.assertIn(r'COPY /Y C:\USOS9X\NET\USOSNET.INF C:\WINDOWS\INF\USOSNET.INF > NUL',s)
        self.assertIn(r'C:\WIN95\PRECOPY1.CAB netapi.dll',s)
        for name in ('vredir.vxd','msnp32.dll','vdhcp.386','vtcp.386','winsock.dll'):
            self.assertIn('C:\\WIN95\\WIN95_02.CAB '+name,s)

    def test_dos_syntax_and_all_jump_targets(self):
        for batch in self.create():
            self.assertEqual(batch.count(b'\n'),batch.count(b'\r\n'))
            self.assertLessEqual(max(map(len,batch.split(b'\r\n'))),125)
            s=batch.decode('ascii')
            labels=re.findall(r'^:([A-Z0-9]+)\r?$',s,re.M)
            self.assertEqual(len(labels),len(set(labels)))
            self.assertTrue(all(len(label)<=8 for label in labels))
            self.assertFalse(set(re.findall(r'GOTO ([A-Z0-9]+)',s))-set(labels))
            self.assertNotIn('APPDATA',s.upper())

    def test_failure_restores_registry_attributes_and_blocks_start(self):
        batch,files=self.create();s=batch.decode('ascii')
        self.assertIn('IF EXIST C:\\USOS9X\\NET\\NET95.ERR GOTO PREPERR',s)
        self.assertIn('IF EXIST C:\\USOS9X\\NET\\NFILES.ERR GOTO PREPERR',s)
        self.assertIn('IF EXIST C:\\USOS9X\\NET\\NFILES.RUN GOTO PREPERR',s)
        self.assertIn('IF EXIST C:\\USOS9X\\REG95.RUN GOTO PREPERR',s)
        self.assertIn('IF NOT EXIST C:\\WINDOWS\\COMMAND\\FIND.EXE GOTO REGFAIL',s)
        failed=s.split(':REGFAIL\r\n')[1]
        self.assertIn('ATTRIB.EXE +S +R +H SYSTEM.DAT',failed)
        self.assertIn('ATTRIB.EXE +S +R +H USER.DAT',failed)
        self.assertNotIn('REG95.OK',failed)
        # Fail-soft: logged on the target disk, then Windows starts (no PAUSE loop).
        self.assertNotIn('PAUSE',s)
        tail=failed.split(':PREPERR\r\n')[1]
        self.assertIn('>> C:\\USOS9X\\USOSLOG.TXT\r\n:END',tail)
        self.assertNotIn('GOTO',tail)
        self.assertIn(b'NFILES.OK DEL',files)
        self.assertNotIn(b'NFILES.OK',files.split(b':FAIL\r\n')[1])

    def test_source_version_is_wired_and_generation_failure_is_terminal(self):
        target=(ROOT/'tools/w9x_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('"$reg95_net" "${setup_version:-}"',target)
        self.assertIn("fail 'RTM/OSR1 network files and registry helpers could not be prepared; target start withheld'",target)

if __name__=='__main__':unittest.main()
