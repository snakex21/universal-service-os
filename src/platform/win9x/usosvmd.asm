;*****************************************************************************
; USOSVMD.VXD - USB mouse for MS-DOS boxes under Windows 9x/Me on CSMWrap.
; Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
;
; A Windows 9x VMOUSE mouse minidriver (a VxD) that feeds Windows' own
; virtual mouse device (VMOUSE / *VMD) from the USB mouse that CSMWrap's
; SeaBIOS serves as the BIOS PS/2 pointing device, so the standard DOS-box
; mouse handling works:
;   - windowed DOS boxes: VMOUSE's per-VM Int 33h emulation (QuickEdit off),
;   - full-screen DOS sessions: Int 33h events,
;   - the Windows desktop through VMOUSE -> USER's Mouse_Event (USOSMOUS.DRV
;     hands USER's event procedure to VMOUSE in its VMOUSE mode).
;
; Version 2 (2026-10-19): the BIOS callback is a VMM V86 callback.
; SeaBIOS keeps ONE INT 15h C207h far pointer for the whole machine and
; far-calls it from its USB poll (INT 08h), in whatever VM is current. The
; v1 design registered USOSKEY's `mcb` there; on Windows Me that code is a
; copy in the system VM's GlobalDosAlloc block (private V86 memory), so a
; poll landing while a DOS VM is current would have executed whatever that
; DOS VM has at the same address (the "Me callback hazard"; v3's DOS-box
; pause in USOSKEY.DRV exists only because of it). Now USOSMOUS.DRV, in
; VMOUSE mode, registers the address of a callback allocated here with
; Allocate_V86_Call_Back: a VMM breakpoint in global V86 memory, valid in
; every VM, that traps to ring 0 (EBX = the VM that was current). The
; packet words are read from that VM's stack through its own high linear
; mapping, so no V86 code in any private memory is ever run for the mouse.
;
; Version 3 (2026-10-19), after a Windows Me boot bluescreen on the X470
; ("VMM(01) + 00009676 Error 0E : 0028 : C000A676"):
;   - the DDB is the full 0x50-byte 4.0 VxD_Desc_Block. v2 stopped at
;     DDB_Service_Table_Size and kept its status block at DDB+38h, so
;     Device_Init wrote the VMOUSE version over DDB_Prev (+3Ch), the chain
;     VMM walks backwards for its reverse-order control messages; VMM then
;     called "[garbage+18h]" (confirmed in Me's VMM: object 1 + 963Fh walks
;     DDB_Prev, + 9676h is the call through DDB_Control_Proc);
;   - the V86 callback reads the arguments above SeaBIOS's far return
;     address and returns with Simulate_Far_Ret (VMM does not do it; v2
;     would have re-run the breakpoint for ever on the first packet);
;   - Init_Complete and every time-out check that VMM-visible DDB fields we
;     own (DDB_Size, DDB_Reserved1..3) are intact (err bit 80h otherwise).
;
; Version 3.1 (2026-10-19), after "right button does nothing" on the X470
; (Windows Me; left, motion and the DOS boxes worked):
;   - the VMOUSE button byte. v3 posted right = 08h and middle = 10h (the
;     DDK reference table read as b2/b3). VMOUSE itself decodes AL with
;     two masks, PrimaryButton 20h and SecondaryButton 10h by default
;     (registry values of the same names, button numbers indexing the
;     table 20h, 08h, 10h, 04h), and 04h as the middle button; Windows Me's
;     VMOUSE takes 08h as a fourth button (98 SE: 08h folds into the middle
;     button). So v3's right button was a 4th / middle button and its
;     middle button the right one. Now left 20h, right 10h, middle 04h;
;   - one VMD_Post_Pointer_Message per time-out. VMOUSE keeps ONE pending
;     message: a post while its event (Call_Priority_VM_Event) has not run
;     yet is dropped. v3 posted every queued packet in a loop, so all but
;     the first packet of a time-out were lost (a press or release among
;     them with it). Now the time-out sums the packets with the same button
;     state and stops at a button change (the rest waits for the next
;     time-out, 20 ms later), and a time-out with nothing queued repeats
;     the last button change once, without motion (VMOUSE compares with its
;     own state, so a repeat that arrives twice changes nothing).
;   Both from a behaviour analysis of Windows Me's VMOUSE.VXD and the 98 SE
;   DDK debug VMOUSE.VXD (with its symbol file) supplied by the user; only
;   the facts were taken, no code.
;
; Per packet the callback
;   - queues it in this driver's own ring (posted to VMOUSE from a 20 ms
;     global time-out with VMD_Post_Pointer_Message, one message per
;     time-out: buttons mapped to the VMOUSE AL format, X as read, Y
;     negated), only while this driver owns VMOUSE's mouse data (see below);
;   - copies it into USOSKEY's shared-block mouse ring (magic "USKY", v4) in
;     the system VM, through the system VM's high linear mapping: USOSMOUS
;     .DRV's timer takes only the wheel byte (Z word, CSMWrap patch 0016 /
;     0020) from there in VMOUSE mode and sends it to USER (AX=0800h), since
;     VMOUSE has no wheel. The shared block is given to this driver by
;     USOSMOUS.DRV (PM API function 1), never searched.
;
; VMOUSE's own PS/2 detection (INT 15h C2xx probing and IRQ 12) hung the
; X470 under CSMWrap (no 8042) and on Me resets the emulated mouse ID to 0,
; so at Device_Init this driver claims VMOUSE's mouse data with
; VMD_Set_Mouse_Data (non-PS/2 type, no IRQ) when VMOUSE has none yet
; (VMD_Get_Mouse_Data type 0). If VMOUSE already has a mouse (another
; minidriver or its built-in PS/2 code got there first), or it changes to
; another type later, this driver does not post at all ("observer": no
; duplicate pointer motion) and USOSMOUS.DRV stays on its own path; the
; state is in the status block for USOSDBG.
;
; PM API (INT 2Fh AX=1684h BX=0 ES:DI -> "USOSVMD "), AX = function:
;   0  status: AX='UV', BX=version 0301h, CX=callbacks (low word),
;      DX=mode (0 VMOUSE absent, 1 minidriver, 2 observer)
;   1  attach: BX:CX = segment:offset of USOSKEY's shared block in the
;      system VM. Checks magic and version, then returns AX='UV',
;      BX:CX = the V86 callback (segment:offset) for INT 15h C207h,
;      DX = mode. Carry set (AX=0) when there is no callback or the block
;      is not a version 4 block.
;   2  status block: copies STATUS_SIZE bytes to ES:DI, CX = size.
;
; Written from the public Windows 95 DDK documentation (DOCS\KERNEL: the
; VMM services, callbacks and Client_Reg_Struc; MOUSE.DOC: the VMOUSE
; minidriver model; INC32\VMM.INC / VMD.INC: service numbers and layouts).
; No Microsoft code is copied or linked (own DDB and control proc, INT 20h
; service dispatch only). The version 3 fixes also rest on a behaviour
; analysis of Microsoft binaries supplied by the user (Windows Me's VMM in
; VMM32.VXD: the DDB_Prev reverse walk and the V86 callback dispatcher; the
; Windows 98 SE DDK debug VMOUSE.VXD: its BIOS-mouse callback ends with
; Simulate_Far_Ret, VMD_Get/Set_Mouse_Data work on static data); only the
; facts were taken, no code. OpenWatcom wasm + wlink, tools/build_win3_usb_
; keyboard.py. Host test: tools/tests/legacy_bios/test_usosvmd.py.
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

