/*
 * USOSMOUS.DRV - USB mouse for Windows 3.x and 9x under CSMWrap.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * A Windows mouse driver (SYSTEM.INI [boot] mouse.drv=usosmous.drv, module
 * name MOUSE) for a UEFI PC without a CSM. CSMWrap's SeaBIOS serves a USB
 * boot-protocol mouse as the BIOS PS/2 pointing device (INT 15h AX=C2xxh)
 * and far-calls the INT 15h C207h handler from its USB poll (INT 08h) with
 * the 3-byte PS/2 packet. That handler lives in the DOS TSR USOSKEY.COM
 * (src/platform/bios/msdos/usoskey.S): loaded
 * before Windows, it is the same memory in every VM, and it only stores the
 * packet in a ring (shared block version 4). This driver
 *   - finds the block (INT 2Fh AX=D700h) and reports a relative 3-button
 *     mouse to USER (Inquire) when the BIOS accepts the mouse (C205h),
 *   - on Enable registers the TSR's handler with the BIOS through DPMI
 *     0300h (C205h init with 3-byte packets, C207h handler, C200h enable),
 *     on Disable switches it off again (C200h, C207h with 0:0),
 *   - drains the ring from a SYSTEM.DRV system timer (20 ms) and calls the
 *     event procedure USER passed to Enable (mouse_event register
 *     interface: AX flags, BX/CX relative mickeys, DX buttons), merging
 *     packets with the same buttons, after scaling the movement by
 *     SYSTEM.INI [usosmous] Multiplier= / Divisor= (default 1/2, with the
 *     remainder carried, usosmous_scale.h); USER then applies the Control
 *     Panel speed and acceleration on top.
 * Windows' own PS/2 mouse VxD (*vmouse / VMOUSE) must stay out: next to
 * SeaBIOS's BIOS mouse it stopped the X470 in VPICD (U9FIX /CSM removes
 * the line). Only the Windows desktop gets the mouse; DOS programs and DOS
 * boxes do not (no INT 33h). The Windows mouse driver interface used here
 * is the documented one of the Windows 3.1 DDK (Inquire, Enable, Disable,
 * MouseGetIntVect; MOUSEINFO) as also described by Wine's mouse.drv16.
 *
 * Windows Me (no AUTOEXEC.BAT programs, so no USOSKEY.COM), v2 2026-10-18:
 * KERNEL loads this driver right after KEYBOARD.DRV, before DISPLAY, GDI
 * and USER (Me BOOTLOG.TXT), and USER asks it (Inquire, Enable) before it
 * loads the installable drivers of [boot] drivers=. v1 imported USER (a
 * WH_CBT hook) and installed the bridge copy from Inquire; Me no longer
 * started. v2:
 *   - imports KERNEL only (the build checks it): no hook, no copy here;
 *   - Inquire without a bridge answers from static data (a mouse exists)
 *     and changes nothing; Enable then only keeps USER's event procedure;
 *   - USOSKEY.DRV installs the copy at its DRV_LOAD (task time, USER is up:
 *     the keyboard-only state that works on Me) and then calls this
 *     driver's USOSATTACH by name; only there the BIOS mouse is registered
 *     and the timer started. Every failure leaves the pointer still;
 *   - C:\USOS9X\NOMOUSE.TXT present: "no mouse", nothing else happens.
 * DOS-box guard (Me, v3): the copy lives in the system VM's DOS memory
 * while SeaBIOS keeps the C207h pointer for every VM, so a DOS VM must
 * never get SeaBIOS's far call. USOSKEY.DRV (loaded after USER) counts the
 * WinOldAp "tty" windows in its WH_CBT hook and calls this driver's
 * USOSPAUSE by name: 1 when the first one appears (C200h off, C207h 0:0,
 * state "paused"), 0 when the last one is gone (C205h/C207h/C200h again),
 * 2 when it has no hook (paused for good). Paused is the default on Me
 * from before USOSATTACH until the hook is there; every failure leaves the
 * mouse paused (docs/win9x-modern-2026-09-30.md 4g). This driver itself
 * still imports KERNEL only.
 * 95/98/98 SE (TSR from AUTOEXEC.BAT, the same memory in every VM): the
 * plain path, as before.
 * No OpenWatcom runtime is linked (own entry point, -zl).
 * Built with tools/build_win3_usb_keyboard.py; docs/win9x-modern-2026-09-30.md.
 */
