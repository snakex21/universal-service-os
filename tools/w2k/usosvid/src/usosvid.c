/*
 * usosvid (BOOTVID.DLL) - USOS text-mode boot video driver for Windows 2000
 * text-mode Setup, diagnostic build.
 *
 * Universal Service OS (USOS)
 * Copyright (C) 2026 Maksymilian and the USOS Authors (see NOTICE)
 * SPDX-License-Identifier: GPL-3.0-or-later
 *
 * Own implementation, written for USOS (no third-party code); the export
 * names and argument sizes are those the Windows 2000 kernel imports.
 *
 * Why: behind CSMWrap on the X470 the Microsoft boot video driver's
 * 640x480 planar mode never shows, so everything the kernel draws through
 * it - the /SOS lines and, above all, the STOP screen of a bugcheck that
 * happens before USOS's own drivers (usosrst, AHCINT) are started - is a
 * black screen with a blinking cursor (Windows 2000 ACPI HAL, X470,
 * 2026-10-13). This replacement keeps the VGA text mode and writes into the
 * text buffer (B8000h) instead:
 *
 *   row 11  "usosvid ... phase 1": the kernel reached InbvDriverInitialize
 *           (HAL phase 0 and kernel phase 0 are done). A screen that still
 *           shows SETUPLDR's last line without this row = the hang is
 *           earlier.
 *   row 12  HPET (capabilities, general configuration: bit 1 =
 *           LegacyReplacement), RSDP (address, revision, RSDT, XSDT), RSDT
 *           entry count.
 *   row 13  FACP revision, SCI, DSDT/SSDT QWord names still present
 *           (0 = the USOS W2K ACPI MBR patched them), checksums, MADT:
 *           enabled/total local APICs, x2APIC entries, I/O APIC id@GSI base,
 *           local APIC NMI entries.
 *   row 14  the "*** STOP" line, kept even when the console scrolls.
 *   row 15  the last other "***" line (the driver the STOP points into).
 *   16-24   console: every string the kernel displays (/SOS, STOP text).
 *
 * Only staged into $WIN_NT$.~BT (text-mode Setup) for Windows 2000 with the
 * ACPI HAL; the installed system keeps the Microsoft BOOTVID.DLL.
 */
#include <ntddk.h>

#define USOSVID_VERSION "usosvid 1.0"

#define COLS        80
#define ROWS        25
#define ROW_MARK    11
#define ROW_ACPI1   12
#define ROW_ACPI2   13
#define ROW_STOP    14
#define ROW_ADDR    15
#define CON_TOP     16
#define CON_BOTTOM  24

static PUSHORT g_Vga;
static USHORT g_Attr = 0x0F00;          /* white on black */
static ULONG g_Row = CON_TOP, g_Col;
static CHAR g_Line[COLS + 1];
static ULONG g_LineLen;

/* ------------------------------------------------------------------ */
/* Text output                                                         */
/* ------------------------------------------------------------------ */

static VOID
PutRow(ULONG Row, PCSTR Text, ULONG Len, USHORT Attr)
{
    ULONG i;

    if (g_Vga == NULL || Row >= ROWS) return;
    for (i = 0; i < COLS; i++) g_Vga[Row * COLS + i] = (USHORT)(Attr | (UCHAR)(i < Len ? Text[i] : ' '));
}

static PCHAR
PutStr(PCHAR p, PCHAR end, PCSTR s)
{
    while (*s && p < end) *p++ = *s++;
    return p;
}

static PCHAR
PutHex(PCHAR p, PCHAR end, ULONG v, ULONG digits)
{
    static const CHAR hex[] = "0123456789ABCDEF";
    while (digits-- > 0 && p < end) *p++ = hex[(v >> (digits * 4)) & 0xF];
    return p;
}

static VOID
ConScroll(VOID)
{
    ULONG r, c;

    for (r = CON_TOP; r < CON_BOTTOM; r++)
        for (c = 0; c < COLS; c++) g_Vga[r * COLS + c] = g_Vga[(r + 1) * COLS + c];
    for (c = 0; c < COLS; c++) g_Vga[CON_BOTTOM * COLS + c] = (USHORT)(g_Attr | ' ');
}

