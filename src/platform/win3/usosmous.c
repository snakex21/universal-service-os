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
 * Wheel (2026-10-18): CSMWrap patch 0016 reads a USB wheel mouse in the HID
 * report protocol and emulates a PS/2 IntelliMouse: after the knock (C202h
 * sample rates 200, 100, 80) C204h answers device ID 3 and, with 3-byte
 * packages, the BIOS passes the wheel byte (up negative) in the handler's Z
 * word; USOSKEY.COM's handler keeps it as the ring's 4th byte (0 from an
 * older TSR or BIOS). On Windows 98, 98 SE and Me (DOS 7.10 and later in
 * GetVersion) this driver sends the knock after C205h; device ID 3 = wheel:
 *   - Inquire returns msExists = 4Bh (75, SM_MOUSEWHEELPRESENT): USER of
 *     98 / 98 SE / Me then reports a wheel mouse (that is how it reads the
 *     wheel from the mouse driver; any nonzero value is "mouse present"),
 *   - the poll sums the wheel bytes and calls USER's event procedure once
 *     more with AX = 0800h (MOUSEEVENTF_WHEEL) and DX = the delta in
 *     WHEEL_DELTA units (120 per notch, up positive); USER queues
 *     WM_MOUSEWHEEL for the focus window as for its own wheel mice (USER
 *     drops button flags in a wheel call, so it is a call of its own).
 * Without the knock answered (older CSMWrap, wheel-less mouse, Windows
 * 3.x / 95, SYSTEM.INI [usosmous] Wheel=0) nothing changes.
 * Wheel v4 (2026-10-19, Me on the X470 with CSMWrap usos14: the knock was
 * answered with ID 0, the BIOS saw a later reset and rates 10, 40 from
 * another INT 15h client): CSMWrap 3.1.2-usos15 (patch 0020) passes the
 * wheel in the Z word with 3-byte packages also without the knock. So
 * where the wheel is wanted (98 / 98 SE / Me, Wheel=1) a nonzero Z sum is
 * sent as a wheel event even when the knock was not answered with ID 3
 * (Z is 0 from an older CSMWrap and from a mouse without a wheel), and a
 * knock answered with an ID other than 3 is sent once more (once per
 * C205h init, i.e. per Enable / USOSATTACH / end of a DOS-box pause).
 * Wheel scrolling of Win16 windows (2026-10-19): USOSWHEELINFO version 2
 * adds a running notch count (up positive), moved here before USER gets
 * the wheel event; USOSKEY.DRV's WH_GETMESSAGE hook (task time) reads it
 * for the real delta (usoskey_wheel.h). Nothing else changes here.
 * VMOUSE mode (USOSVMD.VXD v2, 2026-10-19; C:\USOS9X\USOSVMD.ON): see
 * vmd_present() below and docs/dos-mouse-2026-10-18.md. The INT 15h C207h
 * handler is then the VxD's V86 callback (global VMM breakpoint, valid in
 * every VM), never the bridge copy in the system VM's memory, so the Me
 * DOS-box guard is not needed (USOSVMDMODE tells USOSKEY.DRV); VMOUSE feeds
 * USER (and DOS boxes) and this driver's timer only adds the wheel.
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
#define SF_WHEEL      0x0800    /* 98 / Me USER: DX = wheel delta */
#define WHEEL_DELTA   120
#define MS_EXISTS_WHEEL 0x4B    /* Inquire msExists: wheel mouse (98 / Me USER) */

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
static BYTE wheel;                  /* the BIOS answered the IntelliMouse knock */
static BYTE wheel_pref;             /* wheel_wanted: 0 not asked yet, 1 no, 2 yes */
static int wheel_sum;               /* DGROUP: -zu, SS is not DS */

/* Wheel diagnostics for USOSDBG.EXE (USOSWHEELINFO): written here only. */
typedef struct {
    BYTE version;                   /* 2 (notches added) */
    BYTE pref;                      /* wheel_pref */
    BYTE wheel;                     /* the knock was answered with ID 3 */
    BYTE knock_id;                  /* BH of the last C204h after a knock, FFh none */
    WORD knock_err;                 /* (step << 12) | bios15 result of a failed knock */
    WORD knocks;                    /* knocks sent */
    WORD wheel_calls;               /* AX=0800h event procedure calls */
    int last_sum;                   /* the last wheel sum handed to USER */
    WORD notches;                   /* version 2: running notch count, up positive,
                                     * wraps; moved before USER gets the event
                                     * (USOSKEY.DRV's wheel scrolling) */
} WHEELINFO;
static WHEELINFO winfo = { 2, 0, 0, 0xFF };