; VMM service ordinals (public DDK VMM.INC service table order)
Get_Sys_VM_Handle       equ 03h
Allocate_V86_Call_Back  equ 0Bh
Map_Flat                equ 1Ch
Set_Global_Time_Out     equ 3Ch
Simulate_Far_Ret        equ 4Ah

; VMOUSE (VMD) service ordinals (public DDK VMD.INC service table order)
VMD_Get_Version                 equ 00h
VMD_Post_Pointer_Message        equ 03h
VMD_Set_Mouse_Data              equ 06h
VMD_Get_Mouse_Data              equ 07h

; VxD control messages (public DDK VMM.INC)
Device_Init             equ 0001h
Init_Complete           equ 0002h

; Mouse_Instance flags (public DDK VMD.INC)
MIF_Active              equ 0002h
MIF_Detected            equ 0004h
MIF_NoIRQ               equ 0080h

; VMD mouse type (public DDK VMD.INC): not PS/2 (4), so VMOUSE does not run
; its own PS/2 code for it.
VMD_Type_Serial         equ 2
BUTTONS                 equ 3

; Control block / client register offsets (public DDK VMM.INC)
CB_High_Linear          equ 4
Client_EBX              equ 10h
Client_EDX              equ 14h
Client_ECX              equ 18h
Client_EAX              equ 1Ch
Client_EFlags           equ 2Ch
Client_ESP              equ 30h
Client_SS               equ 34h
Client_ES               equ 38h
Client_EDI              equ 00h

