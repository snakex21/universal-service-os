/*
 * usosvbe.dll - frame buffer display driver for Windows NT 4.0.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Own implementation, written for USOS from the documented NT display driver
 * interface (DDI) (no third-party code). Pairs with usosvbe.sys, the VBE
 * miniport (../mini).
 *
 * The miniport sets a VBE mode with a linear frame buffer and maps it. This
 * driver tells GDI that the frame buffer is an ordinary top-down DIB
 * (EngCreateBitmap with the mapped bits, EngAssociateSurface without hooks),
 * so GDI draws everything itself. DrvSetPointerShape declines, so GDI draws
 * a software pointer. DrvDitherColor gives one solid color.
 *
 * STATUS 2026-10-07: the logon dialog does not appear with this DLL in QEMU
 * (see ../../README.md); not wired into the NT4 flow. The IOCTL 0x8F0 trace
 * calls (tr) are diagnostics for that.
 *
 * Mode choice: the DEVMODE GDI passes (Display applet or
 * Services\usosvbe\Device0 DefaultSettings.*). If it names no listed mode,
 * 1024x768 16 bpp, then 800x600 16 bpp, then the first listed mode is used.
 *
 * Imports only routines that NT 4.0 RTM's win32k.sys exports
 * (tools/tests/check_nt4_driver_imports.py --display).
 */

#include <stddef.h>
#include <stdarg.h>
#include <windef.h>
#include <wingdi.h>
#include <winddi.h>
#include <devioctl.h>
#include <ntddvdeo.h>

#define TAG 'ebvU'
#define NT4_DEVMODE_SPEC 0x0401

typedef struct _PDEV {
    HANDLE hDriver;
    HDEV hdev;
    HSURF hsurf;
    HPALETTE hpal;
    ULONG NumModes;
    PVIDEO_MODE_INFORMATION Modes;
    ULONG Mode;                 /* index into Modes */
    PVOID FrameBuffer;
    ULONG FrameLength;
} PDEV, *PPDEV;

static void zero(void *p, ULONG n)
{
    volatile UCHAR *b = (volatile UCHAR *)p;
    while (n--) *b++ = 0;
}

static void copy(void *d, const void *s, ULONG n)
{
    volatile UCHAR *a = (volatile UCHAR *)d;
    const UCHAR *b = (const UCHAR *)s;
    while (n--) *a++ = *b++;
}

static void wcopy(WCHAR *d, const WCHAR *s, ULONG max)
{
    while (*s && max > 1) { *d++ = *s++; max--; }
    *d = 0;
}

static DWORD ioctl(HANDLE h, DWORD code, void *in, DWORD cin, void *out, DWORD cout, DWORD *ret)
{
    DWORD dummy;
    return EngDeviceIoControl(h, code, in, cin, out, cout, ret ? ret : &dummy);
}

#define IOCTL_USOSVBE_TRACE CTL_CODE(FILE_DEVICE_VIDEO, 0x8F0, METHOD_BUFFERED, FILE_ANY_ACCESS)
static HANDLE g_h;
static void tr(ULONG v)
{
    if (g_h) ioctl(g_h, IOCTL_USOSVBE_TRACE, &v, sizeof(v), NULL, 0, NULL);
}

/* ----------------------------------------------------------- mode list */

/* Mode list from the miniport; *pModes is EngAllocMem'd. */
static ULONG get_modes(HANDLE h, PVIDEO_MODE_INFORMATION *pModes)
{
    VIDEO_NUM_MODES nm;
    DWORD ret;
    PVIDEO_MODE_INFORMATION m;

    *pModes = NULL;
    if (ioctl(h, IOCTL_VIDEO_QUERY_NUM_AVAIL_MODES, NULL, 0, &nm, sizeof(nm), &ret) || nm.NumModes == 0)
        return 0;
    if (nm.ModeInformationLength != sizeof(VIDEO_MODE_INFORMATION)) return 0;
    m = (PVIDEO_MODE_INFORMATION)EngAllocMem(FL_ZERO_MEMORY, nm.NumModes * sizeof(*m), TAG);
    if (!m) return 0;
    if (ioctl(h, IOCTL_VIDEO_QUERY_AVAIL_MODES, NULL, 0, m, nm.NumModes * sizeof(*m), &ret)) {
        EngFreeMem(m);
        return 0;
    }
    *pModes = m;
    return nm.NumModes;
}

