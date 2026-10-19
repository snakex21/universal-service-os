"""USOSUSB.MPD (tools/nt/usosusb9x): the Windows 9x SCSIPORT.PDR miniport of the
USOS USB disk service (docs/usb9x-hotswap-design-2026-10-19.md, stage 1).
Static source rules, the committed PE image (bin/W9X/usosusb.mpd), INF / REG
sanity and a host simulation: usosusb.c + usosuds_slot.c built with zig cc
against a fake miniport.h and a fake UDS helper (one stick, delays, removal,
watchdog). No VM, no disk.
Usage: python -I tools/tests/usb9x/test_usosusb9x.py [zig]"""
from pathlib import Path
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools/tests'))
from check_nt52_driver_imports import pe  # noqa: E402

DRV = ROOT / 'tools/nt/usosusb9x'
MPD = DRV / 'bin/W9X/usosusb.mpd'
UDS = ROOT / 'src/platform/bios/win9x'
SRC = (DRV / 'src/usosusb.c').read_text(encoding='latin-1')
HDR = (DRV / 'src/usosusb.h').read_text(encoding='latin-1')

# What SCSIPORT.PDR 4.x resolves for a PE miniport (same list as test_usosnvme_w9x.py).
PDR_EXPORTS = {
    'ScsiPortCompleteRequest', 'ScsiPortConvertPhysicalAddressToUlong', 'ScsiPortConvertUlongToPhysicalAddress',
    'ScsiPortFlushDma', 'ScsiPortFreeDeviceBase', 'ScsiPortGetBusData', 'ScsiPortGetDeviceBase',
    'ScsiPortGetLogicalUnit', 'ScsiPortGetPhysicalAddress', 'ScsiPortGetSrb', 'ScsiPortGetUncachedExtension',
    'ScsiPortGetVirtualAddress', 'ScsiPortInitialize', 'ScsiPortIoMapTransfer', 'ScsiPortLogError',
    'ScsiPortMoveMemory', 'ScsiPortNotification', 'ScsiPortReadPortUchar', 'ScsiPortReadPortUshort',
    'ScsiPortReadPortUlong', 'ScsiPortReadRegisterUchar', 'ScsiPortReadRegisterUshort', 'ScsiPortReadRegisterUlong',
    'ScsiPortWritePortUchar', 'ScsiPortWritePortUshort', 'ScsiPortWritePortUlong', 'ScsiPortWriteRegisterUchar',
    'ScsiPortWriteRegisterUshort', 'ScsiPortWriteRegisterUlong', 'ScsiPortSetBusDataByOffset',
    'ScsiPortStallExecution', 'ScsiPortValidateRange', 'ScsiDebugPrint'}


def find_zig():
    if len(sys.argv) > 1 and Path(sys.argv[1]).exists():
        return sys.argv[1]
    for cand in (ROOT / 'tools/zig/zig.exe', Path.home() / 'Desktop/Universal_Service_OS/tools/zig/zig.exe'):
        if cand.exists():
            return str(cand)
    return shutil.which('zig')


class Source(unittest.TestCase):
    def test_no_crt(self):
        for text in (SRC, HDR):
            for banned in ('#include <string.h>', '#include <stdio.h>', '#include <stdlib.h>', 'memcpy(', 'memset(',
                           'malloc(', 'printf(', 'MmMapIoSpace', 'ScsiPortGetBusData', 'ScsiPortGetDeviceBase',
                           '0xCF8', '0xCFC'):
                self.assertNotIn(banned, text)

    def test_licence_and_provenance(self):
        for text in (SRC, HDR):
            self.assertIn('Copyright (C) 2026 Maksymilian and the USOS Authors', text)
            self.assertIn('GPL-3.0-or-later', text)
            self.assertIn('No Microsoft source code', text)
        readme = (DRV / 'README.md').read_text(encoding='utf-8')
        self.assertIn('Provenance', readme)

    def test_uses_slot_machine(self):
        for fn in ('uds_slot_init(', 'uds_slot_update(', 'uds_slot_before(', 'uds_slot_fill(', 'uds_slot_after(',
                   'uds_local_inquiry(', 'uds_local_sense('):
            self.assertIn(fn, SRC)
        # not reimplemented here
        for fn in ('void uds_slot_', 'uds_u32 uds_req_check'):
            self.assertNotIn(fn, SRC)
        self.assertIn('#include "usosuds.h"', HDR)
        sources = (DRV / 'src/W9X/sources').read_text(encoding='latin-1')
        self.assertIn(r'..\usosuds_slot.c', sources)
        cmd = (DRV / 'build.cmd').read_text(encoding='latin-1')
        self.assertIn(r'"%REPO%\src\platform\bios\win9x\usosuds_slot.c"', cmd)
        self.assertIn(r'"%REPO%\src\platform\bios\win9x\usosuds.h"', cmd)

    def test_w9x_rules(self):
        src = SRC.replace('\r\n', '\n')
        for want in ('init.AdapterInterfaceType = Isa;', 'init.NumberOfAccessRanges = 0;', 'init.HwInterrupt = NULL;',
                     'init.HwAdapterState = UsbAdapterState;', 'init.MapBuffers = TRUE;',
                     'init.NeedPhysicalAddresses = TRUE;', 'init.AutoRequestSense = TRUE;',
                     'init.MultipleRequestPerLu = FALSE;', '_emit 06Ch', 'UsbMapPhys(0xF0000UL, 0x10000UL)',
                     'c->magic == UDS_CH1_MAGIC', 'return SP_RETURN_NOT_FOUND;', '*Again = FALSE;',
                     'ConfigInfo->ScatterGather = FALSE;', 'ConfigInfo->CachesData = FALSE;',
                     'ConfigInfo->InitiatorBusId[0] = USB_INITIATOR_ID;', 'ch->req_phys = ext->BlockPhys;',
                     'ScsiPortNotification(RequestTimerCall, Ext, UsbTimer, USB_TIMER_US);',
                     'Ext->Ch->doorbell = Ext->Seq;', 'SRB_STATUS_AUTOSENSE_VALID', 'SRB_FLAGS_DISABLE_AUTOSENSE',
                     'uncached extension not contiguous'):
            self.assertIn(want, src)
        self.assertNotIn('cli', [w.strip(';') for w in src.split()])   # never disables interrupts
        sources = (DRV / 'src/W9X/sources').read_text(encoding='latin-1')
        self.assertIn('/MERGE:INIT=.text', sources)
        self.assertIn('SUBSYSTEM_VERSION=4.00', sources)
        self.assertNotIn('ntoskrnl.lib', sources)
        cmd = (DRV / 'build.cmd').read_text(encoding='latin-1')
        self.assertIn('--version 4.00', cmd)
        self.assertIn(r'"%HERE%bin\W9X\usosusb.mpd"', cmd)