POLL_MS                 equ 20

; Init order (public DDK VMM.INC VMD_INIT_ORDER). The DDK suggests
; Undefined_Init_Order for minidrivers; this driver runs each init phase
; just BEFORE VMOUSE instead, so its VMD_Set_Mouse_Data at Device_Init
; lands before VMOUSE's own Device_Init and its built-in PS/2 detection
; (the INT 15h C2xx probing that hung the X470; VMOUSE's Sys_Critical_Init,
; which sets up its data, has run by then: every device's Sys_Critical_Init
; comes before any Device_Init). If VMOUSE clears the type again during its
; init, check_type claims it once more (type 0 is "no mouse").
; Re-checked for v3 (the Me bluescreen was the DDB, not this order): in the
; 98 SE DDK debug VMOUSE, VMD_Get_Mouse_Data only reads static (load-time
; initialised) data, so calling it and VMD_Set_Mouse_Data before VMOUSE's
; Device_Init touches no state VMOUSE builds later; VMOUSE's own BIOS-mouse
; (PS/2) setup sits in its PS2_Device_Init path. The documented minidriver
; point (MOUSE README: detect at Device_Init, Undefined order; VMD.INC:
; VMOUSE searches for mice itself "by the start of Init_Complete" when none
; was set) would also be before that search, but not provably before
; PS2_Device_Init, so the order stays. IRQ: VMD_Set_Mouse_Data's AL is
; information only (Int 33h function 24h reports it; no documented "none"
; value, 0 is what Int 33h reports for a PS/2 mouse); this driver
; virtualises no IRQ (MIF_NoIRQ in its Mouse_Instance).
VMD_INIT_ORDER          equ 34000000h

; mode
MODE_NONE               equ 0           ; VMOUSE not loaded
MODE_MINI               equ 1           ; we own VMOUSE's mouse data: post
MODE_OBSERVER           equ 2           ; VMOUSE has another mouse: never post

; err bits
ERR_NO_CALLBACK         equ 0001h       ; Allocate_V86_Call_Back failed
ERR_VMD_HAD_MOUSE       equ 0002h       ; VMOUSE had a mouse at Device_Init
ERR_BAD_BLOCK           equ 0004h       ; attach: not a v4 "USKY" block
ERR_TYPE_CHANGED        equ 0008h       ; VMOUSE's mouse type changed later
ERR_RING_FULL           equ 0010h       ; own ring overflowed at least once
ERR_SHARED_FULL         equ 0020h       ; the shared ring was full at least once
ERR_NO_VMOUSE           equ 0040h       ; VMD_Get_Version: VMOUSE absent
ERR_DDB_DAMAGED         equ 0080h       ; DDB_Size / DDB_Reserved1..3 changed

; USOSKEY.COM shared block layout (byte-exact, src/platform/bios/msdos/
; usoskey.S; checked by tools/tests/legacy_bios/test_usosvmd.py).
SB_VERSION      equ 4
OFF_VERSION     equ 4
OFF_MHEAD       equ 396          ; +396 byte (producer: TSR mcb, or this VxD)
OFF_MTAIL       equ 397          ; +397 byte (consumer: USOSMOUS.DRV)
OFF_MALIVE      equ 398          ; +398 byte
OFF_MCBOFS      equ 400          ; +400 word
OFF_MPACKETS    equ 408          ; +408 dword: packets seen
OFF_MLAST       equ 412          ; +412 4 bytes: last packet
OFF_MDROPPED    equ 402          ; +402 word: ring full
OFF_MRING       equ 420          ; +420: 32 x 4-byte packets [status,dx,dy,z]
RING_MASK       equ 31

