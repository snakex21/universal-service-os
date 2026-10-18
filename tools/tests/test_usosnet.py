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
    'NdisWritePciSlotInformation', 'NdisWriteErrorLogEntry',
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
    struct { unsigned long sec, isr, rxt, up; int want; } w[] = {
        {3, 0, 5, 1, 0},                 /* too early */
        {5, 0, 0, 0, 0},                 /* no link, no traffic: nothing to judge */
        {5, 0, 3, 0, 1},                 /* timer found frames, ISR never claimed */
        {6, 0, 0, 1, 1},                 /* link up (LSC would have fired), no interrupt */
        {9, 1, 40, 1, 0},                /* interrupts arrive */
    };
    unsigned i; int bad = 0;
    for (i = 0; i < sizeof t / sizeof t[0]; i++)
        if (UsosnetIrqClaim(t[i].m, t[i].icr) != t[i].want) { printf("case %u\n", i); bad = 1; }
    for (i = 0; i < sizeof w / sizeof w[0]; i++)
        if (UsosnetIrqBroken(w[i].sec, w[i].isr, w[i].rxt, w[i].up) != w[i].want) { printf("wd %u\n", i); bad = 1; }
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
        self.assertIn('CTRL_RFCE | CTRL_TFCE', src)       # iNVM RFCE = 1 cleared too

    def test_timer_polls_and_watchdog_masks(self):
        '''X470 + Me round 1: no RX at all. The timer polls RX / TX in every
        mode, the IRQ watchdog masks the chip, the DPC does not unmask it then.'''
        src = (DRV / 'src/usosnet.c').read_text(encoding='latin-1')
        timer = re.search(r'static VOID TimerFn\(.*?\n\}', src, re.S).group(0)
        self.assertIn('RxPoll(A)', timer)
        self.assertIn('TxReclaim(A)', timer)
        self.assertNotIn('if (A->PollMode) {', timer)
        sec = re.search(r'static void TimerSecond\(PADAPTER A\)\n\{(.*?)\n\}', src, re.S).group(1)
        self.assertLess(sec.index('UsosnetIrqBroken'), sec.index('IrqDisable(A)'))
        dpc = re.search(r'static VOID MpHandleInterrupt\(NDIS_HANDLE Ctx\)\n\{(.*?)\n\}', src, re.S).group(1)
        self.assertIn('if (!A->PollMode) A->Chip->Ops->IrqEnable(A)', dpc)
        send = re.search(r'static NDIS_STATUS MpSend\(.*?\n\}', src, re.S).group(0)
        self.assertNotIn('UsStall', send)                 # no busy wait in the send path


def _host_cc():
    import shutil
    return shutil.which('gcc') or shutil.which('cc') or (
        'C:/msys64/mingw64/bin/gcc.exe' if Path('C:/msys64/mingw64/bin/gcc.exe').exists() else None)