static ULONG depth(const VIDEO_MODE_INFORMATION *m)
{
    /* 5-5-5 modes report 16 bits per plane and 15 color bits */
    if (m->BitsPerPlane == 16 && m->NumberRedBits + m->NumberGreenBits + m->NumberBlueBits == 15) return 15;
    return m->BitsPerPlane;
}

static ULONG find_mode(PPDEV p, ULONG w, ULONG h, ULONG bpp)
{
    ULONG i;
    for (i = 0; i < p->NumModes; i++) {
        const VIDEO_MODE_INFORMATION *m = &p->Modes[i];
        if (m->VisScreenWidth == w && m->VisScreenHeight == h && bpp == depth(m))
            return i;
    }
    return (ULONG)~0;
}

static ULONG pick_mode(PPDEV p, DEVMODEW *dm)
{
    ULONG i = (ULONG)~0;
    if (dm && dm->dmPelsWidth && dm->dmPelsHeight && dm->dmBitsPerPel)
        i = find_mode(p, dm->dmPelsWidth, dm->dmPelsHeight, dm->dmBitsPerPel);
    if (i == (ULONG)~0) i = find_mode(p, 1024, 768, 16);
    if (i == (ULONG)~0) i = find_mode(p, 800, 600, 16);
    if (i == (ULONG)~0) i = 0;
    return i;
}

/* ------------------------------------------------------------ patterns */

/* Standard hatch brushes, 8x8 1 bpp, rows padded to 4 bytes. 0 = line. */
static ULONG g_hatch[HS_DDI_MAX][8] = {
    { 0xFF, 0xFF, 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF },     /* HS_HORIZONTAL */
    { 0xF7, 0xF7, 0xF7, 0xF7, 0xF7, 0xF7, 0xF7, 0xF7 },     /* HS_VERTICAL */
    { 0x7F, 0xBF, 0xDF, 0xEF, 0xF7, 0xFB, 0xFD, 0xFE },     /* HS_FDIAGONAL */
    { 0xFE, 0xFD, 0xFB, 0xF7, 0xEF, 0xDF, 0xBF, 0x7F },     /* HS_BDIAGONAL */
    { 0xF7, 0xF7, 0xF7, 0x00, 0xF7, 0xF7, 0xF7, 0xF7 },     /* HS_CROSS */
    { 0x7E, 0xBD, 0xDB, 0xE7, 0xE7, 0xDB, 0xBD, 0x7E },     /* HS_DIAGCROSS */
};

/* --------------------------------------------------------- DDI entries */

