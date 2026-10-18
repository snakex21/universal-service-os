;*****************************************************************************
; USOSVMD.VXD - USB mouse for MS-DOS boxes under Windows 9x/Me on CSMWrap.
; Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
;
; A Windows 9x VMOUSE mouse minidriver (a VxD) that feeds Windows' own
; virtual mouse device (VMOUSE / *VMD) from the USB mouse data USOS already
; collects, so the standard DOS-box mouse handling works:
;   - windowed DOS boxes: the cursor moves when the DOS app owns the mouse
;     (VMOUSE's per-VM Int 33h emulation / QuickEdit off),
;   - full-screen DOS sessions: Int 33h events,
;   - the Windows desktop keeps its mouse through VMOUSE -> USER's
;     Mouse_Event (when the mouse.drv registers USER's callback with
;     VMOUSE; see usosmous.c's VMOUSE mode).
;
; Data source (no new hardware access): CSMWrap's SeaBIOS serves the USB
; boot-protocol mouse as the BIOS PS/2 pointing device and far-calls the
; INT 15h C207h handler in USOS's DOS TSR (USOSKEY.COM, src/platform/bios/
; msdos/usoskey.S, or the resident copy USOSKEY.DRV installs on Me). That
; handler only stores the 3-byte PS/2 packet in a ring in its own, global,
; conventional-memory block (magic "USKY", version 4). This VxD finds that
; block at ring 0 and drains the mouse ring from a VMM global time-out,
; posting each packet to VMOUSE with VMD_Post_Pointer_Message. VMOUSE then
; scales, converts to pixels and serves the focused VM (system VM or a DOS
; box), exactly as it does for a built-in PS/2 mouse. Because the ring lives
; in global conventional memory and is read from ring 0 through a flat
; linear pointer, this works whichever VM is current - so, unlike the Win16
; USOSMOUS.DRV path, it needs no Me DOS-box pause. The existing pause in
; USOSKEY.DRV/USOSMOUS.DRV stays as the fallback for when this VxD is not
; loaded.
;
; VMOUSE's own PS/2 detection (INT 15h C2xx probing and IRQ 12
; virtualisation) is what hung the X470 under CSMWrap (no 8042), so it must
; not run: this driver calls VMD_Set_Mouse_Data at Device_Init and
; Init_Complete with a non-PS/2 mouse type and a zero IRQ, which makes
; VMOUSE's VMD_Hardware_Init skip all built-in *_Device_Init detection
; (it returns as soon as VMD_Mouse_Type is set and is not PS/2). On a
; UEFI/CSMWrap PC there is no *PNP0F13 PS/2-mouse devnode, so nothing else
; triggers the detection either.
;
; This is USOS's own implementation, written from the public Windows 95/98
; DDK documentation (DOCS\DESGUIDE\MOUSE.DOC, INC32\VMD.INC, INC32\VMM.INC
; and the DDK minidriver sample MOUSE\SAMPLES\MOUSEDRV) - the documented
; VMOUSE minidriver interface (VMD_Set_Mouse_Data, VMD_Post_Pointer_Message)
; and the documented VMM service numbers. No Microsoft code is copied.
;
; Built with OpenWatcom wasm + wlink (format windows vxd); see
; tools/build_win9x_support.py. Host test: tools/tests/legacy_bios/
; test_usosvmd.py.
;*****************************************************************************

.386p
.model flat

;--- VxD service invocation: INT 20h, dd (DeviceID<<16) | Service ---------
VMM_ID          equ 00000001h
VMD_ID          equ 0000000Ch

VxDcall macro id, svc
        int     20h
        dd      (id shl 16) or svc
        endm

; VMM service ordinals (public DDK VMM.INC)
Get_Cur_VM_Handle       equ 01h
Get_Sys_VM_Handle       equ 03h
Test_Cur_VM_Handle      equ 04h
Set_Global_Time_Out     equ 3Ch
Out_Debug_String        equ 0C2h