class Image(unittest.TestCase):
    def test_imports_only_scsiport(self):
        imps = pe(MPD)[1]
        self.assertTrue(imps)
        self.assertEqual({m.upper() for m, _ in imps}, {'SCSIPORT.SYS'})
        self.assertLessEqual({n for _, n in imps}, PDR_EXPORTS)
        self.assertNotIn(b'ntoskrnl', MPD.read_bytes().lower())

    def test_pe_layout(self):
        b = MPD.read_bytes()
        off = int.from_bytes(b[0x3C:0x40], 'little')
        self.assertEqual(b[off:off + 4], b'PE\0\0')
        self.assertEqual(int.from_bytes(b[off + 4:off + 6], 'little'), 0x14C)
        opt = off + 24
        self.assertEqual(int.from_bytes(b[opt + 28:opt + 32], 'little'), 0x10000)   # ImageBase
        self.assertEqual(struct.unpack_from('<HH', b, opt + 40), (4, 0))             # OS version
        self.assertEqual(struct.unpack_from('<HH', b, opt + 48), (4, 0))             # subsystem version
        self.assertEqual(int.from_bytes(b[opt + 68:opt + 70], 'little'), 1)          # native
        _, reloc_size = struct.unpack_from('<II', b, opt + 96 + 5 * 8)
        self.assertGreater(reloc_size, 0)
        nsec = int.from_bytes(b[off + 6:off + 8], 'little')
        sec = opt + int.from_bytes(b[off + 20:off + 22], 'little')
        names = {b[sec + 40 * i:sec + 40 * i + 8].rstrip(b'\0') for i in range(nsec)}
        # same section set as the working usosnvme.mpd (its INIT also survives /MERGE:INIT=.text)
        self.assertEqual(names, {b'.text', b'.rdata', b'.data', b'INIT', b'.rsrc', b'.reloc'})
        self.assertIn(b'USOSUSB 1.1', b)


class InfReg(unittest.TestCase):
    def test_inf(self):
        raw = (DRV / 'usosusb.inf').read_bytes()
        self.assertNotIn(b'\n', raw.replace(b'\r\n', b''))
        t = raw.decode('ascii')
        for want in ('Signature="$CHICAGO$"', 'Class=SCSIAdapter', 'DefaultDestDir=12',
                     '%USOSUSB.DeviceDesc%=USOSUSB, USOSUSB', 'HKR,,DevLoader,,*IOS',
                     'HKR,,PortDriver,,usosusb.mpd', 'usosusb.mpd=1', 'CopyFiles=USOSUSB.Copy'):
            self.assertIn(want, t)
        self.assertNotIn('PCI\\', t.split('[Version]')[1])

    def test_reg(self):
        raw = (DRV / 'usosusb.reg').read_bytes()
        self.assertNotIn(b'\n', raw.replace(b'\r\n', b''))
        t = raw.decode('ascii')
        self.assertTrue(t.startswith('REGEDIT4\r\n\r\n'))
        for want in ('[HKEY_LOCAL_MACHINE\\Enum\\Root\\SCSIAdapter\\@CLASSIDX@]', '"Class"="SCSIAdapter"',
                     '"Driver"="SCSIAdapter\\\\@CLASSIDX@"', '"HardwareID"="USOSUSB"',
                     '[HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\SCSIAdapter\\@CLASSIDX@]',
                     '"DevLoader"="*IOS"', '"PortDriver"="usosusb.mpd"'):
            self.assertIn(want, t)
        # numeric root instance (the form CONFIGMG writes, proven by the usosnvme
        # --regbind QEMU run with 0000), same number as the class instance
        self.assertEqual(t.count('@CLASSIDX@'), 3)
        self.assertNotIn('SCSIAdapter\\USOSUSB]', t)
        # the flow substitutes a 4-digit class instance, e.g. 0009
        sub = t.replace('@CLASSIDX@', '0009')
        self.assertIn('Services\\Class\\SCSIAdapter\\0009]', sub)