static BOOLEAN
StartsWith(PCSTR s, ULONG len, PCSTR prefix)
{
    ULONG i;
    for (i = 0; prefix[i]; i++) if (i >= len || s[i] != prefix[i]) return FALSE;
    return TRUE;
}

/* A finished console line: STOP lines and "***" lines are also pinned. */
static VOID
LineDone(VOID)
{
    ULONG i = 0;

    while (i < g_LineLen && g_Line[i] == ' ') i++;
    if (StartsWith(g_Line + i, g_LineLen - i, "*** STOP")) {
        PutRow(ROW_STOP, g_Line + i, g_LineLen - i, 0x4F00);
    } else if (StartsWith(g_Line + i, g_LineLen - i, "***")) {
        PutRow(ROW_ADDR, g_Line + i, g_LineLen - i, 0x4F00);
    }
    g_LineLen = 0;
}

static VOID
ConNewLine(VOID)
{
    LineDone();
    g_Col = 0;
    if (g_Row >= CON_BOTTOM) ConScroll(); else g_Row++;
}

static VOID
ConPut(CHAR c)
{
    if (c == '\n') { ConNewLine(); return; }
    if (c == '\r') { g_Col = 0; return; }
    if (g_Col >= COLS) ConNewLine();
    g_Vga[g_Row * COLS + g_Col] = (USHORT)(g_Attr | (UCHAR)c);
    g_Col++;
    if (g_LineLen < COLS) g_Line[g_LineLen++] = c;
}

/* ------------------------------------------------------------------ */
/* ACPI / HPET facts (read only)                                       */
/* ------------------------------------------------------------------ */

static PVOID
MapPhys(ULONG Address, ULONG Length, MEMORY_CACHING_TYPE Type)
{
    PHYSICAL_ADDRESS pa;
    if (Address == 0 || Length == 0) return NULL;
    pa.QuadPart = Address;
    return MmMapIoSpace(pa, Length, Type);
}

/* Table length from its header, 0 when the signature does not match (or
   Sig == 0 and the length is implausible). */
static ULONG
TableLength(ULONG Address, ULONG Sig, PULONG FoundSig)
{
    PULONG h = (PULONG)MapPhys(Address, 36, MmCached);
    ULONG len = 0, sig = 0;

    if (h == NULL) return 0;
    sig = h[0];
    if ((Sig == 0 || sig == Sig) && h[1] >= 36 && h[1] < 0x100000) len = h[1];
    MmUnmapIoSpace(h, 36);
    if (FoundSig) *FoundSig = sig;
    return len;
}

static UCHAR
ByteSum(PUCHAR p, ULONG len)
{
    UCHAR s = 0;
    while (len--) s = (UCHAR)(s + *p++);
    return s;
}

/* Name(NNNN, QWordConst) left in an AML table (the USOS MBR's pattern). */
static ULONG
QWordNames(PUCHAR t, ULONG len)
{
    ULONG i, n = 0;
    for (i = 36; i + 14 <= len; i++) {
        if (t[i] == 0x08 && t[i + 5] == 0x0E && t[i + 1] >= 0x41 &&
            !((t[i + 1] | t[i + 2] | t[i + 3] | t[i + 4]) & 0x80)) n++;
    }
    return n;
}

static ULONG
FindRsdp(PUCHAR Base, ULONG Length)
{
    ULONG i;
    for (i = 0; i + 20 <= Length; i += 16) {
        if (*(PULONG)(Base + i) == 0x20445352 && *(PULONG)(Base + i + 4) == 0x20525450 &&  /* "RSD PTR " */
            ByteSum(Base + i, 20) == 0) return i + 1;      /* offset + 1 */
    }
    return 0;
}

