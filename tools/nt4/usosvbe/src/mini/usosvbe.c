/*
 * usosvbe.sys - VESA BIOS Extensions video miniport for Windows NT 4.0.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Own implementation, written for USOS from the public VESA BIOS Extensions
 * 3.0 specification and the documented NT video miniport interface (no
 * third-party code). Pairs with usosvbe.dll (display driver, ../disp).
 *
 * NT 4.0 has no generic high-resolution driver: without a vendor driver the
 * desktop stays at 640x480x16 (vga.sys + vga.dll). On a board run without
 * CSM through CSMWrap the video BIOS (the card's own legacy option ROM) is
 * still there, and NT 4.0's VideoPortInt10 runs it in V86 mode inside CSRSS.
 * This miniport uses only that:
 *
 *  - VBE 4F00h (controller info) and 4F01h (mode info) list the direct-color
 *    modes (15/16/24/32 bpp, at least 640x480) that have a linear frame
 *    buffer and fit in the video memory;
 *  - 4F02h sets a mode with the linear frame buffer bit, AX=0003h goes back
 *    to text mode (IOCTL_VIDEO_RESET_DEVICE);
 *  - the frame buffer (VBE 2.0 PhysBasePtr) is mapped with
 *    VideoPortMapMemory for the display driver.
 *
 * NT 4.0's VIDEO_X86_BIOS_ARGUMENTS has no ES: the V86 call runs with a
 * segment value chosen by the kernel. The 4F00h/4F01h buffers therefore sit
 * at ES:DI in CSRSS's V86 address space (linear = ES*16 + DI, which in the
 * CSRSS process is also the virtual address). The first 4F00h call finds
 * ES by looking for the "VESA" signature it wrote. The queries run once, in
 * HwInitialize or the first query IOCTL (both come from CSRSS); the results
 * are cached, so later IOCTLs from other processes do not need the buffer.
 *
 * Services\usosvbe\Device0\UsosVbeDiag (REG_SZ) holds a short status line.
 * Imports only routines that NT 4.0 RTM and SP6a export
 * (tools/tests/check_nt4_driver_imports.py).
 */

#include <dderror.h>
#include <devioctl.h>
#include <miniport.h>
#include <ntddvdeo.h>
#include <video.h>

#define USOSVBE_VERSION L"usosvbe 1.0-nt4"

#define MAXMODES 64
#define MAXLIST 256

/* NT 4.0 kernel export, used to scan CSRSS's V86 memory safely. */
__declspec(dllimport) BOOLEAN __stdcall MmIsAddressValid(PVOID VirtualAddress);

typedef struct _VBEMODE {
    USHORT Number;      /* VBE mode number */
    USHORT Width;
    USHORT Height;
    USHORT Bpp;         /* 15, 16, 24, 32 */
    ULONG Pitch;
    ULONG PhysBase;
    ULONG RMask, GMask, BMask;
    UCHAR RBits, GBits, BBits;
} VBEMODE;

typedef struct _DEVEXT {
    BOOLEAN Queried;
    BOOLEAN QueryOk;
    USHORT VbeVersion;
    ULONG EsSeg;
    ULONG VramBytes;
    ULONG NumModes;
    ULONG Current;          /* index into Modes, or ~0 */
    ULONG ListCount;        /* modes the BIOS listed */
    ULONG LastVp;           /* VideoPortInt10 status of the last call */
    ULONG Tries;            /* query attempts */
    VBEMODE Modes[MAXMODES];
    PVOID MappedBase;
    ULONG MappedLength;
    WCHAR Diag[160];
    WCHAR Trace[200];
} DEVEXT, *PDEVEXT;

/* Buffer offsets (DI). 4F00h writes 512 bytes, 4F01h 256 bytes. */
#define INFO_DI 0x7000
#define MODE_DI 0x7200

/* ---------------------------------------------------------------- utils */

static ULONG rd16(const UCHAR *p) { return (ULONG)p[0] | ((ULONG)p[1] << 8); }
static ULONG rd32(const UCHAR *p) { return rd16(p) | (rd16(p + 2) << 16); }