static void fill_caps(PPDEV p, const DEVMODEW *dm, GDIINFO *gi, DEVINFO *di)
{
    const VIDEO_MODE_INFORMATION *m = &p->Modes[p->Mode];
    ULONG d = depth(m);

    zero(gi, sizeof(*gi));
    gi->ulVersion = GDI_DRIVER_VERSION;
    gi->ulTechnology = DT_RASDISPLAY;
    gi->ulHorzSize = m->XMillimeter;
    gi->ulVertSize = m->YMillimeter;
    gi->ulHorzRes = m->VisScreenWidth;
    gi->ulVertRes = m->VisScreenHeight;
    gi->cBitsPixel = m->BitsPerPlane;
    gi->cPlanes = 1;
    gi->ulNumColors = (ULONG)-1;
    gi->flRaster = 0;
    /* The font DPI GDI asks for (dmLogPixels: small/large fonts setting). */
    gi->ulLogPixelsX = dm ? dm->dmLogPixels : 0;
    gi->ulLogPixelsY = dm ? dm->dmLogPixels : 0;
    gi->flTextCaps = TC_RA_ABLE;
    gi->ulDACRed = m->NumberRedBits;
    gi->ulDACGreen = m->NumberGreenBits;
    gi->ulDACBlue = m->NumberBlueBits;
    gi->ulAspectX = 0x24;
    gi->ulAspectY = 0x24;
    gi->ulAspectXY = 0x33;
    gi->xStyleStep = 1;
    gi->yStyleStep = 1;
    gi->denStyleStep = 3;
    gi->ulNumPalReg = 0;
    /* NTSC primaries and D65 white, x/y scaled by 10000 */
    gi->ciDevice.Red.x = 6700;     gi->ciDevice.Red.y = 3300;     gi->ciDevice.Red.Y = 0;
    gi->ciDevice.Green.x = 2100;   gi->ciDevice.Green.y = 7100;   gi->ciDevice.Green.Y = 0;
    gi->ciDevice.Blue.x = 1400;    gi->ciDevice.Blue.y = 800;     gi->ciDevice.Blue.Y = 0;
    gi->ciDevice.Cyan.x = 0;       gi->ciDevice.Cyan.y = 0;       gi->ciDevice.Cyan.Y = 0;
    gi->ciDevice.Magenta.x = 0;    gi->ciDevice.Magenta.y = 0;    gi->ciDevice.Magenta.Y = 0;
    gi->ciDevice.Yellow.x = 0;     gi->ciDevice.Yellow.y = 0;     gi->ciDevice.Yellow.Y = 0;
    gi->ciDevice.AlignmentWhite.x = 3127; gi->ciDevice.AlignmentWhite.y = 3290; gi->ciDevice.AlignmentWhite.Y = 0;
    gi->ciDevice.RedGamma = 20000;
    gi->ciDevice.GreenGamma = 20000;
    gi->ciDevice.BlueGamma = 20000;
    gi->ulDevicePelsDPI = 0;
    gi->ulPrimaryOrder = PRIMARY_ORDER_CBA;
    gi->ulHTPatternSize = HT_PATSIZE_4x4_M;
    gi->ulHTOutputFormat = d <= 16 ? HT_FORMAT_16BPP : (d == 24 ? HT_FORMAT_24BPP : HT_FORMAT_32BPP);
    gi->flHTFlags = HT_FLAG_ADDITIVE_PRIMS;
    gi->ulVRefresh = m->Frequency;
    gi->ulBltAlignment = 1;
    gi->ulPanningHorzRes = m->VisScreenWidth;
    gi->ulPanningVertRes = m->VisScreenHeight;

    zero(di, sizeof(*di));
    di->flGraphicsCaps = GCAPS_OPAQUERECT;
    di->lfDefaultFont.lfHeight = 16;
    di->lfDefaultFont.lfWidth = 7;
    di->lfDefaultFont.lfWeight = 700;
    di->lfDefaultFont.lfCharSet = ANSI_CHARSET;
    di->lfDefaultFont.lfOutPrecision = OUT_DEFAULT_PRECIS;
    di->lfDefaultFont.lfClipPrecision = CLIP_DEFAULT_PRECIS;
    di->lfDefaultFont.lfQuality = DEFAULT_QUALITY;
    di->lfDefaultFont.lfPitchAndFamily = VARIABLE_PITCH | FF_DONTCARE;
    wcopy(di->lfDefaultFont.lfFaceName, L"System", LF_FACESIZE);
    di->lfAnsiVarFont.lfHeight = 12;
    di->lfAnsiVarFont.lfWidth = 9;
    di->lfAnsiVarFont.lfWeight = 400;
    di->lfAnsiVarFont.lfCharSet = ANSI_CHARSET;
    di->lfAnsiVarFont.lfOutPrecision = OUT_DEFAULT_PRECIS;
    di->lfAnsiVarFont.lfClipPrecision = CLIP_STROKE_PRECIS;
    di->lfAnsiVarFont.lfQuality = PROOF_QUALITY;
    di->lfAnsiVarFont.lfPitchAndFamily = VARIABLE_PITCH | FF_DONTCARE;
    wcopy(di->lfAnsiVarFont.lfFaceName, L"MS Sans Serif", LF_FACESIZE);
    di->lfAnsiFixFont.lfHeight = 12;
    di->lfAnsiFixFont.lfWidth = 9;
    di->lfAnsiFixFont.lfWeight = 400;
    di->lfAnsiFixFont.lfCharSet = ANSI_CHARSET;
    di->lfAnsiFixFont.lfOutPrecision = OUT_DEFAULT_PRECIS;
    di->lfAnsiFixFont.lfClipPrecision = CLIP_STROKE_PRECIS;
    di->lfAnsiFixFont.lfQuality = PROOF_QUALITY;
    di->lfAnsiFixFont.lfPitchAndFamily = FIXED_PITCH | FF_DONTCARE;
    wcopy(di->lfAnsiFixFont.lfFaceName, L"Courier", LF_FACESIZE);
    di->cFonts = 0;
    di->iDitherFormat = d <= 16 ? BMF_16BPP : (d == 24 ? BMF_24BPP : BMF_32BPP);
    di->cxDither = 8;
    di->cyDither = 8;
    di->hpalDefault = p->hpal;
}

