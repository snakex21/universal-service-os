"""NT351 build/import/ABI checks plus execution of the real checker body.

Host callback tests use mock chip operations; they do not claim Windows,
NDIS scheduler, interrupt, DMA, DHCP or DNS runtime coverage.
"""
from pathlib import Path
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import unittest

import capstone
from capstone.x86_const import X86_OP_IMM, X86_OP_MEM, X86_REG_EBP
import pefile

ROOT = Path(__file__).resolve().parents[2]
DRV = ROOT / 'tools/nt/usosnet'
CONTRACT = json.loads((Path(__file__).parent / 'fixtures/nt351-ndis-contract.json').read_text())


class BuiltBinary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pe = pefile.PE(str(DRV / 'bin/i386/usosnet351.sys'))
        cls.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        cls.md.detail = True
        cls.base = cls.pe.OPTIONAL_HEADER.ImageBase
        cls.iat = {i.address: i.name.decode() for m in cls.pe.DIRECTORY_ENTRY_IMPORT for i in m.imports}
        cls.code = [i for section in cls.pe.sections if section.Characteristics & 0x20000000
            for i in cls.md.disasm(section.get_data(), cls.base + section.VirtualAddress)]

    def test_only_original_ndis351_exports(self):
        self.assertEqual(CONTRACT['ndis_sha256'],
            '948d3c6feee3f80b98da5b40a254f7047b044a0bcc9be23739a460d7cfc5ab1b')
        names = set()
        for module in self.pe.DIRECTORY_ENTRY_IMPORT:
            self.assertEqual(module.dll.lower(), b'ndis.sys')
            for item in module.imports:
                self.assertIsNotNone(item.name)
                name = item.name.decode()
                self.assertIn(name, CONTRACT['exports'])
                names.add(name)
        self.assertIn('NdisMSetAttributes', names)
        self.assertIn('NdisMRegisterInterrupt', names)
        self.assertFalse(any('Timer' in n for n in names), names)
        self.assertTrue(names.isdisjoint({'NdisMSetAttributesEx', 'NdisWriteConfiguration',
            'NdisWriteErrorLogEntry'}))

    def test_native_i386_pe310(self):
        pe = self.pe
        self.assertEqual(pe.FILE_HEADER.Machine, 0x14c)
        opt = pe.OPTIONAL_HEADER
        self.assertEqual(opt.Subsystem, 1)
        self.assertEqual((opt.MajorOperatingSystemVersion, opt.MinorOperatingSystemVersion), (3, 10))
        self.assertEqual((opt.MajorSubsystemVersion, opt.MinorSubsystemVersion), (3, 10))

    def test_registration_and_callback_prefix_in_built_code(self):
        rva = self.pe.OPTIONAL_HEADER.AddressOfEntryPoint
        entry = list(self.md.disasm(self.pe.get_memory_mapped_image()[rva:rva+500], self.base+rva))
        register = next(n for n, i in enumerate(entry) if i.mnemonic == 'call' and
            len(i.operands) == 1 and i.operands[0].type == X86_OP_MEM and
            self.iat.get(i.operands[0].mem.disp) == 'NdisMRegisterMiniport')
        before = entry[:register]
        major = next(i for i in before if i.mnemonic == 'mov' and len(i.operands) == 2
            and i.operands[0].type == X86_OP_MEM and i.operands[0].size == 1
            and i.operands[0].mem.base == X86_REG_EBP and i.operands[1].type == X86_OP_IMM
            and i.operands[1].imm == 3)
        struct_disp = major.operands[0].mem.disp
        fields = {i.operands[0].mem.disp-struct_disp: i.operands[1].imm for i in before
            if i.mnemonic == 'mov' and len(i.operands) == 2
            and i.operands[0].type == X86_OP_MEM and i.operands[0].mem.base == X86_REG_EBP
            and i.operands[1].type == X86_OP_IMM}
        self.assertEqual(fields[1], 0)
        self.assertTrue(any(i.mnemonic == 'push' and i.operands[0].type == X86_OP_IMM
            and i.operands[0].imm == 0x3c for i in before))
        for offset in range(8, 0x3c, 4):
            if offset == 0x28:  # ReconfigureHandler is deliberately optional/NULL.
                continue
            self.assertGreater(fields[offset], self.base)
        checker = fields[8]-self.base
        instructions = list(self.md.disasm(self.pe.get_memory_mapped_image()[checker:checker+150], fields[8]))
        self.assertTrue(any(i.mnemonic == 'call' for i in instructions))
        self.assertTrue(any(i.mnemonic.startswith('j') for i in instructions))

    def test_receive_and_complete_pass_ethdb_d8(self):
        seen = set()
        for n, instruction in enumerate(self.code):
            if instruction.mnemonic != 'call' or len(instruction.operands) != 1:
                continue
            op = instruction.operands[0]
            if op.type != X86_OP_MEM:
                continue
            name = self.iat.get(op.mem.disp)
            if name not in {'EthFilterDprIndicateReceive', 'EthFilterDprIndicateReceiveComplete'}:
                continue
            self.assertTrue(any(i.mnemonic == 'push' and len(i.operands) == 1
                and i.operands[0].type == X86_OP_MEM and i.operands[0].mem.disp == 0xd8
                for i in self.code[max(0, n-18):n]), name)
            seen.add(name)
        self.assertEqual(len(seen), 2)

    def test_attributes_uses_four_argument_legacy_call(self):
        calls = [(n, i) for n, i in enumerate(self.code) if i.mnemonic == 'call'
            and len(i.operands) == 1 and i.operands[0].type == X86_OP_MEM
            and self.iat.get(i.operands[0].mem.disp) == 'NdisMSetAttributes']
        self.assertEqual(len(calls), 1)
        n, _ = calls[0]
        args = self.code[n-4:n]
        self.assertEqual([i.mnemonic for i in args], ['push']*4)
        self.assertEqual(args[0].operands[0].imm, 5)  # NdisInterfacePci
        self.assertEqual(args[1].op_str, 'edi')
        # The compiler keeps TRUE in nonvolatile EDI across initialization calls.
        init = [i for i in self.code[:n] if i.mnemonic == 'xor' and i.op_str == 'edi, edi'][-1]
        tail = [i for i in self.code[:n] if i.address > init.address]
        edi_writes = [i for i in tail if i.mnemonic not in {'push', 'cmp', 'test', 'call'}
            and i.op_str.split(',')[0] == 'edi']
        self.assertEqual([(i.mnemonic, i.op_str) for i in edi_writes], [('inc', 'edi')])

    def test_existing_nt4_and_ndis5_binaries_unchanged(self):
        for name, expected in {
            # 89b7337c: canonical igb IRQ registers, NT4 tuple09 QEMU qualification.
            'usosnet4.sys': '89b7337c294ca0c56415cdc4e7023615a628ae8158a5a7ab80dcf6f35ca02233',
            'usosnet.sys': '8eac15b474b23fb4e7ac2c2431a4b17e6666cc2d03788b78ec2d8e19eeef89f9',
        }.items():
            self.assertEqual(hashlib.sha256((DRV / 'bin/i386' / name).read_bytes()).hexdigest(), expected)


