/*
 * USOSKEY.DRV - USB keyboard for Windows 3.x under CSMWrap.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * An installable driver (SYSTEM.INI [boot] drivers=... USOSKEY.DRV) next to
 * the unchanged stock KEYBOARD.DRV. The DOS TSR USOSKEY.COM captures the raw
 * set-1 bytes SeaBIOS produces for the USB keyboard (INT 15h/4Fh from its
 * timer interrupt) while this driver polls; this driver drains them from a
 * SYSTEM.DRV system timer (interrupt time, every 20 ms) and hands them to
 * Windows:
 *   386 enhanced mode: VKD_API_Force_Key (VKD PM API, INT 2Fh AX=1684h
 *     BX=000Dh) puts each byte into the focus VM as if typed on the 8042
 *     keyboard: the stock KEYBOARD.DRV (system VM, national layouts, dead
 *     keys) or the BIOS of a DOS box processes it natively.
 *   Windows 9x, Windows desktop in front: keybd_event as in standard mode
 *     (below). The 98 VKD only queues forced bytes for the system VM while
 *     it traps the 8042 ports or the VM is in its message mode; with a real
 *     8042 (X470 + PS/2 keyboard, 2026-10-06) the bytes were accepted and
 *     never reached Windows. VKD stays in use when a DOS box (WinOldAp
 *     "tty" window) is active.
 *   standard mode (no VKD): the driver translates to a virtual key (the
 *     stock driver's MapVirtualKey for the typing keys, so QWERTZ/AZERTY
 *     layouts keep their VKs; a fixed table for the rest) and calls USER's
 *     keyboard event procedure (keybd_event, USER.289) like KEYBOARD.DRV's
 *     interrupt handler does; ToAscii stays the stock driver's. The
 *     translation (E0/E1 keys, Windows keys, AltGr = Ctrl+Alt, lock keys,
 *     Print Screen / Pause) is in usoskey_xlat.h, host-tested by
 *     tools/tests/legacy_bios/test_usoskey_xlat.py. Ctrl+Alt+Del goes to
 *     VKD as forced bytes so its hot key (9x Close Program) still fires.
 *     On this path the driver also keeps the BIOS shift flags (0040:0017,
 *     0040:0018, 0040:0096) as SeaBIOS's INT 09h code would have (the stock
 *     KEYBOARD.DRV reads them) and logs the last 32 keybd_event calls in
 *     the TSR's shared block (version 3) for USOSDBG.EXE.
 * Interrupt time: the timer callback (poll) interrupts whatever runs in the
 * system VM, Win32 threads included (X470 98 SE, 2026-10-06: Win32
 * processes died in KERNEL32's exit path, 0167:BFF8976B, while v3 called
 * GetAsyncKeyState from it). It only touches the shared block, the BIOS
 * data area, VKD_API_Force_Key and keybd_event (USER's interrupt-time entry,
 * the one KEYBOARD.DRV's INT 9 handler uses); no other USER/KERNEL call.
 * Everything else is computed outside it: MapVirtualKey into vk_of at load
 * time, the DOS-box test in a WH_CBT hook (HCBT_ACTIVATE, the activating
 * thread's context), which only sets a flag the callback reads. The
 * callback also saves all 32-bit registers and FS/GS. Host test:
 * tools/tests/legacy_bios/test_usoskey_timer_safe.py.
 * Without the TSR (Windows Me starts no real-mode program from AUTOEXEC.BAT
 * and has no WINSTART.BAT) the driver installs the TSR's resident part
 * itself: a copy in DOS memory (GlobalDosAlloc) with INT 08h/09h/15h/1Ch/2Fh
 * hooked in the system VM's real-mode vector table (DPMI 0200h/0201h); the
 * vectors are restored when the driver is freed (usos_resident.h). With
 * that copy (Me) it then calls USOSMOUS.DRV's USOSATTACH by name, if that
 * is the mouse driver: USER enabled the mouse before drivers= were loaded,
 * and only now is there a bridge to register with the BIOS. SYSTEM.INI is
 * never written here (v2, 2026-10-18).
 * DOS-box guard for that mouse (Me, v3): SeaBIOS keeps one C207h pointer
 * for every VM and it points into the system VM's DOS memory, so no DOS VM
 * may get the far call. The WH_CBT hook counts the WinOldAp "tty" windows
 * (HCBT_CREATEWND / HCBT_DESTROYWND) and calls USOSMOUS.DRV's USOSPAUSE by
 * name: 1 for the first, 0 after the last; the mouse is paused from before
 * USOSATTACH until the hook is installed (DRV_ENABLE), and stays paused for
 * good (USOSPAUSE 2) if the hook cannot be installed. The hook then stays
 * until DRV_FREE. USOSMOUS.DRV imports KERNEL only, so the USER part of
 * the guard lives here.
 * Wheel scrolling of Win16 windows (98 / 98 SE / Me, 2026-10-19): USER
 * sends WM_MOUSEWHEEL to the focus window and Win16 windows ignore it (Me's
 * Device Manager: 16-bit COMMCTRL "SysTreeView"). A WH_GETMESSAGE hook
 * (task time, the thread that takes a message; separate from the WH_CBT
 * DOS-box hook) sees USOSMOUS.DRV's notch counter (USOSWHEELINFO v2) move
 * and, for a Win16 or no-wheel window under the pointer, sends it
 * WM_VSCROLL in its own task and turns those notches' WM_MOUSEWHEEL into
 * WM_NULL; Win32 windows keep the stock path. The decisions are in
 * usoskey_wheel.h; USOSWHEELLOG (by name, USOSDBG.EXE) gives the last
 * decisions with the real delta. SYSTEM.INI [usosmous] WheelScroll=0: off.
 * No OpenWatcom runtime is linked (own entry point, -zl): the binary is only
 * this file plus import records. docs/design/bios-via-csmwrap.md.
 */