static void dcat(PDEVEXT x, const WCHAR *s)
{
    ULONG n = 0;
    while (x->Diag[n]) n++;
    while (*s && n < 159) x->Diag[n++] = *s++;
    x->Diag[n] = 0;
}

static void dnum(PDEVEXT x, ULONG v, ULONG base, ULONG minDigits)
{
    WCHAR b[12];
    int i = 11;
    b[i] = 0;
    do {
        ULONG d = v % base;
        b[--i] = (WCHAR)(d < 10 ? L'0' + d : L'A' + d - 10);
        v /= base;
        if (minDigits) minDigits--;
    } while ((v || minDigits) && i > 0);
    dcat(x, &b[i]);
}

__declspec(dllimport) HANDLE __stdcall PsGetCurrentProcessId(VOID);
#define IOCTL_USOSVBE_TRACE CTL_CODE(FILE_DEVICE_VIDEO, 0x8F0, METHOD_BUFFERED, FILE_ANY_ACCESS)

static void trace(PDEVEXT x, WCHAR tag, ULONG v)
{
    ULONG n = 0, i;
    WCHAR b[16];
    int k = 15;
    ULONG pid = (ULONG)(ULONG_PTR)PsGetCurrentProcessId();
    while (x->Trace[n]) n++;
    if (n > 170) {      /* keep the newest part */
        for (i = 0; i + 60 <= n; i++) x->Trace[i] = x->Trace[i + 60];
        n -= 60;
        x->Trace[n] = 0;
    }
    b[k] = 0;
    b[--k] = L' ';
    do { ULONG d = pid % 16; b[--k] = (WCHAR)(d < 10 ? L'0' + d : L'a' + d - 10); pid /= 16; } while (pid && k > 8);
    b[--k] = L'.';
    do { ULONG d = v % 16; b[--k] = (WCHAR)(d < 10 ? L'0' + d : L'a' + d - 10); v /= 16; } while (v && k > 1);
    b[--k] = tag;
    for (i = (ULONG)k; b[i] && n < 199; i++) x->Trace[n++] = b[i];
    x->Trace[n] = 0;
    VideoPortSetRegistryParameters(x, L"UsosVbeTrace", x->Trace, (n + 1) * sizeof(WCHAR));
}

static void savediag(PDEVEXT x)
{
    ULONG n = 0;
    while (x->Diag[n]) n++;
    VideoPortSetRegistryParameters(x, L"UsosVbeDiag", x->Diag, (n + 1) * sizeof(WCHAR));
}

static BOOLEAN valid(ULONG va)
{
    return MmIsAddressValid((PVOID)(ULONG_PTR)va);
}

/* Is "VESA" at va (all four bytes on valid pages)? */
static BOOLEAN vesa_at(ULONG va)
{
    const UCHAR *p = (const UCHAR *)(ULONG_PTR)va;
    if (!valid(va) || !valid(va + 3)) return FALSE;
    return p[0] == 'V' && p[1] == 'E' && p[2] == 'S' && p[3] == 'A';
}

static ULONG int10(PDEVEXT x, ULONG eax, ULONG ebx, ULONG ecx, ULONG edi)
{
    VIDEO_X86_BIOS_ARGUMENTS a;
    VideoPortZeroMemory(&a, sizeof(a));
    a.Eax = eax; a.Ebx = ebx; a.Ecx = ecx; a.Edi = edi;
    x->LastVp = VideoPortInt10(x, &a);
    if (x->LastVp != NO_ERROR) return 0xFFFFFFFF;
    return a.Eax & 0xFFFF;
}

/* --------------------------------------------------------- VBE queries */

#define SEGS 0x10000
static UCHAR g_stale[SEGS / 8];   /* segments with an old "VESA" at seg:INFO_DI */