#include <windows.h>
#include "usosmous_scale.h"

typedef struct {
    BYTE msExists;
    BYTE msRelative;
    WORD msNumButtons;
    WORD msRate;
    WORD msXThreshold;
    WORD msYThreshold;
    WORD msXRes;
    WORD msYRes;
    WORD msMouseCommPort;
} MOUSEINFO;

/* USOSKEY.COM shared block (usoskey.S), up to version 4. */
typedef struct {
    char magic[4];
    WORD version;
    BYTE head, tail, alive, origin; /* origin: 'W' copy from USOSKEY.DRV, 0 TSR */
    WORD dropped, captured, passed;
    BYTE ring[64];
    WORD forced, refused;
    WORD polls;
    BYTE last4f, last4f9;
    DWORD c08, c1c, c4f, c4fusb;
    WORD sp08, ss08, sp4f, ss4f;
    /* version 3: keyboard diagnostics */
    WORD c16[10];
    WORD last16ax, last16ip, last16cs;
    WORD evseq;
    BYTE evlog[32][8];
    /* version 4: mouse (+396) */
    BYTE mhead, mtail, malive, mstate;
    WORD mcb;
    WORD mdropped, mignored, mpolls;
    DWORD mpackets;
    BYTE mlast[4];
    WORD mevents, merr;
    BYTE mring[128];
} SHARED;

/* mstate */
#define MS_NONE       0
#define MS_ENABLED    1
#define MS_NO_MOUSE   2     /* C205h failed: no BIOS pointing device */
#define MS_FAILED     3     /* C207h/C200h failed */
#define MS_DISABLED   4
#define MS_PAUSED     5     /* Me: a DOS box exists (USOSPAUSE 1) */
#define MS_NO_GUARD   6     /* Me: USOSKEY.DRV has no DOS-box hook (USOSPAUSE 2) */

/* mouse_event flags (SF_ in the DDK) */
#define SF_MOVEMENT   0x0001
#define SF_B1_DOWN    0x0002
#define SF_B1_UP      0x0004
#define SF_B2_DOWN    0x0008
#define SF_B2_UP      0x0010
#define SF_B3_DOWN    0x0020
#define SF_B3_UP      0x0040

typedef struct {
    DWORD edi, esi, ebp, reserved, ebx, edx, ecx, eax;
    WORD flags, es, ds, fs, gs, ip, cs, sp, ss;
} RMREGS;

typedef WORD (FAR PASCAL *CREATETIMER)(WORD, FARPROC);
typedef WORD (FAR PASCAL *KILLTIMER)(WORD);

static SHARED FAR *shared;
static WORD shared_sel, shared_seg;
static BYTE probed, present;
static DWORD event_proc;            /* USER's mouse event procedure */
static CREATETIMER create_timer;
static KILLTIMER kill_timer;
static WORD timer;
static BYTE busy, buttons;
static RMREGS rm;
static SCALE scale;
static int move_x, move_y;          /* DGROUP: -zu, SS is not DS */
static BYTE nomouse, nomouse_checked;
static BYTE paused;                 /* 0, MS_PAUSED or MS_NO_GUARD (USOSPAUSE) */

