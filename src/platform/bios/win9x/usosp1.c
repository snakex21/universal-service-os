/*
 * USOSP1.DRV - Windows Me Setup phase 1 end fixes on the native path.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * With the phase 1 in USOS's VM, w9x_phase1_patch_c (tools/w9x_phase1_qemu.sh)
 * edits C: after Setup's first restart, before the real PC boots it:
 * SYSTEM.INI [386Enh] mouse= goes (Setup's detection writes
 * mouse=*vmouse, msmouse.vxd; on the X470 VPICD_Phys_EOI stopped with that
 * line under CSMWrap) and MSDOS.SYS gets Logo=0 and BootLog=1 (Me writes its
 * own MSDOS.SYS; the animated logo hung under QEMU OVMF + CSMWrap, and
 * BootLog=1 writes C:\BOOTLOG.TXT so a power-off at boot names the last VxD).
 * 95/98/98 SE repeat the
 * first in real mode (U9FIX /CSM from C:\AUTOEXEC.BAT); Me runs no program
 * from AUTOEXEC.BAT, so with a native phase 1 nothing did either.
 *
 * Setup's own mini-Windows (MINI.CAB, standard mode) runs this phase 1 up to
 * the restart and loads this driver from its SYSTEM.INI [boot] drivers=,
 * next to USOSKEY.DRV (src/compat/win3x/w9x_mini.zig; tools/w9x_csmwrap_target.sh
 * keeps it only for Me with a native phase 1). When that Windows ends
 * (DRV_EXITSESSION, DRV_DISABLE, DRV_FREE: after Setup wrote SYSTEM.INI
 * and MSDOS.SYS for the restart) it applies the same edits
 * (usosp1_logic.h) to C:\WINDOWS\SYSTEM.INI and C:\MSDOS.SYS. Every one of
 * those messages repeats the check: the edits are idempotent, so an early
 * one changes nothing a later one would miss.
 *
 * Files are rewritten in place (open, write, truncate with a zero-length
 * write): MSDOS.SYS keeps its directory entry and gets its attributes back
 * (read-only is cleared only for the write). One line per check goes to
 * C:\USOS9X\USOSP1.TXT. Only KERNEL calls that Windows 3.1 standard mode
 * has, checked against the Me mini-Windows KRNL386.EXE
 * (tools/tests/legacy_bios/test_usosp1.py). No OpenWatcom runtime is linked
 * (own entry point, -zl), as USOSKEY.DRV / USOSPID.DRV.
 */
#include <windows.h>
#include "usosp1_logic.h"

#ifndef DRV_EXITSESSION
#define DRV_EXITSESSION 0x000B
#endif

#define INI_FILE  "C:\\WINDOWS\\SYSTEM.INI"
#define DOS_FILE  "C:\\MSDOS.SYS"
#define LOG_FILE  "C:\\USOS9X\\USOSP1.TXT"

/* DGROUP only: SS is not DS in a driver (-zu), so nothing on the stack is
 * handed to Windows or DOS by address. */
static char in[P1_MAX + 1];
static char out[P1_MAX + P1_SLACK];
static char line[96];
static char path[24];
static OFSTRUCT of;
static unsigned lpos;
static unsigned olen, oremoved;    /* p1_* results (DGROUP, see above) */
static BYTE busy;

/* INT 21h 4300h / 4301h on the DS:DX path; 0xFFFF / -1 on an error. */
extern unsigned dos_getattr(const char *p);
#pragma aux dos_getattr = \
    "mov ax,4300h" "int 21h" "sbb ax,ax" "or cx,ax" \
    parm [dx] value [cx] modify [ax];
extern int dos_setattr(const char *p, unsigned attr);
#pragma aux dos_setattr = \
    "mov ax,4301h" "int 21h" "sbb ax,ax" \
    parm [dx] [cx] value [ax];

static void put(const char *s)
{
    while (*s && lpos < sizeof(line) - 3) line[lpos++] = *s++;
}

static void put_num(unsigned v)
{
    char d[6];
    int n = 0;
    do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v && n < 5);
    while (n && lpos < sizeof(line) - 3) line[lpos++] = d[--n];
}

