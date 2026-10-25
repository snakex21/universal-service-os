"""Windows 95 RTM / OSR1 usosnet (USOSNET_W95RTM, WDK 7.1 via tools/nt/usosnet/build95rtm.py):
binary ABI prerequisites, real staging selection, and the one-shot timer."""
from pathlib import Path
import ast
import os
import re
import shutil
import struct
import subprocess
import tempfile
import json
import hashlib
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
        objdump=shutil.which('objdump') or r'C:\msys64\mingw64\bin\objdump.exe'
        if not os.path.exists(objdump):
            self.skipTest('no objdump')
        assembly=subprocess.check_output([objdump,'-d',str(DRIVER)],text=True)
        self.assertIsNone(re.search(r'\b(?:xmm|ymm|zmm|mm)[0-9]+\b',assembly))

    def test_build_manifest_matches_the_committed_binary(self):
        manifest=json.loads((DRIVER.parent/'BUILD.json').read_text(encoding='utf-8'))
        self.assertEqual(manifest['sha256'],hashlib.sha256(DRIVER.read_bytes()).hexdigest())
        self.assertEqual((manifest['ndis_version'],manifest['characteristics_size'],manifest['ethdb_offset']),('3.0',60,216))
        self.assertIn('WDK 7.1',manifest['toolchain'])
        sources=(ROOT/'tools/nt/usosnet/src95rtm/sources').read_text(encoding='utf-8')
        self.assertIn('-DUSOSNET_NDIS4=1 -DUSOSNET_W95RTM=1',sources)
        self.assertIn('SUBSYSTEM_VERSION=4.00',sources)

    def test_registration_uses_ndis3_size_and_version(self):
        entry=entry_bytes()
        # major 3, minor 0 in the characteristics (MSVC: two byte stores to
        # the stack copy; the earlier mingw build used one word store)
        self.assertTrue(re.search(rb'\xc6\x45(.)\x03\xc6\x45(.)\x00',entry,re.S) or b'\x66\xc7\x01\x03\x00' in entry)
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
#define USOSNET_W95RTM 1
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