; VMOUSE (VMD) service ordinals (public DDK VMD.INC service-table order)
VMD_Get_Version                 equ 00h
VMD_Set_Mouse_Type              equ 01h
VMD_Post_Pointer_Message        equ 03h
VMD_Set_Mouse_Data              equ 06h

; VxD control messages (public DDK VMM.INC)
Sys_Critical_Init       equ 0000h
Device_Init             equ 0001h
Init_Complete           equ 0002h
Sys_VM_Terminate        equ 0004h
System_Exit             equ 0005h

; Mouse_Instance flags (public DDK VMD.INC)
MIF_Active              equ 0002h
MIF_Detected            equ 0004h
MIF_NoIRQ               equ 0080h

; VMD mouse type (public DDK VMD.INC) - anything non-zero and not PS/2 (4)
; keeps VMOUSE from running its built-in PS/2 detection.
VMD_Type_Serial         equ 2

; Poll period (ms). Matches the 20 ms Win16 timer path of USOSMOUS.DRV.
POLL_MS                 equ 20

; USOSKEY.COM shared block layout (byte-exact, src/platform/bios/msdos/
; usoskey.S; checked by tools/tests/legacy_bios/test_usosvmd.py).
SB_VERSION      equ 4            ; +4  word: block version (>=4 has the mouse ring)
OFF_VERSION     equ 4
OFF_MALIVE      equ 398          ; +398 byte: mcb stores only while non-zero
OFF_MHEAD       equ 396          ; +396 byte
OFF_MTAIL       equ 397          ; +397 byte
OFF_MCBOFS      equ 400          ; +400 word: offset of the C207h handler (mcb)
OFF_MRING       equ 420          ; +420: 32 x 4-byte packets [status,dx,dy,_]
RING_MASK       equ 31

;=========================== DDB (fixed, preloaded) ==========================
_LDATA segment dword public use32 'LCODE'

        public  USOSVMD_DDB
USOSVMD_DDB label dword
        dd      0                       ; DDB_Next
        dw      400h                    ; DDB_SDK_Version (DDK 4.0)
        dw      0                       ; DDB_Req_Device_Number = Undefined
        db      1                       ; DDB_Dev_Major_Version
        db      0                       ; DDB_Dev_Minor_Version
        dw      0                       ; DDB_Flags
        db      'USOSVMD '              ; DDB_Name (8 chars)
        dd      80000000h               ; DDB_Init_Order = Undefined (after VMOUSE)
        dd      offset USOSVMD_Control  ; DDB_Control_Proc
        dd      0                       ; DDB_V86_API_Proc
        dd      offset USOSVMD_PM_API   ; DDB_PM_API_Proc (status query)
        dd      0                       ; DDB_V86_API_CSIP
        dd      0                       ; DDB_PM_API_CSIP
        dd      0                       ; DDB_Reference_Data
        dd      0                       ; DDB_Service_Table_Ptr
        dd      0                       ; DDB_Service_Table_Size

; --- our state (ring-0 flat) ---
sb_base         dd      0               ; linear base of the "USKY" block, 0 = not found
buttons         db      0               ; last button state
drained         dd      0               ; packets posted (diagnostics)
                db      0,0,0

; Mouse_Instance passed to VMD_Post_Pointer_Message (EDX). VMOUSE reads the
; flags and uses the struct as the "device that produced the event".
mi_inst label dword
        dw      MIF_Detected or MIF_Active or MIF_NoIRQ ; MI_Flags
        dw      0                       ; MI_IO_Base
        db      0                       ; MI_IRQNumber
        db      0                       ; MI_PortNum
        dw      VMD_Type_Serial         ; MI_MouseType
        dd      0                       ; MI_Reference
        dd      0                       ; MI_hDevNode
        dd      0                       ; MI_hIRQ
        dd      0                       ; MI_HWINT
        dd      0                       ; MI_Reset
        dd      0                       ; MI_Disable
        dd      0                       ; MI_Initialize
        dd      0                       ; MI_LoadHandle