DHPDEV APIENTRY DrvEnablePDEV(DEVMODEW *pdm, LPWSTR pwszLogAddress, ULONG cPat, HSURF *phsurfPatterns,
                              ULONG cjCaps, ULONG *pdevcaps, ULONG cjDevInfo, DEVINFO *pdi, HDEV hdev,
                              LPWSTR pwszDeviceName, HANDLE hDriver)
{
    PPDEV p;
    GDIINFO gi;
    DEVINFO di;
    const VIDEO_MODE_INFORMATION *m;
    ULONG i;

    UNREFERENCED_PARAMETER(pwszLogAddress);
    UNREFERENCED_PARAMETER(hdev);
    UNREFERENCED_PARAMETER(pwszDeviceName);

    p = (PPDEV)EngAllocMem(FL_ZERO_MEMORY, sizeof(PDEV), TAG);
    if (!p) return NULL;
    p->hDriver = hDriver;
    g_h = hDriver;
    tr(0xE0);
    p->NumModes = get_modes(hDriver, &p->Modes);
    if (!p->NumModes) goto fail;
    p->Mode = pick_mode(p, pdm);
    m = &p->Modes[p->Mode];
    if (depth(m) == 32 || depth(m) == 24 || depth(m) == 16 || depth(m) == 15)
        p->hpal = EngCreatePalette(PAL_BITFIELDS, 0, NULL, m->RedMask, m->GreenMask, m->BlueMask);
    if (!p->hpal) goto fail;

#ifdef USOSVBE_PATTERNS
    for (i = 0; i < cPat && i < HS_DDI_MAX; i++) {
        SIZEL sz;
        sz.cx = 8; sz.cy = 8;
        phsurfPatterns[i] = (HSURF)EngCreateBitmap(sz, sizeof(ULONG), BMF_1BPP, BMF_TOPDOWN, g_hatch[i]);
    }
#else
    UNREFERENCED_PARAMETER(cPat); UNREFERENCED_PARAMETER(phsurfPatterns); UNREFERENCED_PARAMETER(i);
#endif
    fill_caps(p, pdm, &gi, &di);
    copy(pdevcaps, &gi, cjCaps < sizeof(gi) ? cjCaps : sizeof(gi));
    copy(pdi, &di, cjDevInfo < sizeof(di) ? cjDevInfo : sizeof(di));
    return (DHPDEV)p;

fail:
    if (p->hpal) EngDeletePalette(p->hpal);
    if (p->Modes) EngFreeMem(p->Modes);
    EngFreeMem(p);
    return NULL;
}

VOID APIENTRY DrvCompletePDEV(DHPDEV dhpdev, HDEV hdev)
{
    ((PPDEV)dhpdev)->hdev = hdev;
    tr(0xC0);
}

VOID APIENTRY DrvDisablePDEV(DHPDEV dhpdev)
{
    PPDEV p = (PPDEV)dhpdev;
    tr(0xD0);
    if (p->hpal) EngDeletePalette(p->hpal);
    if (p->Modes) EngFreeMem(p->Modes);
    EngFreeMem(p);
}

static BOOL set_mode(PPDEV p)
{
    VIDEO_MODE vm;
    vm.RequestedMode = p->Modes[p->Mode].ModeIndex;
    return ioctl(p->hDriver, IOCTL_VIDEO_SET_CURRENT_MODE, &vm, sizeof(vm), NULL, 0, NULL) == 0;
}

