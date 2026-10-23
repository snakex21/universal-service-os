; USOS GPL-3.0-or-later. Own MZ entry, no compiler runtime.
.8086
_DATA segment word public 'DATA'
_DATA ends
_BSS segment word public 'BSS'
_BSS ends
STACK segment para stack 'STACK'
    db 8192 dup (?)
STACK ends
DGROUP group _DATA, _BSS, STACK
_TEXT segment word public 'CODE'
assume cs:_TEXT, ds:DGROUP
extrn dos_entry_:near
public vesbind_start
vesbind_start:
    mov ax, DGROUP
    mov ds, ax
    mov es, ax
    ; DOS sets SS to the STACK segment. Small-model near pointers require
    ; SS=DS, so preserve the physical stack top while normalizing SS:SP.
    mov bx, ss
    sub bx, ax
    mov cl, 4
    shl bx, cl
    mov dx, sp
    add dx, bx
    cli
    mov ss, ax
    mov sp, dx
    sti
    cld
    call dos_entry_
    mov ah, 4ch
    int 21h
_TEXT ends
end vesbind_start