msg_init        db      'USOSVMD: loaded',13,10,0

_LDATA ends

;=============================== code ========================================
_LTEXT segment dword public use32 'LCODE'

        public  drain, find_block, timer_cb      ; for tools/tests/.../test_usosvmd.py

;--- tell VMOUSE a (non-PS/2) mouse is present so it skips PS/2 detection ---
set_mouse_data proc near
        ; VMD_Get_Version: AH.AL = version; the one service safe if VMOUSE
        ; is absent. Require >= 4.0.
        VxDcall VMD_ID, VMD_Get_Version
        cmp     ah, 4
        jb      smd_done
        ; VMD_Set_Mouse_Data: AH=type, AL=IRQ, EBX=ballpoint flag,
        ; ECX=ballpoint id, DH=button count, DL=port number.
        mov     ah, VMD_Type_Serial
        xor     al, al                  ; no IRQ (we do not own one)
        xor     ebx, ebx
        xor     ecx, ecx
        mov     dh, 3                   ; 3 buttons
        xor     dl, dl
        VxDcall VMD_ID, VMD_Set_Mouse_Data
smd_done:
        ret
set_mouse_data endp

;--- find the "USKY" block in global conventional memory (ring 0, flat) -----
; Scans the SYSTEM VM's low memory (CB_High_Linear + 0x600 .. + 0x9FC00) on
; paragraph boundaries for the magic, version >= 4 and a non-zero mcb offset,
; and stores the absolute linear address in sb_base. Using the system VM's
; mapping (not the current VM's) means the block is found and read correctly
; even while a DOS VM is current - the TSR / USOSKEY.DRV copy lives in the
; system VM's conventional memory. Harmless to repeat.
find_block proc near
        cmp     dword ptr [sb_base], 0
        jne     fb_ok
        ; EBX = system VM handle -> control block; CB_High_Linear at +4.
        VxDcall VMM_ID, Get_Sys_VM_Handle
        mov     edi, [ebx+4]                    ; CB_High_Linear of the system VM
        lea     esi, [edi+600h]
        mov     ecx, edi
        add     ecx, 9FC00h                     ; scan end
fb_loop:
        cmp     dword ptr [esi], 'YKSU'         ; "USKY" little-endian
        jne     fb_next
        movzx   eax, word ptr [esi+OFF_VERSION]
        cmp     ax, SB_VERSION
        jb      fb_next
        cmp     ax, 100h
        ja      fb_next
        cmp     word ptr [esi+OFF_MCBOFS], 0
        je      fb_next
        mov     [sb_base], esi
        jmp     fb_ok
fb_next:
        add     esi, 16
        cmp     esi, ecx
        jb      fb_loop
        xor     eax, eax                        ; not found
        ret
fb_ok:
        mov     eax, 1
        ret
find_block endp

;--- drain the mouse ring and post each packet to VMOUSE --------------------
; One packet: status/dx/dy. VMOUSE packet AL: bit5=b1(left), bit3=b2(right),
; bit4=b3(middle) (public DDK VMD.INC / MOUSE.DOC). ESI/EDI = deltas; we post
; the X delta as read and negate the PS/2 Y so down is positive, matching
; Mouse_Event. EDX -> our Mouse_Instance.
drain proc near
        call    find_block
        test    eax, eax
        jz      drain_done
        mov     ebx, [sb_base]
        mov     byte ptr [ebx+OFF_MALIVE], 18   ; keep the TSR storing packets
dr_loop:
        mov     al, [ebx+OFF_MTAIL]
        cmp     al, [ebx+OFF_MHEAD]
        je      drain_done
        movzx   edx, al
        shl     edx, 2
        lea     esi, [ebx+edx+OFF_MRING]        ; -> packet
        mov     cl, [esi]                       ; status
        ; advance tail (wrap 32)
        inc     al
        and     al, RING_MASK
        mov     [ebx+OFF_MTAIL], al
        ; overflow bits: no valid motion
        test    cl, 0C0h
        jnz     dr_loop
        ; deltas with PS/2 sign bits (status bit4 = dx sign, bit5 = dy sign)
        movzx   eax, byte ptr [esi+1]           ; dx
        test    cl, 10h
        jz      dr_dxp
        or      eax, 0FFFFFF00h
dr_dxp:
        mov     edi, eax                        ; stash dx
        movzx   eax, byte ptr [esi+2]           ; dy
        test    cl, 20h
        jz      dr_dyp
        or      eax, 0FFFFFF00h
dr_dyp:
        neg     eax                             ; PS/2 up-positive -> down-positive
        push    edi                             ; dx
        push    eax                             ; dy
        ; button status -> VMOUSE AL
        xor     al, al
        test    cl, 1                           ; left
        jz      dr_nl
        or      al, 20h                         ; b1
dr_nl:
        test    cl, 2                           ; right
        jz      dr_nr
        or      al, 08h                         ; b2
dr_nr:
        test    cl, 4                           ; middle
        jz      dr_nm
        or      al, 10h                         ; b3
dr_nm:
        pop     edi                             ; dy -> EDI
        pop     esi                             ; dx -> ESI
        mov     edx, offset mi_inst
        push    ebx
        push    ecx
        VxDcall VMD_ID, VMD_Post_Pointer_Message
        pop     ecx
        pop     ebx
        inc     dword ptr [drained]
        jmp     dr_loop
drain_done:
        ret
drain endp

;--- global time-out callback: drain, then re-arm ---------------------------
; Entry (public DDK): EAX = ms the time-out was late, EBX = current VM.
; Must preserve nothing in particular for VMM; we save what we use.
timer_cb proc near
        pushad
        call    drain
        popad
        ; re-arm
        mov     eax, POLL_MS
        mov     edx, 0
        mov     esi, offset timer_cb
        VxDcall VMM_ID, Set_Global_Time_Out
        ret
timer_cb endp

;--- VxD control procedure --------------------------------------------------
; Dispatch on EAX = message. Return with carry clear = success.
        public  USOSVMD_Control
USOSVMD_Control proc near
        cmp     eax, Device_Init
        je      c_devinit
        cmp     eax, Init_Complete
        je      c_initcomplete
        clc
        ret
c_devinit:
        call    set_mouse_data
        clc
        ret
c_initcomplete:
        call    set_mouse_data
        ; arm the drain time-out once
        mov     eax, POLL_MS
        mov     edx, 0
        mov     esi, offset timer_cb
        VxDcall VMM_ID, Set_Global_Time_Out
        clc
        ret
USOSVMD_Control endp

;--- PM API: a status query for USOSMOUS.DRV / tools ------------------------
; INT 2Fh AX=1684h returns this entry; the caller sets AX = function:
;   0 -> AX = 'UV' signature, BX = version (0100h), CX = packets drained low,
;        DX = 1 if the "USKY" block was found else 0.
; Entry: EBP -> Client_Reg_Struc (we write Client_EAX/EBX/ECX/EDX). We keep
; it tiny and only implement function 0.
        public  USOSVMD_PM_API
USOSVMD_PM_API proc near
        ; Client_Reg_Struc: EAX at +1Ch, EBX +10h, ECX +18h, EDX +14h.
        mov     eax, [ebp+1Ch]
        and     eax, 0FFFFh
        jnz     api_done
        mov     dword ptr [ebp+1Ch], 5655h      ; 'UV'
        mov     dword ptr [ebp+10h], 0100h
        mov     eax, [drained]
        mov     [ebp+18h], eax
        xor     eax, eax
        cmp     dword ptr [sb_base], 0
        je      api_nofound
        inc     eax
api_nofound:
        mov     [ebp+14h], eax
api_done:
        clc
        ret
USOSVMD_PM_API endp

_LTEXT ends

end
