"""usosnvme flush / timeout / shutdown / diagnostics path on the host.

The driver's queue functions (NvmeSubmit, NvmeWait, NvmeExec, NvmeFlush,
NvmeIoFailed, NvmeShutdown, NvmeIoControl) are taken from usosnvme.c as they
are and compiled with gcc against a simulated NVMe controller: a doorbell
write queues a completion that is posted after a configurable latency, and
every ScsiPortStallExecution advances a simulated clock by the stall plus a
per-call overhead. That overhead is what the old 2 us polling loop did not
count (X470 Micron, Win10 x86: ~55-60 s at shutdown for a "30 s" limit).

X470 B261022 evidence: RegFlushKey 1016 in the WinPE (2 of 3 runs), a long
black screen at shutdown after specialize. QEMU / host only; the next X470
run prints the driver's counters (windows_nvme_modern.c, diag lines)."""
from pathlib import Path
import re, shutil, subprocess, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
SRC_DIR = ROOT / 'tools/nt/usosnvme/src'
SRC = (SRC_DIR / 'usosnvme.c').read_text(encoding='latin-1')
HDR = (SRC_DIR / 'usosnvme.h').read_text(encoding='latin-1')


def function(name):
    m = re.search(r'\nstatic [^\n;]*\b' + name + r'\([^;{]*\)\n\{', SRC)
    assert m, name
    start = m.start() + 1
    return SRC[start:SRC.index('\n}\n', start) + 3]


FAKE_MINIPORT = r'''#include <stdint.h>
#include <string.h>
typedef uint32_t ULONG, *PULONG; typedef unsigned char UCHAR, *PUCHAR, BOOLEAN, *PBOOLEAN;
typedef uint16_t USHORT, *PUSHORT; typedef char CHAR; typedef void VOID, *PVOID; typedef int32_t LONG;
typedef uintptr_t ULONG_PTR;
#define TRUE 1
#define FALSE 0
#define IN
#define OUT
typedef struct { uint32_t LowPart; int32_t HighPart; } SCSI_PHYSICAL_ADDRESS;
typedef struct {
    UCHAR Function, SrbStatus, ScsiStatus, PathId, TargetId, Lun, SenseInfoBufferLength;
    ULONG SrbFlags, DataTransferLength, TimeOutValue;
    PVOID DataBuffer, SenseInfoBuffer;
    UCHAR Cdb[16];
} SCSI_REQUEST_BLOCK, *PSCSI_REQUEST_BLOCK;
#define SRB_STATUS_SUCCESS 0x01
#define SRB_STATUS_ERROR 0x04
#define SRB_STATUS_INVALID_REQUEST 0x06
#define SRB_STATUS_AUTOSENSE_VALID 0x80
#define SRB_FLAGS_DISABLE_AUTOSENSE 0x20
#define SCSISTAT_CHECK_CONDITION 0x02
#define SCSI_SENSE_NOT_READY 0x02
#define SCSI_SENSE_MEDIUM_ERROR 0x03
#define SCSI_SENSE_HARDWARE_ERROR 0x04
#define SCSI_SENSE_ILLEGAL_REQUEST 0x05
#define SCSI_SENSE_ABORTED_COMMAND 0x0B
ULONG ScsiPortReadRegisterUlong(PULONG p);
VOID ScsiPortWriteRegisterUlong(PULONG p, ULONG v);
VOID ScsiPortStallExecution(ULONG us);
'''

