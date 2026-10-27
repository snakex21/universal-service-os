"""Host checks for 950 / OSR2 network-file staging before static registry binding."""
from pathlib import Path
import re, shutil, sys, tempfile, unittest
sys.path.insert(0,str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh, scratch
from test_w9x_reg95 import ANSWER_95, REG95
ROOT=Path(__file__).resolve().parents[2]
NET=(ROOT/'tools/network_setup.sh').as_posix()

# Cabinet numbers of the network files on the 95 OSR2.1 PL CD (its
# LAYOUT.INF [SourceDisksFiles]); a synthetic LAYOUT.INF is built from them.
OSR2_DISKS={'netapi.dll':2,'mstcp.dll':1,'mapi32.dll':11,'vlb32.dll':11,
    **{n:18 for n in 'rpcltc1.dll pmspl.dll msnet32.dll msab32.dll msnp32.dll mspp32.dll choosusr.dll winpopup.cnt vtdi.386 vip.386 vtcp.386 vdhcp.386 vnbt.386 icmp.dll rpcltc3.dll rpclts3.dll inetmib1.dll winsock.dll'.split()},
    **{n:19 for n in 'vredir.vxd vnetsup.vxd mssp.vxd lmscript.exe lmscript.pif filesec.vxd net.exe net.msg neth.msg winpopup.exe winpopup.hlp afvxd.vxd wshtcp.vxd wsock.vxd wsasrv.exe ping.exe telnet.exe telnet.hlp ftp.exe hosts.sam lmhosts.sam networks protocol services arp.exe nbtstat.exe netstat.exe route.exe tracert.exe winipcfg.exe'.split()}}
OSR2_CABS={1:'PRECOPY1.CAB',2:'PRECOPY2.CAB',**{n:'win95_%02d.cab'%(n-1) for n in range(3,28)}}

def osr2_setup_folder(parent,disks=OSR2_DISKS,name='WIN95'):
    """parent/<name>/LAYOUT.INF (synthetic, CR LF, the CD's form)."""
    folder=parent/name;folder.mkdir(parents=True,exist_ok=True)
    lines=['[version]','signature="$CHICAGO$"','','[SourceDisksNames]','; <cab#> = <disk#>,<cabinet filename>, ID']
    lines+=[f'{n}="Windows 95 CD-ROM","{c}",0' for n,c in OSR2_CABS.items()]
    lines+=['','[SourceDisksFiles]',';<file> = <cabinet number>,<subdir>,<filename>,<size>,<checksum>','other.dll=5,,100']
    lines+=[f'{f}={d},,1234' for f,d in disks.items()]
    (folder/'LAYOUT.INF').write_bytes(('\r\n'.join(lines)+'\r\n').encode('ascii'))
    (folder/'LAYOUT1.INF').write_bytes(b'[SourceDisksFiles]\r\nnetapi.dll=7,,1\r\n')   # the first layout wins
    return folder

class NetworkFiles(unittest.TestCase):
    def create(self, version='4 0 0 950', net=True, folder='auto', rc=0):
        tmp=scratch('netfiles-');self.addCleanup(shutil.rmtree,tmp,ignore_errors=True)
        out=tmp/'USOS9X';(out/'NET').mkdir(parents=True)
        inf=tmp/'MSBATCH.INF';inf.write_bytes(ANSWER_95.encode('ascii'))
        reg=out/'NET/NET95.REG'
        if folder=='auto':folder=osr2_setup_folder(tmp) if version not in ('4 0 0 950','') else None
        elif callable(folder):folder=folder(tmp)
        script=f'. "{NET}"\n. "{REG95}"\n'
        if net:script+=f"usos_net_w95_reg 'PCI\\VEN_8086&DEV_10C9' 'BUS_00&DEV_03&FUNC_00' '82576' USOSNET82576.ndi 03 > '{reg.as_posix()}'\n"
        script+=f"w9x_reg95_write '{out.as_posix()}' '{inf.as_posix()}' '' '' '{reg.as_posix() if net else ''}' '{version}' '' '{folder.as_posix() if folder else ''}'\n"
        code,so,err=sh(script,{})
        self.assertEqual(code,rc,so+err)
        if rc:return None,None
        self.out=out
        batch=(out/'REG95.BAT').read_bytes()
        files=(out/'NET/NFILES.BAT').read_bytes() if (out/'NET/NFILES.BAT').exists() else None
        return batch,files

    def test_950_and_osr2_with_static_network_only(self):
        self.assertIsNotNone(self.create()[1])
        for version in ('4 0 0 1068','4 0 0 1111','4 0 0 1216'):
            batch,files=self.create(version)
            self.assertIsNotNone(files,version);self.assertIn(b'CALL C:\\USOS9X\\NET\\NFILES.BAT',batch)
        for version,net in [('',True),('4 0 0 950',False),('4 0 0 1111',False)]:
            batch,files=self.create(version,net)
            self.assertIsNone(files,(version,net))
            self.assertNotIn(b'NFILES',batch)

    def test_osr2_needs_its_win95_folder_and_a_complete_layout(self):
        """NFILES.BAT extracts from C:\\WIN95 with this CD's cabinets: no
        folder, another folder name, or a layout without a file refuses."""
        self.create('4 0 0 1111',folder=None,rc=1)
        self.create('4 0 0 1111',folder=lambda t:osr2_setup_folder(t,name='WIN9X'),rc=1)
        self.create('4 0 0 1111',folder=lambda t:t/'EMPTY',rc=1)
        less={k:v for k,v in OSR2_DISKS.items() if k!='vredir.vxd'}
        self.create('4 0 0 1111',folder=lambda t:osr2_setup_folder(t,less),rc=1)
        nocab=dict(OSR2_DISKS,**{'vtcp.386':0})                     # not in a cabinet
        self.create('4 0 0 1111',folder=lambda t:osr2_setup_folder(t,nocab),rc=1)

    def test_osr2_cabinets_come_from_the_layout(self):
        _,files=self.create('4 0 0 1111');s=files.decode('ascii')
        self.assertIn('REM USOS: original OSR2 network files',s)
        pairs=[]
        for line in re.findall(r'^EXTRACT.EXE .*$',s,re.M):
            cab,names=re.search(r'/Y C:\\WIN95\\(\S+) (.+) >>',line).groups()
            pairs+=[(n,cab) for n in names.split()]
        self.assertEqual(len(pairs),52);self.assertEqual(len({n for n,_ in pairs}),52)
        for name,cab in pairs:
            self.assertEqual(cab,OSR2_CABS[OSR2_DISKS[name]].upper(),name)
        self.assertEqual(dict(pairs)['netapi.dll'],'PRECOPY2.CAB')      # LAYOUT.INF before LAYOUT1.INF
        self.assertEqual(dict(pairs)['mstcp.dll'],'PRECOPY1.CAB')
        checks=re.findall(r'^IF NOT EXIST C:\\WIN95\\(\S+) GOTO FAIL\r$',s,re.M)
        self.assertEqual(checks,['EXTRACT.EXE','PRECOPY2.CAB','WIN95_18.CAB','WIN95_17.CAB','WIN95_10.CAB','PRECOPY1.CAB'])
        self.assertRegex(s,r'IF EXIST C:\\WINDOWS\\SYSTEM\\mstcp.dll GOTO F[0-9]+\r\nIF NOT EXIST mstcp.dll GOTO FAIL')
        self.assertIn('COPY /Y winsock.dll C:\\WINDOWS\\winsock.dll > NUL',s)
        self.assertIn('COPY /Y winpopup.hlp C:\\WINDOWS\\HELP\\winpopup.hlp > NUL',s)

    def test_950_batch_is_unchanged_by_the_layout_support(self):
        _,files=self.create();s=files.decode('ascii')
        self.assertIn('REM USOS: original 950 network files before the NET95 registry import.\r\n',s)
        self.assertEqual(re.findall(r'^IF NOT EXIST C:\\WIN95\\(\S+) GOTO FAIL\r$',s,re.M),['EXTRACT.EXE','PRECOPY1.CAB','WIN95_02.CAB'])
        self.assertNotIn('mstcp.dll',s)

    def test_preparation_precedes_marker_and_registry(self):
        batch,_=self.create();s=batch.decode('ascii')
        call=s.index('CALL C:\\USOS9X\\NET\\NFILES.BAT')
        self.assertLess(s.index('IF NOT EXIST C:\\WINDOWS\\SYSTEM.DAT'),call)
        self.assertLess(call,s.index('ECHO run> C:\\USOS9X\\REG95.RUN'))
        self.assertLess(call,s.index('ATTRIB.EXE -S -R -H SYSTEM.DAT'))
        self.assertIn('IF NOT EXIST C:\\USOS9X\\NET\\NFILES.OK GOTO PREPERR',s)

    def test_existing_files_are_skipped_and_core_is_preserved(self):
        _,files=self.create();s=files.decode('ascii')
        extracts=re.findall(r'^EXTRACT.EXE .*$',s,re.M)
        self.assertGreater(len(extracts),1)
        self.assertLessEqual(len(extracts),15, 'Do not scan all cabinets once per missing file')
        extracted=[]
        for line in extracts:
            match=re.search(r'/Y C:\\WIN95\\(\S+) (.+) >>',line)
            self.assertIsNotNone(match,line)
            cab,names=match.groups();extracted.extend(names.split())
            self.assertTrue(cab in ('PRECOPY1.CAB','WIN95_02.CAB'))
        self.assertEqual(len(extracted),51)
        self.assertEqual(len(extracted),len(set(extracted)))
        copies=re.findall(r'^COPY /Y ([^ \\]+) (C:\\WINDOWS(?:\\SYSTEM|\\HELP)?\\[^ ]+) > NUL\r?$',s,re.M)
        self.assertEqual(len(copies),51)
        for name,dest in copies:
            self.assertIn(name,extracted)
            self.assertRegex(s,rf'IF EXIST {re.escape(dest)} GOTO F[0-9]+\r\nIF NOT EXIST {re.escape(name)} GOTO FAIL\r\nCOPY /Y {re.escape(name)} {re.escape(dest)} > NUL')
        self.assertIn('CD \\USOS9X\\NET\\NF\r\n',s)
        self.assertTrue(s.endswith(':END\r\nC:\r\nCD \\WINDOWS\r\n'))
        self.assertNotIn('ndis.vxd',s.lower())
        self.assertNotIn('vmm32.vxd',s.lower())
        self.assertIn(r'COPY /Y C:\USOS9X\NET\USOSNET.SYS C:\WINDOWS\SYSTEM\USOSNET.SYS > NUL',s)
        self.assertIn(r'COPY /Y C:\USOS9X\NET\USOSNET.INF C:\WINDOWS\INF\USOSNET.INF > NUL',s)
        self.assertIn(r'C:\WIN95\PRECOPY1.CAB netapi.dll',s)
        for name in ('vredir.vxd','msnp32.dll','vdhcp.386','vtcp.386','winsock.dll'):
            self.assertIn(name,extracted)

    def test_dos_syntax_and_all_jump_targets(self):
        for batch in self.create()+self.create('4 0 0 1111'):
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