static BOOLEAN find_es(PDEVEXT x)
{
    ULONG s, ax;
    for (s = 0; s < SEGS; s++) {
        ULONG va = s * 16 + INFO_DI;
        g_stale[s >> 3] &= (UCHAR)~(1 << (s & 7));
        if (va + 512 < 0x100000 && vesa_at(va)) g_stale[s >> 3] |= (UCHAR)(1 << (s & 7));
    }
    ax = int10(x, 0x4F00, 0, 0, INFO_DI);
    if (ax != 0x004F) {
        dcat(x, L" 4F00=");
        dnum(x, ax, 16, 4);
        if (x->LastVp != NO_ERROR) { dcat(x, L" vp="); dnum(x, x->LastVp, 10, 0); }
        return FALSE;
    }
    for (s = 0; s < SEGS; s++) {
        ULONG va = s * 16 + INFO_DI;
        if (va + 512 >= 0x100000) break;
        if (!(g_stale[s >> 3] & (1 << (s & 7))) && vesa_at(va) && valid(va + 511)) {
            x->EsSeg = s;
            return TRUE;
        }
    }
    dcat(x, L" nosig");
    return FALSE;
}

static void add_mode(PDEVEXT x, ULONG num, const UCHAR *mi)
{
    ULONG attr = rd16(mi + 0x00);
    ULONG w = rd16(mi + 0x12), h = rd16(mi + 0x14);
    ULONG bpp = mi[0x19], model = mi[0x1B];
    ULONG pitch = rd16(mi + 0x10);
    ULONG phys = rd32(mi + 0x28);
    ULONG rs, rp, gs, gp, bs, bp, i, depth;
    VBEMODE *m;

    /* supported, color, graphics, linear frame buffer available */
    if ((attr & 0x99) != 0x99) return;
    if (model != 6 || phys == 0 || w < 640 || h < 480) return;
    if (x->VbeVersion >= 0x300 && rd16(mi + 0x32)) pitch = rd16(mi + 0x32);
    rs = mi[0x1F]; rp = mi[0x20]; gs = mi[0x21]; gp = mi[0x22]; bs = mi[0x23]; bp = mi[0x24];
    if (x->VbeVersion >= 0x300 && mi[0x36]) {
        rs = mi[0x36]; rp = mi[0x37]; gs = mi[0x38]; gp = mi[0x39]; bs = mi[0x3A]; bp = mi[0x3B];
    }
    if (bpp == 16 && rs + gs + bs == 15) depth = 15;
    else if (bpp == 15) { depth = 15; bpp = 16; }
    else depth = bpp;
    if (bpp != 16 && bpp != 24 && bpp != 32) return;
    if (rs == 0 || gs == 0 || bs == 0 || rp + rs > 32 || gp + gs > 32 || bp + bs > 32) return;
    if (pitch < w * (bpp / 8) || (ULONGLONG)pitch * h > x->VramBytes) return;
    for (i = 0; i < x->NumModes; i++)
        if (x->Modes[i].Width == w && x->Modes[i].Height == h && x->Modes[i].Bpp == depth) return;
    if (x->NumModes >= MAXMODES) return;
    m = &x->Modes[x->NumModes++];
    m->Number = (USHORT)num;
    m->Width = (USHORT)w;
    m->Height = (USHORT)h;
    m->Bpp = (USHORT)depth;
    m->Pitch = pitch;
    m->PhysBase = phys;
    m->RMask = ((1UL << rs) - 1) << rp;
    m->GMask = ((1UL << gs) - 1) << gp;
    m->BMask = ((1UL << bs) - 1) << bp;
    m->RBits = (UCHAR)rs; m->GBits = (UCHAR)gs; m->BBits = (UCHAR)bs;
}

static int mode_less(const VBEMODE *a, const VBEMODE *b)
{
    if (a->Bpp != b->Bpp) return a->Bpp < b->Bpp;
    if (a->Width != b->Width) return a->Width < b->Width;
    return a->Height < b->Height;
}