#include <windows.h>
#include "usoskey_tsr.h"            /* generated: USOSKEY.COM resident part */

typedef struct {
    char magic[4];
    WORD version;
    BYTE head, tail, alive, pad;
    WORD dropped, captured, passed;
    BYTE ring[64];
    WORD forced, refused;           /* diagnostics */
    WORD polls;                     /* version 2: timer polls */
    BYTE last4f, last4f9;           /* version 2: TSR counters (not used here) */
    DWORD c08, c1c, c4f, c4fusb;
    WORD sp08, ss08, sp4f, ss4f;
    WORD c16[10];                   /* version 3: TSR INT 16h guard */
    WORD last16ax, last16ip, last16cs;
    WORD evseq;                     /* version 3: keybd_event log, written here */
    BYTE evlog[32][8];
} SHARED;

typedef WORD (FAR PASCAL *CREATETIMER)(WORD, FARPROC);
typedef WORD (FAR PASCAL *KILLTIMER)(WORD);
typedef int (FAR PASCAL *MAPVK)(WORD, WORD);

static SHARED FAR *shared;
static WORD shared_sel;
static DWORD keybd_event_proc;      /* USER.289, register interface */
static DWORD vkd_entry;             /* VKD PM API (enhanced mode) */
static BYTE win9x;                  /* Windows 4.x: desktop keys via keybd_event */
static CREATETIMER create_timer;
static KILLTIMER kill_timer;
static WORD timer;
static BYTE busy;
static HHOOK cbt_hook;
static BYTE dos_focus;              /* WH_CBT: a DOS box (class "tty") is active */
static BYTE mouse_guard;            /* Me: USOSMOUS.DRV paused while DOS boxes exist */
static WORD dos_boxes;              /* WH_CBT: "tty" windows alive (mouse_guard) */
static BYTE FAR *bda;               /* selector for 0040:0000 */