class ResourceQueryExecution(unittest.TestCase):
    def test_real_pci_branch_with_original_nonwriting_stub_and_nt4_control(self):
        cc=shutil.which('gcc') or 'C:/msys64/mingw64/bin/gcc.exe'
        self.assertTrue(Path(cc).is_file())
        source=(DRV/'src/usosnet.c').read_text()
        start=source.index('#if USOSNET_NT35\n    A->Legacy = TRUE;')
        end=source.index('\n\n    /* PCI identity;',start)
        branch=source[start:end]
        harness=r"""
#include <stdint.h>
#include <stdio.h>
#define USOSNET_NDIS4 1
#define USOSNET_NDIS3 USOSNET_NT351
#define NDIS_STATUS_SUCCESS 0U
#define NDIS_STATUS_NOT_SUPPORTED 0xC00000BBU
#define NDIS_STATUS_ADAPTER_NOT_FOUND 0xC0010006U
#define TRUE 1
#define FALSE 0
typedef uint32_t ULONG,NDIS_STATUS,UINT;
typedef struct { ULONG Count; } NDIS_RESOURCE_LIST,*PNDIS_RESOURCE_LIST;
typedef struct { void *Handle; ULONG PciSlot,AssignStatus,Legacy; } ADAPTER;
static unsigned query_calls,find_calls,assign_calls,write_status,found;
static NDIS_RESOURCE_LIST assigned={2};
static void NdisMQueryAdapterResources(NDIS_STATUS *st,void *ctx,PNDIS_RESOURCE_LIST res,UINT *len) {
 (void)ctx;(void)len;query_calls++;
 /* Original351 stub returns EAX=C00000BB; caller's VOID prototype ignores it.
    Precisely the important contract: neither *st nor *res is written. */
 if(write_status){*st=0;res->Count=1;}
}
static int LegacyFind(ADAPTER *a,void *ctx){(void)ctx;find_calls++;a->PciSlot=3;return found;}
static NDIS_STATUS NdisMPciAssignResources(void *h,ULONG slot,PNDIS_RESOURCE_LIST *r) {
 (void)h;if(slot!=3)return 99;assign_calls++;*r=&assigned;return 0;
}
static void UsLog(ADAPTER *a,const char *s,ULONG v1,ULONG v2){(void)a;(void)s;(void)v1;(void)v2;}
static NDIS_STATUS run(void) {
 ADAPTER adapter={0},*A=&adapter;void *WrapperConfigurationContext=(void*)1;
 void *MiniportAdapterHandle=(void*)2;
 NDIS_RESOURCE_LIST buffer={0xDEADBEEFU},*res=&buffer,*rl=0;
 UINT resLen=sizeof buffer;NDIS_STATUS st=NDIS_STATUS_SUCCESS;
"""+branch+r"""
 if(write_status)return (!rl||rl->Count!=1||find_calls||assign_calls)?10:0;
 return (!A->Legacy||find_calls!=1||assign_calls!=1||rl!=&assigned)?11:0;
fail:
 return st;
}
int main(void) {
 NDIS_STATUS st;
 write_status=1;found=1;st=run();if(st||query_calls!=1)return 1;
#if USOSNET_NT351
 query_calls=find_calls=assign_calls=0;write_status=0;found=1;
 st=run();if(st||query_calls!=1)return 2;
 query_calls=find_calls=assign_calls=0;found=0;
 st=run();if(st!=NDIS_STATUS_ADAPTER_NOT_FOUND||find_calls!=1||assign_calls)return 3;
#endif
 puts("resource branch PASS");return 0;
}
"""
        owned=ROOT/'artifacts/nt351-network/host-tests';owned.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='resource-',dir=owned) as directory:
            work=Path(directory);c=work/'resource.c';c.write_text(harness,encoding='utf-8')
            env=dict(os.environ,TEMP=str(work),TMP=str(work))
            for nt351 in (0,1):
                exe=work/f'resource-{nt351}.exe'
                built=subprocess.run([cc,'-std=c99','-Wall','-Werror','-Wno-unused-function',
                    f'-DUSOSNET_NT351={nt351}',str(c),'-o',str(exe)],capture_output=True,text=True,env=env)
                self.assertEqual(built.returncode,0,built.stdout+built.stderr)
                result=subprocess.run([str(exe)],capture_output=True,text=True,env=env)
                self.assertEqual(result.returncode,0,result.stdout+result.stderr)