static VOID
ShowAcpi(VOID)
{
    CHAR line[COLS], line2[COLS];
    PCHAR p = line, end = line + COLS, q = line2, qend = line2 + COLS;
    PULONG hpet;
    PUCHAR area, rsdp = NULL, t;
    ULONG off, rsdpAddr = 0, rsdt = 0, xsdtLo = 0, xsdtHi = 0, rev = 0, n = 0, i, len, sig, addr;
    ULONG dsdt = 0, facpRev = 0, sci = 0, dq = 0, sq = 0, ssdts = 0, bad = 0;
    ULONG lapics = 0, lapicsOn = 0, x2 = 0, nmis = 0, ios = 0, ebda = 0;
    PULONG r = NULL;
    PUSHORT bda;

    /* HPET (the usual address; capabilities all-ones = nothing there) */
    hpet = (PULONG)MapPhys(0xFED00000, 0x400, MmNonCached);
    if (hpet != NULL) {
        p = PutStr(p, end, "hpet ");
        p = PutHex(p, end, hpet[0], 8);
        p = PutStr(p, end, " cfg=");
        p = PutHex(p, end, hpet[4], 8);
        MmUnmapIoSpace(hpet, 0x400);
    }

    /* RSDP: EBDA first KiB, then E0000h-FFFFFh */
    bda = (PUSHORT)MapPhys(0x400, 0x100, MmCached);
    if (bda != NULL) { ebda = (ULONG)bda[7] << 4; MmUnmapIoSpace(bda, 0x100); }
    if (ebda >= 0x80000 && ebda < 0xA0000) {
        area = (PUCHAR)MapPhys(ebda, 0x400, MmCached);
        if (area != NULL) {
            off = FindRsdp(area, 0x400);
            if (off) { rsdpAddr = ebda + off - 1; }
            MmUnmapIoSpace(area, 0x400);
        }
    }
    if (rsdpAddr == 0) {
        area = (PUCHAR)MapPhys(0xE0000, 0x20000, MmCached);
        if (area != NULL) {
            off = FindRsdp(area, 0x20000);
            if (off) rsdpAddr = 0xE0000 + off - 1;
            MmUnmapIoSpace(area, 0x20000);
        }
    }
    p = PutStr(p, end, " rsdp@");
    p = PutHex(p, end, rsdpAddr, 5);
    if (rsdpAddr) rsdp = (PUCHAR)MapPhys(rsdpAddr, 36, MmCached);
    if (rsdp != NULL) {
        rev = rsdp[15];
        rsdt = *(PULONG)(rsdp + 16);
        if (rev >= 2) { xsdtLo = *(PULONG)(rsdp + 24); xsdtHi = *(PULONG)(rsdp + 28); }
        MmUnmapIoSpace(rsdp, 36);
    }
    p = PutStr(p, end, " r");
    p = PutHex(p, end, rev, 1);
    p = PutStr(p, end, " rsdt=");
    p = PutHex(p, end, rsdt, 8);
    len = rsdt ? TableLength(rsdt, 0x54445352, NULL) : 0;  /* "RSDT" */
    if (len) r = (PULONG)MapPhys(rsdt, len, MmCached);
    if (r != NULL) n = (len - 36) / 4;
    p = PutStr(p, end, len ? "(" : "(none ");
    p = PutHex(p, end, n, 2);
    p = PutStr(p, end, ") xsdt=");
    if (xsdtHi) { p = PutHex(p, end, xsdtHi, 8); p = PutStr(p, end, ":"); }
    p = PutHex(p, end, xsdtLo, 8);
    PutRow(ROW_ACPI1, line, (ULONG)(p - line), 0x1F00);

    /* Every RSDT entry: FACP -> DSDT; SSDTs; APIC */
    for (i = 0; r != NULL && i < n && i < 64; i++) {
        addr = r[9 + i];
        len = TableLength(addr, 0, &sig);
        if (len == 0) { bad++; continue; }
        if (sig == 0x50434146) {                            /* "FACP" */
            t = (PUCHAR)MapPhys(addr, len, MmCached);
            if (t == NULL) continue;
            facpRev = t[8];
            if (len >= 48) { dsdt = *(PULONG)(t + 40); sci = *(PUSHORT)(t + 46); }
            MmUnmapIoSpace(t, len);
        } else if (sig == 0x54445353) {                     /* "SSDT" */
            t = (PUCHAR)MapPhys(addr, len, MmCached);
            if (t == NULL) continue;
            ssdts++;
            sq += QWordNames(t, len);
            if (ByteSum(t, len) != 0) bad++;
            MmUnmapIoSpace(t, len);
        } else if (sig == 0x43495041) {                     /* "APIC" */
            t = (PUCHAR)MapPhys(addr, len, MmCached);
            if (t == NULL) continue;
            for (off = 44; off + 2 <= len && t[off + 1] >= 2; off += t[off + 1]) {
                switch (t[off]) {
                case 0: lapics++; if (t[off + 4] & 1) lapicsOn++; break;
                case 1:
                    if (ios < 3) {
                        q = PutStr(q, qend, ios ? "," : " io=");
                        q = PutHex(q, qend, t[off + 2], 2);
                        q = PutStr(q, qend, "@");
                        q = PutHex(q, qend, *(PULONG)(t + off + 8), 2);
                    }
                    ios++;
                    break;
                case 4: nmis++; break;
                case 9: x2++; break;
                }
            }
            MmUnmapIoSpace(t, len);
        }
    }
    if (r != NULL) MmUnmapIoSpace(r, (ULONG)(36 + n * 4));
    if (dsdt) {
        len = TableLength(dsdt, 0x54445344, NULL);          /* "DSDT" */
        t = len ? (PUCHAR)MapPhys(dsdt, len, MmCached) : NULL;
        if (t != NULL) {
            dq = QWordNames(t, len);
            if (ByteSum(t, len) != 0) bad++;
            MmUnmapIoSpace(t, len);
        } else {
            bad++;
        }
    }

    /* Row 13: FACP, DSDT/SSDT, MADT (the I/O APIC part is in line2 so far) */
    p = line;
    p = PutStr(p, end, "facp r");
    p = PutHex(p, end, facpRev, 1);
    p = PutStr(p, end, " sci");
    p = PutHex(p, end, sci, 2);
    p = PutStr(p, end, " dsdt=");
    p = PutHex(p, end, dsdt, 8);
    p = PutStr(p, end, " q");
    p = PutHex(p, end, dq, 1);
    p = PutStr(p, end, " ssdt");
    p = PutHex(p, end, ssdts, 1);
    p = PutStr(p, end, " q");
    p = PutHex(p, end, sq, 1);
    p = PutStr(p, end, " bad");
    p = PutHex(p, end, bad, 1);
    p = PutStr(p, end, " lapic ");
    p = PutHex(p, end, lapicsOn, 2);
    p = PutStr(p, end, "/");
    p = PutHex(p, end, lapics, 2);
    p = PutStr(p, end, " x2 ");
    p = PutHex(p, end, x2, 2);
    p = PutStr(p, end, " nmi");
    p = PutHex(p, end, nmis, 1);
    for (i = 0; line2 + i < q && p < end; i++) *p++ = line2[i];
    PutRow(ROW_ACPI2, line, (ULONG)(p - line), 0x1F00);
}