HSURF APIENTRY DrvEnableSurface(DHPDEV dhpdev)
{
    PPDEV p = (PPDEV)dhpdev;
    const VIDEO_MODE_INFORMATION *m = &p->Modes[p->Mode];
    VIDEO_MEMORY in;
    VIDEO_MEMORY_INFORMATION out;
    DWORD ret;
    SIZEL sz;
    ULONG fmt, d = depth(m);
    HSURF hs;

    tr(0x50);
    if (!set_mode(p)) return NULL;
    in.RequestedVirtualAddress = NULL;
    if (ioctl(p->hDriver, IOCTL_VIDEO_MAP_VIDEO_MEMORY, &in, sizeof(in), &out, sizeof(out), &ret))
        return NULL;
    p->FrameBuffer = out.FrameBufferBase;
    p->FrameLength = out.FrameBufferLength;

    fmt = d <= 16 ? BMF_16BPP : (d == 24 ? BMF_24BPP : BMF_32BPP);
    sz.cx = m->VisScreenWidth;
    sz.cy = m->VisScreenHeight;
    hs = (HSURF)EngCreateBitmap(sz, m->ScreenStride, fmt, BMF_TOPDOWN, p->FrameBuffer);
    if (!hs) goto unmap;
    if (!EngAssociateSurface(hs, p->hdev, 0)) {
        EngDeleteSurface(hs);
        goto unmap;
    }
    p->hsurf = hs;
    return hs;

unmap:
    in.RequestedVirtualAddress = p->FrameBuffer;
    ioctl(p->hDriver, IOCTL_VIDEO_UNMAP_VIDEO_MEMORY, &in, sizeof(in), NULL, 0, NULL);
    p->FrameBuffer = NULL;
    return NULL;
}

VOID APIENTRY DrvDisableSurface(DHPDEV dhpdev)
{
    PPDEV p = (PPDEV)dhpdev;
    VIDEO_MEMORY in;
    tr(0x5D);
    if (p->hsurf) EngDeleteSurface(p->hsurf);
    p->hsurf = NULL;
    if (p->FrameBuffer) {
        in.RequestedVirtualAddress = p->FrameBuffer;
        ioctl(p->hDriver, IOCTL_VIDEO_UNMAP_VIDEO_MEMORY, &in, sizeof(in), NULL, 0, NULL);
        p->FrameBuffer = NULL;
    }
}

/* NT 4.0 declares DrvAssertMode as VOID; later versions read a BOOL. */
BOOL APIENTRY DrvAssertMode(DHPDEV dhpdev, BOOL bEnable)
{
    PPDEV p = (PPDEV)dhpdev;
    tr(0xA0 + (bEnable ? 1 : 0));
    if (bEnable) return set_mode(p);
    return ioctl(p->hDriver, IOCTL_VIDEO_RESET_DEVICE, NULL, 0, NULL, 0, NULL) == 0;
}

ULONG APIENTRY DrvGetModes(HANDLE hDriver, ULONG cjSize, DEVMODEW *pdm)
{
    PVIDEO_MODE_INFORMATION modes;
    ULONG n = get_modes(hDriver, &modes), i, out = 0;
    const ULONG cj = sizeof(DEVMODEW);

    g_h = hDriver;
    tr(0x60 + (pdm ? 1 : 0));
    if (!n) return 0;
    if (!pdm) {
        EngFreeMem(modes);
        return n * cj;
    }
    for (i = 0; i < n && cjSize >= cj; i++) {
        const VIDEO_MODE_INFORMATION *m = &modes[i];
        zero(pdm, cj);
        wcopy(pdm->dmDeviceName, L"usosvbe", CCHDEVICENAME);
        pdm->dmSpecVersion = NT4_DEVMODE_SPEC;
        pdm->dmDriverVersion = NT4_DEVMODE_SPEC;
        pdm->dmSize = (WORD)cj;
        pdm->dmDriverExtra = 0;
        pdm->dmBitsPerPel = depth(m);     /* 15 for 5-5-5, as NT 4.0's drivers report */
        pdm->dmPelsWidth = m->VisScreenWidth;
        pdm->dmPelsHeight = m->VisScreenHeight;
        pdm->dmDisplayFrequency = m->Frequency;
        pdm->dmDisplayFlags = 0;
        pdm->dmFields = DM_BITSPERPEL | DM_PELSWIDTH | DM_PELSHEIGHT | DM_DISPLAYFREQUENCY | DM_DISPLAYFLAGS;
        pdm = (DEVMODEW *)((UCHAR *)pdm + cj);
        cjSize -= cj;
        out += cj;
    }
    EngFreeMem(modes);
    return out;
}

/* Brush colors: GDI uses the nearest solid color (direct-color modes only). */
static ULONG pack(ULONG v8, ULONG mask)
{
    ULONG shift = 0, bits = 0, m = mask;
    if (!m) return 0;
    while (!(m & 1)) { m >>= 1; shift++; }
    while (m & 1) { m >>= 1; bits++; }
    return ((v8 >> (8 - (bits > 8 ? 8 : bits))) << shift) & mask;
}