OWN_MASK        equ 63           ; own ring: 64 x 4 bytes

;=========================== DDB (fixed, preloaded) ==========================
_LDATA segment dword public use32 'LCODE'

        public  USOSVMD_DDB
USOSVMD_DDB label dword
        dd      0                       ; DDB_Next
        dw      400h                    ; DDB_SDK_Version (DDK 4.0)
        dw      0                       ; DDB_Req_Device_Number = Undefined
        db      3                       ; DDB_Dev_Major_Version
        db      1                       ; DDB_Dev_Minor_Version (3.1)
        dw      0                       ; DDB_Flags
        db      'USOSVMD '              ; DDB_Name (8 chars)
        dd      VMD_INIT_ORDER - 1      ; DDB_Init_Order: just before VMOUSE (see below)
        dd      offset USOSVMD_Control  ; DDB_Control_Proc
        dd      0                       ; DDB_V86_API_Proc
        dd      offset USOSVMD_PM_API   ; DDB_PM_API_Proc
        dd      0                       ; DDB_V86_API_CSIP
        dd      0                       ; DDB_PM_API_CSIP
        dd      0                       ; DDB_Reference_Data
        dd      0                       ; DDB_Service_Table_Ptr
        dd      0                       ; DDB_Service_Table_Size
        ; --- the rest of the 4.0 VxD_Desc_Block (public DDK VMM.INC). VMM
        ; owns these fields: it links every 4.0 DDB backwards through
        ; DDB_Prev after loading the static VxDs and walks that chain for
        ; the reverse-order control messages (Destroy_Thread, Destroy_VM2,
        ; End_PM_App2, ...). v2 ended the DDB here and kept its status
        ; block at +38h, so Device_Init overwrote DDB_Prev with the VMOUSE
        ; version and type bytes and Windows Me faulted in VMM's reverse
        ; walk ("VMM(01) + 00009676 Error 0E", 2026-10-19 X470). Nothing in
        ; this driver writes these 0x18 bytes.
        dd      0                       ; DDB_Win32_Service_Table
        dd      'Prev'                  ; DDB_Prev (VMM fills it in)
        dd      DDB_SIZE_40             ; DDB_Size
        dd      'Rsv1'                  ; DDB_Reserved1
        dd      'Rsv2'                  ; DDB_Reserved2
        dd      'Rsv3'                  ; DDB_Reserved3
USOSVMD_DDB_END label byte
DDB_SIZE_40     equ     50h

; --- status block (PM API function 2; USOSDBG "VMD" lines) ---
; Our own data from here on, after the 0x50-byte DDB (checked by
; tools/tests/legacy_bios/test_usosvmd.py: every written symbol lies at or
; after USOSVMD_DDB + 50h).
        public  status
status label byte
st_sig          dw      5655h           ; +0  'UV'
st_version      db      3               ; +2
st_mode         db      MODE_NONE       ; +3
st_vmd_version  dw      0               ; +4  VMOUSE version (AH.AL)
st_type_init    db      0FFh            ; +6  VMOUSE mouse type at Device_Init (FF = not asked)
st_type_now     db      0FFh            ; +7  at the last time-out
cb_addr         dd      0               ; +8  V86 callback seg:off (0 = none)
sb_base         dd      0               ; +12 shared block linear (system VM), 0 = not attached
st_callbacks    dd      0               ; +16 BIOS calls of the callback
st_foreign      dd      0               ; +20 ... of them while a non-system VM was current
st_posted       dd      0               ; +24 VMD_Post_Pointer_Message calls
st_own_drop     dd      0               ; +28 own ring full
st_shared_put   dd      0               ; +32 copied into the shared ring
st_shared_drop  dd      0               ; +36 shared ring full
st_last_vm      dd      0               ; +40 VM handle at the last callback
st_last_pkt     db      0,0,0,0         ; +44 last packet status, X, Y, Z
st_err          dw      0               ; +48 ERR_* bits
st_type_changes dw      0               ; +50
st_ticks        dd      0               ; +52 time-outs run
st_attach       dw      0               ; +56 successful attach calls
st_sys_vm       dd      0               ; +58 system VM handle
st_reclaims     db      0,0             ; +62 type found 0 again and claimed once more (word)
STATUS_SIZE     equ     64

