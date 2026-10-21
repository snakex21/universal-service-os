"""RTM binary ABI prerequisites, real staging selection, and one-shot timer."""
from pathlib import Path
import ast
import os
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[2]
DRIVER=ROOT/'tools/nt/usosnet/bin/i386/win95-rtm/usosnet4.sys'
OLD=ROOT/'tools/nt/usosnet/bin/i386/usosnet4.sys'
OUT=ROOT/'artifacts/ndis31-tests'
tree=ast.parse((ROOT/'tools/tests/check_nt52_driver_imports.py').read_text())
namespace={'Path':Path,'struct':struct}
exec(compile(ast.Module(body=[n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='pe'],
    type_ignores=[]),'own_pe_reader','exec'),namespace)

def imports(path):
    return set(namespace['pe'](path)[1])

def headers():
    data=DRIVER.read_bytes();offset=struct.unpack_from('<I',data,60)[0]
    return data,offset,offset+24

def entry_bytes():
    data,offset,optional=headers()
    entry=struct.unpack_from('<I',data,optional+16)[0]
    sections=struct.unpack_from('<H',data,offset+6)[0]
    table=optional+struct.unpack_from('<H',data,offset+20)[0]
    for i in range(sections):
        size,va,raw_size,raw=struct.unpack_from('<IIII',data,table+i*40+8)
        if va<=entry<va+max(size,raw_size):return data[raw+entry-va:raw+entry-va+256]
    raise ValueError('Entry point outside the image')

class Binary(unittest.TestCase):
    def test_import_contract_replaces_only_the_unavailable_apis(self):
        expected=imports(OLD)-{('ndis.sys','NdisMSetAttributesEx'),('ndis.sys','NdisMSetPeriodicTimer')}
        expected|={('ndis.sys','NdisMSetAttributes'),('ndis.sys','NdisSetTimer')}
        self.assertEqual(imports(DRIVER),expected)

    def test_native_pe4_has_relocations_and_no_vector_instructions(self):
        data,offset,optional=headers()
        self.assertEqual((struct.unpack_from('<H',data,offset+4)[0],struct.unpack_from('<H',data,optional)[0]),(0x14c,0x10b))
        self.assertEqual((struct.unpack_from('<H',data,optional+68)[0],struct.unpack_from('<H',data,optional+48)[0]),(1,4))
        self.assertTrue(struct.unpack_from('<I',data,optional+96+5*8+4)[0])
        assembly=subprocess.check_output([r'C:\msys64\mingw64\bin\objdump.exe','-d',str(DRIVER)],text=True)
        self.assertIn('<_DriverEntry@8>',assembly)
        self.assertIsNone(re.search(r'\b(?:xmm|ymm|zmm|mm)[0-9]+\b',assembly))

    def test_registration_uses_ndis3_size_and_version(self):
        entry=entry_bytes()
        self.assertIn(b'\x66\xc7\x01\x03\x00',entry) # major 3, minor 0 in the characteristics
        self.assertIn(b'\x6a\x3c',entry) # NDIS 3 characteristics, 60 bytes
        self.assertNotIn(b'\x6a\x48',entry)