ULONG APIENTRY DrvDitherColor(DHPDEV dhpdev, ULONG iMode, ULONG rgb, ULONG *pul)
{
    PPDEV p = (PPDEV)dhpdev;
    const VIDEO_MODE_INFORMATION *m = &p->Modes[p->Mode];
    ULONG r = rgb & 0xFF, g = (rgb >> 8) & 0xFF, b = (rgb >> 16) & 0xFF, v, i;
    if (iMode == DM_MONOCHROME)
        v = (r * 30 + g * 59 + b * 11) >= 12800 ? 1 : 0;
    else
        v = pack(r, m->RedMask) | pack(g, m->GreenMask) | pack(b, m->BlueMask);
    for (i = 0; i < 64; i++) pul[i] = v;     /* 8x8, one solid color */
    return DCR_DRIVER;
}

/* No palette in direct-color modes. */
BOOL APIENTRY DrvSetPalette(DHPDEV dhpdev, PALOBJ *ppalo, FLONG fl, ULONG iStart, ULONG cColors)
{
    UNREFERENCED_PARAMETER(dhpdev); UNREFERENCED_PARAMETER(ppalo); UNREFERENCED_PARAMETER(fl);
    UNREFERENCED_PARAMETER(iStart); UNREFERENCED_PARAMETER(cColors);
    return FALSE;
}

/* No hardware pointer: decline, GDI draws the pointer itself. */
ULONG APIENTRY DrvSetPointerShape(SURFOBJ *pso, SURFOBJ *psoMask, SURFOBJ *psoColor, XLATEOBJ *pxlo,
                                  LONG xHot, LONG yHot, LONG x, LONG y, RECTL *prcl, FLONG fl)
{
    UNREFERENCED_PARAMETER(pso); UNREFERENCED_PARAMETER(psoMask); UNREFERENCED_PARAMETER(psoColor);
    UNREFERENCED_PARAMETER(pxlo); UNREFERENCED_PARAMETER(xHot); UNREFERENCED_PARAMETER(yHot);
    UNREFERENCED_PARAMETER(x); UNREFERENCED_PARAMETER(y); UNREFERENCED_PARAMETER(prcl); UNREFERENCED_PARAMETER(fl);
    { static ULONG c; if (c++ < 3) tr(0x70); }
    return SPS_DECLINE;
}

VOID APIENTRY DrvMovePointer(SURFOBJ *pso, LONG x, LONG y, RECTL *prcl)
{
    UNREFERENCED_PARAMETER(pso); UNREFERENCED_PARAMETER(x); UNREFERENCED_PARAMETER(y); UNREFERENCED_PARAMETER(prcl);
}

static DRVFN g_fn[] = {
    { INDEX_DrvEnablePDEV, (PFN)DrvEnablePDEV },
    { INDEX_DrvCompletePDEV, (PFN)DrvCompletePDEV },
    { INDEX_DrvDisablePDEV, (PFN)DrvDisablePDEV },
    { INDEX_DrvEnableSurface, (PFN)DrvEnableSurface },
    { INDEX_DrvDisableSurface, (PFN)DrvDisableSurface },
    { INDEX_DrvAssertMode, (PFN)DrvAssertMode },
    { INDEX_DrvDitherColor, (PFN)DrvDitherColor },
    { INDEX_DrvSetPalette, (PFN)DrvSetPalette },
    { INDEX_DrvSetPointerShape, (PFN)DrvSetPointerShape },
    { INDEX_DrvMovePointer, (PFN)DrvMovePointer },
    { INDEX_DrvGetModes, (PFN)DrvGetModes },
};

BOOL APIENTRY DrvEnableDriver(ULONG iEngineVersion, ULONG cj, DRVENABLEDATA *pded)
{
    UNREFERENCED_PARAMETER(iEngineVersion);
    if (cj < sizeof(ULONG) * 2 + sizeof(DRVFN *)) return FALSE;
    pded->iDriverVersion = DDI_DRIVER_VERSION_NT4;
    pded->c = sizeof(g_fn) / sizeof(g_fn[0]);
    pded->pdrvfn = g_fn;
    return TRUE;
}

VOID APIENTRY DrvDisableDriver(VOID)
{
}