FAKE_MINIPORT = r'''
#include <stdint.h>
#include <stddef.h>
typedef uint32_t ULONG, *PULONG;
typedef int32_t LONG;
typedef uint16_t USHORT, *PUSHORT;
typedef uint8_t UCHAR, *PUCHAR, BOOLEAN, *PBOOLEAN;
typedef char CHAR, *PCHAR;
typedef void VOID, *PVOID;
typedef uint64_t ULONGLONG;
#define IN
#define OUT
#define TRUE 1
#define FALSE 0
#define FIELD_OFFSET(t, f) ((ULONG)offsetof(t, f))
typedef struct { ULONG LowPart; LONG HighPart; } SCSI_PHYSICAL_ADDRESS;
typedef struct _SCSI_REQUEST_BLOCK {
    USHORT Length; UCHAR Function, SrbStatus, ScsiStatus, PathId, TargetId, Lun, QueueTag, QueueAction,
    CdbLength, SenseInfoBufferLength; ULONG SrbFlags, DataTransferLength, TimeOutValue; PVOID DataBuffer,
    SenseInfoBuffer; UCHAR Cdb[16];
} SCSI_REQUEST_BLOCK, *PSCSI_REQUEST_BLOCK;
typedef struct {
    ULONG NumberOfBuses; UCHAR MaximumNumberOfTargets; UCHAR InitiatorBusId[8]; BOOLEAN ScatterGather, Master,
    Dma32BitAddresses, CachesData; ULONG AlignmentMask, MaximumTransferLength, NumberOfPhysicalBreaks,
    BusInterruptLevel, BusInterruptVector;
} PORT_CONFIGURATION_INFORMATION, *PPORT_CONFIGURATION_INFORMATION;
typedef enum { Internal, Isa } INTERFACE_TYPE;
typedef struct {
    ULONG HwInitializationDataSize; INTERFACE_TYPE AdapterInterfaceType;
    BOOLEAN (*HwInitialize)(PVOID); BOOLEAN (*HwStartIo)(PVOID, PSCSI_REQUEST_BLOCK);
    BOOLEAN (*HwInterrupt)(PVOID);
    ULONG (*HwFindAdapter)(PVOID, PVOID, PVOID, PCHAR, PPORT_CONFIGURATION_INFORMATION, PBOOLEAN);
    BOOLEAN (*HwResetBus)(PVOID, ULONG); PVOID HwDmaStarted; BOOLEAN (*HwAdapterState)(PVOID, PVOID, BOOLEAN);
    ULONG DeviceExtensionSize, SpecificLuExtensionSize, SrbExtensionSize, NumberOfAccessRanges;
    PVOID Reserved; BOOLEAN MapBuffers, NeedPhysicalAddresses, TaggedQueuing, AutoRequestSense,
    MultipleRequestPerLu, ReceiveEvent; USHORT VendorIdLength; PVOID VendorId; USHORT ReservedUshort,
    DeviceIdLength; PVOID DeviceId; PVOID HwAdapterControl;
} HW_INITIALIZATION_DATA;
enum { RequestComplete, NextRequest, NextLuRequest, ResetDetected, CallDisableInterrupts,
       CallEnableInterrupts, RequestTimerCall };
#define SP_RETURN_NOT_FOUND 0
#define SP_RETURN_FOUND 1
#define SP_RETURN_ERROR 2
#define SP_UNTAGGED ((UCHAR)~0)
#define SRB_FUNCTION_EXECUTE_SCSI 0x00
#define SRB_FUNCTION_ABORT_COMMAND 0x10
#define SRB_FUNCTION_RESET_DEVICE 0x13
#define SRB_FUNCTION_RESET_BUS 0x12
#define SRB_FUNCTION_TERMINATE_IO 0x14
#define SRB_FUNCTION_RELEASE_RECOVERY 0x11
#define SRB_FUNCTION_SHUTDOWN 0x07
#define SRB_FUNCTION_FLUSH 0x08
#define SRB_STATUS_SUCCESS 0x01
#define SRB_STATUS_ERROR 0x04
#define SRB_STATUS_INVALID_REQUEST 0x06
#define SRB_STATUS_TIMEOUT 0x09
#define SRB_STATUS_SELECTION_TIMEOUT 0x0A
#define SRB_STATUS_BUS_RESET 0x0E
#define SRB_STATUS_DATA_OVERRUN 0x12
#define SRB_STATUS_QUEUE_FROZEN 0x40
#define SRB_STATUS_AUTOSENSE_VALID 0x80
#define SRB_STATUS(s) ((s) & ~(SRB_STATUS_AUTOSENSE_VALID | SRB_STATUS_QUEUE_FROZEN))
#define SRB_FLAGS_DISABLE_AUTOSENSE 0x20
#define SRB_FLAGS_DATA_IN 0x40
#define SRB_FLAGS_DATA_OUT 0x80
#define SCSISTAT_GOOD 0x00
#define SCSISTAT_CHECK_CONDITION 0x02
ULONG ScsiPortInitialize(PVOID, PVOID, HW_INITIALIZATION_DATA *, PVOID);
PVOID ScsiPortGetUncachedExtension(PVOID, PPORT_CONFIGURATION_INFORMATION, ULONG);
SCSI_PHYSICAL_ADDRESS ScsiPortGetPhysicalAddress(PVOID, PSCSI_REQUEST_BLOCK, PVOID, ULONG *);
void ScsiPortStallExecution(ULONG);
void ScsiPortMoveMemory(PVOID, PVOID, ULONG);
void ScsiPortNotification(int, PVOID, ...);
void ScsiPortCompleteRequest(PVOID, UCHAR, UCHAR, UCHAR, UCHAR);
PVOID host_map_phys(ULONG phys, ULONG bytes);
void host_dbg_str(const CHAR *s);
void host_barrier(void);
BOOLEAN host_has_tsc(void);
ULONGLONG host_rdtsc(void);
'''

