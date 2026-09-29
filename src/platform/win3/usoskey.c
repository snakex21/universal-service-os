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
 *   standard mode (no VKD): the driver translates to a virtual key (the
 *     stock driver's MapVirtualKey for the typing keys, so QWERTZ/AZERTY
 *     layouts keep their VKs; a fixed table for the rest) and calls USER's
 *     keyboard event procedure (keybd_event, USER.289) like KEYBOARD.DRV's
 *     interrupt handler does; ToAscii stays the stock driver's.
 * No OpenWatcom runtime is linked (own entry point, -zl): the binary is only
 * this file plus import records. docs/design/bios-via-csmwrap.md.
 */
#include <windows.h>

typedef struct {
    char magic[4];
    WORD version;
    BYTE head, tail, alive, pad;
    WORD dropped, captured, passed;
    BYTE ring[64];
    WORD forced, refused;           /* diagnostics */
} SHARED;

typedef WORD (FAR PASCAL *CREATETIMER)(WORD, FARPROC);
typedef WORD (FAR PASCAL *KILLTIMER)(WORD);
typedef int (FAR PASCAL *MAPVK)(WORD, WORD);

static SHARED FAR *shared;
static WORD shared_sel;
static DWORD keybd_event_proc;      /* USER.289, register interface */
static DWORD vkd_entry;             /* VKD PM API (enhanced mode) */
static CREATETIMER create_timer;
static KILLTIMER kill_timer;
static WORD timer;
static BYTE busy;
static BYTE prefix;                 /* 0 or 0E0h */
static BYTE e1_left;                /* bytes of an E1 (Pause) sequence to skip */
static BYTE e1_make;
static BYTE numlock, lshift, rshift, alt;
static BYTE vk_of[0x59];            /* non-extended scan code -> VK */

/* US enhanced (101/102) keyboard, set 1; the typing keys are replaced by the
 * stock driver's MapVirtualKey(scan, 1) when it knows them. */
static const BYTE vk_us[0x59] = {
    0,    0x1B, '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  '0',  0xBD, 0xBB, 0x08, 0x09,
    'Q',  'W',  'E',  'R',  'T',  'Y',  'U',  'I',  'O',  'P',  0xDB, 0xDD, 0x0D, 0x11, 'A',  'S',
    'D',  'F',  'G',  'H',  'J',  'K',  'L',  0xBA, 0xDE, 0xC0, 0x10, 0xDC, 'Z',  'X',  'C',  'V',
    'B',  'N',  'M',  0xBC, 0xBE, 0xBF, 0x10, 0x6A, 0x12, 0x20, 0x14, 0x70, 0x71, 0x72, 0x73, 0x74,
    0x75, 0x76, 0x77, 0x78, 0x79, 0x90, 0x91, 0x24, 0x26, 0x21, 0x6D, 0x25, 0x0C, 0x27, 0x6B, 0x23,
    0x28, 0x22, 0x2D, 0x2E, 0,    0,    0xE2, 0x7A, 0x7B
};
/* Numeric keypad with NumLock on (scan 47h..53h). */
static const BYTE vk_numpad[13] = { 0x67, 0x68, 0x69, 0x6D, 0x64, 0x65, 0x66, 0x6B, 0x61, 0x62, 0x63, 0x60, 0x6E };

static int is_typing_key(BYTE code)
{
    return (code >= 0x02 && code <= 0x0D) || (code >= 0x10 && code <= 0x1B) ||
           (code >= 0x1E && code <= 0x29) || (code >= 0x2B && code <= 0x35) || code == 0x56;
}

static BYTE extended_vk(BYTE code)
{
    switch (code) {
    case 0x1C: return 0x0D;   /* keypad Enter */
    case 0x1D: return 0x11;   /* right Ctrl */
    case 0x35: return 0x6F;   /* keypad / */
    case 0x37: return 0x2C;   /* Print Screen */
    case 0x38: return 0x12;   /* right Alt (AltGr) */
    case 0x46: return 0x03;   /* Ctrl+Break */
    case 0x47: return 0x24;
    case 0x48: return 0x26;
    case 0x49: return 0x21;
    case 0x4B: return 0x25;
    case 0x4D: return 0x27;
    case 0x4F: return 0x23;
    case 0x50: return 0x28;
    case 0x51: return 0x22;
    case 0x52: return 0x2D;
    case 0x53: return 0x2E;
    }
    return 0;                 /* E0 2A/36 fake shifts, Windows keys: none */
}

static void keyboard_event(WORD ax_value, WORD bx_value)
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
        mov ax, 1             ; VKD_API_Force_Key
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