static void query(PDEVEXT x)
{
    USHORT list[MAXLIST];
    ULONG n = 0, i, j, base, lp;
    const UCHAR *info;

    if (x->Queried) return;
    x->Queried = TRUE;
    x->Tries++;
    x->Diag[0] = 0;
    dcat(x, USOSVBE_VERSION);
    dcat(x, L" try="); dnum(x, x->Tries, 10, 0);
    if (!find_es(x)) {
        /* VideoPortInt10 not usable yet (e.g. before CSRSS is known): retry
         * at the next query, a few times. */
        if (x->LastVp != NO_ERROR && x->Tries < 8) x->Queried = FALSE;
        savediag(x);
        return;
    }
    base = x->EsSeg * 16;
    info = (const UCHAR *)(ULONG_PTR)(base + INFO_DI);
    x->VbeVersion = (USHORT)rd16(info + 4);
    x->VramBytes = rd16(info + 0x12) * 0x10000;
    lp = (rd16(info + 0x10) << 4) + rd16(info + 0x0E);   /* VideoModePtr seg:off */
    dcat(x, L" es="); dnum(x, x->EsSeg, 16, 4);
    dcat(x, L" vbe="); dnum(x, x->VbeVersion, 16, 4);
    dcat(x, L" mem="); dnum(x, x->VramBytes >> 10, 10, 0); dcat(x, L"k");
    if (x->VbeVersion < 0x200) { dcat(x, L" old"); savediag(x); return; }
    if (x->VramBytes == 0) x->VramBytes = 0x10000;
    /* Copy the mode list first: it may live in the info block. */
    while (n < MAXLIST && lp + 2 * n + 1 < 0x100000 && valid(lp + 2 * n) && valid(lp + 2 * n + 1)) {
        USHORT v = (USHORT)rd16((const UCHAR *)(ULONG_PTR)(lp + 2 * n));
        if (v == 0xFFFF) break;
        list[n++] = v;
    }
    x->ListCount = n;
    for (i = 0; i < n; i++) {
        const UCHAR *mi = (const UCHAR *)(ULONG_PTR)(base + MODE_DI);
        if (int10(x, 0x4F01, 0, list[i], MODE_DI) != 0x004F) continue;
        if (!valid(base + MODE_DI) || !valid(base + MODE_DI + 255)) continue;
        add_mode(x, list[i], mi);
    }
    /* insertion sort: by depth, width, height */
    for (i = 1; i < x->NumModes; i++) {
        VBEMODE t = x->Modes[i];
        for (j = i; j > 0 && mode_less(&t, &x->Modes[j - 1]); j--) x->Modes[j] = x->Modes[j - 1];
        x->Modes[j] = t;
    }
    dcat(x, L" list="); dnum(x, n, 10, 0);
    dcat(x, L" modes="); dnum(x, x->NumModes, 10, 0);
    x->QueryOk = x->NumModes != 0;
    savediag(x);
}

/* ------------------------------------------------------------- IOCTLs */

static void fill_info(PDEVEXT x, ULONG i, PVIDEO_MODE_INFORMATION v)
{
    const VBEMODE *m = &x->Modes[i];
    VideoPortZeroMemory(v, sizeof(*v));
    v->Length = sizeof(*v);
    v->ModeIndex = i;
    v->VisScreenWidth = m->Width;
    v->VisScreenHeight = m->Height;
    v->ScreenStride = m->Pitch;
    v->NumberOfPlanes = 1;
    v->BitsPerPlane = m->Bpp == 15 ? 16 : m->Bpp;
    v->Frequency = 60;
    v->XMillimeter = 320;
    v->YMillimeter = 240;
    v->NumberRedBits = m->RBits;
    v->NumberGreenBits = m->GBits;
    v->NumberBlueBits = m->BBits;
    v->RedMask = m->RMask;
    v->GreenMask = m->GMask;
    v->BlueMask = m->BMask;
    v->AttributeFlags = VIDEO_MODE_COLOR | VIDEO_MODE_GRAPHICS;
    v->VideoMemoryBitmapWidth = m->Width;
    v->VideoMemoryBitmapHeight = m->Height;
    v->DriverSpecificAttributeFlags = m->Number;
}

static void report_set(PDEVEXT x, ULONG i, ULONG ax)
{
    ULONG k = 0;
    /* keep the query part, replace any old " set=" tail */
    while (x->Diag[k]) {
        if (x->Diag[k] == L' ' && x->Diag[k + 1] == L's' && x->Diag[k + 2] == L'e' && x->Diag[k + 3] == L't') {
            x->Diag[k] = 0;
            break;
        }
        k++;
    }
    dcat(x, L" set="); dnum(x, x->Modes[i].Width, 10, 0); dcat(x, L"x");
    dnum(x, x->Modes[i].Height, 10, 0); dcat(x, L"x"); dnum(x, x->Modes[i].Bpp, 10, 0);
    dcat(x, L"/"); dnum(x, x->Modes[i].Number, 16, 3);
    dcat(x, ax == 0x004F ? L" ok" : L" fail");
    savediag(x);
}