class CallbackExecution(unittest.TestCase):
    def test_real_checker_with_mock_chip_ops_and_nominal_time_policy(self):
        cc = shutil.which('gcc') or ('C:/msys64/mingw64/bin/gcc.exe'
            if Path('C:/msys64/mingw64/bin/gcc.exe').is_file() else None)
        self.assertIsNotNone(cc, 'A host C compiler is required for this test')
        source = (DRV / 'src/usosnet.c').read_text()
        body = re.search(r'static BOOLEAN MpCheckForHang\(NDIS_HANDLE Ctx\)\n\{.*?\n\}', source, re.S).group()
        harness = r'''
#include <stdio.h>
#include <string.h>
#define USOSNET_NT351 1
#define USOSNET_NDIS3 1
#define TICKS_PER_SEC 50
#define FALSE 0
typedef unsigned long ULONG;
typedef int BOOLEAN;
typedef void *NDIS_HANDLE;
#include "usosnet351_policy.h"
typedef struct _A A;
struct _OPS { void (*RxPoll)(A *); void (*TxReclaim)(A *); };
struct _CHIP { const struct _OPS *Ops; };
struct _A { const struct _CHIP *Chip; ULONG RxOk, RxByTimer, PollMode, TimerCount; int Started; };
typedef A *PADAPTER;
static unsigned rx_calls, tx_calls, maintenance_calls, bad, sequence;
static void Rx(A *a) { if (sequence != 0) bad++; sequence=1; rx_calls++; a->RxOk+=3; }
static void Tx(A *a) { (void)a; if (sequence != 1) bad++; sequence=2; tx_calls++; }
static void TimerSecond(A *a) { if (sequence != 2 || a->TimerCount % 100) bad++; sequence=0; maintenance_calls++; }
'''+body+r'''
int main(void) {
    const struct _OPS ops={Rx, Tx}; const struct _CHIP chip={&ops}; A a={0};
    unsigned mode, n; unsigned long stall=0;
    /* An unstarted adapter has no valid chip pointer: no operation may touch it. */
    if (MpCheckForHang(&a) || rx_calls || tx_calls || maintenance_calls || a.TimerCount) return 1;
    for (mode=0; mode<3; mode++) {
        memset(&a,0,sizeof a); a.Started=1; a.Chip=&chip; a.PollMode=mode;
        for (n=0;n<100;n++) if (MpCheckForHang(&a)) return 2;
        if (a.TimerCount!=10000 || a.RxOk!=300 || a.RxByTimer!=(mode ? 0 : 300)) return 3;
    }
    if (rx_calls!=300 || tx_calls!=300 || maintenance_calls!=300 || bad) return 4;
    stall=Usosnet351StallNext(stall); if(stall!=2) return 5;
    stall=Usosnet351StallNext(stall); if(stall!=4) return 6;
    for(n=0;n<100;n++) stall=Usosnet351StallNext(stall); if(stall!=4) return 7;
    for(n=0;n<610;n+=2) {
        int want=n==30 || n==66 || n==300 || n==600;
        if(Usosnet351PeriodicLog(n)!=want) return 8;
    }
    puts("checker PASS: unstarted guard, IRQ/poll modes, ordered RX/TX, nominal time, stall saturation, log cadence");
    return 0;
}
'''
        owned = ROOT / 'artifacts/nt351-network/host-tests'
        owned.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix='callback-', dir=owned) as directory:
            work = Path(directory)
            c = work / 'callback.c'
            c.write_text(harness, encoding='utf-8')
            exe = work / 'callback.exe'
            built = subprocess.run([cc, '-std=c99', '-Wall', '-Werror', '-Wno-misleading-indentation',
                '-I', str(DRV / 'src'), str(c), '-o', str(exe)], capture_output=True, text=True)
            self.assertEqual(built.returncode, 0, built.stdout+built.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
