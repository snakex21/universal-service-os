/*
 * usoskey_xlat.h - set-1 scan codes -> Windows virtual-key events for
 * USOSKEY.DRV (src/platform/win3/usoskey.c).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Plain C (no Windows headers, no inline assembly) so the host test
 * tools/tests/legacy_bios/test_usoskey_xlat.py compiles it unchanged. The
 * includer provides BYTE/WORD and:
 *   xlat_event(ax, bx)  USER's keybd_event register interface: AL = VK,
 *                       AH = 80h for a key release, BL = scan code,
 *                       BH bit 0 = extended (E0) key
 *   xlat_cad()          Ctrl+Alt+Del was pressed (USOSKEY.DRV hands it to
 *                       VKD, whose hot key opens the 9x Close Program box)
 *
 * The bytes come from SeaBIOS (CSMWrap 3.1.2, src/hw/usb-hid.c prockeys):
 *   - E0-prefixed keys: E0 xx make, E0 xx|80h break; no fake shifts are
 *     generated (E0 2A / E0 AA are ignored anyway, as a PS/2 keyboard sends)
 *   - Pause: E1 1D 45 on press, E1 9D C5 on release; Ctrl+Pause: E0 46 / E0 C6
 *   - Print Screen: E0 37; Alt+Print Screen: 54h (SysReq)
 *   - Windows keys: E0 5B / E0 5C (USB modifiers); USB Application (Menu)
 *     and the ISO 102nd key are not in SeaBIOS's table: never produced
 *   - typematic: the last pressed non-modifier key repeats as plain makes
 */

#define VK_CANCEL_    0x03
#define VK_CONTROL_   0x11
#define VK_MENU_      0x12
#define VK_PAUSE_     0x13
#define VK_SNAPSHOT_  0x2C
#define VK_DELETE_    0x2E

static BYTE prefix;                 /* last byte was E0 */
static BYTE e1_left;                /* bytes of an E1 (Pause) sequence still to come */
static BYTE e1_up;
static BYTE numlock;                /* NumLock toggle (keypad digits) */
static BYTE lshift, rshift, lctrl, rctrl, lalt, ralt;
static BYTE altgr_ctrl;             /* Ctrl down sent for AltGr */
static BYTE cad_held;               /* Del of a Ctrl+Alt+Del is down */
static BYTE locks_down;             /* 1 Caps, 2 Num, 4 Scroll: typematic filter */
static BYTE vk_of[0x59];            /* non-extended scan code -> VK */

/* US enhanced (101/102) keyboard, set 1; USOSKEY.DRV replaces the typing
 * keys by the stock driver's MapVirtualKey(scan, 1) when it knows them. */
static const BYTE vk_us[0x59] = {
    0,    0x1B, '1',  '2',  '3',  '4',  '5',  '6',  '7',  '8',  '9',  '0',  0xBD, 0xBB, 0x08, 0x09,
    'Q',  'W',  'E',  'R',  'T',  'Y',  'U',  'I',  'O',  'P',  0xDB, 0xDD, 0x0D, 0x11, 'A',  'S',
    'D',  'F',  'G',  'H',  'J',  'K',  'L',  0xBA, 0xDE, 0xC0, 0x10, 0xDC, 'Z',  'X',  'C',  'V',
    'B',  'N',  'M',  0xBC, 0xBE, 0xBF, 0x10, 0x6A, 0x12, 0x20, 0x14, 0x70, 0x71, 0x72, 0x73, 0x74,
    0x75, 0x76, 0x77, 0x78, 0x79, 0x90, 0x91, 0x24, 0x26, 0x21, 0x6D, 0x25, 0x0C, 0x27, 0x6B, 0x23,
    0x28, 0x22, 0x2D, 0x2E, 0x2C, 0,    0xE2, 0x7A, 0x7B
};
/* Numeric keypad with NumLock on (scan 47h..53h). */
static const BYTE vk_numpad[13] = { 0x67, 0x68, 0x69, 0x6D, 0x64, 0x65, 0x66, 0x6B, 0x61, 0x62, 0x63, 0x60, 0x6E };

static int is_typing_key(BYTE code)
{
    return (code >= 0x02 && code <= 0x0D) || (code >= 0x10 && code <= 0x1B) ||
           (code >= 0x1E && code <= 0x29) || (code >= 0x2B && code <= 0x35) || code == 0x56;
}