static BOOLEAN __stdcall StartIO(PVOID ext, PVIDEO_REQUEST_PACKET rp)
{
    PDEVEXT x = (PDEVEXT)ext;
    PSTATUS_BLOCK sb = rp->StatusBlock;
    ULONG i;

    sb->Information = 0;
    if (rp->IoControlCode == IOCTL_USOSVBE_TRACE) {
        trace(x, L'D', rp->InputBufferLength >= 4 ? *(PULONG)rp->InputBuffer : 0);
        sb->Status = NO_ERROR;
        return TRUE;
    }
    trace(x, L'i', (rp->IoControlCode >> 2) & 0xFFF);
    switch (rp->IoControlCode) {
    case IOCTL_VIDEO_QUERY_NUM_AVAIL_MODES: {
        PVIDEO_NUM_MODES nm = (PVIDEO_NUM_MODES)rp->OutputBuffer;
        query(x);
        if (rp->OutputBufferLength < sizeof(VIDEO_NUM_MODES)) { sb->Status = ERROR_INSUFFICIENT_BUFFER; break; }
        nm->NumModes = x->NumModes;
        nm->ModeInformationLength = sizeof(VIDEO_MODE_INFORMATION);
        sb->Information = sizeof(VIDEO_NUM_MODES);
        sb->Status = NO_ERROR;
        break;
    }
    case IOCTL_VIDEO_QUERY_AVAIL_MODES: {
        PVIDEO_MODE_INFORMATION v = (PVIDEO_MODE_INFORMATION)rp->OutputBuffer;
        query(x);
        if (rp->OutputBufferLength < x->NumModes * sizeof(VIDEO_MODE_INFORMATION)) {
            sb->Status = ERROR_INSUFFICIENT_BUFFER; break;
        }
        for (i = 0; i < x->NumModes; i++) fill_info(x, i, v + i);
        sb->Information = x->NumModes * sizeof(VIDEO_MODE_INFORMATION);
        sb->Status = NO_ERROR;
        break;
    }
    case IOCTL_VIDEO_QUERY_CURRENT_MODE:
        if (x->Current >= x->NumModes) { sb->Status = ERROR_INVALID_PARAMETER; break; }
        if (rp->OutputBufferLength < sizeof(VIDEO_MODE_INFORMATION)) { sb->Status = ERROR_INSUFFICIENT_BUFFER; break; }
        fill_info(x, x->Current, (PVIDEO_MODE_INFORMATION)rp->OutputBuffer);
        sb->Information = sizeof(VIDEO_MODE_INFORMATION);
        sb->Status = NO_ERROR;
        break;
    case IOCTL_VIDEO_SET_CURRENT_MODE: {
        ULONG ax;
        if (rp->InputBufferLength < sizeof(VIDEO_MODE)) { sb->Status = ERROR_INSUFFICIENT_BUFFER; break; }
        i = ((PVIDEO_MODE)rp->InputBuffer)->RequestedMode & ~VIDEO_MODE_NO_ZERO_MEMORY;
        if (i >= x->NumModes) { sb->Status = ERROR_INVALID_PARAMETER; break; }
        /* bit 14: linear frame buffer; bit 15 (keep memory) when asked */
        ax = int10(x, 0x4F02, x->Modes[i].Number | 0x4000 |
                   ((((PVIDEO_MODE)rp->InputBuffer)->RequestedMode & VIDEO_MODE_NO_ZERO_MEMORY) ? 0x8000 : 0), 0, 0);
        report_set(x, i, ax);
        if (ax != 0x004F) { sb->Status = ERROR_INVALID_PARAMETER; break; }
        x->Current = i;
        sb->Status = NO_ERROR;
        break;
    }
    case IOCTL_VIDEO_RESET_DEVICE:
        int10(x, 0x0003, 0, 0, 0);
        x->Current = (ULONG)~0;
        sb->Status = NO_ERROR;
        break;
    case IOCTL_VIDEO_MAP_VIDEO_MEMORY: {
        PVIDEO_MEMORY_INFORMATION mi = (PVIDEO_MEMORY_INFORMATION)rp->OutputBuffer;
        PHYSICAL_ADDRESS pa;
        ULONG len, inIo = VIDEO_MEMORY_SPACE_MEMORY;
        PVOID va;
        VP_STATUS st;
        if (rp->InputBufferLength < sizeof(VIDEO_MEMORY) ||
            rp->OutputBufferLength < sizeof(VIDEO_MEMORY_INFORMATION)) { sb->Status = ERROR_INSUFFICIENT_BUFFER; break; }
        if (x->Current >= x->NumModes) { sb->Status = ERROR_INVALID_PARAMETER; break; }
        pa.QuadPart = x->Modes[x->Current].PhysBase;
        len = (x->Modes[x->Current].Pitch * x->Modes[x->Current].Height + 0xFFF) & ~0xFFFUL;
        va = ((PVIDEO_MEMORY)rp->InputBuffer)->RequestedVirtualAddress;
        st = VideoPortMapMemory(x, pa, &len, &inIo, &va);
        if (st != NO_ERROR) { dcat(x, L" mapfail"); savediag(x); sb->Status = st; break; }
        mi->VideoRamBase = va;
        mi->VideoRamLength = len;
        mi->FrameBufferBase = va;
        mi->FrameBufferLength = len;
        sb->Information = sizeof(VIDEO_MEMORY_INFORMATION);
        sb->Status = NO_ERROR;
        break;
    }
    case IOCTL_VIDEO_UNMAP_VIDEO_MEMORY:
        if (rp->InputBufferLength < sizeof(VIDEO_MEMORY)) { sb->Status = ERROR_INSUFFICIENT_BUFFER; break; }
        sb->Status = VideoPortUnmapMemory(x, ((PVIDEO_MEMORY)rp->InputBuffer)->RequestedVirtualAddress, 0);
        break;
    default:
        sb->Status = ERROR_INVALID_FUNCTION;
        break;
    }
    return TRUE;
}