class InitDiagnostics(unittest.TestCase):
    """X470 950 run (2026-10-25): the mapped range answered like RAM (STATUS =
    x86 code, IMS kept after IMC), USN4 was lost in the quiet time. 95 RTM
    only: init log round, no non-BAR0 fallback, MMIO probe, UsosBootBar0."""
    SRC=ROOT/'tools/nt/usosnet/src'

    def source(self):
        return (self.SRC/'usosnet.c').read_text(encoding='latin-1')

    def test_init_round_has_the_four_records_before_any_event_round(self):
        src=self.source()
        init=re.search(r'static void InitLog\(PADAPTER A\)\r?\n\{(.*?)\r?\n\}',src,re.S).group(1)
        self.assertEqual(re.findall(r'LOG10\((0x55534E3\d)UL',init),
            ['0x55534E36','0x55534E37','0x55534E38','0x55534E34'])
        second=re.search(r'static void TimerSecond\(PADAPTER A\)\r?\n\{(.*?)\r?\n\}',src,re.S).group(1)
        self.assertLess(second.index('InitLog(A)'),second.index('CheckLink(A)'))
        self.assertLess(second.index('InitLog(A)'),second.index('DiagLog('))

    def test_quiet_time_does_not_use_up_a_round(self):
        diag=re.search(r'static void DiagLog\(PADAPTER A, ULONG Event, ULONG Sec\)\r?\n\{(.*?)\r?\n\}',
            self.source(),re.S).group(1)
        quiet=diag.index('if (A->TimerCount < LOG_QUIET_SEC * TICKS_PER_SEC) return;')
        self.assertLess(quiet,diag.index('A->LogCount++'))
        self.assertLess(diag.index('#if !USOSNET_W95RTM'),diag.index('if (A->LogCount == 1)'))

    def test_rtm_has_no_non_bar0_memory_fallback(self):
        src=self.source()
        block=src[src.index('A->ResInfo |= res->Count & 0xFF;'):]
        self.assertLess(block.index('#else'),block.index('for (i = 0; !memFound && i < res->Count; i++)'))
        init=src[src.index('static NDIS_STATUS MpInitialize('):]
        self.assertLess(init.index('NdisMMapIoSpace((PVOID *)&A->Mmio'),init.index('A->ProbeMap = IgbMmioProbe(A);'))
        self.assertLess(init.index('A->ProbeMap = IgbMmioProbe(A);'),init.index('A->Chip->Ops->Reset(A)'))

    def compile_run(self,name,code):
        cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        if not os.path.exists(cc) and not shutil.which('gcc'):
            self.skipTest('no host C compiler')
        OUT.mkdir(parents=True,exist_ok=True)
        c=OUT/(name+'.c');exe=OUT/(name+'.exe');c.write_text(code)
        r=subprocess.run([cc,'-Wall','-Werror',str(c),'-o',str(exe)],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stderr)
        r=subprocess.run([str(exe)],capture_output=True,text=True)
        self.assertEqual(r.returncode,0,r.stdout)

    def test_boot_bar_string_parser_host_compiled(self):
        fn=re.search(r'static ULONG CfgHexString\(NDIS_HANDLE Cfg, NDIS_STRING \*Key\)\r?\n\{.*?\r?\n\}',
            self.source(),re.S).group(0)
        harness=r'''#include <string.h>
typedef unsigned long ULONG; typedef unsigned char UCHAR; typedef unsigned short USHORT;
typedef int NDIS_STATUS; typedef void *NDIS_HANDLE;
#define NDIS_STATUS_SUCCESS 0
enum { NdisParameterInteger, NdisParameterHexInteger, NdisParameterString };
typedef struct { USHORT Length, MaximumLength; void *Buffer; } NDIS_STRING;
typedef struct { int ParameterType; union { ULONG IntegerData; NDIS_STRING StringData; } ParameterData; }
    NDIS_CONFIGURATION_PARAMETER, *PNDIS_CONFIGURATION_PARAMETER;
static NDIS_CONFIGURATION_PARAMETER str, hex; static int have_str, have_hex;
static void NdisReadConfiguration(NDIS_STATUS *st, PNDIS_CONFIGURATION_PARAMETER *p, NDIS_HANDLE c,
    NDIS_STRING *k, int type)
{
    (void)c; (void)k;
    if (type == NdisParameterString && have_str) { *p = &str; *st = 0; return; }
    if (type == NdisParameterHexInteger && have_hex) { *p = &hex; *st = 0; return; }
    *p = 0; *st = 1;
}
'''+fn+r'''
static ULONG ansi(const char *s) { have_str = 1; have_hex = 0; str.ParameterType = NdisParameterString;
    str.ParameterData.StringData.Buffer = (void *)s; str.ParameterData.StringData.Length = (USHORT)strlen(s);
    return CfgHexString(0, 0); }
static ULONG wide(const char *s) { static unsigned short w[32]; int i, n = (int)strlen(s);
    for (i = 0; i < n; i++) w[i] = (unsigned char)s[i];
    have_str = 1; have_hex = 0; str.ParameterType = NdisParameterString;
    str.ParameterData.StringData.Buffer = w; str.ParameterData.StringData.Length = (USHORT)(2 * n);
    return CfgHexString(0, 0); }
int main(void)
{
    if (ansi("FC900000") != 0xFC900000UL) return 1;
    if (wide("FC900000") != 0xFC900000UL) return 2;
    if (ansi("0xfc900000") != 0xFC900000UL) return 3;
    if (ansi(" FC900000") != 0xFC900000UL) return 4;
    if (ansi("1FC900000") != 0) return 5;            /* more than 32 bits */
    if (ansi("zz") != 0) return 6;
    have_str = 0; have_hex = 1; hex.ParameterType = NdisParameterHexInteger;
    hex.ParameterData.IntegerData = 0xFC900000UL;
    if (CfgHexString(0, 0) != 0xFC900000UL) return 7;  /* DWORD value */
    have_hex = 0;
    if (CfgHexString(0, 0) != 0) return 8;             /* absent */
    return 0;
}
'''
        self.compile_run('bootbar',harness)

    def test_mmio_probe_tells_chip_from_ram_host_compiled(self):
        igb=(self.SRC/'usosnet_igb.c').read_text(encoding='latin-1')
        fn=re.search(r'ULONG IgbMmioProbe\(PADAPTER A\)\r?\n\{.*?\r?\n\}',igb,re.S).group(0)
        harness=r'''typedef unsigned long ULONG;
#define IMS 0x00D0
#define IMC 0x00D8
#define ICR_LSC (1UL << 2)
typedef struct { int chip; ULONG ram[0x40], ims; } ADAPTER, *PADAPTER;
static void WR32(PADAPTER A, ULONG r, ULONG v)
{
    if (!A->chip) { A->ram[r / 4] = v; return; }
    if (r == IMS) A->ims |= v; else if (r == IMC) A->ims &= ~v;
}
static ULONG RD32(PADAPTER A, ULONG r) { return A->chip ? (r == IMS ? A->ims : 0) : A->ram[r / 4]; }
'''+fn+r'''
int main(void)
{
    ADAPTER chip = {1, {0}, 0xDC}, ram = {0, {0}, 0};
    ram.ram[IMS / 4] = 0xDC;
    if (IgbMmioProbe(&chip) != 1 || chip.ims != 0) return 1;
    if (IgbMmioProbe(&ram) != (0x80000000UL | (ICR_LSC << 16) | ICR_LSC)) return 2;
    return 0;
}
'''
        self.compile_run('mmioprobe',harness)

if __name__=='__main__': unittest.main()