/* The stock KEYBOARD.DRV keeps the BIOS shift flags in step with every
 * modifier and lock key and reads them back; under USOSKEY the bytes never
 * reach SeaBIOS's INT 09h code, so this driver keeps them (bios_shift_flags
 * in usoskey_xlat.h). Only the bits it owns change; written when different. */
static void sync_bios_flags(void);

static void keyboard_event_raw(WORD ax_value, WORD bx_value);
static BYTE sent_ctrl(void);
static BYTE sent_shift(void);

static void keyboard_event(WORD ax_value, WORD bx_value)
{
    sync_bios_flags();
    keyboard_event_raw(ax_value, bx_value);
    if (shared->version >= 3) {         /* log for USOSDBG.EXE (EVT lines) */
        BYTE FAR *e = shared->evlog[shared->evseq & 31];
        e[0] = LOBYTE(ax_value);
        e[1] = HIBYTE(ax_value);
        e[2] = LOBYTE(bx_value);
        e[3] = HIBYTE(bx_value);
        /* Ctrl / Shift as this driver sent them (80h down): USER's key
         * state cannot be read at interrupt time (USOSDBG shows its own). */
        e[4] = sent_ctrl();
        e[5] = sent_shift();
        e[6] = bda ? bda[0x17] : 0;
        e[7] = bda ? bda[0x18] : 0;
        shared->evseq++;
    }
}

static void keyboard_event_raw(WORD ax_value, WORD bx_value)
{
    _asm {
        pusha
        push es
        mov ax, ax_value
        mov bx, bx_value
        xor si, si
        xor di, di
        call dword ptr keybd_event_proc
        pop es
        popa
    }
}

/* Returns 0 when VKD refused the byte (its buffer is full: CF set). */
static int force_key(BYTE scan)
{
    BYTE failed = 0;
    _asm {
        pushad
        push es
        mov ch, scan
        mov cl, 1
        mov eax, 1            ; VKD_API_Force_Key: VKD compares all of EAX
        xor ebx, ebx          ; focus VM
        mov edx, 0FFFFFFFFh   ; shift state unchanged
        call dword ptr vkd_entry
        pop es
        popad
        jnc done
        mov failed, 1
    done:
    }
    return !failed;
}

/* Ctrl+Alt+Del on the Windows desktop: USER does not act on it, VKD's hot
 * key does (the 9x Close Program box, Windows 3.x's own handling). VKD's
 * forced bytes share its hardware queue, which checks the hot keys. */
static void cad_via_vkd(void)
{
    static const BYTE seq[6] = { 0x1D, 0x38, 0x53, 0xD3, 0xB8, 0x9D };
    BYTE i;
    if (!vkd_entry) return;
    for (i = 0; i < sizeof(seq); i++)
        if (!force_key(seq[i])) { shared->refused++; break; }
}

#define xlat_event(ax, bx) keyboard_event((ax), (bx))
#define xlat_cad() cad_via_vkd()
#include "usoskey_xlat.h"

static BYTE sent_ctrl(void) { return (BYTE)((lctrl || rctrl || altgr_ctrl) ? 0x80 : 0); }
static BYTE sent_shift(void) { return (BYTE)((lshift || rshift) ? 0x80 : 0); }

static void sync_bios_flags(void)
{
    static BYTE f17, f18, f96;          /* DGROUP: SS is not DS here */
    if (!bda) return;
    f17 = bda[0x17]; f18 = bda[0x18]; f96 = bda[0x96];
    bios_shift_flags(&f17, &f18, &f96);
    if (bda[0x17] != f17) bda[0x17] = f17;
    if (bda[0x18] != f18) bda[0x18] = f18;
    if (bda[0x96] != f96) bda[0x96] = f96;
}

static int is_dos_box(HWND w)
{
    char name[8];
    return w && GetClassName(w, name, sizeof(name)) == 3 &&
           (name[0] | 0x20) == 't' && (name[1] | 0x20) == 't' && (name[2] | 0x20) == 'y';
}

/* An export of the mouse driver (module MOUSE) by name, task time only:
 * looked up at every use, so a freed or foreign mouse driver is never
 * called. */