/* INT 2Fh AX=D700h: the bridge (TSR or USOSKEY.DRV's copy), read only. */
static int query_bridge(void)
{
    WORD al_out = 0, rseg = 0, roff = 0, magic = 0;
    if (shared) return 1;
    _asm {
        push si
        push di
        mov ax, 0D700h
        xor bx, bx
        xor cx, cx
        xor dx, dx
        int 2Fh
        mov al_out, ax
        mov rseg, bx
        mov roff, cx
        mov magic, dx
        pop di
        pop si
    }
    if ((al_out & 0xFF) != 0xFF || magic != 0x554B) return 0;
    if (!shared_sel) shared_sel = AllocSelector(HIWORD((DWORD)(void FAR *)&rm));
    if (!shared_sel) return 0;
    SetSelectorBase(shared_sel, (DWORD)rseg << 4);
    SetSelectorLimit(shared_sel, 0xFFFFL);
    shared = (SHARED FAR *)MAKELP(shared_sel, roff);
    if (shared->magic[0] != 'U' || shared->magic[1] != 'S' || shared->magic[2] != 'K' ||
        shared->magic[3] != 'Y' || shared->version < 4) {
        shared = 0;                 /* an old USOSKEY.COM: no mouse ring */
        return 0;
    }
    shared_seg = rseg;
    return 1;
}

/* INT 15h in real mode (V86) through DPMI 0300h. Returns 0 on success,
 * else 100h | AH (BIOS error) or 0FFFFh (DPMI refused). */
static WORD bios15(WORD ax, WORD bx, WORD es)
{
    BYTE failed = 0;
    WORD off = (WORD)(void NEAR *)&rm;
    BYTE NEAR *p = (BYTE NEAR *)&rm;
    WORD i;
    for (i = 0; i < sizeof(rm); i++) p[i] = 0;
    rm.eax = ax;
    rm.ebx = bx;
    rm.es = es;
    rm.flags = 0x0202;              /* IF */
    _asm {
        push es
        push di
        pushad
        mov ax, ds
        mov es, ax
        xor edi, edi
        mov di, off
        mov ax, 0300h
        mov bx, 0015h
        xor cx, cx
        int 31h
        popad
        pop di
        pop es
        jnc ok
        mov failed, 1
    ok:
    }
    if (failed) return 0xFFFF;
    if (rm.flags & 1) return 0x100 | (WORD)((rm.eax >> 8) & 0xFF);
    return 0;
}

static void note_error(WORD function, WORD result)
{
    if (shared) shared->merr = (WORD)((function & 0xFF) << 8) | (result & 0xFF);
}

/* Once there is a bridge: is there a BIOS pointing device (USB through
 * SeaBIOS)? Without a bridge (Me before USOSKEY.DRV) nothing happens. */
static void probe(void)
{
    WORD r;
    if (probed) return;
    if (!query_bridge()) return;
    probed = 1;
    r = bios15(0xC205, 0x0300, 0);  /* initialize, 3-byte packets */
    present = r == 0;
    if (!present) {
        note_error(0x05, r);
        shared->mstate = MS_NO_MOUSE;
    }
}

static void call_event(WORD flags, int dx, int dy)
{
    WORD fx, mx, my;
    move_x = dx;
    move_y = dy;
    scale_move(&scale, &move_x, &move_y);
    dx = move_x;
    dy = move_y;
    if (!dx && !dy) {
        flags &= ~SF_MOVEMENT;
        if (!flags) return;         /* below one pixel: carried to the next one */
    }
    fx = flags;
    mx = (WORD)dx;
    my = (WORD)dy;
    _asm {
        pusha
        push ds
        push es
        mov ax, fx
        mov bx, mx
        mov cx, my
        mov dx, 3
        xor si, si
        xor di, di
        call dword ptr event_proc
        pop es
        pop ds
        popa
    }
    shared->mevents++;
}

static WORD button_flags(BYTE old, BYTE now)
{
    WORD f = 0;
    BYTE changed = old ^ now;
    if (changed & 1) f |= (now & 1) ? SF_B1_DOWN : SF_B1_UP;
    if (changed & 2) f |= (now & 2) ? SF_B2_DOWN : SF_B2_UP;
    if (changed & 4) f |= (now & 4) ? SF_B3_DOWN : SF_B3_UP;
    return f;
}

/* Interrupt time (SYSTEM.DRV timer, may interrupt a Win32 thread): only
 * the shared block (fixed DOS memory), DGROUP (fixed), scale_move and
 * USER's event procedure; no USER or KERNEL call
 * (test_usoskey_timer_safe.py). */