/* VMOUSE mode (USOSVMD.VXD) state; USOSDBG.EXE reads it (USOSVMDINFO). */
typedef struct {
    BYTE version;                   /* 1 */
    BYTE checked;                   /* vmd_present() decided */
    BYTE flag;                      /* C:\USOS9X\USOSVMD.ON exists */
    BYTE vmouse_api;                /* VMOUSE PM API found */
    BYTE vxd_api;                   /* USOSVMD PM API found */
    BYTE vxd_mode;                  /* VxD: 0 no VMOUSE, 1 minidriver, 2 observer, FF no answer */
    BYTE active;                    /* VMOUSE mode in use */
    BYTE cb_ok;                     /* VMDAPI_SET_MOUSE_EVENT_CALLBACK accepted */
    DWORD vxd_cb;                   /* the VxD's V86 callback seg:off */
    WORD direct_err;                /* last DPMI 0200h/0302h failure (1 / 2), 0 none */
    WORD vxd_status;                /* bytes of the VxD status block copied below */
    WORD wheel_only_polls;          /* timer polls in VMOUSE mode */
    BYTE vxd[64];                   /* USOSVMD status block (PM API 2), at USOSVMDINFO */
} VMDINFO;
static VMDINFO vinfo = { 1, 0, 0, 0, 0, 0xFF };
static BYTE vmdmode;                /* VMOUSE mode active */
static BYTE direct15;               /* INT 15h through the real-mode vector (0302h) */

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
    if (direct15) {
        /* VMOUSE mode: the system VM's real-mode INT 15h vector called as a
         * far procedure with an IRET frame (DPMI 0302h), so a VxD that hooks
         * V86 INT 15h C2xxh (VMOUSE virtualises the BIOS mouse for VMs)
         * cannot swallow the registration: SeaBIOS itself must get the
         * VxD's callback. */
        WORD vseg = 0, voff = 0;
        _asm {
            push bx
            push cx
            push dx
            mov ax, 0200h
            mov bl, 15h
            int 31h
            jc v_fail
            mov vseg, cx
            mov voff, dx
            jmp v_done
        v_fail:
            mov failed, 1
        v_done:
            pop dx
            pop cx
            pop bx
        }
        if (failed) { vinfo.direct_err = 1; return 0xFFFF; }
        rm.cs = vseg;
        rm.ip = voff;
        _asm {
            push es
            push di
            pushad
            mov ax, ds
            mov es, ax
            xor edi, edi
            mov di, off
            mov ax, 0302h
            xor bx, bx
            xor cx, cx
            int 31h
            popad
            pop di
            pop es
            jnc ok2
            mov failed, 1
        ok2:
        }
        if (failed) { vinfo.direct_err = 2; return 0xFFFF; }
    } else {
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
    }
    if (failed) return 0xFFFF;
    if (rm.flags & 1) return 0x100 | (WORD)((rm.eax >> 8) & 0xFF);
    return 0;
}

static void note_error(WORD function, WORD result)
{
    if (shared) shared->merr = (WORD)((function & 0xFF) << 8) | (result & 0xFF);
}

/* Windows 98 or later (DOS 7.10+ in GetVersion's high word; 95 OSR2 is
 * 7.10 as well, its USER ignores the wheel flag) and not switched off
 * with SYSTEM.INI [usosmous] Wheel=0. */
static int wheel_wanted(void)
{
    WORD dos;
    if (!wheel_pref) {
        dos = HIWORD(GetVersion());
        wheel_pref = 1;
        if (HIBYTE(dos) > 7 || (HIBYTE(dos) == 7 && LOBYTE(dos) >= 10))
            if (GetPrivateProfileInt("usosmous", "Wheel", 1, "SYSTEM.INI")) wheel_pref = 2;
    }
    return wheel_pref == 2;
}