; own ring (callback -> time-out), 64 x [status, dx, dy, z]
own_head        db      0
own_tail        db      0
own_last        db      0               ; VMOUSE button byte of the last post
own_resend      db      0               ; 1: repeat own_last once (see drain)
own_ring        db      256 dup (0)

; Mouse_Instance passed to VMD_Post_Pointer_Message (EDX).
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

_LDATA ends

;=============================== code ========================================
_LTEXT segment dword public use32 'LCODE'

        public  drain, v86_cb, dev_init_proc, check_type, api_attach, ddb_check, timer_cb

;--- Device_Init: VMOUSE present? claim its mouse data; allocate the callback
dev_init_proc proc near
        VxDcall VMM_ID, Get_Sys_VM_Handle
        mov     [st_sys_vm], ebx
        ; VMD_Get_Version: for a device that is not loaded VMM returns
        ; EAX = 0 with carry set (service 0 of every VxD).
        xor     eax, eax
        VxDcall VMD_ID, VMD_Get_Version
        jc      di_novmd
        cmp     ah, 4
        jb      di_novmd
        mov     [st_vmd_version], ax
        VxDcall VMD_ID, VMD_Get_Mouse_Data      ; AH = type
        mov     [st_type_init], ah
        test    ah, ah
        jnz     di_had
        call    claim
        mov     byte ptr [st_mode], MODE_MINI
        jmp     di_cb
di_had:
        or      word ptr [st_err], ERR_VMD_HAD_MOUSE
        mov     byte ptr [st_mode], MODE_OBSERVER
        jmp     di_cb
di_novmd:
        or      word ptr [st_err], ERR_NO_VMOUSE
        mov     byte ptr [st_mode], MODE_NONE
        ret                             ; no VMOUSE: nothing to feed, no callback
di_cb:
        ; The V86 callback for INT 15h C207h (VMM allocates callbacks in
        ; its global V86 breakpoint area: the same address in every VM).
        xor     edx, edx
        mov     esi, offset v86_cb
        VxDcall VMM_ID, Allocate_V86_Call_Back
        jc      di_nocb
        mov     [cb_addr], eax
        ret
di_nocb:
        or      word ptr [st_err], ERR_NO_CALLBACK
        ret
dev_init_proc endp

;--- VMD_Set_Mouse_Data: serial type (not PS/2), no IRQ, 3 buttons, no port
claim proc near
        mov     ah, VMD_Type_Serial
        xor     al, al                  ; no IRQ
        xor     ebx, ebx                ; not a BallPoint
        xor     ecx, ecx
        mov     dh, BUTTONS
        xor     dl, dl                  ; no port
        VxDcall VMD_ID, VMD_Set_Mouse_Data
        ret
claim endp

;--- our DDB's tail still as declared? (Init_Complete and every time-out) --
; Read only: DDB_Prev (+3Ch) belongs to VMM and is not looked at.
ddb_check proc near
        cmp     dword ptr [USOSVMD_DDB+40h], DDB_SIZE_40
        jne     dc_bad
        cmp     dword ptr [USOSVMD_DDB+44h], 'Rsv1'
        jne     dc_bad
        cmp     dword ptr [USOSVMD_DDB+48h], 'Rsv2'
        jne     dc_bad
        cmp     dword ptr [USOSVMD_DDB+4Ch], 'Rsv3'
        je      dc_ok
dc_bad:
        or      word ptr [st_err], ERR_DDB_DAMAGED
dc_ok:
        ret
ddb_check endp

;--- is VMOUSE's mouse still ours? (Init_Complete and every time-out) -------
; A different type (another minidriver or VMOUSE's own PS/2 code took the
; mouse) switches to observer for good: no posting, no duplicate motion.
check_type proc near
        cmp     byte ptr [st_mode], MODE_NONE
        je      ct_done
        VxDcall VMD_ID, VMD_Get_Mouse_Data
        cmp     ah, [st_type_now]
        je      ct_same
        cmp     byte ptr [st_type_now], 0FFh
        je      ct_first
        inc     word ptr [st_type_changes]
ct_first:
        mov     [st_type_now], ah
