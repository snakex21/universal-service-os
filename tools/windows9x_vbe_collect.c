/* USOSVBI.EXE: windowless Win16, read-only VBE queries through DPMI 0300h.
 * Intended for Me too, where AUTOEXEC.BAT is not executed (needs hardware test).
 * Every run also writes VBE.LOG beside it: the stage reached and the VBE facts
 * (98 SE X470 2026-10-20: no VBE.DAT and no reason; USOSRES copies the line).
 * No runtime library, graphics mode changes, PCI or timer writes.
 * USOS, GPL-3.0-or-later. Entry/DPMI conventions follow USOSDBG.
 */
#include <windows.h>
#include "display_vbe.h"
typedef struct {
    DWORD edi,esi,ebp,reserved,ebx,edx,ecx,eax;
    WORD flags,es,ds,fs,gs,ip,cs,sp,ss;
} RM;
/* Reserved instance data (as USOSDBG): KERNEL's InitTask/LocalInit write the
 * local heap and stack bounds into the first 16 bytes of DGROUP. Without it
 * they overwrote CONST ("VBE.DAT" at DS:0) and zero_bss then cleared the
 * stack bounds (98 SE X470 2026-10-20: no VBE.DAT). */
#pragma data_seg("_NULL", "BEGDATA")
char null_area[32] = { 0 };
#pragma data_seg()
static RM rm;
static UsosDisplayVbeList output;
static WORD mode_numbers[256];
static WORD instance,exit_code;
static char output_path[260];
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
/* VBE.LOG: one line, "VBI stage=N ..." (stage 0 = VBE.DAT written). */
static WORD stage,diag_version,diag_memory,diag_listed,diag_kept,diag_seg,diag_off;
static WORD diag_first[8],diag_rejects;
static char log_line[256];
static WORD log_length;
static void log_text(const char *s) { while(*s && log_length<sizeof(log_line)-3) log_line[log_length++]=*s++; }
static void log_hex(const char *name,WORD value) {
    static const char digits[]="0123456789ABCDEF"; char out[6]; int i;
    log_text(" ");log_text(name);log_text("=");
    for(i=0;i<4;i++)out[i]=digits[(value>>(12-4*i))&15];
    out[4]=0;log_text(out);
}
static WORD module_dir(void) {
    WORD length=GetModuleFileName((HINSTANCE)instance,output_path,sizeof output_path);
    if(!length || length>=sizeof output_path)return 0;
    while(length && output_path[length-1]!='\\')length--;
    if(!length || length+sizeof("VBE.DAT")>sizeof output_path)return 0;
    return length;
}
static void write_log(void) {
    WORD length=module_dir(),j; HFILE file; const char *name="VBE.LOG";
    if(!length)return;
    for(j=0;j<sizeof("VBE.LOG");j++)output_path[length+j]=name[j];
    log_length=0;log_text("VBI");
    log_hex("stage",stage);log_hex("ver",diag_version);log_hex("mem64k",diag_memory);
    log_hex("list_seg",diag_seg);log_hex("list_off",diag_off);log_hex("listed",diag_listed);
    log_hex("kept",diag_kept);log_hex("rejected",diag_rejects);
    if(diag_rejects) {
        /* first rejected mode: number, why (1 4F01 2 attr/planes/model/LFB 3 bpp 4 masks),
           attributes, planes<<8|model, bpp, mask offset<<8|red size, red position */
        log_hex("r_mode",diag_first[0]);log_hex("r_why",diag_first[1]);log_hex("r_attr",diag_first[2]);
        log_hex("r_pl_mm",diag_first[3]);log_hex("r_bpp",diag_first[4]);log_hex("r_off_rs",diag_first[5]);
        log_hex("r_rp",diag_first[6]);
    }
    log_line[log_length++]='\r';log_line[log_length++]='\n';
    file=_lcreat(output_path,0);
    if(file!=HFILE_ERROR) { _lwrite(file,(const char FAR *)log_line,log_length);_lclose(file); }
}
static void reject(WORD number,WORD why,const BYTE FAR *info,WORD offset) {
    if(!diag_rejects++) {
        diag_first[0]=number;diag_first[1]=why;diag_first[2]=word_at(info);
        diag_first[3]=((WORD)info[24]<<8)|info[27];diag_first[4]=info[25];
        diag_first[5]=(offset<<8)|info[offset];diag_first[6]=info[offset+1];
    }
}
static void collect(void) {
    DWORD memory=GlobalDosAlloc(1024),vram,address;
    WORD selector=LOWORD(memory),segment=HIWORD(memory),i,list_segment,list_offset,list_selector,number;
    WORD version,offset,count=0,length; BYTE FAR *data; BYTE FAR *info; WORD FAR *list; HFILE file;
    stage=1;if(!memory)return;
    data=(BYTE FAR *)MAKELONG(0,selector);
    for(i=0;i<1024;i++)data[i]=0;
    data[0]='V';data[1]='B';data[2]='E';data[3]='2';
    stage=2;if(!bios(0x4F00,0,segment,0))goto done;
    stage=3;if(data[0]!='V'||data[1]!='E'||data[2]!='S'||data[3]!='A')goto done;
    version=word_at(data+4);diag_version=version;diag_memory=word_at(data+18);
    stage=4;if(version<0x0200)goto done;
    stage=5;vram=(DWORD)word_at(data+18)*65536UL;if(!vram)goto done;
    list_offset=word_at(data+14);list_segment=word_at(data+16);diag_seg=list_segment;diag_off=list_offset;
    address=(DWORD)list_segment*16+list_offset;
    stage=6;if(address<0x500UL || address>0xFFFFDUL)goto done;
    stage=7;list_selector=list_segment==segment?selector:descriptor(list_segment);if(!list_selector)goto done;
    list=(WORD FAR *)MAKELONG(list_offset,list_selector);
    /* The BIOS may point inside the controller buffer; copy before 4F01. */
    stage=8;
    for(i=0;i<256;i++) {
        if((DWORD)list_offset+(DWORD)i*2>0xFFFDUL || address+(DWORD)i*2>0xFFFFDUL)goto done;
        if(list_segment==segment && (DWORD)list_offset+(DWORD)i*2>1021)goto done;
        number=list[i];if(number==0xFFFF)break;
        mode_numbers[count++]=number;
    }
    diag_listed=count;if(i==256)goto done;
    info=data+512;
    output.magic=USOS_DISPLAY_VBE_MAGIC;
    for(i=0;i<count && output.count<USOS_DISPLAY_VBE_COUNT;i++) {
        UsosDisplayVbeMode *m;
        WORD j;
        number=mode_numbers[i];
        for(j=0;j<512;j++)info[j]=0;
        if(number>0x1FFF || !bios(0x4F01,number,segment,512)) {reject(number,1,info,31);continue;}
        if((word_at(info)&0x0091)!=0x0091 || info[24]!=1 || info[27]!=6 || !long_at(info+40)) {reject(number,2,info,31);continue;}
        if(info[25]!=16 && info[25]!=32) {reject(number,3,info,31);continue;}
        offset=version>=0x0300 && word_at(info+50)?54:31;
        if(info[25]==16 && (info[offset]!=5||info[offset+1]!=11||info[offset+2]!=6||info[offset+3]!=5||info[offset+4]!=5||info[offset+5]!=0)) {reject(number,4,info,offset);continue;}
        if(info[25]==32 && (info[offset]!=8||info[offset+1]!=16||info[offset+2]!=8||info[offset+3]!=8||info[offset+4]!=8||info[offset+5]!=0)) {reject(number,4,info,offset);continue;}
        m=&output.modes[output.count++];m->width=word_at(info+18);m->height=word_at(info+20);m->bpp=info[25];
        m->pitch=version>=0x0300&&word_at(info+50)?word_at(info+50):word_at(info+16);m->vram=vram;
    }
    diag_kept=(WORD)output.count;stage=9;if(!output.count)goto done;
    stage=10;length=module_dir();if(!length)goto done;
    {
        WORD j;const char *name="VBE.DAT";
        for(j=0;j<sizeof("VBE.DAT");j++)output_path[length+j]=name[j];
    }
    file=_lcreat(output_path,0);
    if(file!=HFILE_ERROR) {
        WORD bytes=8+(WORD)output.count*sizeof(UsosDisplayVbeMode);
        stage=11;if(_lwrite(file,(const char FAR *)&output,bytes)==bytes){exit_code=0;stage=0;}
        _lclose(file);
    }
done:
    GlobalDosFree(selector);
}
static void zero_bss(void) { char *p;for(p=edata;p<end;p++)*p=0; }
static void start(void) { WaitEvent(0);InitApp((HINSTANCE)instance);exit_code=1;collect();write_log(); }
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