static FARPROC mouse_export(LPCSTR name)
{
    HINSTANCE mouse = GetModuleHandle("MOUSE");
    return mouse ? GetProcAddress(mouse, name) : 0;
}

/* USOSMOUS.DRV's USOSPAUSE: 1 pause (DOS box), 2 pause (no guard), 0 resume. */
static void mouse_pause(WORD how)
{
    FARPROC pause = mouse_export("USOSPAUSE");
    if (pause) ((void (FAR PASCAL *)(WORD))pause)(how);
}

/* Windows 9x: WH_CBT hook, called in the context of the thread that
 * creates, destroys or activates a window (never at interrupt time):
 *   HCBT_ACTIVATE: is the new active window a DOS box (WinOldAp, class
 *     "tty")? Only the flag reaches the timer.
 *   HCBT_CREATEWND / HCBT_DESTROYWND (mouse_guard, Me): the first DOS box
 *     pauses the USB mouse, the last one gone resumes it. A creation that
 *     another hook cancels leaves the count high: the mouse stays paused. */
LRESULT FAR PASCAL __export __loadds cbt_proc(int code, WPARAM wp, LPARAM lp)
{
    if (code == HCBT_ACTIVATE) {
        dos_focus = is_dos_box((HWND)wp);
    } else if (mouse_guard && (code == HCBT_CREATEWND || code == HCBT_DESTROYWND) && is_dos_box((HWND)wp)) {
        if (code == HCBT_CREATEWND) {
            if (dos_boxes++ == 0) mouse_pause(1);
        } else if (dos_boxes && --dos_boxes == 0) {
            mouse_pause(0);
        }
    }
    return CallNextHookEx(cbt_hook, code, wp, lp);
}

/* ---- Wheel scrolling of Win16 windows (usoskey_wheel.h) --------------
 * Task time only: everything below runs in the WH_GETMESSAGE hook (the
 * thread that takes a message, Win32 threads included, under the Win16
 * lock) or at DRV_ENABLE / DRV_DISABLE; the timer path never comes here.
 * USOSMOUS.DRV's DGROUP is fixed and the mouse driver stays loaded while
 * USER runs, so its record is looked up once (wheel_start) and read in
 * place. */
#include "usoskey_wheel.h"

#ifndef WM_MOUSEWHEEL
#define WM_MOUSEWHEEL 0x020A
#endif
#define SPI_GETWHEELSCROLLLINES 0x0068

typedef struct {                    /* USOSMOUS.DRV USOSWHEELINFO, version 2 */
    BYTE version, pref, wheel, knock_id;
    WORD knock_err, knocks, wheel_calls;
    int last_sum;
    WORD notches;
} MOUSEWHEELINFO;

#define WHEEL_RECS 16
typedef struct {
    WORD seq;                       /* record number + 1 (0: empty) */
    DWORD tick;                     /* GetTickCount at the decision */
    int notches;                    /* real delta in notches, up positive */
    BYTE action;                    /* WA_* */
    BYTE kind;                      /* WM_KIND_* of the target's module */
    WORD hwnd;                      /* target: window under the pointer or its WS_VSCROLL ancestor */
    WORD sent;                      /* WM_VSCROLL sent for it (translated) */
    WORD code;                      /* SB_* sent */
    char cls[20];                   /* target class */
} WHEELREC;
typedef struct {
    BYTE version;                   /* 1 */
    BYTE enabled;                   /* hook in place */
    WORD seq;                       /* decisions so far */
    WORD swallowed;                 /* WM_MOUSEWHEEL turned into WM_NULL */
    WORD expired;                   /* translations dropped (window gone, task never ran) */
    DWORD lines;                    /* last SPI_GETWHEELSCROLLLINES value (3 if the call failed) */
    WHEELREC rec[WHEEL_RECS];
} WHEELLOG;