class Staging(unittest.TestCase):
    def setUp(self):
        OUT.mkdir(parents=True,exist_ok=True)
        self.temp=tempfile.TemporaryDirectory(dir=OUT)
        self.addCleanup(self.temp.cleanup)
        self.work=Path(self.temp.name)
        self.lib=self.work/'lib/network';(self.lib/'win95-rtm').mkdir(parents=True)
        self.target=self.work/'target';self.target.mkdir()
        self.pci=self.work/'pci';card=self.pci/'0000-08-00.0';card.mkdir(parents=True)
        for k,v in {'vendor':'0x8086','device':'0x1539','subsystem_vendor':'0x1849',
                    'subsystem_device':'0x1539','revision':'0x03','class':'0x020000'}.items():
            (card/k).write_text(v+'\n')
        for name in ('usosnet95.inf','usosnet95rtm.inf'):
            shutil.copyfile(ROOT/'tools/nt/usosnet/inf'/name,self.lib/name)
        shutil.copyfile(OLD,self.lib/'usosnet4.sys')
        shutil.copyfile(DRIVER,self.lib/'win95-rtm/usosnet4.sys')
        self.cfg=self.work/'config.ini'
        self.cfg.write_text('system=95\nnetwork=on\nip=dhcp\ngateway=\ndns=\nhome_page=about:blank\ndialup=off\n')

    def run_stage(self,version):
        source=(ROOT/'tools/network_setup.sh').as_posix()
        command=f'. "{source}"\nusos_net_stage '
        command+=' '.join("'"+p.as_posix()+"'" for p in (self.cfg,self.target,self.lib.parent,self.pci))
        env=dict(os.environ,TEMP=str(self.work),TMP=str(self.work),USOS_NET_W95_VERSION=version,
            USOS_NET_W95_PATH='/sys/devices/pci0000:00/0000:00:01.3/0000:02:00.2/0000:03:01.0/0000:08:00.0')
        return subprocess.run([r'C:\Program Files\Git\bin\sh.exe','-c',command],env=env,capture_output=True,text=True)

    def test_rtm_uses_separate_binary_and_ndis3_registry(self):
        r=self.run_stage('4 0 0 950');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        net=self.target/'USOS9X/NET'
        self.assertEqual((net/'USOSNET.SYS').read_bytes(),DRIVER.read_bytes())
        self.assertIn('"MajorNdisVersion"=hex:03',(net/'NET95.REG').read_text())
        self.assertIn('MajorNdisVersion,1,03',(net/'USOSNET.INF').read_text())

    def test_osr2_keeps_existing_binary_and_ndis4_registry(self):
        r=self.run_stage('4 0 0 1068');self.assertEqual(r.returncode,0,r.stderr+r.stdout)
        net=self.target/'USOS9X/NET'
        self.assertEqual((net/'USOSNET.SYS').read_bytes(),OLD.read_bytes())
        self.assertIn('"MajorNdisVersion"=hex:04',(net/'NET95.REG').read_text())
        self.assertIn('MajorNdisVersion,1,04',(net/'USOSNET.INF').read_text())

    def test_missing_rtm_variant_stops_instead_of_silently_dropping_lan(self):
        (self.lib/'win95-rtm/usosnet4.sys').unlink()
        self.assertNotEqual(self.run_stage('4 0 0 950').returncode,0)
        self.assertFalse((self.target/'USOS9X/NET/USOSNET.SYS').exists())

class Timer(unittest.TestCase):
    def test_real_callback_rearms_after_work_and_respects_cancel(self):
        source=(ROOT/'tools/nt/usosnet/src/usosnet.c').read_text()
        callback=re.search(r'static VOID TimerFn\(.*?\n\}',source,re.S).group()
        harness=r'''
#define USOSNET_NDIS31 1
#define VOID void
#define PVOID void *
#define ULONG unsigned long
#define TICKS_PER_SEC 50
#define TICK_MS 20
#define UNREFERENCED_PARAMETER(x) (void)(x)
typedef struct Adapter Adapter;
struct Ops {void (*RxPoll)(Adapter*);void (*TxReclaim)(Adapter*);};
struct Chip {struct Ops *Ops;};
struct Adapter {unsigned long RxOk,RxByTimer,TimerCount;int PollMode,TimerInit,Timer;struct Chip *Chip;};
typedef Adapter *PADAPTER;
typedef int *PNDIS_TIMER;
static int sequence,arms,seconds;
static void rx(Adapter *a){if(sequence!=0)__builtin_trap();sequence=1;a->RxOk++;}
static void tx(Adapter *a){(void)a;if(sequence!=1)__builtin_trap();sequence=2;}
static void TimerSecond(Adapter *a){(void)a;if(sequence!=2)__builtin_trap();seconds++;}
static void NdisSetTimer(int *timer,int ms){(void)timer;if(sequence!=2||ms!=20)__builtin_trap();arms++;}
'''+callback+r'''
int main(void){struct Ops ops={rx,tx};struct Chip chip={&ops};
Adapter a={0,0,49,0,1,0,&chip};TimerFn(0,&a,0,0);
if(arms!=1||seconds!=1||a.RxByTimer!=1)return 1;
a.TimerInit=0;sequence=0;TimerFn(0,&a,0,0);if(arms!=1)return 2;return 0;}
'''
        OUT.mkdir(parents=True,exist_ok=True)
        c=OUT/'timer.c';exe=OUT/'timer.exe';c.write_text(harness)
        subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-Wall','-Werror',str(c),'-o',str(exe)],check=True,capture_output=True)
        subprocess.run([str(exe)],check=True,capture_output=True)

if __name__=='__main__': unittest.main()