class ProtoStats(unittest.TestCase):
    """0.4: per-protocol classification, RX status decode (checksum errors
    never drop), the statistics page and its wiring into the data path."""

    HARNESS = r'''
#include <stdio.h>
#include <string.h>
#define __inline inline
#include "usosnet_proto.h"
static unsigned char f[200];
static unsigned long eth(int bcast, unsigned et) {
    memset(f, 0, sizeof f);
    memset(f, bcast ? 0xFF : 0x00, 6); if (!bcast) f[5] = 0x7D;
    f[6] = 0x70; f[12] = et >> 8; f[13] = et & 0xFF; return 14;
}
static unsigned long ipv4(int proto, unsigned sp, unsigned dp, unsigned frag) {
    unsigned char *ip = f + 14;
    ip[0] = 0x45; ip[6] = frag >> 8; ip[7] = frag & 0xFF; ip[9] = proto;
    ip[12] = 1; ip[13] = 1; ip[14] = 1; ip[15] = 1;           /* src 1.1.1.1 */
    ip[16] = 192; ip[17] = 168; ip[18] = 0; ip[19] = 215;    /* dst 192.168.0.215 */
    ip[20] = sp >> 8; ip[21] = sp & 0xFF; ip[22] = dp >> 8; ip[23] = dp & 0xFF;
    return 14 + 20 + 8;
}
int main(void) {
    unsigned long c, ports, peer, drop[USNS_DROPS] = {0}, ctr[USNS_CLASSES] = {0};
    static USNS_BLOCK s;
    int bad = 0, i;
#define CHECK(x) do { if (!(x)) { printf("line %d: %s\n", __LINE__, #x); bad = 1; } } while (0)
    /* DNS reply from 1.1.1.1: UDP + DNS, peer = source */
    eth(0, 0x0800); ipv4(17, 53, 1025, 0);
    c = UsnsClassify(f, 90, 1, &ports, &peer);
    CHECK(c == (USNS_C_IPV4 | USNS_C_UDP | USNS_C_DNS));
    CHECK(ports == ((53UL << 16) | 1025)); CHECK(peer == 0x01010101UL);
    c = UsnsClassify(f, 90, 0, &ports, &peer);
    CHECK(peer == (192UL | (168UL << 8) | (0UL << 16) | (215UL << 24)));
    /* ICMP, TCP 80, ARP broadcast, IPv6, other, short, DHCP broadcast */
    eth(0, 0x0800); ipv4(1, 0, 0, 0); CHECK(UsnsClassify(f, 74, 1, &ports, &peer) == (USNS_C_IPV4 | USNS_C_ICMP));
    eth(0, 0x0800); ipv4(6, 1030, 80, 0); CHECK(UsnsClassify(f, 60, 0, &ports, &peer) == (USNS_C_IPV4 | USNS_C_TCP | USNS_C_HTTP));
    eth(1, 0x0806); CHECK(UsnsClassify(f, 60, 1, &ports, &peer) == (USNS_C_BCAST | USNS_C_ARP));
    eth(0, 0x86DD); CHECK(UsnsClassify(f, 80, 1, &ports, &peer) == USNS_C_IPV6);
    eth(0, 0x8899); CHECK(UsnsClassify(f, 60, 1, &ports, &peer) == USNS_C_OTHER);
    CHECK(UsnsClassify(f, 10, 1, &ports, &peer) == USNS_C_SHORT);
    eth(0, 0x0800); CHECK(UsnsClassify(f, 30, 1, &ports, &peer) == (USNS_C_IPV4 | USNS_C_SHORT));
    eth(1, 0x0800); ipv4(17, 68, 67, 0);
    CHECK(UsnsClassify(f, 342, 0, &ports, &peer) == (USNS_C_BCAST | USNS_C_IPV4 | USNS_C_UDP | USNS_C_DHCP));
    /* fragments: a later fragment has no ports */
    eth(0, 0x0800); ipv4(17, 53, 1025, 0x2000);
    CHECK(UsnsClassify(f, 90, 1, &ports, &peer) == (USNS_C_IPV4 | USNS_C_FRAG | USNS_C_UDP | USNS_C_DNS));
    eth(0, 0x0800); ipv4(17, 53, 1025, 0x00B9);
    c = UsnsClassify(f, 90, 1, &ports, &peer);
    CHECK(c == (USNS_C_IPV4 | USNS_C_FRAG | USNS_C_UDP) && ports == 0);
    /* USOSLOG request broadcast */
    eth(1, 0x0800); ipv4(17, 1050, USNS_LOG_PORT, 0);
    c = UsnsClassify(f, 60, 0, &ports, &peer);
    CHECK(UsnsIsLogRequest(c, ports));
    eth(0, 0x0800); ipv4(17, 1050, USNS_LOG_PORT, 0);
    c = UsnsClassify(f, 60, 0, &ports, &peer);
    CHECK(!UsnsIsLogRequest(c, ports));
    /* RX status: L4E / IPE (checksum offload verdicts) never drop */
    c = USNS_C_IPV4 | USNS_C_UDP | USNS_C_DNS;
    CHECK(UsnsRxStatus(drop, 0x00000003UL | USNS_ST_L4E | USNS_ST_IPE | USNS_ST_L4CS | USNS_ST_UDPCS | USNS_ST_IPCS, c) == 0);
    CHECK(drop[USNS_N_L4E] == 1 && drop[USNS_N_L4E_UDP] == 1 && drop[USNS_N_L4E_DNS] == 1 && drop[USNS_N_IPE] == 1);
    CHECK(drop[USNS_N_L4CS] == 1 && drop[USNS_N_UDPCS] == 1 && drop[USNS_N_IPCS] == 1);
    CHECK(UsnsRxStatus(drop, 0x00000003UL, c) == 0);
    /* frame errors drop, each counted */
    CHECK(UsnsRxStatus(drop, 0x00000001UL, c) == 1 && drop[USNS_D_NOT_EOP] == 1);
    CHECK(UsnsRxStatus(drop, 0x00000003UL | USNS_ST_CE, c) == 1 && drop[USNS_D_CE] == 1);
    CHECK(UsnsRxStatus(drop, 0x00000003UL | USNS_ST_RXE | USNS_ST_SEQ, c) == 1 && drop[USNS_D_RXE] == 1 && drop[USNS_D_SEQ] == 1);
    CHECK(USNS_ST_FRAME_ERR == 0x97000000UL);
    CHECK((USNS_ST_FRAME_ERR & (USNS_ST_L4E | USNS_ST_IPE)) == 0);
    /* counting and history */
    UsnsCount(ctr, USNS_C_IPV4 | USNS_C_UDP | USNS_C_DNS);
    CHECK(ctr[3] == 1 && ctr[5] == 1 && ctr[7] == 1 && ctr[4] == 0);
    for (i = 0; i < 40; i++) UsnsHistory(&s, 1, i, 0, 60, 3, 0);
    CHECK(s.Seq == 40 && (s.Hist[39 % USNS_HIST][0] >> 8) == 39 && s.Hist[39 % USNS_HIST][1] == 39);
    CHECK(sizeof(USNS_BLOCK) <= 4096 && sizeof(unsigned long) == 4);
    printf("size %u\n", (unsigned)sizeof(USNS_BLOCK));
    return bad;
}
'''

    def test_classifier_host_compiled(self):
        import subprocess, tempfile
        cc = _host_cc()
        if not cc:
            self.skipTest('no host C compiler')
        with tempfile.TemporaryDirectory() as d:
            c = Path(d) / 't.c'
            c.write_text(self.HARNESS)
            exe = Path(d) / 't.exe'
            r = subprocess.run([cc, '-m32', '-I', str(DRV / 'src'), '-o', str(exe), str(c)], capture_output=True, text=True)
            if r.returncode:   # no 32-bit runtime: unsigned long is 32-bit on 64-bit Windows too
                r = subprocess.run([cc, '-I', str(DRV / 'src'), '-o', str(exe), str(c)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout)

    def test_data_path_wiring(self):
        src = (DRV / 'src/usosnet.c').read_text(encoding='latin-1')
        igb = (DRV / 'src/usosnet_igb.c').read_text(encoding='latin-1')
        hdr = (DRV / 'src/usosnet.h').read_text(encoding='latin-1')
        self.assertIn('#define USOSNET_MINOR 4', hdr)
        poll = re.search(r'static void IgbRxPoll\(PADAPTER A\)\n\{(.*?)\n\}', igb, re.S).group(1)
        self.assertIn('USNS_ST_FRAME_ERR', poll)          # only frame errors drop
        self.assertNotIn('L4E', poll)
        self.assertNotIn('IPE', poll)
        self.assertIn('UsRxDropped(A', poll)
        self.assertIn('UsIndicateRx(A, A->RxBuf[i], len, st)', poll)
        send = re.search(r'static NDIS_STATUS MpSend\(.*?\n\}', src, re.S).group(0)
        self.assertIn('UsnsCount(S->Tx', send)
        self.assertIn('UsnsIsLogRequest', send)
        td = re.search(r'static NDIS_STATUS MpTransferData\(.*?\n\}', src, re.S).group(0)
        self.assertIn('USNS_T_NO_FRAME', td)
        self.assertIn('UsosnetStatsVa', src)
        self.assertIn('UsosnetStatsPa', src)
        free = re.search(r'static void FreeAll\(PADAPTER A\)\n\{(.*?)\n\}', src, re.S).group(1)
        self.assertLess(free.index('Magic = 0'), free.index('DmaFree(A, &A->StatsMem)'))


if __name__ == '__main__':
    unittest.main()