ct_same:
        cmp     byte ptr [st_mode], MODE_MINI
        jne     ct_done
        cmp     ah, VMD_Type_Serial
        je      ct_done
        test    ah, ah
        jnz     ct_lost
        call    claim                   ; VMOUSE cleared it: ours again
        mov     byte ptr [st_type_now], VMD_Type_Serial
        inc     word ptr [st_reclaims]
        ret
ct_lost:
        mov     byte ptr [st_mode], MODE_OBSERVER
        or      word ptr [st_err], ERR_TYPE_CHANGED
ct_done:
        ret
check_type endp

;--- the V86 callback: SeaBIOS far-called the C207h handler ---------------
; Entry (DDK): EBX = current VM, EDX = reference data, EBP -> client regs.
; VMM's V86 breakpoint dispatcher does NOT simulate the far return (checked
; in Windows Me's VMM and in the way VMOUSE's own BIOS-mouse callback ends,
; 2026-10-19; v2 wrongly assumed it did): Client_CS:IP is still the
; breakpoint and Client_SS:SP points at SeaBIOS's far return address, so
; the handler's arguments are [SP+4] Z, [SP+6] Y, [SP+8] X, [SP+0Ah] status,
; and this procedure ends with Simulate_Far_Ret (without it the VM would
; re-execute the breakpoint for ever).
ARG_Z                   equ 4
ARG_Y                   equ 6
ARG_X                   equ 8
ARG_STATUS              equ 0Ah
v86_cb proc near
        pushad
        inc     dword ptr [st_callbacks]
        mov     [st_last_vm], ebx
        cmp     ebx, [st_sys_vm]
        je      cb_sys
        inc     dword ptr [st_foreign]
cb_sys:
        ; linear address of the client stack in that VM
        movzx   esi, word ptr [ebp+Client_SS]
        shl     esi, 4
        movzx   eax, word ptr [ebp+Client_ESP]
        add     esi, eax
        add     esi, [ebx+CB_High_Linear]
        mov     cl, [esi+ARG_STATUS]    ; status
        mov     ch, [esi+ARG_X]         ; X
        mov     dl, [esi+ARG_Y]         ; Y
        mov     dh, [esi+ARG_Z]         ; Z (wheel, 0 without)
        mov     [st_last_pkt], cl
        mov     [st_last_pkt+1], ch
        mov     [st_last_pkt+2], dl
        mov     [st_last_pkt+3], dh
        ; own ring: only while we post
        cmp     byte ptr [st_mode], MODE_MINI
        jne     cb_shared
        mov     al, [own_head]
        mov     ah, al
        inc     ah
        and     ah, OWN_MASK
        cmp     ah, [own_tail]
        jne     cb_own_put
        inc     dword ptr [st_own_drop]
        or      word ptr [st_err], ERR_RING_FULL
        jmp     cb_shared
cb_own_put:
        movzx   edi, al
        shl     edi, 2
        mov     [own_ring+edi], cl
        mov     [own_ring+edi+1], ch
        mov     [own_ring+edi+2], dl
        mov     [own_ring+edi+3], dh
        mov     [own_head], ah
cb_shared:
        ; USOSKEY's shared ring in the system VM (same format as the TSR
        ; mcb): USOSMOUS.DRV takes the wheel byte from there.
        mov     edi, [sb_base]
        test    edi, edi
        jz      cb_done
        inc     dword ptr [edi+OFF_MPACKETS]
        mov     [edi+OFF_MLAST], cl
        mov     [edi+OFF_MLAST+1], ch
        mov     [edi+OFF_MLAST+2], dl
        mov     [edi+OFF_MLAST+3], dh
        mov     al, [edi+OFF_MHEAD]
        mov     ah, al
        inc     ah
        and     ah, RING_MASK
        cmp     ah, [edi+OFF_MTAIL]
        jne     cb_sh_put
        inc     word ptr [edi+OFF_MDROPPED]
        inc     dword ptr [st_shared_drop]
        or      word ptr [st_err], ERR_SHARED_FULL
        jmp     cb_done
cb_sh_put:
        movzx   esi, al
        shl     esi, 2
        add     esi, edi
        mov     [esi+OFF_MRING], cl
        mov     [esi+OFF_MRING+1], ch
        mov     [esi+OFF_MRING+2], dl
        mov     [esi+OFF_MRING+3], dh
        mov     [edi+OFF_MHEAD], ah
        inc     dword ptr [st_shared_put]