static void copy_path(const char *s)
{
    int i = 0;
    while (s[i] && i < (int)sizeof(path) - 1) { path[i] = s[i]; i++; }
    path[i] = 0;
}

/* The whole file into in[]; its length, or -1 (missing, unreadable or
 * larger than P1_MAX). */
static int load(const char *name)
{
    HFILE f;
    int n;
    copy_path(name);
    f = OpenFile(path, &of, OF_READ);
    if (f == HFILE_ERROR) return -1;
    n = _lread(f, in, sizeof(in));
    _lclose(f);
    if (n < 0 || n > (int)P1_MAX) return -1;
    return n;
}

/* out[0..len) over the file, cut there. 1 = written. */
static int store(unsigned len)
{
    HFILE f;
    int ok;
    f = OpenFile(path, &of, OF_WRITE);
    if (f == HFILE_ERROR) return 0;
    ok = _lwrite(f, out, len) == len;
    if (ok) ok = _lwrite(f, out, 0) == 0;          /* DOS: truncate here */
    _lclose(f);
    return ok;
}

static void fix_ini(void)
{
    int n = load(INI_FILE);
    put(" ini=");
    if (n < 0) { put("absent"); return; }
    if (p1_drop_mouse(in, (unsigned)n, out, &olen, &oremoved) != P1_CHANGED) { put("ok"); return; }
    if (!store(olen)) { put("write-failed"); return; }
    put("mouse-removed:");
    put_num(oremoved);
}

static void fix_logo(void)
{
    unsigned attr;
    int n, r;
    copy_path(DOS_FILE);
    attr = dos_getattr(path);
    put(" logo=");
    if (attr == 0xFFFFu) { put("absent"); return; }
    n = load(DOS_FILE);
    if (n < 0) { put("unreadable"); return; }
    r = p1_add_logo(in, (unsigned)n, out, &olen);
    if (r == P1_PRESENT) { put("present"); return; }
    if (r != P1_CHANGED) { put("no-options"); return; }
    copy_path(DOS_FILE);
    if (attr & 1) dos_setattr(path, attr & ~1u);
    r = store(olen);
    copy_path(DOS_FILE);
    if (attr & 1) dos_setattr(path, attr);
    put(r ? "added" : "write-failed");
}

static void log_line(void)
{
    HFILE f;
    copy_path(LOG_FILE);
    f = OpenFile(path, &of, OF_WRITE);
    if (f == HFILE_ERROR) f = OpenFile(path, &of, OF_CREATE | OF_WRITE);
    if (f == HFILE_ERROR) return;
    _llseek(f, 0L, 2);
    line[lpos++] = '\r';
    line[lpos++] = '\n';
    _lwrite(f, line, lpos);
    _lclose(f);
}

/* One check: both edits and a log line naming the message. */
static void fix(const char *event)
{
    if (busy) return;
    busy = 1;
    lpos = 0;
    put("USOSP1 ");
    put(event);
    fix_ini();
    fix_logo();
    log_line();
    busy = 0;
}

LRESULT FAR PASCAL __export __loadds DriverProc(DWORD id, HANDLE driver, UINT msg, LPARAM p1, LPARAM p2)
{
    (void)id; (void)driver; (void)p1; (void)p2;
    switch (msg) {
    case DRV_LOAD:
    case DRV_ENABLE:
    case DRV_OPEN:
    case DRV_CLOSE:       return 1L;
    case DRV_EXITSESSION: fix("exitsession"); return 1L;
    case DRV_DISABLE:     fix("disable"); return 1L;
    case DRV_FREE:        fix("free"); return 1L;
    }
    return 0L;
}

/* No file work at WEP: KERNEL may already be shutting down. */
int FAR PASCAL __export __loadds WEP(int exit_type)
{
    (void)exit_type;
    return 1;
}

/* DLL entry (no C runtime): DS = DGROUP. Returns AX = 1. */
#pragma aux dll_entry "__DLLstart_"
void __declspec(naked) __far dll_entry(void)
{
    _asm {
        mov ax, 1
        retf
    }
}