HARNESS = r'''
#include <assert.h>
#include <stdio.h>
#define USOSNVME_NT6
#include "usosnvme.h"
#define NVME_TIMEOUT_STATUS 0xFFFFFFFFUL
#define NVME_BADPA_STATUS 0xFFFFFFFEUL
static HW_DEVICE_EXTENSION ext;
static _Alignas(4096) UCHAR bar[0x2000];
static _Alignas(4096) NVME_SQE sq[32];
static _Alignas(4096) NVME_CQE cq[32];
/* simulated controller */
static uint64_t now_us, overhead_us = 2;
static ULONG csts = NVME_CSTS_RDY, cc = NVME_CC_EN, ctl_sq_head, ctl_cq_tail, ctl_phase = 1;
static long long latency_us = 50;      /* < 0: never completes */
static ULONG status_for_nsid1, status_other;
static ULONG submitted, last_nsid[8], last_opcode;
static int shn_pending; static uint64_t shn_due, shn_latency = 3000;
static struct { int used; uint64_t due; ULONG cid, status; } pend[32];
static ULONG logs[16], nlogs;
static VOID NvmeReport(PHW_DEVICE_EXTENSION Ext, const CHAR *Msg, ULONG Value, BOOLEAN Error) { (void)Ext; (void)Msg; (void)Value; (void)Error; }
static VOID NvmeLog(PHW_DEVICE_EXTENSION Ext, ULONG Id) { (void)Ext; if (nlogs < 16) logs[nlogs++] = Id; }
static void post(void) {
    for (int i = 0; i < 32; i++) if (pend[i].used && now_us >= pend[i].due) {
        NVME_CQE *e = &cq[ctl_cq_tail];
        e->Dw0 = 0; e->Dw2 = ctl_sq_head; e->Dw3 = pend[i].cid | (ctl_phase << 16) | (pend[i].status << 17);
        pend[i].used = 0;
        if (++ctl_cq_tail == 32) { ctl_cq_tail = 0; ctl_phase ^= 1; }
    }
    if (shn_pending && now_us >= shn_due) { csts = (csts & ~NVME_CSTS_SHST_MASK) | NVME_CSTS_SHST_DONE; shn_pending = 0; }
}
ULONG ScsiPortReadRegisterUlong(PULONG p) {
    ULONG off = (ULONG)((PUCHAR)p - bar);
    if (off == NVME_REG_CSTS) return csts;
    if (off == NVME_REG_CC) return cc;
    return 0;
}
VOID ScsiPortWriteRegisterUlong(PULONG p, ULONG v) {
    ULONG off = (ULONG)((PUCHAR)p - bar);
    if (off == NVME_REG_CC) {
        cc = v;
        if ((v & (3UL << 14)) == NVME_CC_SHN_NORMAL) { shn_pending = 1; shn_due = now_us + shn_latency; }
        return;
    }
    if (off == ext.Io.SqDoorbell) {
        while (ctl_sq_head != v) {
            NVME_SQE *c = &sq[ctl_sq_head];
            ULONG cid = c->Cdw0 >> 16, st = c->Nsid == 1 ? status_for_nsid1 : status_other;
            assert(cid != 0xFFFF);
            last_opcode = c->Cdw0 & 0xFF; last_nsid[submitted & 7] = c->Nsid; submitted++;
            ctl_sq_head = (ctl_sq_head + 1) % 32;
            if (latency_us >= 0) for (int i = 0; i < 32; i++) if (!pend[i].used) {
                pend[i].used = 1; pend[i].due = now_us + (uint64_t)latency_us; pend[i].cid = cid; pend[i].status = st; break;
            }
        }
    }
}
VOID ScsiPortStallExecution(ULONG us) { now_us += us + overhead_us; post(); }
/* FUNCTIONS */
static void reset(void) {
    memset(&ext, 0, sizeof ext); memset(sq, 0, sizeof sq); memset(cq, 0, sizeof cq); memset(pend, 0, sizeof pend);
    ext.Regs = bar; ext.Nsid = 1; ext.VolatileCache = 1; ext.Dirty = 1; ext.ControllerUp = 1; ext.NamespaceReady = 1;
    ext.Diag.Vwc = 1; ext.ShutdownMs = 5000; ext.PciId = 0x54071344;
    ext.Io.Sq = sq; ext.Io.Cq = cq; ext.Io.Depth = 32; ext.Io.Phase = 1;
    ext.Io.SqDoorbell = 0x1008; ext.Io.CqDoorbell = 0x100C;
    csts = NVME_CSTS_RDY; cc = NVME_CC_EN; ctl_sq_head = ctl_cq_tail = 0; ctl_phase = 1; shn_pending = 0;
    latency_us = 50; status_for_nsid1 = status_other = 0; submitted = 0; nlogs = 0; now_us = 0;
}
int main(void) {
    SCSI_REQUEST_BLOCK srb; UCHAR sense[18]; uint64_t t0;
    /* 1. a slow flush (3 ms): success, duration roughly real time, clean afterwards */
    reset(); latency_us = 3000; overhead_us = 1;
    assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0);
    assert(submitted == 1 && last_opcode == NVME_NVM_FLUSH && last_nsid[0] == 1);
    assert(ext.Diag.LastFlushUs >= 2600 && ext.Diag.LastFlushUs <= 3100);
    assert(ext.Diag.FlushOk == 1 && ext.Dirty == 0 && ext.Diag.Ring[1].Seq == 1);
    assert(ext.Diag.Ring[1].Source == USOSNVME_FLUSH_SYNC_CACHE && ext.Diag.Ring[1].Us == ext.Diag.LastFlushUs);
    /* 2. the SRB flush right after: no command (nothing written) */
    assert(NvmeFlush(&ext, USOSNVME_FLUSH_SRB_FLUSH) == 0 && submitted == 1);
    assert(ext.Diag.FlushSkipped == 1 && ext.Diag.Ring[2].Source == (USOSNVME_FLUSH_SRB_FLUSH | USOSNVME_FLUSH_CLEAN));
    /* 3. a write makes it dirty again (the flag NvmeRw sets) */
    ext.Dirty = 1; assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0 && submitted == 2);
    /* 4. no volatile write cache: never sent */
    ext.Dirty = 1; ext.VolatileCache = 0; assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0 && submitted == 2);
    assert((ext.Diag.Ring[4].Source & 0xFFFF0000UL) == USOSNVME_FLUSH_NO_VWC);
    /* 5. never completes: timeout in about 10 s of REAL time even with 1 or 3 us
       of overhead per poll (the old loop: 30 s counted = 45 / 75 s real) */
    for (int oh = 1; oh <= 3; oh += 2) {
        reset(); latency_us = -1; overhead_us = (uint64_t)oh;
        assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == NVME_TIMEOUT_STATUS);
        printf("overhead %d us: timeout after %llu us real, %lu us counted\n", oh, (unsigned long long)now_us, (unsigned long)ext.Diag.LastFlushUs);
        assert(now_us >= 10000000ull && now_us <= (oh == 1 ? 10400000ull : 11000000ull));
        assert(ext.NeedRestart && ext.Diag.FlushTimeouts == 1 && ext.Diag.FlushErrors == 1 && ext.Dirty);
        assert(nlogs == 1 && logs[0] == (NVME_LOG_FLUSH_BASE | 0xFFF) && ext.Diag.LastFlushStatus == NVME_TIMEOUT_STATUS);
    }
    /* 6. the SCSI view of a flush timeout: ABORTED COMMAND (retried) */
    memset(&srb, 0, sizeof srb); srb.SenseInfoBuffer = sense; srb.SenseInfoBufferLength = 18;
    NvmeIoFailed(&ext, &srb, NVME_TIMEOUT_STATUS, TRUE);
    assert(srb.SrbStatus == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && sense[2] == SCSI_SENSE_ABORTED_COMMAND);
    /* 7. Invalid Field for NSID 1: resent for all namespaces only if VWC bits 2:1 = 11b */
    reset(); status_for_nsid1 = 0x002; ext.Diag.Vwc = 0x07;
    assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0 && submitted == 2 && last_nsid[1] == 0xFFFFFFFFUL);
    assert((ext.Diag.Ring[1].Source & USOSNVME_FLUSH_ALL_NS) && ext.Diag.FlushSent == 2 && ext.Diag.FlushSkipped == 0);
    reset(); status_for_nsid1 = 0x002; ext.Diag.Vwc = 0x01;
    assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0x002 && submitted == 1 && !ext.NeedRestart);
    assert(nlogs == 1 && logs[0] == (NVME_LOG_FLUSH_BASE | 0x002));
    /* ... and SCSI gets ILLEGAL REQUEST / invalid field, not a device error */
    memset(&srb, 0, sizeof srb); memset(sense, 0, sizeof sense); srb.SenseInfoBuffer = sense; srb.SenseInfoBufferLength = 18;
    NvmeIoFailed(&ext, &srb, 0x002, TRUE); assert(sense[2] == SCSI_SENSE_ILLEGAL_REQUEST && sense[12] == 0x24);
    NvmeIoFailed(&ext, &srb, 0x001, TRUE); assert(sense[2] == SCSI_SENSE_ILLEGAL_REQUEST && sense[12] == 0x20);
    NvmeIoFailed(&ext, &srb, 0x082, TRUE); assert(sense[2] == SCSI_SENSE_NOT_READY && sense[12] == 0x04 && sense[13] == 0x01);
    NvmeIoFailed(&ext, &srb, 0x021, TRUE); assert(sense[2] == SCSI_SENSE_ABORTED_COMMAND);
    NvmeIoFailed(&ext, &srb, 0x006, TRUE); assert(sense[2] == SCSI_SENSE_HARDWARE_ERROR && sense[12] == 0x44);
    NvmeIoFailed(&ext, &srb, 0x281, TRUE); assert(sense[2] == SCSI_SENSE_MEDIUM_ERROR);
    NvmeIoFailed(&ext, &srb, 0x080, FALSE); assert(sense[2] == SCSI_SENSE_ILLEGAL_REQUEST && sense[12] == 0x21);
    /* 8. shutdown: flush + CC.SHN, wait for SHST, controller marked down */
    reset(); overhead_us = 1; t0 = now_us;
    NvmeShutdown(&ext);
    assert(submitted == 1 && ext.Diag.Shutdowns == 1 && !ext.ControllerUp);
    assert((cc & (3UL << 14)) == NVME_CC_SHN_NORMAL && (cc & NVME_CC_EN));
    assert(ext.Diag.LastShutdownUs >= 2000 && ext.Diag.LastShutdownUs <= 4000 && now_us - t0 < 10000);
    assert(ext.Diag.Ring[1].Source == USOSNVME_FLUSH_SHUTDOWN);
    /* after a timed-out command: no flush, but still the notification */
    reset(); ext.NeedRestart = 1; NvmeShutdown(&ext); assert(submitted == 0 && ext.Diag.Shutdowns == 1);
    /* SHST never completes: bounded by ShutdownMs */
    reset(); ext.Dirty = 0; shn_latency = 1ull << 40; t0 = now_us; NvmeShutdown(&ext);
    assert(ext.Diag.LastShutdownUs == 5000000 && now_us - t0 < 5100000); shn_latency = 3000;
    /* controller down and disabled: nothing at all */
    reset(); ext.ControllerUp = 0; cc = 0; csts = 0; NvmeShutdown(&ext); assert(submitted == 0 && ext.Diag.Shutdowns == 0);
    /* 9. diagnostics IOCTL */
    {
        static UCHAR buf[sizeof(USOSNVME_SRB_IO_CONTROL) + sizeof(USOSNVME_DIAG)];
        PUSOSNVME_SRB_IO_CONTROL h = (PUSOSNVME_SRB_IO_CONTROL)buf; PUSOSNVME_DIAG d = (PUSOSNVME_DIAG)(buf + sizeof(*h));
        reset(); ext.Writes = 7; ext.Diag.FlushOk = 3; ext.Diag.MaxFlushUs = 1234;
        memset(&srb, 0, sizeof srb); srb.DataBuffer = buf; srb.DataTransferLength = sizeof buf;
        h->HeaderLength = sizeof(*h); memcpy(h->Signature, "USOSNVME", 8); h->ControlCode = USOSNVME_DIAG_CODE; h->Length = sizeof(USOSNVME_DIAG);
        NvmeIoControl(&ext, &srb);
        assert(srb.SrbStatus == SRB_STATUS_SUCCESS && h->ReturnCode == 0 && h->Length == sizeof(USOSNVME_DIAG));
        assert(d->Version == USOSNVME_DIAG_VERSION && d->Size == sizeof(USOSNVME_DIAG) && d->Writes == 7);
        assert(d->FlushOk == 3 && d->MaxFlushUs == 1234 && d->PciId == 0x54071344 && d->State == (1 | 2 | 8));
        memcpy(h->Signature, "OTHERDRV", 8); srb.SrbStatus = 0; NvmeIoControl(&ext, &srb);
        assert(srb.SrbStatus == SRB_STATUS_INVALID_REQUEST);
        memcpy(h->Signature, "USOSNVME", 8); srb.DataTransferLength = sizeof(*h) + 8; NvmeIoControl(&ext, &srb);
        assert(srb.SrbStatus == SRB_STATUS_INVALID_REQUEST && h->ReturnCode == 1);
    }
    /* 10. sub-ms flushes still add up in TotalFlushMs (us remainder carried):
       ten ~300 us flushes = ~3 ms, the old us / 1000 counted 0 */
    reset(); latency_us = 300; overhead_us = 1;
    for (int i = 0; i < 10; i++) { ext.Dirty = 1; assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0); }
    assert(ext.Diag.LastFlushUs < 1000 && ext.Diag.FlushOk == 10);
    assert(ext.Diag.TotalFlushMs >= 2 && ext.Diag.TotalFlushMs <= 4 && ext.FlushUsCarry < 1000);
    {
        ULONG sum = 0; for (int i = 0; i < 8; i++) sum += ext.Diag.Ring[i].Us;
        assert(ext.Diag.TotalFlushMs * 1000 + ext.FlushUsCarry >= sum);
    }
    /* 11. CID FFFFh is never used */
    reset(); ext.CommandId = 0xFFFD;
    for (int i = 0; i < 4; i++) { ext.Dirty = 1; assert(NvmeFlush(&ext, USOSNVME_FLUSH_SYNC_CACHE) == 0); }
    return 0;
}
'''