cb_done:
        popad
        ; back to SeaBIOS's far call (EBP -> client regs, restored above)
        VxDcall VMM_ID, Simulate_Far_Ret
        ret
v86_cb endp

;--- drain the own ring: ONE post to VMOUSE per time-out --------------------
; VMOUSE button byte (AL of VMD_Post_Pointer_Message) as VMOUSE decodes it
; (Windows Me and 98 SE VMOUSE.VXD, version 3.1 above): PrimaryButton mask
; 20h, SecondaryButton mask 10h (registry defaults), 04h middle; 08h is a
; fourth button on Me; bit 0 would announce a wheel in ECX (not used:
; USOSMOUS.DRV sends the wheel). PS/2 status bit 0 left, 1 right, 2 middle.
VMB_LEFT                equ 20h
VMB_RIGHT               equ 10h
VMB_MIDDLE              equ 04h

; VMOUSE keeps one pending message and drops a post while its event has
; not run, so each time-out posts once: the packets from the tail with the
; same button state as the first one, X and Y summed; a packet with another
; button state stays queued for the next time-out (every press and release
; gets a post of its own, in order). Overflow packets (status C0h bits) are
; skipped. With nothing queued, the last button change is posted once more
; without motion (in case its post met a pending event). ESI = X sum as
; read, EDI = PS/2 Y sum negated (down positive), EDX -> our Mouse_Instance.
drain proc near
        cmp     byte ptr [st_mode], MODE_MINI
        je      dr_mini
        mov     al, [own_head]          ; observer since queued: drop all
        mov     [own_tail], al
        ret
dr_mini:
        xor     esi, esi                ; X sum
        xor     edi, edi                ; PS/2 Y sum (up positive)
        xor     edx, edx                ; DL = 1 once the run has a packet, DH = its buttons
dr_loop:
        mov     al, [own_tail]
        cmp     al, [own_head]
        je      dr_post
        movzx   ebx, al
        shl     ebx, 2
        mov     cl, [own_ring+ebx]      ; status
        test    cl, 0C0h
        jnz     dr_next                 ; overflow: no valid packet
        xor     ch, ch
        test    cl, 1
        jz      dr_nl
        or      ch, VMB_LEFT
dr_nl:
        test    cl, 2
        jz      dr_nr
        or      ch, VMB_RIGHT
dr_nr:
        test    cl, 4
        jz      dr_nm
        or      ch, VMB_MIDDLE
dr_nm:
        test    dl, dl
        jz      dr_first
        cmp     ch, dh
        jne     dr_post                 ; button change: the next time-out
        jmp     dr_add
dr_first:
        mov     dh, ch
        mov     dl, 1
dr_add:
        movzx   eax, byte ptr [own_ring+ebx+1]
        test    cl, 10h
        jz      dr_dxp
        or      eax, 0FFFFFF00h
dr_dxp:
        add     esi, eax
        movzx   eax, byte ptr [own_ring+ebx+2]
        test    cl, 20h
        jz      dr_dyp
        or      eax, 0FFFFFF00h
dr_dyp:
        add     edi, eax
dr_next:
        mov     al, [own_tail]
        inc     al
        and     al, OWN_MASK
        mov     [own_tail], al
        jmp     dr_loop
dr_post:
        test    dl, dl
        jnz     dr_have
        cmp     byte ptr [own_resend], 0
        je      drain_done              ; nothing queued, nothing to repeat
        mov     byte ptr [own_resend], 0
        mov     dh, [own_last]          ; ESI = EDI = 0
        jmp     dr_send
dr_have:
        mov     al, 0
        cmp     dh, [own_last]
        je      dr_keep
        mov     al, 1                   ; a button change: repeat it once
dr_keep:
        mov     [own_resend], al
        mov     [own_last], dh
dr_send:
        neg     edi
        mov     al, dh
        mov     edx, offset mi_inst
        VxDcall VMD_ID, VMD_Post_Pointer_Message
        inc     dword ptr [st_posted]
drain_done:
        ret
drain endp