static void __near __loadds poll_body(void)
{
    int sx = 0, sy = 0;
    if (busy || !shared || !event_proc) return;
    busy = 1;
    shared->malive = 18;            /* about 1 s of INT 1Ch ticks */
    shared->mpolls++;
    while (shared->mtail != shared->mhead) {
        BYTE FAR *p = shared->mring + ((WORD)shared->mtail << 2);
        BYTE status = p[0], now;
        int dx = (int)(p[1] | ((status & 0x10) ? 0xFF00 : 0));
        int dy = (int)(p[2] | ((status & 0x20) ? 0xFF00 : 0));
        shared->mtail = (BYTE)((shared->mtail + 1) & 31);
        if (status & 0xC0) continue;            /* overflow: no valid motion */
        now = (BYTE)(status & 7);
        sx += dx;
        sy -= dy;                               /* PS/2: up is positive */
        if (now != buttons) {
            call_event(button_flags(buttons, now) | ((sx || sy) ? SF_MOVEMENT : 0), sx, sy);
            buttons = now;
            sx = sy = 0;
        }
    }
    if (sx || sy) call_event(SF_MOVEMENT, sx, sy);
    busy = 0;
}

/* Timer callback: all registers back, 32-bit halves and FS/GS included. */
void __declspec(naked) __far poll(void)
{
    _asm {
        pushad
        push ds
        push es
        push fs
        push gs
        call poll_body
        pop gs
        pop fs
        pop es
        pop ds
        popad
        retf
    }
}

static int init_timer_procs(void)
{
    HINSTANCE system;
    if (create_timer) return 1;
    system = GetModuleHandle("SYSTEM");
    create_timer = (CREATETIMER)GetProcAddress(system, MAKEINTRESOURCE(2));
    kill_timer = (KILLTIMER)GetProcAddress(system, MAKEINTRESOURCE(3));
    return create_timer && kill_timer;
}

/* C205h init (3-byte packets), C207h the TSR's handler, C200h enable.
 * Sets mstate; 1 when the BIOS mouse runs. */
static int bios_on(void)
{
    WORD r = bios15(0xC205, 0x0300, 0);
    if (r) { note_error(0x05, r); shared->mstate = MS_NO_MOUSE; return 0; }
    r = bios15(0xC207, shared->mcb, shared_seg);
    if (r) { note_error(0x07, r); shared->mstate = MS_FAILED; return 0; }
    r = bios15(0xC200, 0x0100, 0);
    if (r) { note_error(0x00, r); bios15(0xC207, 0, 0); shared->mstate = MS_FAILED; return 0; }
    shared->mstate = MS_ENABLED;
    return 1;
}

static void bios_off(BYTE state)
{
    bios15(0xC200, 0x0000, 0);      /* disable */
    bios15(0xC207, 0, 0);           /* remove the handler */
    shared->mstate = state;
}

static void stop(void)
{
    if (timer) { kill_timer(timer); timer = 0; }
    if (shared && shared->mstate == MS_ENABLED) bios_off(MS_DISABLED);
    if (shared && (shared->mstate == MS_PAUSED || shared->mstate == MS_NO_GUARD)) shared->mstate = MS_DISABLED;
    if (shared) shared->malive = 0;
    event_proc = 0;                 /* paused stays: USOSKEY.DRV's count */
}

/* C:\USOS9X\NOMOUSE.TXT (KERNEL OpenFile, OF_EXIST: read only): the
 * recovery switch, checked once. */
static int switched_off(void)
{
    OFSTRUCT of;
    if (!nomouse_checked) {
        nomouse_checked = 1;
        nomouse = OpenFile("C:\\USOS9X\\NOMOUSE.TXT", &of, OF_EXIST) != HFILE_ERROR;
    }
    return nomouse;
}

/* Windows Me: DOS 8.00 in GetVersion's high word (95/98: 7.x). */
static int is_me(void)
{
    return HIBYTE(HIWORD(GetVersion())) >= 8;
}

/* BIOS mouse on and the poll timer started once USER's procedure and the
 * bridge are both there; while paused (Me: a DOS box, or no guard) only the
 * timer, the BIOS mouse stays off. Task time only (Enable, USOSATTACH). */