static HHOOK msg_hook;
static MOUSEWHEELINFO FAR *mwi;
static WHEELLOG wlog = { 1 };
static WORD notch_seen;
static BYTE wheel_busy, swallow_on;
static DWORD translated_at;
static HWND pend_hwnd;              /* translation waiting for the target's task */
static int pend_notches;
static DWORD pend_tick;
static WORD pend_seq;
static POINT wpt;                   /* DGROUP: SS is not DS here */
static char wcls[20];
static BYTE wmdb[16];
static DWORD wlines;
static WORD wcode;

static HWND wheel_target(void)
{
    HWND w;
    GetCursorPos(&wpt);
    w = WindowFromPoint(wpt);
    while (w) {
        LONG style = GetWindowLong(w, GWL_STYLE);
        if (style & WS_VSCROLL) return w;
        if (!(style & WS_CHILD)) break;
        w = GetParent(w);
    }
    return 0;
}

/* Module kind of the window's instance: GetModuleHandle of an instance
 * handle (high word 0) is the module database selector. */
static BYTE window_kind(HWND w)
{
    HINSTANCE inst = (HINSTANCE)GetWindowWord(w, GWW_HINSTANCE);
    HMODULE mod;
    BYTE FAR *p;
    WORD i;
    if (!inst) return WM_KIND_UNKNOWN;
    mod = GetModuleHandle((LPCSTR)MAKELP(0, inst));
    if (!mod) return WM_KIND_UNKNOWN;
    p = (BYTE FAR *)MAKELP(mod, 0);
    if (IsBadReadPtr(p, sizeof(wmdb))) return WM_KIND_UNKNOWN;
    for (i = 0; i < sizeof(wmdb); i++) wmdb[i] = p[i];
    return wheel_module_kind(wmdb);
}

static WHEELREC NEAR *wheel_rec(WORD seq)
{
    WHEELREC NEAR *r = &wlog.rec[(seq - 1) % WHEEL_RECS];
    return r->seq == seq ? r : 0;
}

/* The counter moved: decide for the window under the pointer now. */
static void wheel_new(void)
{
    int n = wheel_notches(mwi->notches, notch_seen);
    HWND t = wheel_target();
    BYTE kind = WM_KIND_UNKNOWN, action;
    WHEELREC NEAR *r;
    WORD i;
    notch_seen = mwi->notches;
    wcls[0] = 0;
    if (t) {
        GetClassName(t, wcls, sizeof(wcls));
        kind = window_kind(t);
    }
    action = wheel_decide(1, t != 0, kind, wcls);
    r = &wlog.rec[wlog.seq % WHEEL_RECS];
    r->seq = ++wlog.seq;
    r->tick = GetTickCount();
    r->notches = n;
    r->action = action;
    r->kind = kind;
    r->hwnd = (WORD)t;
    r->sent = 0;
    r->code = 0;
    for (i = 0; i < sizeof(r->cls); i++) r->cls[i] = wcls[i];
    if (action != WA_TRANSLATE) { swallow_on = 0; return; }
    swallow_on = 1;
    translated_at = r->tick;
    if (pend_hwnd && pend_hwnd != t) wlog.expired++;     /* a new target: the old notches go */
    if (pend_hwnd != t) pend_notches = 0;
    pend_hwnd = t;
    pend_notches += n;
    pend_tick = r->tick;
    pend_seq = r->seq;
    /* Not this task's window: wake its task, which then sends (wheel_send). */
    if (GetWindowTask(t) != GetCurrentTask()) PostMessage(t, WM_NULL, 0, 0L);
}

