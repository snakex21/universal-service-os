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
 * vectors are restored when the driver is freed.
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

/* Windows 9x: WH_CBT hook, called in the context of the thread that
 * activates a window (never at interrupt time): is the new active window a
 * DOS box (WinOldAp, class "tty")? Only the flag reaches the timer. */
LRESULT FAR PASCAL __export __loadds cbt_proc(int code, WPARAM wp, LPARAM lp)
{
    if (code == HCBT_ACTIVATE) {
        char name[8];
        HWND w = (HWND)wp;
        dos_focus = w && GetClassName(w, name, sizeof(name)) == 3 &&
                    (name[0] | 0x20) == 't' && (name[1] | 0x20) == 't' && (name[2] | 0x20) == 'y';
    }
    return CallNextHookEx(cbt_hook, code, wp, lp);
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

#define TSR_HOOKS 6
static const BYTE tsr_ints[TSR_HOOKS] = { 0x08, 0x09, 0x15, 0x16, 0x1C, 0x2F };
static const WORD tsr_handler[TSR_HOOKS] = { TSR_INT08, TSR_INT09, TSR_INT15, TSR_INT16, TSR_INT1C, TSR_INT2F };
static const WORD tsr_old_slot[TSR_HOOKS] = { TSR_OLD08, TSR_OLD09, TSR_OLD15, TSR_OLD16, TSR_OLD1C, TSR_OLD2F };
static DWORD tsr_mem;               /* GlobalDosAlloc: segment:selector */

static DWORD get_rm_vector(BYTE n)
{
    WORD s = 0, o = 0;
    _asm {
        mov ax, 0200h
        mov bl, n
        int 31h
        mov s, cx
        mov o, dx
    }
    return ((DWORD)s << 16) | o;
}

static void set_rm_vector(BYTE n, DWORD v)
{
    WORD s = HIWORD(v), o = LOWORD(v);
    _asm {
        mov ax, 0201h
        mov bl, n
        mov cx, s
        mov dx, o
        int 31h
    }
}

/* The TSR's resident part at offset 0100h of a DOS block, as if loaded. */
static void install_resident(void)
{
    BYTE FAR *p;
    WORD i, seg;
    tsr_mem = GlobalDosAlloc(0x100 + sizeof(tsr_image));
    if (!tsr_mem) return;
    seg = HIWORD(tsr_mem);
    p = (BYTE FAR *)MAKELP(LOWORD(tsr_mem), 0);
    for (i = 0; i < sizeof(tsr_image); i++) p[0x100 + i] = tsr_image[i];
    for (i = 0; i < TSR_HOOKS; i++) *(DWORD FAR *)(p + tsr_old_slot[i]) = get_rm_vector(tsr_ints[i]);
    _asm cli
    for (i = 0; i < TSR_HOOKS; i++) set_rm_vector(tsr_ints[i], ((DWORD)seg << 16) | tsr_handler[i]);
    _asm sti
}

static void remove_resident(void)
{
    BYTE FAR *p;
    WORD i, seg;
    if (!tsr_mem) return;
    seg = HIWORD(tsr_mem);
    p = (BYTE FAR *)MAKELP(LOWORD(tsr_mem), 0);
    /* Only vectors that still point at the copy go back. */
    for (i = 0; i < TSR_HOOKS; i++)
        if (get_rm_vector(tsr_ints[i]) == (((DWORD)seg << 16) | tsr_handler[i]))
            set_rm_vector(tsr_ints[i], *(DWORD FAR *)(p + tsr_old_slot[i]));
}

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
    return 1;
}

static void start(void)
{
    if (!timer && shared) timer = create_timer(20, (FARPROC)poll);
    /* DOS-box routing (Windows 9x): without the hook every key takes the
     * keybd_event path, as on the desktop. */
    if (win9x && vkd_entry && !cbt_hook)
        cbt_hook = SetWindowsHookEx(WH_CBT, (HOOKPROC)cbt_proc, GetModuleHandle("USOSKEY"), 0);
}

static void stop(void)
{
    if (timer) { kill_timer(timer); timer = 0; }
    if (cbt_hook) { UnhookWindowsHookEx(cbt_hook); cbt_hook = 0; }
    dos_focus = 0;
    if (shared) shared->alive = 0;
}

LRESULT FAR PASCAL __export __loadds DriverProc(DWORD id, HANDLE driver, UINT msg, LPARAM p1, LPARAM p2)
{
    (void)id; (void)driver; (void)p1; (void)p2;
    switch (msg) {
    case DRV_LOAD:    return init() ? 1L : 0L;
    case DRV_ENABLE:  start(); return 1L;
    case DRV_DISABLE: stop(); return 1L;
    case DRV_FREE:    stop(); remove_resident(); return 1L;
    case DRV_OPEN:
    case DRV_CLOSE:   return 1L;
    }
    return 0L;
}

int FAR PASCAL __export __loadds WEP(int exit_type)
{
    (void)exit_type;
    stop();
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