# The fake helper: serves channel 1 from ScsiPortStallExecution / the
# test's timer ticks after a configurable delay; one stick (dev 2 of the
# table, dev 0 has a BIOS number) with an in-memory 4 MiB disk.
HARNESS = r'''
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "usosusb.c"   /* direct: the test resets the one-adapter latch */

int scenario(void);
static HW_INITIALIZATION_DATA g_init;
static UCHAR g_fseg[0x10000];
static UCHAR *g_unc; static ULONG g_unc_phys = 0x00300000; static int g_split_page = -1;
static ULONGLONG g_tsc; static int g_fails;
static void (*g_timer)(PVOID); static int g_completed, g_next; static PSCSI_REQUEST_BLOCK g_last;
static struct uds_channel *g_ch;
/* helper model */
static int h_delay_us = 0, h_left = -1, h_dead = 0, h_gen = 5, h_present = 1, h_sync_illegal = 1;
static ULONG h_ops[8]; static int h_gone_next = 0;
static UCHAR h_disk[4u << 20];

#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); g_fails++; } } while (0)

ULONG ScsiPortInitialize(PVOID a, PVOID b, HW_INITIALIZATION_DATA *i, PVOID c)
{ (void)a; (void)b; (void)c; g_init = *i; return 0; }
PVOID ScsiPortGetUncachedExtension(PVOID e, PPORT_CONFIGURATION_INFORMATION ci, ULONG n)
{ (void)e; (void)ci; g_unc = calloc(1, n + 4096); return g_unc + 0x234; }
SCSI_PHYSICAL_ADDRESS ScsiPortGetPhysicalAddress(PVOID e, PSCSI_REQUEST_BLOCK s, PVOID va, ULONG *len)
{
    SCSI_PHYSICAL_ADDRESS p; ULONG off = (ULONG)((UCHAR *)va - g_unc);
    (void)e; (void)s;
    p.LowPart = g_unc_phys + off; p.HighPart = 0;
    if (g_split_page >= 0 && off >= (ULONG)g_split_page * 4096u) p.LowPart += 0x100000;
    *len = 4096 - (p.LowPart & 4095);
    return p;
}
static void *phys2va(ULONG phys)
{
    ULONG off = phys - g_unc_phys;
    if (g_split_page >= 0 && phys >= g_unc_phys + 0x100000) off -= 0x100000;
    return g_unc + off;
}
static void helper_serve(void);
static void helper_tick(ULONG us)
{
    if (g_ch->doorbell == g_ch->done || h_dead) return;
    if (h_left < 0) h_left = h_delay_us;
    h_left -= (int)us;
    if (h_left <= 0) { h_left = -1; helper_serve(); }
}
void ScsiPortStallExecution(ULONG us) { g_tsc += (ULONGLONG)us * 1000; helper_tick(us); }
void ScsiPortMoveMemory(PVOID d, PVOID s, ULONG n) { memmove(d, s, n); }
void ScsiPortNotification(int t, PVOID e, ...)
{
    va_list ap; va_start(ap, e);
    if (t == RequestComplete) { g_last = va_arg(ap, PSCSI_REQUEST_BLOCK); g_completed++; }
    else if (t == NextRequest) g_next++;
    else if (t == RequestTimerCall) { g_timer = va_arg(ap, void (*)(PVOID)); CHECK(va_arg(ap, ULONG) == 1000); }
    va_end(ap);
}
void ScsiPortCompleteRequest(PVOID e, UCHAR p, UCHAR t, UCHAR l, UCHAR s) { (void)e; (void)p; (void)t; (void)l; (void)s; g_completed++; }
PVOID host_map_phys(ULONG phys, ULONG bytes) { return phys == 0xF0000 && bytes == 0x10000 ? g_fseg : NULL; }
void host_dbg_str(const CHAR *s) { if (getenv("USOSUSB_VERBOSE")) fputs(s, stdout); }
void host_barrier(void) {}
BOOLEAN host_has_tsc(void) { return 1; }
ULONGLONG host_rdtsc(void) { return g_tsc; }

static void sense(struct uds_req *r, UCHAR key, UCHAR asc)
{
    r->status = UDS_S_CHECK; r->csw_status = 1; r->sense_len = 18;
    memset(r->sense, 0, sizeof(r->sense)); r->sense[0] = 0x70; r->sense[2] = key; r->sense[7] = 10; r->sense[12] = asc;
}
static ULONG be32(const UCHAR *p) { return (ULONG)p[0] << 24 | (ULONG)p[1] << 16 | (ULONG)p[2] << 8 | p[3]; }
static void helper_serve(void)
{
    struct uds_req *r = phys2va(g_ch->req_phys);
    uds_u32 why;
    CHECK(r->seq == g_ch->doorbell);
    if (uds_req_check(r, &why) != UDS_S_OK) { r->status = UDS_S_BADREQ; printf("BADREQ why %u\n", why); g_fails++; }
    else {
        h_ops[r->op]++;
        r->residue = 0;
        if (r->op == UDS_OP_ENUM) {
            struct uds_dev_info *t = phys2va(r->data_phys);
            memset(t, 0, r->data_len);
            t[0].state = UDS_DEV_PRESENT; t[0].bios_drive = 0x81; t[0].generation = 1;   /* INT 13h's */
            if (h_present) { t[2].state = UDS_DEV_PRESENT; t[2].generation = (uds_u32)h_gen; t[2].block_size = 512; }
            r->status = UDS_S_OK;
        } else if (r->op == UDS_OP_SCSI) {
            UCHAR *d = r->data_len ? phys2va(r->data_phys) : NULL;
            r->status = UDS_S_OK;
            if (h_gone_next) { r->status = UDS_S_GONE; h_gone_next = 0; }
            else if (r->dev != 2 || !h_present) r->status = UDS_S_NODEV;
            else if (r->generation != (uds_u32)h_gen) r->status = UDS_S_GONE;
            else switch (r->cdb[0]) {
            case 0x00: break;
            case 0x25: CHECK(r->dir == UDS_DIR_IN && r->data_len == 8);
                d[0] = 0; d[1] = 0; d[2] = 0x1F; d[3] = 0xFF; d[4] = 0; d[5] = 0; d[6] = 2; d[7] = 0; break;
            case 0x28: CHECK(r->dir == UDS_DIR_IN); memcpy(d, h_disk + be32(r->cdb + 2) * 512, r->data_len); break;
            case 0x2A: CHECK(r->dir == UDS_DIR_OUT); memcpy(h_disk + be32(r->cdb + 2) * 512, d, r->data_len); break;
            case 0x1A: CHECK(r->dir == UDS_DIR_IN); memset(d, 0, r->data_len); d[0] = 3; r->residue = r->data_len - 4; break;
            case 0x35: if (h_sync_illegal) sense(r, 5, 0x20); break;
            default: sense(r, 5, 0x20); break;
            }
            r->generation = (uds_u32)h_gen;
        } else r->status = UDS_S_OK;
    }
    g_ch->done = g_ch->doorbell;
}

static HW_DEVICE_EXTENSION *g_ext;
static UCHAR g_buf[65536], g_sense[18];
static ULONG ref_crc(const UCHAR *p, ULONG n)   /* bitwise CRC-32, independent of the table */
{
    ULONG c = 0xFFFFFFFFUL; int k;
    while (n--) { c ^= *p++; for (k = 0; k < 8; k++) c = (c >> 1) ^ (0xEDB88320UL & (0UL - (c & 1))); }
    return c ^ 0xFFFFFFFFUL;
}
static SCSI_REQUEST_BLOCK g_srb;

/* StartIo, then 1 ms timer ticks until the SRB completes (or limit) */
static UCHAR run(UCHAR target, const UCHAR *cdb, UCHAR cdb_len, ULONG flags, ULONG len, int max_ticks)
{
    int before = g_completed, ticks = 0;
    memset(&g_srb, 0, sizeof(g_srb));
    memset(g_sense, 0, sizeof(g_sense));
    g_srb.Function = SRB_FUNCTION_EXECUTE_SCSI; g_srb.TargetId = target; g_srb.CdbLength = cdb_len;
    memcpy(g_srb.Cdb, cdb, cdb_len); g_srb.SrbFlags = flags; g_srb.DataTransferLength = len;
    g_srb.DataBuffer = len ? g_buf : NULL; g_srb.SenseInfoBuffer = g_sense; g_srb.SenseInfoBufferLength = 18;
    /* a timer armed earlier stays pending (SCSIPORT keeps it) */
    g_init.HwStartIo(g_ext, &g_srb);
    while (g_completed == before && ticks < max_ticks) {
        void (*t)(PVOID) = g_timer;
        CHECK(t != NULL);
        if (!t) break;
        g_timer = NULL;
        g_tsc += 1000000; helper_tick(1000);
        t(g_ext);
        ticks++;
    }
    CHECK(g_completed == before + 1);
    CHECK(g_next >= g_completed);
    return g_srb.SrbStatus;
}
static UCHAR func(UCHAR f)
{
    int before = g_completed, ticks = 0;
    memset(&g_srb, 0, sizeof(g_srb)); g_srb.Function = f;
    g_init.HwStartIo(g_ext, &g_srb);
    while (g_completed == before && g_timer && ticks++ < 100000) { void (*t)(PVOID) = g_timer; g_timer = NULL; g_tsc += 1000000; helper_tick(1000); t(g_ext); }
    CHECK(g_completed == before + 1);
    return g_srb.SrbStatus;
}

static const UCHAR TUR[6] = { 0 }, INQ[6] = { 0x12, 0, 0, 0, 36, 0 }, RC[10] = { 0x25 };
static const UCHAR SYNC[10] = { 0x35 }, EJECT[6] = { 0x1B, 0, 0, 0, 0x02, 0 }, MS[6] = { 0x1A, 0, 0x3F, 0, 192, 0 };

static int find_adapter(void)
{
    PORT_CONFIGURATION_INFORMATION ci; BOOLEAN again = 1;
    memset(&ci, 0, sizeof(ci));
    UsbClaimed = FALSE;
    if (g_ext) free(g_ext);
    g_ext = calloc(1, sizeof(*g_ext));
    return (int)g_init.HwFindAdapter(g_ext, NULL, NULL, NULL, &ci, &again) * 10 + again +
           (ci.MaximumNumberOfTargets == 1 && ci.InitiatorBusId[0] == 7 && !ci.ScatterGather && ci.Master &&
            ci.MaximumTransferLength == g_ext->BounceLen && ci.NumberOfBuses == 1 ? 100 : 0);
}

int main(void)
{
    DriverEntry(NULL, NULL);
    CHECK(g_init.AdapterInterfaceType == Isa && g_init.NumberOfAccessRanges == 0 && g_init.HwInterrupt == NULL);
    CHECK(g_init.HwAdapterState != NULL && g_init.MapBuffers && g_init.NeedPhysicalAddresses);
    CHECK(g_init.AutoRequestSense && !g_init.MultipleRequestPerLu);
    CHECK(g_init.HwInitializationDataSize == FIELD_OFFSET(HW_INITIALIZATION_DATA, HwAdapterControl));

    /* no signature (firmware CSM): not found */
    CHECK(find_adapter() % 100 == 0);
    /* CSMPPrxy without channel 1 (older CSMWrap): not found */
    memcpy(g_fseg + 0x6A40, "CSMPPrxy", 8);
    CHECK(find_adapter() % 100 == 0);
    g_ch = (struct uds_channel *)(g_fseg + 0x6A40 + UDS_CH1_OFFSET);
    g_ch->magic = UDS_CH1_MAGIC; g_ch->done = g_ch->doorbell = 41;
    /* split uncached extension: shorter bounce buffer */
    g_split_page = 6;
    CHECK(find_adapter() == 110);
    CHECK(g_ext->BounceLen == 4 * 4096);
    printf("findadapter ok\n");
    scenario();
    return g_fails ? 1 : 0;
}
'''