/* In the target's own task: WM_VSCROLL is a direct call there. */
static void wheel_send(void)
{
    HWND w = pend_hwnd;
    WORD i;
    int count;
    WHEELREC NEAR *r;
    if (!IsWindow(w) || GetTickCount() - pend_tick > 1000) {
        pend_hwnd = 0;
        wlog.expired++;
        return;
    }
    if (GetWindowTask(w) != GetCurrentTask()) return;
    wlines = 0;
    if (!SystemParametersInfo(SPI_GETWHEELSCROLLLINES, 0, &wlines, 0)) wlines = 3;
    wlines &= 0xFFFF;               /* a 16-bit UINT or the 32-bit value */
    wlog.lines = wlines;
    count = wheel_plan(pend_notches, wlines, &wcode);
    pend_hwnd = 0;
    pend_notches = 0;
    for (i = 0; i < (WORD)count; i++) SendMessage(w, WM_VSCROLL, wcode, 0L);
    if (count) SendMessage(w, WM_VSCROLL, WHEEL_SB_ENDSCROLL, 0L);
    if ((r = wheel_rec(pend_seq)) != 0) { r->sent = (WORD)count; r->code = wcode; }
}

LRESULT FAR PASCAL __export __loadds getmsg_proc(int code, WPARAM wp, LPARAM lp)
{
    if (code >= 0 && lp && mwi && !wheel_busy) {
        MSG FAR *m = (MSG FAR *)lp;
        wheel_busy = 1;
        if (mwi->notches != notch_seen) wheel_new();
        if (pend_hwnd) wheel_send();
        if (m->message == WM_MOUSEWHEEL && wheel_swallow(swallow_on, translated_at, m->time)) {
            m->message = WM_NULL;
            wlog.swallowed++;
        }
        wheel_busy = 0;
    }
    return CallNextHookEx(msg_hook, code, wp, lp);
}

/* DRV_ENABLE: 98 / 98 SE / Me with USOSMOUS.DRV v4 (USOSWHEELINFO v2), the
 * wheel not switched off (Wheel=0) and WheelScroll not 0. */
static void wheel_start(void)
{
    FARPROC info;
    MOUSEWHEELINFO FAR *w;
    if (msg_hook || !win9x) return;
    if (!GetPrivateProfileInt("usosmous", "WheelScroll", 1, "SYSTEM.INI")) return;
    info = mouse_export("USOSWHEELINFO");
    if (!info) return;
    w = (MOUSEWHEELINFO FAR *)((DWORD (FAR PASCAL *)(void))info)();
    if (!w || w->version < 2 || w->pref == 1) return;
    mwi = w;
    notch_seen = w->notches;
    swallow_on = 0;
    pend_hwnd = 0;
    msg_hook = SetWindowsHookEx(WH_GETMESSAGE, (HOOKPROC)getmsg_proc, GetModuleHandle("USOSKEY"), 0);
    wlog.enabled = msg_hook != 0;
    if (!msg_hook) mwi = 0;
}

static void wheel_stop(void)
{
    if (msg_hook) { UnhookWindowsHookEx(msg_hook); msg_hook = 0; }
    mwi = 0;
    pend_hwnd = 0;
    wlog.enabled = 0;
}

/* By name from USOSDBG.EXE (task time): the decision log, read only. */
DWORD FAR PASCAL __export __loadds UsosWheelLog(void)
{
    return (DWORD)(WHEELLOG FAR *)&wlog;
}

/* Interrupt time: poll_body and what it calls (translate, keyboard_event,
 * force_key, cad_via_vkd, sync_bios_flags) run from the system timer.
 * Allowed beyond the shared block and the BIOS data area: keybd_event_proc
 * and vkd_entry, nothing else (test_usoskey_timer_safe.py). */
static void __near __loadds poll_body(void)
{
    BYTE use_vkd;
    if (busy || !shared) return;
    busy = 1;
    /* About 1 s of INT 1Ch ticks (every VM counts them down in 386 enhanced
     * mode): the Windows side may pause while a DOS box has the focus, and
     * a short timeout let keys overtake the queued ones. */
    shared->alive = 18;
    if (shared->version >= 2) shared->polls++;
    use_vkd = vkd_entry && (!win9x || dos_focus);
    while (shared->tail != shared->head) {
        BYTE b = shared->ring[shared->tail];
        /* VKD full: keep the byte for the next tick. */
        if (use_vkd) {
            if (!force_key(b)) { shared->refused++; break; }
            shared->forced++;
        } else {
            translate(b);
            shared->forced++;               /* delivered (keybd_event) */
        }
        shared->tail = (shared->tail + 1) & 63;
    }
    busy = 0;
}