/* E0 xx -> VK, fixed: never the layout's MapVirtualKey. */
static BYTE extended_vk(BYTE code)
{
    switch (code) {
    case 0x1C: return 0x0D;   /* keypad Enter */
    case 0x1D: return 0x11;   /* right Ctrl */
    case 0x35: return 0x6F;   /* keypad / */
    case 0x37: return 0x2C;   /* Print Screen */
    case 0x38: return 0x12;   /* right Alt (AltGr) */
    case 0x46: return 0x03;   /* Ctrl+Break */
    case 0x47: return 0x24;   /* Home */
    case 0x48: return 0x26;   /* Up */
    case 0x49: return 0x21;   /* Page Up */
    case 0x4B: return 0x25;   /* Left */
    case 0x4D: return 0x27;   /* Right */
    case 0x4F: return 0x23;   /* End */
    case 0x50: return 0x28;   /* Down */
    case 0x51: return 0x22;   /* Page Down */
    case 0x52: return 0x2D;   /* Insert */
    case 0x53: return 0x2E;   /* Delete */
    case 0x5B: return 0x5B;   /* left Windows */
    case 0x5C: return 0x5C;   /* right Windows */
    case 0x5D: return 0x5D;   /* Application (Menu) */
    }
    return 0;                 /* E0 2A/36 fake shifts, ACPI keys: none */
}

static void key_event(BYTE vk, BYTE up, BYTE scan, BYTE ext)
{
    xlat_event((WORD)vk | (up ? 0x8000 : 0), (WORD)scan | (ext ? 0x0100 : 0));
}

static void translate_init(BYTE numlock_on)
{
    BYTE code;
    for (code = 0; code < sizeof(vk_of); code++) vk_of[code] = vk_us[code];
    prefix = e1_left = e1_up = 0;
    lshift = rshift = lctrl = rctrl = lalt = ralt = 0;
    altgr_ctrl = cad_held = locks_down = 0;
    numlock = numlock_on;
}

/* One raw byte -> keybd_event, like KEYBOARD.DRV's INT 9 handler. */
static void translate(BYTE b)
{
    BYTE up, code, ext, vk, lock;
    if (e1_left) {                          /* E1 1D 45 / E1 9D C5 */
        e1_left--;
        if (e1_left == 1) e1_up = b & 0x80;
        else key_event(VK_PAUSE_, e1_up, 0x45, 0);
        return;
    }
    if (b == 0xE0) { prefix = 1; return; }
    if (b == 0xE1) { e1_left = 2; prefix = 0; return; }
    up = b & 0x80;
    code = b & 0x7F;
    ext = prefix;
    prefix = 0;

    if (ext) {
        vk = extended_vk(code);
        if (code == 0x1D) rctrl = !up;
        if (code == 0x38) ralt = !up;
    } else {
        if (code >= sizeof(vk_of)) return;
        vk = vk_of[code];
        if (code == 0x2A) lshift = !up;
        if (code == 0x36) rshift = !up;
        if (code == 0x1D) lctrl = !up;
        if (code == 0x38) lalt = !up;
        /* Lock keys: one event per press (SeaBIOS repeats a held key). */
        lock = code == 0x3A ? 1 : code == 0x45 ? 2 : code == 0x46 ? 4 : 0;
        if (lock) {
            if (up) locks_down &= (BYTE)~lock;
            else if (locks_down & lock) return;
            else {
                locks_down |= lock;
                if (lock == 2) numlock = !numlock;
            }
        }
        if (code >= 0x47 && code <= 0x53 && numlock && !lshift && !rshift)
            vk = vk_numpad[code - 0x47];
    }
    if (!vk) return;

    /* Ctrl+Alt+Del (also keypad Del): VKD's hot key, not a Delete key. */
    if (code == 0x53) {
        if (!up && (lctrl || rctrl) && (lalt || ralt)) {
            if (!cad_held) { cad_held = 1; xlat_cad(); }
            return;
        }
        if (up && cad_held) { cad_held = 0; return; }
    }

    /* AltGr = Ctrl+Alt for the 9x layouts (Polish programmer: AltGr+A = a
     * with ogonek): KEYBOARD.DRV's ToAscii looks at VK_CONTROL + VK_MENU. */
    if (ext && code == 0x38) {
        if (!up) {
            if (!altgr_ctrl && !lctrl && !rctrl) {
                altgr_ctrl = 1;
                key_event(VK_CONTROL_, 0, 0x1D, 0);
            }
            key_event(VK_MENU_, 0, 0x38, 1);
        } else {
            key_event(VK_MENU_, 1, 0x38, 1);
            if (altgr_ctrl) {
                altgr_ctrl = 0;
                if (!lctrl && !rctrl) key_event(VK_CONTROL_, 1, 0x1D, 0);
            }
        }
        return;
    }
    /* A real Ctrl released while AltGr still holds the emulated one. */
    if (code == 0x1D && up && altgr_ctrl && !lctrl && !rctrl) return;

    /* Print Screen: BL = 0 whole screen, 1 active window (Alt / SysReq). */
    if (vk == VK_SNAPSHOT_) code = (lalt || ralt || code == 0x54) ? 1 : 0;
    key_event(vk, up, code, ext);
}
