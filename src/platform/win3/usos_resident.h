/*
 * usos_resident.h - the USOSKEY.COM resident part installed from Windows.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Shared by USOSKEY.DRV and USOSMOUS.DRV (include after usoskey_tsr.h).
 * Windows Me starts no real-mode program from AUTOEXEC.BAT, so there is no
 * USOSKEY.COM TSR: whichever driver Windows loads first without finding the
 * bridge (INT 2Fh AX=D700h) puts a copy of the resident part (tsr_image, up
 * to resident_end) at offset 0100h of a DOS block (GlobalDosAlloc, system VM)
 * and hooks INT 08h/09h/15h/16h/1Ch/2Fh in the system VM's real-mode vector
 * table (DPMI 0200h/0201h). On Me USER loads and asks the mouse driver
 * (Inquire) before the installable drivers of [boot] drivers=, so
 * USOSMOUS.DRV is the first one there. The block is never freed (the other
 * driver may still read it); remove_resident only gives back the vectors
 * that still point at the copy. The copy marks itself in the shared block's
 * byte +9 (unused by the TSR, 0 there) with 'W': the bridge comes from
 * Windows, i.e. no AUTOEXEC.BAT ran USOSKEY.COM (Me).
 */
#define RESIDENT_FROM_WINDOWS 'W'
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
    if (tsr_mem) return;
    tsr_mem = GlobalDosAlloc(0x100 + sizeof(tsr_image));
    if (!tsr_mem) return;
    seg = HIWORD(tsr_mem);
    p = (BYTE FAR *)MAKELP(LOWORD(tsr_mem), 0);
    for (i = 0; i < sizeof(tsr_image); i++) p[0x100 + i] = tsr_image[i];
    p[TSR_SHARED + 9] = RESIDENT_FROM_WINDOWS;
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