/* ------------------------------------------------------- init / entry */

static VP_STATUS __stdcall FindAdapter(PVOID ext, PVOID ctx, PWSTR args, PVIDEO_PORT_CONFIG_INFO ci, PUCHAR again)
{
    PDEVEXT x = (PDEVEXT)ext;
    UNREFERENCED_PARAMETER(ctx);
    UNREFERENCED_PARAMETER(args);
    *again = FALSE;
    if (ci->Length < SIZE_OF_NT4_VIDEO_PORT_CONFIG_INFO) return ERROR_INVALID_PARAMETER;
    /* Nothing to claim: all hardware access goes through the video BIOS.
     * VgaSave keeps the VGA ranges for full-screen consoles. */
    ci->NumEmulatorAccessEntries = 0;
    ci->EmulatorAccessEntries = NULL;
    ci->EmulatorAccessEntriesContext = 0;
    ci->VdmPhysicalVideoMemoryAddress.QuadPart = 0;
    ci->VdmPhysicalVideoMemoryLength = 0;
    ci->HardwareStateSize = 0;
    x->Current = (ULONG)~0;
    return NO_ERROR;
}

static BOOLEAN __stdcall Initialize(PVOID ext)
{
    /* Called on the first open, from CSRSS: do the BIOS queries now. */
    query((PDEVEXT)ext);
    return TRUE;
}

ULONG __stdcall DriverEntry(PVOID ctx1, PVOID ctx2)
{
    VIDEO_HW_INITIALIZATION_DATA d;
    ULONG st;

    VideoPortZeroMemory(&d, sizeof(d));
    d.HwInitDataSize = SIZE_OF_NT4_VIDEO_HW_INITIALIZATION_DATA;
    d.HwFindAdapter = FindAdapter;
    d.HwInitialize = Initialize;
    d.HwStartIO = StartIO;
    d.HwDeviceExtensionSize = sizeof(DEVEXT);
    d.AdapterInterfaceType = Isa;
    st = VideoPortInitialize(ctx1, ctx2, &d, NULL);
    if (st != NO_ERROR) {
        d.AdapterInterfaceType = PCIBus;
        st = VideoPortInitialize(ctx1, ctx2, &d, NULL);
    }
    return st;
}