class FlushPath(unittest.TestCase):
    def test_simulated_controller(self):
        gcc = shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        parts = []
        for name in ('NvmeZero', 'NvmeCopy', 'NvmeRd', 'NvmeWr', 'NvmeControllerDead', 'NvmeSubmit',
                     'NvmeWait', 'NvmeExec', 'NvmeFlush', 'NvmeSetSense', 'NvmeIoFailed', 'NvmeShutdown',
                     'NvmeIoControl'):
            parts.append(function(name))
        parent = ROOT / 'zig-out/usosnvme-host-tests'; parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as tmp:
            t = Path(tmp)
            (t / 'miniport.h').write_text(FAKE_MINIPORT)
            (t / 'scsi.h').write_text('')
            for h in ('usosnvme.h', 'usosnvme_diag.h'):
                shutil.copy(SRC_DIR / h, t / h)
            (t / 'flush.c').write_text(HARNESS.replace('/* FUNCTIONS */', '\n'.join(parts)))
            exe = t / 'flush.exe'
            r = subprocess.run([gcc, '-std=c11', '-Wall', '-Wno-unused-function', '-I', str(t), str(t / 'flush.c'), '-o', str(exe)],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('overhead 3 us: timeout after', r.stdout)


class Source(unittest.TestCase):
    def test_wait_counts_real_time_and_limits_stay_below_the_dpc_watchdog(self):
        wait = function('NvmeWait')
        self.assertIn('step = waited < 200 ? 2 : (waited < 2000 ? 10 : 50);', wait)
        self.assertNotIn('ScsiPortStallExecution(2);', wait)
        for want in ('#define NVME_IO_TIMEOUT_US     (10UL * 1000UL * 1000UL)',
                     '#define NVME_FLUSH_TIMEOUT_US  (10UL * 1000UL * 1000UL)',
                     '#define NVME_SHN_MAX_MS        10000UL',
                     '#define NVME_LOG_FLUSH_BASE  0x4E561000UL', '#include "usosnvme_diag.h"'):
            self.assertIn(want, HDR)

    def test_srb_dispatch(self):
        start = function('NvmeStartIo')
        self.assertIn('case SRB_FUNCTION_SHUTDOWN:\n#ifdef USOSNVME_NT6\n        NvmeShutdown(ext);\n#else', start)
        self.assertIn('(VOID)NvmeFlush(ext, USOSNVME_FLUSH_SRB_FLUSH);', start)
        self.assertIn('case SRB_FUNCTION_IO_CONTROL:\n        NvmeIoControl(ext, Srb);', start)
        self.assertIn('status = NvmeFlush(Ext, USOSNVME_FLUSH_SYNC_CACHE);', SRC)
        self.assertIn('#if defined(USOSNVME_W9X) || defined(USOSNVME_NT6)\n/* Flush (if anything is unflushed)', SRC)
        rw = function('NvmeRw')
        self.assertIn('if (Write) Ext->Dirty = TRUE;', rw)
        self.assertLess(rw.index('if (Write) Ext->Dirty = TRUE;'), rw.index('status = NvmeExec('))

    def test_binaries_carry_the_diag_signature(self):
        # every committed build answers the diagnostics IOCTL
        drv = ROOT / 'tools/nt/usosnvme/bin'
        for b in ('2KXP/i386/usosnvme.sys', 'NT6/i386/usosnvme.sys', 'NT6/amd64/usosnvme.sys', 'NT4/i386/usosnvme.sys',
                  'NT351/i386/usosnvme.sys', 'NT31/i386/usosnvme.sys', 'W9X/usosnvme.mpd'):
            data = (drv / b).read_bytes()
            self.assertIn(b'FLUSH timeout; CSTS', data, b)


if __name__ == '__main__':
    unittest.main()
