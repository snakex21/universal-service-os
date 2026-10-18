"""usosnet (tools/nt/usosnet): the USOS own NDIS 5.0 Ethernet miniport for
Windows 98 / 98 SE / Me and 2000 / XP x86. The committed binary imports only
NDIS.SYS functions that the 9x NDIS.VXD provides, carries PE version 4.00,
and both INFs list exactly the PCI IDs of the driver's chip table.

W9X_NDIS_EXPORTS: export names (names only, no Microsoft file) found in the
NDIS.VXD of Windows 98 SE (4.10.2222, 1999-05-05) and Windows Me
(4.90.3000, 2000-06-08); checked 2026-10-18 against the user's own CDs. A new
import must be added here only after that check."""
from pathlib import Path
import re, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_nt52_driver_imports import pe  # noqa: E402

DRV = ROOT / 'tools/nt/usosnet'
SYS = DRV / 'bin/i386/usosnet.sys'

W9X_NDIS_EXPORTS = {
    'NdisAllocateMemory', 'NdisCloseConfiguration', 'NdisFreeMemory', 'NdisInitializeWrapper',
    'NdisMAllocateMapRegisters', 'NdisMAllocateSharedMemory', 'NdisMCancelTimer',
    'NdisMDeregisterAdapterShutdownHandler', 'NdisMDeregisterInterrupt', 'NdisMFreeMapRegisters',
    'NdisMFreeSharedMemory', 'NdisMIndicateStatus', 'NdisMIndicateStatusComplete', 'NdisMInitializeTimer',
    'NdisMMapIoSpace', 'NdisMQueryAdapterResources', 'NdisMRegisterAdapterShutdownHandler',
    'NdisMRegisterInterrupt', 'NdisMRegisterMiniport', 'NdisMSetAttributesEx', 'NdisMSetPeriodicTimer',
    'NdisMSleep', 'NdisMUnmapIoSpace', 'NdisOpenConfiguration', 'NdisQueryBuffer', 'NdisReadConfiguration',
    'NdisReadNetworkAddress', 'NdisReadPciSlotInformation', 'NdisTerminateWrapper', 'NdisWriteConfiguration',
    'NdisWritePciSlotInformation',
}


def chip_ids():
    src = (DRV / 'src/usosnet.c').read_text(encoding='latin-1')
    return {m.upper() for m in re.findall(r'\{ 0x8086, 0x([0-9A-Fa-f]{4}),', src)}


def inf_ids(name):
    text = (DRV / 'inf' / name).read_text(encoding='ascii')
    return set(re.findall(r'^%[^%]+%=\S+, PCI\\VEN_8086&DEV_([0-9A-F]{4})\r?$', text, re.M))


class Binary(unittest.TestCase):
    def test_imports_only_9x_ndis(self):
        imports = pe(SYS)[1]
        self.assertTrue(imports)
        for mod, name in imports:
            self.assertEqual(mod, 'ndis.sys', name)
            self.assertIn(name, W9X_NDIS_EXPORTS, name)

    def test_pe_version_4(self):
        b = SYS.read_bytes()
        off = int.from_bytes(b[0x3C:0x40], 'little') + 24
        self.assertEqual((b[off + 48], b[off + 50]), (4, 0))   # subsystem 4.00


class Inf(unittest.TestCase):
    def test_ids_in_chip_table(self):
        chips = chip_ids()
        for name in ('usosnet9x.inf', 'usosnet.inf'):
            ids = inf_ids(name)
            self.assertIn('1539', ids, name)       # I211 (X470)
            self.assertIn('10C9', ids, name)       # 82576 (QEMU igb)
            self.assertLessEqual(ids, chips, name)

    def test_9x_ndis_loader(self):
        text = (DRV / 'inf/usosnet9x.inf').read_text(encoding='ascii')
        for line in ('HKR,,DevLoader,,*ndis', 'HKR,,DeviceVxDs,,usosnet.sys', 'HKR,NDIS,MajorNdisVersion,1,05',
                     'Signature="$CHICAGO$"', 'Class=Net'):
            self.assertIn(line, text)

    def test_source_no_kernel_macros(self):
        """NdisZeroMemory & co. expand to ntoskrnl / HAL calls with WDK 7.1."""
        for f in ('usosnet.c', 'usosnet_igb.c'):
            src = (DRV / 'src' / f).read_text(encoding='latin-1')
            for bad in ('NdisZeroMemory', 'NdisMoveMemory', 'NdisStallExecution', 'NdisEqualMemory',
                        'NdisRawWritePort', 'NdisWriteRegister', 'NdisReadRegister', 'memset', 'memcpy'):
                self.assertNotIn(bad + '(', src, f'{f}: {bad}')




class IsrClaim(unittest.TestCase):
    """Shared INTx: claim only with ICR.INT_ASSERTED, never while masked."""

    def test_claim_rule_host_compiled(self):
        import shutil, subprocess, tempfile
        cc = shutil.which('gcc') or shutil.which('cc') or (
            'C:/msys64/mingw64/bin/gcc.exe' if Path('C:/msys64/mingw64/bin/gcc.exe').exists() else None)
        if not cc:
            self.skipTest('no host C compiler')
        harness = r'''
#include <stdio.h>
#define __inline inline
#include "usosnet_irq.h"
int main(void) {
    struct { unsigned long m, icr, want; } t[] = {
        {0, 0x00000000UL, 0},            /* idle, shared line: not ours */
        {0, 0x00000084UL, 0},            /* causes latched but not asserted (masked by IMS) */
        {0, 0x80000080UL, 0x80000080UL}, /* RXT0 asserted */
        {0, 0x80000004UL, 0x80000004UL}, /* LSC asserted */
        {0, 0xFFFFFFFFUL, 0},            /* device gone */
        {1, 0x80000080UL, 0},            /* driver masked: never ours */
    };
    unsigned i; int bad = 0;
    for (i = 0; i < sizeof t / sizeof t[0]; i++)
        if (UsosnetIrqClaim(t[i].m, t[i].icr) != t[i].want) { printf("case %u\n", i); bad = 1; }
    return bad;
}
'''
        with tempfile.TemporaryDirectory() as d:
            c = Path(d) / 't.c'
            c.write_text(harness)
            exe = Path(d) / 't.exe'
            r = subprocess.run([cc, '-I', str(DRV / 'src'), '-o', str(exe), str(c)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)

    def test_isr_reads_icr_only_when_unmasked(self):
        src = (DRV / 'src/usosnet_igb.c').read_text(encoding='latin-1')
        body = re.search(r'static ULONG IgbIrqRead\(PADAPTER A\)\n\{(.*?)\n\}', src, re.S).group(1)
        self.assertLess(body.index('A->IrqMasked'), body.index('RD32(A, ICR)'))
        self.assertNotIn('EICR', body)
        self.assertIn('UsosnetIrqClaim', body)
        dis = re.search(r'static void IgbIrqDisable\(PADAPTER A\)\n\{(.*?)\n\}', src, re.S).group(1)
        en = re.search(r'static void IgbIrqEnable\(PADAPTER A\)\n\{(.*?)\n\}', src, re.S).group(1)
        self.assertIn('A->IrqMasked = TRUE', dis)
        self.assertIn('A->IrqMasked = FALSE', en)
        self.assertNotIn('EIMS', en)                      # legacy INTx: no extended causes
        self.assertIn('WR32(A, IVAR0, 0)', src)
        self.assertIn('MdicWrite(A, 4, 0x01E1)', src)     # no pause advertised


if __name__ == '__main__':
    unittest.main()