;--- global time-out: check the type, drain, re-arm -------------------------
timer_cb proc near
        pushad
        inc     dword ptr [st_ticks]
        call    ddb_check
        call    check_type
        call    drain
        popad
        mov     eax, POLL_MS
        xor     edx, edx
        mov     esi, offset timer_cb
        VxDcall VMM_ID, Set_Global_Time_Out
        ret
timer_cb endp

;--- VxD control procedure ---------------------------------------------------
        public  USOSVMD_Control
USOSVMD_Control proc near
        cmp     eax, Device_Init
        je      c_devinit
        cmp     eax, Init_Complete
        je      c_initcomplete
        clc
        ret
c_devinit:
        pushad
        call    dev_init_proc
        popad
        clc
        ret
c_initcomplete:
        pushad
        call    ddb_check
        call    check_type
        cmp     byte ptr [st_mode], MODE_NONE
        je      ic_done
        mov     eax, POLL_MS
        xor     edx, edx
        mov     esi, offset timer_cb
        VxDcall VMM_ID, Set_Global_Time_Out
ic_done:
        popad
        clc
        ret
USOSVMD_Control endp

;--- PM API function 1: attach the shared block -----------------------------
; EBP -> client regs: BX = segment, CX = offset (system VM conventional
; memory). Returns EAX = 1 (attached) or 0.
api_attach proc near
        cmp     dword ptr [cb_addr], 0
        je      at_fail
        movzx   esi, word ptr [ebp+Client_EBX]
        shl     esi, 4
        movzx   eax, word ptr [ebp+Client_ECX]
        add     esi, eax
        cmp     esi, 0A0000h - 548
        ja      at_bad
        mov     eax, [st_sys_vm]
        add     esi, [eax+CB_High_Linear]
        cmp     dword ptr [esi], 'YKSU'         ; "USKY"
        jne     at_bad
        movzx   eax, word ptr [esi+OFF_VERSION]
        cmp     ax, SB_VERSION
        jb      at_bad
        cmp     ax, 100h
        ja      at_bad
        mov     [sb_base], esi
        inc     word ptr [st_attach]
        mov     eax, 1
        ret
at_bad:
        or      word ptr [st_err], ERR_BAD_BLOCK
at_fail:
        xor     eax, eax
        ret
api_attach endp

;--- PM API ------------------------------------------------------------------
; Entry: EBX = VM, EBP -> Client_Reg_Struc.
        public  USOSVMD_PM_API
USOSVMD_PM_API proc near
        and     byte ptr [ebp+Client_EFlags], 0FEh      ; CF clear
        movzx   eax, word ptr [ebp+Client_EAX]
        test    eax, eax
        jz      api_status
        cmp     eax, 1
        je      api_att
        cmp     eax, 2
        je      api_copy
        jmp     api_fail
api_status:
        mov     word ptr [ebp+Client_EAX], 5655h        ; 'UV'
        mov     word ptr [ebp+Client_EBX], 0301h
        mov     eax, [st_callbacks]
        mov     word ptr [ebp+Client_ECX], ax
        movzx   eax, byte ptr [st_mode]
        mov     word ptr [ebp+Client_EDX], ax
        clc
        ret
api_att:
        call    api_attach
        test    eax, eax
        jz      api_fail
        mov     word ptr [ebp+Client_EAX], 5655h
        mov     eax, [cb_addr]
        mov     word ptr [ebp+Client_ECX], ax           ; offset
        shr     eax, 16
        mov     word ptr [ebp+Client_EBX], ax           ; segment
        movzx   eax, byte ptr [st_mode]
        mov     word ptr [ebp+Client_EDX], ax
        clc
        ret
api_copy:
        mov     ax, (Client_ES shl 8) or Client_EDI
        VxDcall VMM_ID, Map_Flat
        cmp     eax, -1
        je      api_fail
        mov     edi, eax
        mov     esi, offset status
        mov     ecx, STATUS_SIZE
        cld
        rep     movsb
        mov     word ptr [ebp+Client_ECX], STATUS_SIZE
        mov     word ptr [ebp+Client_EAX], 5655h
        clc
        ret
api_fail:
        mov     word ptr [ebp+Client_EAX], 0
        or      byte ptr [ebp+Client_EFlags], 1         ; CF set
        clc
        ret
USOSVMD_PM_API endp

_LTEXT ends

end