/* IntelliMouse knock (C202h rates 200, 100, 80), then C204h: device ID 3
 * means the BIOS (CSMWrap patch 0016) sends the wheel. Older CSMWrap
 * answers 0AAh or 0, a PS/2 BIOS 0: no wheel. Sets wheel. */
static void knock(void)
{
    static const WORD rates[3] = { 0x0600, 0x0500, 0x0400 };   /* 200, 100, 80 */
    WORD i, r, tries;
    int want = wheel_wanted();
    wheel = 0;
    winfo.wheel = 0;
    winfo.pref = wheel_pref;
    if (!want) return;
    for (tries = 0; tries < 2 && !wheel; tries++) {     /* v4: ID != 3: once more */
        winfo.knocks++;
        winfo.knock_id = 0xFF;
        for (i = 0; i < 3; i++)
            if ((r = bios15(0xC202, rates[i], 0)) != 0) { winfo.knock_err = (WORD)((i + 1) << 12) | (r & 0x1FF); return; }
        if ((r = bios15(0xC204, 0, 0)) != 0) { winfo.knock_err = 0x4000 | (r & 0x1FF); return; }
        winfo.knock_err = 0;
        winfo.knock_id = (BYTE)((rm.ebx >> 8) & 0xFF);
        wheel = winfo.knock_id == 3;
    }
    winfo.wheel = wheel;
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
    } else knock();
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