/* Standard mode: one raw byte -> keybd_event, like KEYBOARD.DRV's INT 9. */
static void translate(BYTE b)
{
    BYTE up, code, ext, vk;
    if (e1_left) {
        e1_left--;
        if (e1_left == 0 && e1_make) {
            keyboard_event(0x0013, 0x0045);           /* VK_PAUSE down */
            keyboard_event(0x8013, 0x0045);           /* and up */
        }
        if ((b & 0x7F) == 0x1D) e1_make = (b & 0x80) == 0;
        return;
    }
    if (b == 0xE0) { prefix = 0xE0; return; }
    if (b == 0xE1) { e1_left = 2; e1_make = 0; prefix = 0; return; }
    up = b & 0x80;
    code = b & 0x7F;
    ext = prefix == 0xE0;
    prefix = 0;
    if (ext) {
        vk = extended_vk(code);
    } else {
        if (code >= sizeof(vk_of)) return;
        vk = vk_of[code];
        if (code == 0x2A) lshift = !up;
        if (code == 0x36) rshift = !up;
        if (code >= 0x47 && code <= 0x53 && numlock && !lshift && !rshift)
            vk = vk_numpad[code - 0x47];
        if (code == 0x45 && !up) numlock = !numlock;
    }
    if (code == 0x38) alt = !up;
    if (!vk) return;
    /* PrtSc: BL = 0 whole screen, 1 active window (Alt). */
    if (vk == 0x2C) code = alt ? 1 : 0;
    keyboard_event((WORD)vk | (up ? 0x8000 : 0), (WORD)code | (ext ? 0x0100 : 0));
}

void __far __loadds __saveregs poll(void)
{
    if (busy || !shared) return;
    busy = 1;
    /* About 1 s of INT 1Ch ticks (every VM counts them down in 386 enhanced
     * mode): the Windows side may pause while a DOS box has the focus, and
     * a short timeout let keys overtake the queued ones. */
    shared->alive = 18;
    while (shared->tail != shared->head) {
        BYTE b = shared->ring[shared->tail];
        /* VKD full: keep the byte for the next tick. */
        if (vkd_entry) {
            if (!force_key(b)) { shared->refused++; break; }
            shared->forced++;
        } else translate(b);
        shared->tail = (shared->tail + 1) & 63;
    }
    busy = 0;
}

static int find_bridge(void)
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
    shared_sel = AllocSelector(HIWORD((DWORD)(void FAR *)&shared));
    if (!shared_sel) return 0;
    SetSelectorBase(shared_sel, (DWORD)rseg << 4);
    SetSelectorLimit(shared_sel, 0xFFFFL);
    shared = (SHARED FAR *)MAKELP(shared_sel, roff);
    return shared->magic[0] == 'U' && shared->magic[1] == 'S' && shared->magic[2] == 'K' && shared->magic[3] == 'Y';
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
    for (code = 0; code < sizeof(vk_of); code++) vk_of[code] = vk_us[code];
    if (keyboard) {
        MAPVK map = (MAPVK)GetProcAddress(keyboard, MAKEINTRESOURCE(131));
        if (map) for (code = 1; code < sizeof(vk_of); code++) {
            if (is_typing_key(code)) {
                int vk = map(code, 1);
                if (vk > 0 && vk < 255) vk_of[code] = (BYTE)vk;
            }
        }
    }
    {   /* NumLock as the BIOS left it (INT 16h AH=02h, AL bit 5). */
        BYTE flags = 0;
        _asm {
            mov ah, 2
            int 16h
            mov flags, al
        }
        numlock = (flags & 0x20) != 0;
    }
    if (GetWinFlags() & WF_ENHANCED) find_vkd();
    return 1;
}

static void start(void)
{
    if (!timer && shared) timer = create_timer(20, (FARPROC)poll);
}

static void stop(void)
{
    if (timer) { kill_timer(timer); timer = 0; }
    if (shared) shared->alive = 0;
}

LRESULT FAR PASCAL __export __loadds DriverProc(DWORD id, HANDLE driver, UINT msg, LPARAM p1, LPARAM p2)
{
    (void)id; (void)driver; (void)p1; (void)p2;
    switch (msg) {
    case DRV_LOAD:    return init() ? 1L : 0L;
    case DRV_ENABLE:  start(); return 1L;
    case DRV_DISABLE: stop(); return 1L;
    case DRV_FREE:    stop(); return 1L;
    case DRV_OPEN:
    case DRV_CLOSE:   return 1L;
    }
    return 0L;
}

int FAR PASCAL __export __loadds WEP(int exit_type)
{
    (void)exit_type;
    stop();
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