/* SYSTEM.DRV timer callback: whatever it interrupted gets all its registers
 * back, the 32-bit halves and FS (a Win32 thread's TIB) included. */
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

#include "usos_resident.h"         /* install_resident / remove_resident */

static int query_bridge(void)
{
    WORD al_out = 0, rseg = 0, roff = 0, magic = 0;
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
    if (shared_sel) FreeSelector(shared_sel);
    shared_sel = AllocSelector(HIWORD((DWORD)(void FAR *)&shared));
    if (!shared_sel) return 0;
    SetSelectorBase(shared_sel, (DWORD)rseg << 4);
    SetSelectorLimit(shared_sel, 0xFFFFL);
    shared = (SHARED FAR *)MAKELP(shared_sel, roff);
    return shared->magic[0] == 'U' && shared->magic[1] == 'S' && shared->magic[2] == 'K' && shared->magic[3] == 'Y';
}

/* C:\USOS9X\USOSVMD.ON (read only): USOSVMD.VXD is deployed, so the DOS-box
 * mouse comes from the VxD (which drains the ring at ring 0 and feeds
 * VMOUSE). The Me DOS-box pause must then stay off, or it would stop the
 * ring while a DOS box is open and starve the VxD. Without the flag the
 * pause is the fallback, unchanged. Checked once. */
static BYTE vmd_on, vmd_on_checked;

static int usosvmd_on(void)
{
    OFSTRUCT of;
    if (!vmd_on_checked) {
        vmd_on_checked = 1;
        vmd_on = OpenFile("C:\\USOS9X\\USOSVMD.ON", &of, OF_EXIST) != HFILE_ERROR;
    }
    return vmd_on;
}

/* Me: the bridge copy came from here, after USER enabled the mouse driver.
 * USOSMOUS.DRV (module MOUSE) registers with the BIOS now; another mouse
 * driver has no USOSATTACH and is left alone. With USOSPAUSE (v3) it is
 * paused first: the DOS-box hook comes at DRV_ENABLE (start), which resumes
 * it. Task time (DRV_LOAD). When USOSVMD.VXD is deployed the guard is left
 * off (the VxD owns the DOS-box mouse). */
static void attach_mouse(void)
{
    FARPROC attach = mouse_export("USOSATTACH");
    if (!attach) return;
    mouse_guard = !usosvmd_on() && mouse_export("USOSPAUSE") != 0;
    if (mouse_guard) mouse_pause(1);
    ((void (FAR PASCAL *)(void))attach)();
}

static int find_bridge(void)
{
    if (query_bridge()) return 1;
    shared = 0;
    install_resident();
    return tsr_mem && query_bridge();
}

static void find_vkd(void)
{
    WORD o = 0, s = 0;
    _asm {
        push es
        push di
        mov ax, 1684h
        mov bx, 000Dh
        xor di, di
        mov es, di
        int 2Fh
        mov o, di
        mov s, es
        pop di
        pop es
    }
    vkd_entry = s ? ((DWORD)s << 16) | o : 0;
}