static void start(void)
{
    if (timer || !event_proc || !shared || !present || !init_timer_procs()) return;
    shared->mtail = shared->mhead;  /* nothing stale */
    buttons = 0;
    if (paused) shared->mstate = paused;
    else if (!bios_on()) return;
    shared->malive = 18;
    timer = create_timer(20, (FARPROC)poll);
    if (!timer) bios_off(MS_FAILED);
}

/* Ordinal 1: fill MOUSEINFO, return its size. With a bridge (USOSKEY.COM:
 * 95/98/98 SE) the BIOS is asked as before (no bridge there: no mouse);
 * on Me without one (the copy comes later from USOSKEY.DRV) static data,
 * a 3-button relative mouse. */
WORD FAR PASCAL __loadds Inquire(MOUSEINFO FAR *info)
{
    WORD i;
    BYTE FAR *p = (BYTE FAR *)info;
    BYTE exists = 0;
    if (!switched_off()) {
        probe();
        exists = probed ? present : (BYTE)is_me();
    }
    for (i = 0; i < sizeof(MOUSEINFO); i++) p[i] = 0;
    info->msExists = exists;
    info->msRelative = 1;
    info->msNumButtons = 3;
    info->msRate = 50;
    info->msXThreshold = 4;
    info->msYThreshold = 4;
    info->msXRes = 4;
    info->msYRes = 4;
    return sizeof(MOUSEINFO);
}

/* Ordinal 2: start sending events to USER's procedure. Without a bridge
 * yet (Me) only the procedure is kept; USOSATTACH starts the mouse. */
void FAR PASCAL __loadds Enable(FARPROC proc)
{
    if (timer) stop();
    event_proc = 0;
    if (switched_off()) return;
    probe();
    if (probed ? !present : !is_me()) return;
    scale_init(&scale, (int)GetPrivateProfileInt("usosmous", "Multiplier", SCALE_MUL_DEFAULT, "SYSTEM.INI"),
               (int)GetPrivateProfileInt("usosmous", "Divisor", SCALE_DIV_DEFAULT, "SYSTEM.INI"));
    event_proc = (DWORD)proc;
    start();
}

/* Ordinal 3. */
void FAR PASCAL __loadds Disable(void)
{
    stop();
}

/* Ordinal 4: no hardware interrupt of our own. */
int FAR PASCAL MouseGetIntVect(void)
{
    return -1;
}

int FAR PASCAL __loadds WEP(int exit_type)
{
    (void)exit_type;
    stop();
    return 1;
}

/* Ordinal 6, called by name from USOSKEY.DRV (DRV_LOAD, task time) after
 * it installed the bridge copy (Me). Nothing happens unless USER has
 * enabled this driver; every failure leaves the pointer still. */
void FAR PASCAL __loadds UsosAttach(void)
{
    if (switched_off() || !event_proc || timer) return;
    probe();
    start();
}

/* Ordinal 7, called by name from USOSKEY.DRV's WH_CBT hook (task time,
 * the thread that creates or destroys a DOS box window) on Me:
 * 1 = the first DOS box appears, 2 = no DOS-box guard: BIOS mouse off;
 * 0 = the last DOS box is gone: on again, unless anything fails (then the
 * state shows the BIOS error and the mouse stays off). Never at interrupt
 * time; the poll timer keeps running and finds an empty ring. */
void FAR PASCAL __loadds UsosPause(WORD how)
{
    if (how) {
        paused = how == 2 ? MS_NO_GUARD : MS_PAUSED;
        if (!shared) return;
        if (shared->mstate == MS_ENABLED) bios_off(paused);
        else if (shared->mstate == MS_PAUSED || shared->mstate == MS_NO_GUARD) shared->mstate = paused;
        return;
    }
    paused = 0;
    if (!shared || !timer || !event_proc) return;   /* start() turns it on later */
    if (shared->mstate != MS_PAUSED && shared->mstate != MS_NO_GUARD) return;
    shared->mtail = shared->mhead;  /* nothing stale */
    bios_on();
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