/* The summed wheel bytes (IntelliMouse: up negative) as one wheel event. */
static void call_wheel(int sum)
{
    WORD delta;
    if (sum > 200) sum = 200;
    if (sum < -200) sum = -200;
    delta = (WORD)(-sum * WHEEL_DELTA);
    winfo.wheel_calls++;
    winfo.last_sum = sum;
    winfo.notches -= (WORD)sum;     /* one 16-bit store: USOSKEY.DRV reads it at task time */
    _asm {
        pusha
        push ds
        push es
        mov ax, SF_WHEEL
        xor bx, bx
        xor cx, cx
        mov dx, delta
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
    wheel_sum = 0;
    if (vmdmode) vinfo.wheel_only_polls++;
    while (shared->mtail != shared->mhead) {
        BYTE FAR *p = shared->mring + ((WORD)shared->mtail << 2);
        BYTE status = p[0], now;
        int dx = (int)(p[1] | ((status & 0x10) ? 0xFF00 : 0));
        int dy = (int)(p[2] | ((status & 0x20) ? 0xFF00 : 0));
        shared->mtail = (BYTE)((shared->mtail + 1) & 31);
        wheel_sum += (signed char)p[3];         /* 0 without the wheel */
        if (vmdmode) continue;                  /* VMOUSE mode: motion and buttons come from VMOUSE */
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
    /* v4: the Z word with or without device ID 3 (CSMWrap patch 0020);
     * wheel_pref is set at task time, no KERNEL call here. */
    if (wheel_sum && (wheel || wheel_pref == 2)) call_wheel(wheel_sum);
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

/* C205h init (3-byte packets), the wheel knock (C205h resets the device
 * ID), C207h the TSR's handler, C200h enable. Sets mstate; 1 when the
 * BIOS mouse runs. */
static int bios_on(void)
{
    WORD r = bios15(0xC205, 0x0300, 0);
    if (r) { note_error(0x05, r); shared->mstate = MS_NO_MOUSE; return 0; }
    knock();
    /* VMOUSE mode: the VxD's V86 callback (global), else the bridge's mcb */
    if (vmdmode) r = bios15(0xC207, LOWORD(vinfo.vxd_cb), HIWORD(vinfo.vxd_cb));
    else r = bios15(0xC207, shared->mcb, shared_seg);
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

/* VMOUSE mode (USOSVMD.VXD v2 present). Gate: C:\USOS9X\USOSVMD.ON exists,
 * VMOUSE's PM API answers, the USOSVMD PM API (INT 2Fh AX=1684h BX=0,
 * ES:DI -> "USOSVMD ") accepts the bridge's shared block (function 1) and
 * reports "minidriver" (it owns VMOUSE's mouse data). Then:
 *   - the BIOS registration (C205h, knock, C207h, C200h) goes to SeaBIOS
 *     through the real-mode INT 15h vector (bios15, direct15) and C207h
 *     names the VxD's V86 callback (a VMM breakpoint in global V86 memory:
 *     valid in every VM, it traps to ring 0). The bridge's mcb is never
 *     registered, so no BIOS far call can land in the system VM's private
 *     memory while a DOS VM is current (the Me callback hazard);
 *   - USER's event procedure goes to VMOUSE (VMDAPI_SET_MOUSE_EVENT_CALLBACK,
 *     95/98 DDK MOUSE.DOC); VMOUSE moves the pointer on the desktop and in
 *     DOS boxes from what the VxD posts;
 *   - the 20 ms timer still runs, but only for the wheel: the VxD copies
 *     every packet into the shared ring and poll() sends the summed Z bytes
 *     to USER (AX=0800h) as before; motion and buttons are skipped there.
 * Any other answer (no flag, no VxD, VMOUSE already has another mouse:
 * "observer") keeps the plain path and the Me DOS-box guard unchanged.
 * Decided once, at task time, after the bridge exists. */
#define VMD_DEVICE_ID              0x000C
#define VMDAPI_SET_MOUSE_EVENT_CB  0x0003
#define USOSVMD_MINIDRIVER         1

static DWORD vmd_api;               /* VMOUSE PM API entry (seg:off), 0 = none */
static DWORD vxd_api;               /* USOSVMD PM API entry, 0 = none */
static const char vxd_name[8] = { 'U', 'S', 'O', 'S', 'V', 'M', 'D', ' ' };

/* INT 2Fh AX=1684h: the PM API entry of a VxD by ID, or (id 0, Windows 95
 * and later) by its 8-byte name at DS:name. 0 = not loaded. */
static DWORD device_api(WORD id, const char NEAR *name)
{
    WORD o = 0, s = 0, noff = id ? 0 : (WORD)name, dsv = 0;
    _asm {
        push es
        push di
        mov dsv, ds
        xor di, di
        mov es, di
        cmp noff, 0
        je d_id
        push ds
        pop es
        mov di, noff
    d_id:
        mov ax, 1684h
        mov bx, id
        int 2Fh
        mov o, di
        mov s, es
        pop di
        pop es
    }
    if (!id && s == dsv && o == noff) return 0;     /* name not found: ES:DI unchanged */
    return s ? ((DWORD)s << 16) | o : 0;
}

/* USOSVMD function 1 (attach): BX:CX = the shared block; out BX:CX = the
 * V86 callback, DX = mode. 0 on failure. */
static int vxd_attach(void)
{
    WORD bseg = shared_seg, boff = OFFSETOF(shared), cseg = 0, coff = 0, mode = 0xFF, sig = 0;
    BYTE failed = 0;
    _asm {
        pusha
        push es
        push ds
        mov ax, 1
        mov bx, bseg
        mov cx, boff
        call dword ptr vxd_api
        pop ds
        pop es
        jnc a_ok
        mov failed, 1
    a_ok:
        mov sig, ax
        mov cseg, bx
        mov coff, cx
        mov mode, dx
        popa
    }
    vinfo.vxd_mode = (BYTE)mode;
    if (failed || sig != 0x5655) { vinfo.vxd_mode = 0xFF; return 0; }
    vinfo.vxd_cb = ((DWORD)cseg << 16) | coff;
    return vinfo.vxd_cb != 0;
}

/* USOSVMD function 2: its status block into vinfo.vxd (task time). */
static void vxd_status(void)
{
    WORD boff = (WORD)(void NEAR *)vinfo.vxd, n = 0;
    BYTE failed = 0;
    if (!vxd_api) return;
    _asm {
        pusha
        push es
        push ds
        push ds
        pop es
        mov di, boff
        mov ax, 2
        call dword ptr vxd_api
        pop ds
        pop es
        jnc s_ok
        mov failed, 1
    s_ok:
        mov n, cx
        popa
    }
    vinfo.vxd_status = failed ? 0 : n;
}

static int vmd_present(void)
{
    OFSTRUCT of;
    if (vinfo.checked) return vmdmode;
    if (!query_bridge()) return 0;  /* not decided before the bridge exists */
    vinfo.checked = 1;
    vinfo.flag = OpenFile("C:\\USOS9X\\USOSVMD.ON", &of, OF_EXIST) != HFILE_ERROR;
    if (!vinfo.flag) return 0;
    vmd_api = device_api(VMD_DEVICE_ID, vxd_name);
    vinfo.vmouse_api = vmd_api != 0;
    vxd_api = device_api(0, vxd_name);
    vinfo.vxd_api = vxd_api != 0;
    if (!vmd_api || !vxd_api) return 0;
    if (!vxd_attach() || vinfo.vxd_mode != USOSVMD_MINIDRIVER) return 0;
    vmdmode = 1;
    direct15 = 1;
    vinfo.active = 1;
    return 1;
}

/* Give VMOUSE the event procedure to call (proc) or 0 to stop; 1 = accepted. */
static int vmd_set_callback(DWORD proc)
{
    WORD vseg = HIWORD(proc), voff = LOWORD(proc);
    BYTE failed = 0;
    if (!vmd_api) return 0;
    _asm {
        pusha
        push es
        push ds
        mov ax, VMDAPI_SET_MOUSE_EVENT_CB
        mov cx, vseg
        mov dx, voff
        call dword ptr vmd_api
        pop ds
        pop es
        popa
        jnc c_ok
        mov failed, 1
    c_ok:
    }
    return !failed;
}

static void stop(void)
{
    if (timer) { kill_timer(timer); timer = 0; }
    if (vmdmode) vmd_set_callback(0);   /* stop VMOUSE calling USER */
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
    /* VMOUSE mode: BIOS registration of the VxD's callback, USER's
     * procedure to VMOUSE, the timer for the wheel only. Never paused (the
     * guard is off in this mode, USOSVMDMODE). */
    if (vmd_present()) {
        shared->mtail = shared->mhead;
        buttons = 0;
        if (!bios_on()) return;
        shared->malive = 18;
        vinfo.cb_ok = (BYTE)vmd_set_callback(event_proc);
        timer = create_timer(20, (FARPROC)poll);
        if (!timer) { vmd_set_callback(0); bios_off(MS_FAILED); }
        return;
    }
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
 * a 3-button relative mouse, with a wheel unless Wheel=0 (no BIOS call
 * there; the knock comes with USOSATTACH). msExists 4Bh: a wheel mouse
 * for 98 / Me USER (SM_MOUSEWHEELPRESENT). */
WORD FAR PASCAL __loadds Inquire(MOUSEINFO FAR *info)
{
    WORD i;
    BYTE FAR *p = (BYTE FAR *)info;
    BYTE exists = 0;
    if (!switched_off()) {
        probe();
        exists = probed ? present : (BYTE)is_me();
        if (exists && (probed ? wheel : wheel_wanted())) exists = MS_EXISTS_WHEEL;
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
    if (vmdmode) return;            /* VMOUSE mode: no BIOS far call into private memory */
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

/* Ordinal 8, by name from USOSDBG.EXE (task time): the wheel diagnostics,
 * a far pointer into this driver's fixed DGROUP; nothing changes. */
DWORD FAR PASCAL __loadds UsosWheelInfo(void)
{
    winfo.wheel = wheel;
    return (DWORD)(WHEELINFO FAR *)&winfo;
}

/* Ordinal 9, by name from USOSKEY.DRV (task time, before USOSATTACH):
 * 1 when the VMOUSE mode (USOSVMD.VXD) is in use, so its Me DOS-box guard
 * stays off. Decides it now if the bridge exists. */
WORD FAR PASCAL __loadds UsosVmdMode(void)
{
    if (switched_off()) return 0;
    return (WORD)vmd_present();
}

/* Ordinal 10, by name from USOSDBG.EXE (task time): the VMOUSE-mode state
 * with a fresh copy of the VxD's status block; nothing else changes. */
DWORD FAR PASCAL __loadds UsosVmdInfo(void)
{
    if (!vxd_api) vxd_api = device_api(0, vxd_name);
    vinfo.vxd_api = vxd_api != 0;
    vxd_status();
    return (DWORD)(VMDINFO FAR *)&vinfo;
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