/* ------------------------------------------------------------------ */
/* BOOTVID.DLL exports (the names and argument sizes the 2000 kernel    */
/* imports)                                                             */
/* ------------------------------------------------------------------ */

BOOLEAN NTAPI
VidInitialize(IN BOOLEAN SetMode)
{
    PHYSICAL_ADDRESS vga;
    CHAR line[COLS];
    PCHAR p, end = line + COLS;
    ULONG c;

    UNREFERENCED_PARAMETER(SetMode);
    if (g_Vga == NULL) {
        vga.QuadPart = 0xB8000;
        g_Vga = (PUSHORT)MmMapIoSpace(vga, COLS * ROWS * 2, MmNonCached);
        if (g_Vga == NULL) return FALSE;
    }
    p = PutStr(line, end, USOSVID_VERSION " (text BOOTVID): kernel phase 1 reached; ACPI facts ...");
    PutRow(ROW_MARK, line, (ULONG)(p - line), 0x2F00);
    for (c = CON_TOP; c <= CON_BOTTOM; c++) PutRow(c, "", 0, 0x0700);
    ShowAcpi();
    p = PutStr(line, end, USOSVID_VERSION " (text BOOTVID): kernel phase 1 reached; ACPI facts below");
    PutRow(ROW_MARK, line, (ULONG)(p - line), 0x2F00);
    return TRUE;
}