def _harness_main():
    # main() of the harness, after FindAdapter: the rest of the scenario
    return r'''
int scenario(void)
{
    UCHAR cdb[10];
    ULONG i, posted;
    g_split_page = -1;
    CHECK(find_adapter() == 110);
    CHECK(g_ext->BounceLen == 65536);
    CHECK(g_ch->req_phys == g_ext->BlockPhys && (g_ext->BlockPhys & 4095) == 0);
    CHECK(g_ext->Mp->sig[0] == UDS_MP_SIG0 && g_ext->Mp->sig[1] == UDS_MP_SIG1 && g_ext->Mp->version == 2);
    CHECK(g_ext->Mp->mp_major == 1 && g_ext->Mp->slots == 1);
    CHECK((UCHAR *)g_ext->Mp == (UCHAR *)g_ext->Req + UDS_MP_STATUS_OFFSET);
    CHECK(g_init.HwInitialize(g_ext));
    CHECK(h_ops[UDS_OP_ENUM] == 1 && g_ch->done == 42);
    CHECK(g_ext->Slot[0].present && g_ext->Slot[0].dev == 2 && g_ext->Slot[0].generation == 5);

    /* INQUIRY: local, removable, fixed identity, no request posted */
    posted = g_ext->Mp->posted;
    CHECK(run(0, INQ, 6, SRB_FLAGS_DATA_IN, 36, 0) == SRB_STATUS_SUCCESS);
    CHECK(g_buf[1] == 0x80 && memcmp(g_buf + 8, "USOS    USB disk slot 0", 23) == 0 && g_srb.DataTransferLength == 36);
    CHECK(g_ext->Mp->posted == posted);
    /* other targets / LUNs: no device */
    CHECK(run(1, INQ, 6, SRB_FLAGS_DATA_IN, 36, 0) == SRB_STATUS_SELECTION_TIMEOUT);
    g_srb.Lun = 1;
    { int b = g_completed; memset(&g_srb, 0, sizeof(g_srb)); g_srb.Function = 0; g_srb.Lun = 1; g_srb.CdbLength = 6;
      g_init.HwStartIo(g_ext, &g_srb); CHECK(g_completed == b + 1 && g_srb.SrbStatus == SRB_STATUS_SELECTION_TIMEOUT); }

    /* READ CAPACITY, fast helper: done inside the StartIo spin */
    h_delay_us = 300;
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 0) == SRB_STATUS_SUCCESS);
    CHECK(g_buf[3] == 0xFF && g_buf[6] == 2);
    /* MODE SENSE short answer: success with the real length */
    CHECK(run(0, MS, 6, SRB_FLAGS_DATA_IN, 192, 0) == SRB_STATUS_SUCCESS && g_srb.DataTransferLength == 4);

    /* RequestTimerCall not seen yet: the first SRB armed it as a probe and a
       slow request (30 ms) completes inside HwStartIo, nothing polled */
    CHECK(!g_ext->TimerSeen && g_ext->TimerArmed && g_timer != NULL);
    h_delay_us = 30000;
    posted = g_ext->Mp->polled;
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 0) == SRB_STATUS_SUCCESS && g_ext->Mp->polled == posted);
    /* the probe fires while HwStartIo runs: re-armed, nothing done */
    g_ext->InPump = TRUE;
    { void (*t)(PVOID) = g_timer; g_timer = NULL; t(g_ext); }
    CHECK(g_ext->TimerSeen && g_ext->TimerArmed && g_timer != NULL);
    g_ext->InPump = FALSE;
    /* and again with no SRB: nothing to do, not re-armed */
    { void (*t)(PVOID) = g_timer; g_timer = NULL; t(g_ext); }
    CHECK(!g_ext->TimerArmed && g_timer == NULL);

    /* 64 KiB WRITE + READ, slow helper (30 ms): timer path */
    for (i = 0; i < 65536; i++) g_buf[i] = (UCHAR)(i * 7 + 3);
    memset(cdb, 0, 10); cdb[0] = 0x2A; cdb[5] = 64; cdb[8] = 128;
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_OUT, 65536, 1000) == SRB_STATUS_SUCCESS);
    CHECK(g_ext->Mp->polled >= 1);
    CHECK(h_disk[64 * 512] == 3 && h_disk[64 * 512 + 65535] == (UCHAR)(65535 * 7 + 3));
    memset(g_buf, 0, 65536);
    cdb[0] = 0x28;
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_IN, 65536, 1000) == SRB_STATUS_SUCCESS);
    CHECK(g_buf[0] == 3 && g_buf[65535] == (UCHAR)(65535 * 7 + 3) && g_srb.DataTransferLength == 65536);
    h_delay_us = 100;
    /* 1.1 request ring: LBA, length and CRC-32 of both transfers */
    CHECK(UsbCrc32(g_ext, (const UCHAR *)"123456789", 9) == 0xCBF43926UL);
    { struct uds_mp_ring *rg = (struct uds_mp_ring *)((UCHAR *)g_ext->Req + UDS_MP_RING_OFFSET);
      struct uds_mp_rent *w = &rg->ent[(rg->next + UDS_MP_RING - 2) % UDS_MP_RING];
      struct uds_mp_rent *rd = &rg->ent[(rg->next + UDS_MP_RING - 1) % UDS_MP_RING];
      CHECK(rg->sig[0] == UDS_MP_SIG0 && rg->sig[1] == UDS_MP_RSIG1 && rg->count >= 2);
      CHECK(w->op == 0x2A && w->lba == 64 && w->bytes == 65536 && w->slot == 0);
      CHECK(rd->op == 0x28 && rd->lba == 64 && rd->bytes == 65536 && rd->srb_status == SRB_STATUS_SUCCESS);
      CHECK(w->crc == rd->crc && rd->crc == ref_crc(g_buf, 65536) && rd->uds_status == UDS_S_OK); }

    /* SYNCHRONIZE CACHE refused by the stick: GOOD; SRB flush / shutdown too */
    CHECK(run(0, SYNC, 10, 0, 0, 10) == SRB_STATUS_SUCCESS);
    posted = h_ops[UDS_OP_SCSI];
    CHECK(func(SRB_FUNCTION_SHUTDOWN) == SRB_STATUS_SUCCESS && h_ops[UDS_OP_SCSI] == posted + 1);

    /* stick removed mid-request: NOT READY / 3A with autosense, then ENUM */
    h_gone_next = 1; h_present = 0;
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID));
    CHECK(g_srb.ScsiStatus == 2 && g_sense[0] == 0x70 && g_sense[2] == 2 && g_sense[12] == 0x3A);
    posted = h_ops[UDS_OP_ENUM];
    CHECK(run(0, TUR, 6, 0, 0, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[12] == 0x3A);
    CHECK(h_ops[UDS_OP_ENUM] == posted + 1);
    /* autosense disabled: plain CHECK, REQUEST SENSE answered locally */
    { int b = g_completed; memset(&g_srb, 0, sizeof(g_srb)); g_srb.CdbLength = 6; g_srb.SrbFlags = SRB_FLAGS_DISABLE_AUTOSENSE;
      g_srb.SenseInfoBuffer = g_sense; g_srb.SenseInfoBufferLength = 18; memset(g_sense, 0, 18);
      g_init.HwStartIo(g_ext, &g_srb); CHECK(g_completed == b + 1 && g_srb.SrbStatus == SRB_STATUS_ERROR && g_sense[0] == 0); }
    { UCHAR rs[6] = { 0x03, 0, 0, 0, 18, 0 };
      CHECK(run(0, rs, 6, SRB_FLAGS_DATA_IN, 18, 0) == SRB_STATUS_SUCCESS && g_buf[2] == 2 && g_buf[12] == 0x3A); }

    /* a new stick (generation 6): TEST UNIT READY within 1 s does not enumerate,
       after 1 s it does; one UNIT ATTENTION, then GOOD */
    h_present = 1; h_gen = 6;
    posted = h_ops[UDS_OP_ENUM];
    g_tsc += 1100ULL * 1000000;
    CHECK(run(0, TUR, 6, 0, 0, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID));
    CHECK(h_ops[UDS_OP_ENUM] == posted + 1 && g_sense[2] == 6 && g_sense[12] == 0x28);
    CHECK(run(0, TUR, 6, 0, 0, 10) == SRB_STATUS_SUCCESS);
    CHECK(h_ops[UDS_OP_ENUM] == posted + 1);
    CHECK(g_ext->Mp->slot[0].generation == 6 && g_ext->Mp->slot[0].present == 1);

    /* 1.1 hot-swap: the stick is pulled; IOS keeps sending READs to the empty
       slot. A READ (not only TEST UNIT READY) enumerates again, at most once
       a second; a new stick (generation 7) gives one UNIT ATTENTION, then
       its data */
    memset(cdb, 0, 10); cdb[0] = 0x28; cdb[8] = 1;
    h_gone_next = 1; h_present = 0;
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_IN, 512, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[12] == 0x3A);
    posted = h_ops[UDS_OP_ENUM];
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_IN, 512, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[12] == 0x3A);
    CHECK(h_ops[UDS_OP_ENUM] == posted + 1 && !g_ext->Slot[0].present);
    h_present = 1; h_gen = 7; h_disk[0] = 0xA7;
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_IN, 512, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[12] == 0x3A);
    CHECK(h_ops[UDS_OP_ENUM] == posted + 1);   /* within 1 s: no ENUM */
    g_tsc += 1100ULL * 1000000;
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_IN, 512, 10) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID));
    CHECK(h_ops[UDS_OP_ENUM] == posted + 2 && g_sense[2] == 6 && g_sense[12] == 0x28);
    CHECK(run(0, cdb, 10, SRB_FLAGS_DATA_IN, 512, 10) == SRB_STATUS_SUCCESS && g_buf[0] == 0xA7);
    CHECK(g_ext->Slot[0].generation == 7 && h_ops[UDS_OP_ENUM] == posted + 2);
    /* 1.1: the empty-slot NOT READY answers are not errors */
    CHECK(g_ext->Mp->notready >= 3);
    { ULONG e = g_ext->Mp->errors, n = g_ext->Mp->notready;
      CHECK(run(0, TUR, 6, 0, 0, 10) == SRB_STATUS_SUCCESS && g_ext->Mp->errors == e && g_ext->Mp->notready == n); }
    printf("hot-swap (empty slot READ enumerates): ok\n");

    /* watchdog: the helper stops answering -> SRB_STATUS_TIMEOUT after 15 s */
    h_dead = 1;
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 20000) == SRB_STATUS_TIMEOUT);
    CHECK(g_ext->Stale);
    /* still stale: a command needing the channel fails NOT READY / 04, INQUIRY works */
    CHECK(run(0, INQ, 6, SRB_FLAGS_DATA_IN, 36, 0) == SRB_STATUS_SUCCESS);
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 0) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[12] == 0x04);
    /* the helper finishes the stale request: next command first RESET, ENUM, then runs */
    h_dead = 0; helper_tick(1000);
    posted = h_ops[UDS_OP_RESET];
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 10) == SRB_STATUS_SUCCESS);
    CHECK(h_ops[UDS_OP_RESET] == posted + 1 && !g_ext->Stale);

    /* eject: START STOP UNIT LoEj -> UDS EJECT */
    CHECK(run(0, EJECT, 6, 0, 0, 10) == SRB_STATUS_SUCCESS && h_ops[UDS_OP_EJECT] == 1);
    /* bus reset SRB: one UDS RESET for the present slot */
    posted = h_ops[UDS_OP_RESET];
    CHECK(func(SRB_FUNCTION_RESET_BUS) == SRB_STATUS_SUCCESS && h_ops[UDS_OP_RESET] == posted + 1);
    CHECK(g_init.HwAdapterState(g_ext, NULL, 1) && g_init.HwAdapterState(g_ext, NULL, 0));
    CHECK(g_ext->Mp->errors > 0 && g_ext->Mp->srbs > 10);
    printf("srbs %u posted %u polled %u enums %u errors %u\n", g_ext->Mp->srbs, g_ext->Mp->posted,
           g_ext->Mp->polled, g_ext->Mp->enums, g_ext->Mp->errors);

    /* fail safe: the helper never answers the first ENUM (dead helper core):
       HwInitialize returns after 3 s, every SRB completes at once with an
       empty slot, nothing is posted; when the helper catches up, the next
       TEST UNIT READY enumerates and the stick appears (UNIT ATTENTION) */
    CHECK(find_adapter() == 110);
    h_dead = 1;
    { ULONGLONG t0 = g_tsc; CHECK(g_init.HwInitialize(g_ext)); CHECK(g_tsc - t0 <= 3100ULL * 1000000); }
    CHECK(g_ext->Stale && !g_ext->Posted && !g_ext->Slot[0].present);
    posted = g_ext->Mp->posted;
    CHECK(run(0, TUR, 6, 0, 0, 0) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[2] == 2 && g_sense[12] == 0x3A);
    CHECK(run(0, RC, 10, SRB_FLAGS_DATA_IN, 8, 0) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[12] == 0x3A);
    CHECK(run(0, INQ, 6, SRB_FLAGS_DATA_IN, 36, 0) == SRB_STATUS_SUCCESS && g_buf[1] == 0x80);
    CHECK(g_ext->Mp->posted == posted);
    h_dead = 0; helper_tick(1000);
    g_tsc += 1100ULL * 1000000;
    CHECK(run(0, TUR, 6, 0, 0, 0) == (SRB_STATUS_ERROR | SRB_STATUS_AUTOSENSE_VALID) && g_sense[2] == 6 && g_sense[12] == 0x28);
    CHECK(!g_ext->Stale && g_ext->Slot[0].present);
    CHECK(run(0, TUR, 6, 0, 0, 0) == SRB_STATUS_SUCCESS);
    printf("dead helper at init: ok\n");
    return g_fails;
}
'''


