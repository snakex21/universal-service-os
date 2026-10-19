/* USOSVBI.EXE: windowless Win16, read-only VBE queries through DPMI 0300h.
 * Intended for Me too, where AUTOEXEC.BAT is not executed (needs hardware test).
 * No runtime library, graphics mode changes, PCI or timer writes.
 * USOS, GPL-3.0-or-later. Entry/DPMI conventions follow USOSDBG.
 */
#include <windows.h>
#include "display_vbe.h"
typedef struct {
    DWORD edi,esi,ebp,reserved,ebx,edx,ecx,eax;
    WORD flags,es,ds,fs,gs,ip,cs,sp,ss;
} RM;
static RM rm;
static UsosDisplayVbeList output;
static WORD mode_numbers[256];
static WORD instance,exit_code;
extern char edata[],end[];
extern BOOL FAR PASCAL WaitEvent(HANDLE);
extern BOOL FAR PASCAL InitApp(HINSTANCE);
extern void FAR PASCAL InitTask(void);

static WORD word_at(const BYTE FAR *p) { return (WORD)p[0]|((WORD)p[1]<<8); }
static DWORD long_at(const BYTE FAR *p) { return (DWORD)word_at(p)|((DWORD)word_at(p+2)<<16); }
static WORD descriptor(WORD segment) {
    WORD result=0;
    _asm {
        mov ax,0002h
        mov bx,segment
        int 31h
        jc done
        mov result,ax
    done:
    }
    return result;
}
static int bios(WORD ax,WORD mode,WORD segment,WORD offset) {
    BYTE failed=0; WORD off=(WORD)(void NEAR *)&rm,i;
    BYTE NEAR *p=(BYTE NEAR *)&rm;
    for(i=0;i<sizeof rm;i++)p[i]=0;
    rm.eax=ax;rm.ecx=mode;rm.es=segment;rm.edi=offset;rm.flags=0x0202;
    _asm {
        push es
        push di
        pushad
        mov ax,ds
        mov es,ax
        xor edi,edi
        mov di,off
        mov ax,0300h
        mov bx,0010h
        xor cx,cx
        int 31h
        popad
        pop di
        pop es
        jnc okay
        mov failed,1
    okay:
    }
    return !failed && !(rm.flags&1) && (WORD)rm.eax==0x004F;
}
static void collect(void) {
    DWORD memory=GlobalDosAlloc(1024),vram,address;
    WORD selector=LOWORD(memory),segment=HIWORD(memory),i,list_segment,list_offset,list_selector,number;
    WORD version,offset,count=0; BYTE FAR *data; BYTE FAR *info; WORD FAR *list; HFILE file;
    if(!memory)return;
    data=(BYTE FAR *)MAKELONG(0,selector);
    for(i=0;i<1024;i++)data[i]=0;
    data[0]='V';data[1]='B';data[2]='E';data[3]='2';
    if(!bios(0x4F00,0,segment,0))goto done;
    if(data[0]!='V'||data[1]!='E'||data[2]!='S'||data[3]!='A')goto done;
    version=word_at(data+4); if(version<0x0200)goto done;
    vram=(DWORD)word_at(data+18)*65536UL;if(!vram)goto done;
    list_offset=word_at(data+14);list_segment=word_at(data+16);
    address=(DWORD)list_segment*16+list_offset;
    if(address<0x500UL || address>0xFFFFDUL)goto done;
    list_selector=list_segment==segment?selector:descriptor(list_segment);if(!list_selector)goto done;
    list=(WORD FAR *)MAKELONG(list_offset,list_selector);
    /* The BIOS may point inside the controller buffer; copy before 4F01. */
    for(i=0;i<256;i++) {
        if((DWORD)list_offset+(DWORD)i*2>0xFFFDUL || address+(DWORD)i*2>0xFFFFDUL)goto done;
        if(list_segment==segment && (DWORD)list_offset+(DWORD)i*2>1021)goto done;
        number=list[i];if(number==0xFFFF)break;
        mode_numbers[count++]=number;
    }
    if(i==256)goto done;
    info=data+512;
    output.magic=USOS_DISPLAY_VBE_MAGIC;
    for(i=0;i<count && output.count<USOS_DISPLAY_VBE_COUNT;i++) {
        UsosDisplayVbeMode *m;
        WORD j;
        number=mode_numbers[i];
        for(j=0;j<512;j++)info[j]=0;
        if(number>0x1FFF || !bios(0x4F01,number,segment,512))continue;
        if((word_at(info)&0x0091)!=0x0091 || info[24]!=1 || info[27]!=6 || !long_at(info+40))continue;
        if(info[25]!=16 && info[25]!=32)continue;
        offset=version>=0x0300 && word_at(info+50)?54:31;
        if(info[25]==16 && (info[offset]!=5||info[offset+1]!=11||info[offset+2]!=6||info[offset+3]!=5||info[offset+4]!=5||info[offset+5]!=0))continue;
        if(info[25]==32 && (info[offset]!=8||info[offset+1]!=16||info[offset+2]!=8||info[offset+3]!=8||info[offset+4]!=8||info[offset+5]!=0))continue;
        m=&output.modes[output.count++];m->width=word_at(info+18);m->height=word_at(info+20);m->bpp=info[25];
        m->pitch=version>=0x0300&&word_at(info+50)?word_at(info+50):word_at(info+16);m->vram=vram;
    }
    if(!output.count)goto done;
    file=_lcreat("C:\\USOS9X\\VBE.DAT",0);
    if(file!=HFILE_ERROR) {
        WORD bytes=8+(WORD)output.count*sizeof(UsosDisplayVbeMode);
        if(_lwrite(file,(const char FAR *)&output,bytes)==bytes)exit_code=0;
        _lclose(file);
    }
done:
    GlobalDosFree(selector);
}
static void zero_bss(void) { char *p;for(p=edata;p<end;p++)*p=0; }
static void start(void) { WaitEvent(0);InitApp((HINSTANCE)instance);exit_code=1;collect(); }
#pragma aux task_entry "__usos_start"
void __declspec(naked) __far task_entry(void) {
    _asm {
        call InitTask
        or ax,ax
        jz fail
        push di
        call zero_bss
        pop di
        mov instance,di
        call start
        mov ax,exit_code
        mov ah,4Ch
        int 21h
    fail:
        mov ax,4C01h
        int 21h
    }
}
