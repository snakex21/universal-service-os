/* Execute the same selector used by the target tools. No display API calls. */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "../display_policy.h"
#include "../display_edid.h"
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
    /* NT 6.2 / 6.3 / 10 (as 6.2 unmanifested, 10.0 manifested): like 6.0 /
       6.1, no CDS_GLOBAL and the per-user Run value is removed; NT5 global;
       NT4 and 9x (high bit) neither. */
    CHECK(usos_display_flags(0x0005)==(CDS_UPDATEREGISTRY|CDS_GLOBAL)&&usos_display_flags(0x0105)==(CDS_UPDATEREGISTRY|CDS_GLOBAL));
    {   static const DWORD nt6[]={0x0006,0x0106,0x0206,0x0306,0x000A}; int i;
        for(i=0;i<5;i++) CHECK(usos_display_flags(nt6[i])==CDS_UPDATEREGISTRY&&usos_display_user_run(nt6[i]));
    }
    CHECK(usos_display_flags(0x0004)==CDS_UPDATEREGISTRY&&!usos_display_user_run(0x0004)&&!usos_display_user_run(0x0005));
    CHECK(!usos_display_user_run(0xC0000A04UL));
    CHECK(usos_display_dm_size(0x0206)==156&&usos_display_dm_size(0x000A)==156);
    CHECK(usos_display_retry(4,0,0,0)&&usos_display_retry(16,3,DISP_CHANGE_NOTUPDATED,0));
    CHECK(usos_display_retry(32,0,0,1)&&!usos_display_retry(32,1,0,0));
    CHECK(usos_display_parse("1920x1080x32\r\n",&r));
    CHECK(usos_display_choose(m,5,&r,0).index==3);
    m[3].valid=0; CHECK(usos_display_choose(m,5,&r,0).index==2); m[3].valid=1;
    CHECK(usos_display_parse("1600x1050x32",&r)); CHECK(usos_display_choose(m,5,&r,0).index==4);
    CHECK(usos_display_parse("autoxauto",&r)); CHECK(usos_display_choose(m,5,&r,0).index==3);
    {   /* Native (EDID) first, else the highest mode: no 1920x1080 cap. */
        static UsosDisplayMode big[] = {
            {1920,1080,32,7680,64UL*1024*1024,1}, {2560,1440,32,10240,64UL*1024*1024,1},
            {3840,2160,32,15360,64UL*1024*1024,1}, {2560,1440,16,5120,64UL*1024*1024,1}};
        static const unsigned char edid_1440[128] = {0,0xFF,0xFF,0xFF,0xFF,0xFF,0xFF,0,
            [54]=0x56,[55]=0x5E,[56]=0x00,[57]=0xA0,[58]=0xA0,[59]=0xA0,[60]=0x29,[61]=0x50};
        unsigned char e[128]; unsigned long w=0,h=0,sum=0; int i;
        CHECK(usos_display_parse("autoxauto\r\n",&r) && !r.native_width);
        c=usos_display_choose(big,4,&r,0); CHECK(c.index==2 && c.reason[0]=='h');
        CHECK(usos_display_parse("autoxauto\r\nnative=2560x1440\r\n",&r) && r.native_width==2560 && r.native_height==1440);
        c=usos_display_choose(big,4,&r,0); CHECK(c.index==1 && c.reason[0]=='n');
        big[1].valid=0; c=usos_display_choose(big,4,&r,0); CHECK(c.index==3); big[1].valid=1;
        big[1].valid=0; big[3].valid=0; c=usos_display_choose(big,4,&r,0); CHECK(c.index==0 && c.reason[0]=='b'); big[1].valid=1; big[3].valid=1;
        /* A fixed request ignores native. */
        CHECK(usos_display_parse("1920x1080x32\r\nnative=2560x1440\r\n",&r)); CHECK(usos_display_choose(big,4,&r,0).index==0);
        CHECK(!usos_display_parse("autoxauto\r\nnative=2560\r\n",&r));
        CHECK(!usos_display_parse("autoxauto\r\nnative=100x100\r\n",&r));
        CHECK(!usos_display_parse("autoxauto\r\nnative=2560x1440;x\r\n",&r));
        for(i=0;i<128;i++)e[i]=edid_1440[i];
        for(i=0;i<127;i++)sum+=e[i]; e[127]=(unsigned char)(256-(sum&255));
        CHECK(usos_edid_native(e,128,&w,&h) && w==2560 && h==1440);
        e[127]^=1; CHECK(!usos_edid_native(e,128,&w,&h)); e[127]^=1;
        CHECK(!usos_edid_native(e,127,&w,&h));
        e[0]=1; CHECK(!usos_edid_native(e,128,&w,&h));
    }
    {   /* 8.1 / 10 x86 on CSMWrap (X470 2026-10-22, BenQ GL2250H): Microsoft
           Basic Display at 1024x768 lists the VBIOS modes 1280x1024 and
           1920x1080; native from EDID picks 1920x1080, not already there. */
        static UsosDisplayMode basic[] = {
            {800,600,32,0,0,1}, {1024,768,32,0,0,1}, {1280,1024,32,0,0,1}, {1920,1080,32,0,0,1}};
        CHECK(usos_display_parse("autoxauto\r\nnative=1920x1080\r\n",&r));
        CHECK(usos_display_already(basic,4,&r,0,1024,768,32,&c)<0 && c.index==3 && c.reason[0]=='n');
        /* Already at native: no-op (no test, no apply). */
        CHECK(usos_display_already(basic,4,&r,0,1920,1080,32,&c)==3);
        /* No EDID: the highest of the driver's list. */
        CHECK(usos_display_parse("autoxauto\r\n",&r));
        CHECK(usos_display_already(basic,4,&r,0,1024,768,32,&c)<0 && c.index==3 && c.reason[0]=='h');
        /* Native size missing from the list: largest mode that fits, never a
           synthetic native mode. */
        CHECK(usos_display_parse("autoxauto\r\nnative=1680x1050\r\n",&r));
        CHECK(usos_display_already(basic,4,&r,0,1024,768,32,&c)<0 && c.index==2 && c.reason[0]=='b');
        CHECK(usos_display_already(basic,4,&r,0,1024,768,16,&c)<0);
        CHECK(usos_display_already(NULL,0,&r,0,1024,768,32,&c)<0 && c.index==-1);
    }
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