static int init(void)
{
    HINSTANCE user, keyboard, system;
    BYTE code;
    if (shared) return 1;
    if (!find_bridge()) return 0;
    user = GetModuleHandle("USER");
    keyboard = GetModuleHandle("KEYBOARD");
    system = GetModuleHandle("SYSTEM");
    keybd_event_proc = (DWORD)GetProcAddress(user, MAKEINTRESOURCE(289));
    create_timer = (CREATETIMER)GetProcAddress(system, MAKEINTRESOURCE(2));
    kill_timer = (KILLTIMER)GetProcAddress(system, MAKEINTRESOURCE(3));
    if (!keybd_event_proc || !create_timer || !kill_timer) return 0;
    translate_init(0);
    {   /* BIOS data area: the shift flags (0040:0017/0018/0096). */
        WORD sel = AllocSelector(HIWORD((DWORD)(void FAR *)&shared));
        if (sel) {
            SetSelectorBase(sel, 0x400);
            SetSelectorLimit(sel, 0xFF);
            bda = (BYTE FAR *)MAKELP(sel, 0);
        }
    }
    if (keyboard) {
        MAPVK map = (MAPVK)GetProcAddress(keyboard, MAKEINTRESOURCE(131));
        if (map) for (code = 1; code < sizeof(vk_of); code++) {
            if (is_typing_key(code)) {
                int vk = map(code, 1);
                if (vk > 0 && vk < 255) vk_of[code] = (BYTE)vk;
            }
        }
    }
    {   /* Lock toggles as the BIOS left them (INT 16h AH=02h = 0040:0017). */
        BYTE flags = 0;
        _asm {
            mov ah, 2
            int 16h
            mov flags, al
        }
        translate_set_locks(flags);
    }
    if (GetWinFlags() & WF_ENHANCED) find_vkd();
    win9x = LOBYTE(LOWORD(GetVersion())) >= 4 ||
            (LOBYTE(LOWORD(GetVersion())) == 3 && HIBYTE(LOWORD(GetVersion())) >= 95);
    if (shared->pad == RESIDENT_FROM_WINDOWS) attach_mouse();
    return 1;
}

static void start(void)
{
    if (!timer && shared) timer = create_timer(20, (FARPROC)poll);
    /* DOS-box routing (Windows 9x): without the hook every key takes the
     * keybd_event path, as on the desktop. Mouse guard (Me): the hook ends
     * the pause attach_mouse began; no hook, the mouse stays paused. */
    if (!cbt_hook && ((win9x && vkd_entry) || mouse_guard)) {
        cbt_hook = SetWindowsHookEx(WH_CBT, (HOOKPROC)cbt_proc, GetModuleHandle("USOSKEY"), 0);
        if (mouse_guard) {
            dos_boxes = 0;
            mouse_pause(cbt_hook ? 0 : 2);
        }
    }
    wheel_start();
}

static void unhook(void)
{
    if (cbt_hook) { UnhookWindowsHookEx(cbt_hook); cbt_hook = 0; }
}

/* DRV_DISABLE: the mouse guard keeps its hook (and its DOS-box count). */
static void stop(void)
{
    if (timer) { kill_timer(timer); timer = 0; }
    wheel_stop();
    if (!mouse_guard) unhook();
    dos_focus = 0;
    if (shared) shared->alive = 0;
}

/* DRV_FREE (task time): without the hook the mouse is unguarded, so it is
 * paused first. */
static void release(void)
{
    stop();
    if (mouse_guard) { mouse_pause(2); mouse_guard = 0; }
    unhook();
    remove_resident();
}

LRESULT FAR PASCAL __export __loadds DriverProc(DWORD id, HANDLE driver, UINT msg, LPARAM p1, LPARAM p2)
{
    (void)id; (void)driver; (void)p1; (void)p2;
    switch (msg) {
    case DRV_LOAD:    return init() ? 1L : 0L;
    case DRV_ENABLE:  start(); return 1L;
    case DRV_DISABLE: stop(); return 1L;
    case DRV_FREE:    release(); return 1L;
    case DRV_OPEN:
    case DRV_CLOSE:   return 1L;
    }
    return 0L;
}

int FAR PASCAL __export __loadds WEP(int exit_type)
{
    (void)exit_type;
    stop();
    unhook();
    remove_resident();
    return 1;
}

/* DLL entry (no C runtime): DS = DGROUP, CX = heap size (0). Returns AX = 1.
 * Named __DLLstart_, the symbol wcc -bd refers to (normally libentry.obj). */
#pragma aux dll_entry "__DLLstart_"
void __declspec(naked) __far dll_entry(void)
{
    _asm {
        mov ax, 1
        retf
    }
}
