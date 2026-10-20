/* Execute the same selector used by the target tools. No display API calls. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "../display_policy.h"
#include "../display_apply.h"
#include "../display_inf.h"
#include "../display_vbe.h"
#include "../display_modes.h"
#include "../display_compat.h"
#define CHECK(x) do { if (!(x)) ExitProcess(__LINE__); } while (0)
static UsosDisplayMode m[] = {
    {1024,768,16,2048,16UL*1024*1024,1},
    {1280,1024,16,2560,16UL*1024*1024,1},
    {1920,1080,16,3840,16UL*1024*1024,1},
    {1920,1080,32,7680,8UL*1024*1024,1},
    {1280,1024,32,5120,16UL*1024*1024,1}
};
static int tests,applies,backups,rollbacks,backup_ok=1;
static long test_value,apply_value;
static long fake_test(void *p,int index,const char *reason) {(void)p;(void)index;(void)reason;tests++;return test_value;}
static int fake_backup(void *p) {(void)p;backups++;return backup_ok;}
static long fake_apply(void *p,int index) {(void)p;(void)index;applies++;return apply_value;}
static long fake_rollback(void *p) {(void)p;rollbacks++;return 0;}
static WORD accepted_size=124;
static int reject_current=1,enum_calls,change_calls;
static DWORD last_flags;
static BOOL WINAPI old_enum(LPCSTR device,DWORD index,DEVMODEA *mode) {
    (void)device;enum_calls++;
    if(mode->dmSize!=accepted_size||(index==(DWORD)-1&&reject_current)||index>1)return FALSE;
    mode->dmPelsWidth=index?1024:800;mode->dmPelsHeight=index?768:600;mode->dmBitsPerPel=16;return TRUE;
}
static int old_caps(DWORD *w,DWORD *h,DWORD *b) {*w=1024;*h=768;*b=16;return 1;}
static LONG WINAPI old_change(DEVMODEA *mode,DWORD flags) {
    (void)mode;change_calls++;last_flags=flags;return flags&CDS_GLOBAL?DISP_CHANGE_BADFLAGS:0;
}
void entry(void) {
    UsosDisplayRequest r; UsosDisplayChoice c;
    UsosDisplayResult result;
    UsosDisplayActions actions={0,fake_test,fake_backup,fake_apply,fake_rollback};
    DEVMODEA mode;
    CHECK(usos_display_dm_size(0x3303)==124&&usos_display_dm_size(4)==148&&usos_display_dm_size(5)==156);
    CHECK(usos_display_enum(old_enum,3,0,&mode)&&enum_calls==1&&mode.dmSize==124);
    enum_calls=0;CHECK(usos_display_enum(old_enum,5,0,&mode)&&enum_calls==3);
    CHECK(usos_display_current(old_enum,3,old_caps,&mode)&&mode.dmPelsWidth==1024&&mode.dmPelsHeight==768);
    CHECK(usos_display_change(old_change,&mode,CDS_UPDATEREGISTRY|CDS_GLOBAL)==0&&change_calls==2&&last_flags==CDS_UPDATEREGISTRY);
    CHECK(usos_display_retry(4,0,0,0)&&usos_display_retry(16,3,DISP_CHANGE_NOTUPDATED,0));
    CHECK(usos_display_retry(32,0,0,1)&&!usos_display_retry(32,1,0,0));
    CHECK(usos_display_parse("1920x1080x32\r\n",&r));
    CHECK(usos_display_choose(m,5,&r,0).index==3);
    m[3].valid=0; CHECK(usos_display_choose(m,5,&r,0).index==2); m[3].valid=1;
    CHECK(usos_display_parse("1600x1050x32",&r)); CHECK(usos_display_choose(m,5,&r,0).index==4);
    CHECK(usos_display_parse("autoxauto",&r)); CHECK(usos_display_choose(m,5,&r,0).index==3);
    CHECK(usos_display_parse("1920x1080xauto",&r));
    /* double buffering rejects 15.82 MiB for an 8 MiB adapter */
    CHECK(usos_display_choose(m,5,&r,1).index==2);
    m[3].vram=32UL*1024*1024; CHECK(usos_display_choose(m,5,&r,1).index==3);
    m[3].pitch=0xFFFFFFFFUL; CHECK(usos_display_choose(m,5,&r,1).index==2); m[3].pitch=7680;
    m[3].vram=0; CHECK(!usos_display_usable(&m[3],1));
    CHECK(usos_display_parse("800x600x16",&r)); c=usos_display_choose(m,5,&r,0); CHECK(c.index==0);
    CHECK(usos_display_choose(NULL,0,&r,0).index==-1);
    CHECK(usos_display_choose(m,USOS_DISPLAY_MAX+1,&r,0).index==-1);
    m[0].valid=0; CHECK(usos_display_choose(m,5,&r,0).index==-1); m[0].valid=1;
    CHECK(!usos_display_parse("1920x1080x24",&r));
    CHECK(!usos_display_parse("0x0x16",&r));
    CHECK(!usos_display_parse("autoxauto;run",&r));
    CHECK(!usos_display_parse("999999999999x1080x32",&r));
    CHECK(!usos_display_parse("",&r));
    CHECK(!usos_display_parse("auto",&r));
    CHECK(sizeof(UsosDisplayVbeMode)==20 && sizeof(UsosDisplayRecord)==12);
    CHECK(usos_display_inf_has(";HKR,\"MODES\\32\\1,2\"\nHKR,\"MODES\\16\\1920,1080\"\r\n",1920,1080,16));
    CHECK(!usos_display_inf_has(";HKR,\"MODES\\32\\1920,1080\"\n",1920,1080,32));
    CHECK(!usos_display_inf_has("HKR,\"MODES\\32\\1920,10800\"\n",1920,1080,32));
    CHECK(usos_display_inf_limit("HKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,128\r\n")==128UL*1024*1024);
    CHECK(!usos_display_inf_limit("HKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,0\n"));
    CHECK(!usos_display_inf_limit("HKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,99999999999\n"));
    CHECK(!usos_display_inf_limit(""));
    CHECK(!usos_display_inf_limit("HKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,\"128\n"));
    CHECK(!usos_display_inf_limit("HKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,64\nHKLM,Software\\vmdisp9x\\vesa,VRAMLimit,,64\n"));
    CHECK(usos_display_parse("1920x1080x32",&r));m[3].vram=32UL*1024*1024;
    result=usos_display_execute(m,5,&r,0,&actions);
    CHECK(result.state==1 && result.index==3 && tests==1 && applies==1 && rollbacks==0);
    apply_value=-2;
    result=usos_display_execute(m,5,&r,0,&actions);
    CHECK(result.state==3 && rollbacks==1 && applies==2);
    backup_ok=0;
    result=usos_display_execute(m,5,&r,0,&actions);
    CHECK(result.state==4 && applies==2 && rollbacks==1);
    backup_ok=1;test_value=-2;
    result=usos_display_execute(m,5,&r,0,&actions);
    CHECK(result.state==0 && applies==2 && rollbacks==1);
    m[3].valid=1;test_value=0;apply_value=1;
    result=usos_display_execute(m,5,&r,0,&actions);
    CHECK(result.state==2 && applies==3);
    ExitProcess(0);
}