VOID NTAPI
VidResetDisplay(IN BOOLEAN HalReset)
{
    UNREFERENCED_PARAMETER(HalReset);
}

VOID NTAPI
VidCleanUp(VOID)
{
}

ULONG NTAPI
VidSetTextColor(IN ULONG Color)
{
    ULONG old = (g_Attr >> 8) & 0x0F;
    g_Attr = (USHORT)((g_Attr & 0xF000) | ((Color & 0x0F) << 8));
    return old;
}

VOID NTAPI
VidDisplayString(IN PUCHAR String)
{
    if (g_Vga == NULL || String == NULL) return;
    while (*String) ConPut((CHAR)*String++);
}

VOID NTAPI
VidDisplayStringXY(IN PUCHAR String, IN ULONG Left, IN ULONG Top, IN BOOLEAN Transparent)
{
    ULONG row = CON_TOP + (Top * (CON_BOTTOM - CON_TOP + 1)) / 480, col = Left / 8;

    UNREFERENCED_PARAMETER(Transparent);
    if (g_Vga == NULL || String == NULL || row > CON_BOTTOM) return;
    while (*String && col < COLS) g_Vga[row * COLS + col++] = (USHORT)(g_Attr | *String++);
}

VOID NTAPI
VidSetScrollRegion(IN ULONG Left, IN ULONG Top, IN ULONG Right, IN ULONG Bottom)
{
    UNREFERENCED_PARAMETER(Left);
    UNREFERENCED_PARAMETER(Top);
    UNREFERENCED_PARAMETER(Right);
    UNREFERENCED_PARAMETER(Bottom);
}

/* A fill that covers the console clears it in that background colour (the
   STOP screen starts with a full-screen blue fill); rows 11-15 stay. */
VOID NTAPI
VidSolidColorFill(IN ULONG Left, IN ULONG Top, IN ULONG Right, IN ULONG Bottom, IN UCHAR Color)
{
    ULONG r;

    UNREFERENCED_PARAMETER(Left);
    UNREFERENCED_PARAMETER(Right);
    if (g_Vga == NULL || Top > 8 || Bottom < 400) return;
    g_Attr = (USHORT)(((Color & 0x07) << 12) | (g_Attr & 0x0F00));
    for (r = CON_TOP; r <= CON_BOTTOM; r++) PutRow(r, "", 0, g_Attr);
    g_Row = CON_TOP;
    g_Col = 0;
    g_LineLen = 0;
}

VOID NTAPI
VidBitBlt(IN PUCHAR Buffer, IN ULONG Left, IN ULONG Top)
{
    UNREFERENCED_PARAMETER(Buffer);
    UNREFERENCED_PARAMETER(Left);
    UNREFERENCED_PARAMETER(Top);
}

VOID NTAPI
VidBufferToScreenBlt(IN PUCHAR Buffer, IN ULONG Left, IN ULONG Top, IN ULONG Width, IN ULONG Height, IN ULONG Delta)
{
    UNREFERENCED_PARAMETER(Buffer);
    UNREFERENCED_PARAMETER(Left);
    UNREFERENCED_PARAMETER(Top);
    UNREFERENCED_PARAMETER(Width);
    UNREFERENCED_PARAMETER(Height);
    UNREFERENCED_PARAMETER(Delta);
}

VOID NTAPI
VidScreenToBufferBlt(OUT PUCHAR Buffer, IN ULONG Left, IN ULONG Top, IN ULONG Width, IN ULONG Height, IN ULONG Delta)
{
    UNREFERENCED_PARAMETER(Left);
    UNREFERENCED_PARAMETER(Top);
    UNREFERENCED_PARAMETER(Width);
    if (Buffer != NULL) RtlZeroMemory(Buffer, Height * Delta);
}

/* Never called (the kernel loads this DLL as an import); EXPORT_DRIVER
   needs an entry point. */
NTSTATUS
DriverEntry(IN PDRIVER_OBJECT DriverObject, IN PUNICODE_STRING RegistryPath)
{
    UNREFERENCED_PARAMETER(DriverObject);
    UNREFERENCED_PARAMETER(RegistryPath);
    return STATUS_SUCCESS;
}