class HostSim(unittest.TestCase):
    def test_simulation(self):
        zig = find_zig()
        if not zig:
            self.skipTest('zig not found')
        harness = HARNESS + _harness_main()
        with tempfile.TemporaryDirectory() as td:
            t = Path(td)
            (t / 'fake_miniport.h').write_text(FAKE_MINIPORT)
            (t / 'harness.c').write_text(harness)
            env = dict(os.environ)
            env.setdefault('ZIG_GLOBAL_CACHE_DIR', str(t / 'zig-cache'))
            for name, extra in (('x86', ['-target', 'x86-windows-gnu']), ('native', [])):
                exe = t / f'sim_{name}.exe'
                cc = [zig, 'cc', *extra, '-std=c99', '-O1', '-g', '-Wall', '-Wextra', '-Werror',
                      '-Wno-unused-function', '-fsanitize=undefined', '-fno-sanitize-recover=all',
                      '-DUSOSUSB_HOST', '-I', str(t), '-I', str(DRV / 'src'), '-I', str(UDS),
                      str(t / 'harness.c'), str(UDS / 'usosuds_slot.c'), '-o', str(exe)]
                r = subprocess.run(cc, capture_output=True, text=True, env=env)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120)
                print(f'[{name}] ' + r.stdout.strip().replace('\n', ' | '))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertNotIn('FAIL', r.stdout)


if __name__ == '__main__':
    if len(sys.argv) > 1 and Path(sys.argv[1]).exists():
        del sys.argv[1]
    unittest.main()
