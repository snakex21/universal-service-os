/* Old USER32 adapter, also exercised with fake APIs on the host. GPL-3.0-or-later. */
#ifndef USOS_DISPLAY_COMPAT_H
#define USOS_DISPLAY_COMPAT_H
typedef BOOL (WINAPI *UsosEnumModes)(LPCSTR,DWORD,DEVMODEA *);
typedef LONG (WINAPI *UsosChangeMode)(DEVMODEA *,DWORD);
typedef int (*UsosCurrentCaps)(DWORD *,DWORD *,DWORD *);
static unsigned usos_display_dm_size(DWORD version) {
    unsigned major=version&255;
    return major<4?124:major<5?148:156;
}
static int usos_display_enum(UsosEnumModes enumerate,DWORD version,DWORD index,DEVMODEA *mode) {
    unsigned sizes[4],i,j; BYTE *p;
    sizes[0]=usos_display_dm_size(version);sizes[1]=156;sizes[2]=148;sizes[3]=124;
    for(i=0;i<4;i++) {
        for(j=0;j<i;j++)if(sizes[j]==sizes[i])break;
        if(j<i)continue;
        p=(BYTE *)mode;for(j=0;j<sizeof *mode;j++)p[j]=0;
        mode->dmSize=(WORD)sizes[i];
        if(enumerate(NULL,index,mode))return 1;
    }
    return 0;
}
static int usos_display_current(UsosEnumModes enumerate,DWORD version,UsosCurrentCaps caps,DEVMODEA *mode) {
    DWORD width,height,bpp;unsigned i;
    if(usos_display_enum(enumerate,version,(DWORD)-1,mode))return 1;
    if(!caps(&width,&height,&bpp))return 0;
    /* A real enumerated mode is required for rollback, never a guessed DEVMODE. */
    for(i=0;i<256;i++) {
        if(!usos_display_enum(enumerate,version,i,mode))break;
        if(mode->dmPelsWidth==width&&mode->dmPelsHeight==height&&mode->dmBitsPerPel==bpp)return 1;
    }
    return 0;
}
/* NT version policy (GetVersion(): low byte major, next byte minor). NT5:
   CDS_GLOBAL (the setup-end user is an administrator). 6.x and later
   (Vista 6.0, 7 6.1, 8 6.2, 8.1 6.3, 10 as 6.2 without a supportedOS
   manifest, 10.0 with one): no CDS_GLOBAL, the settings are per machine and
   CDS_GLOBAL needs an elevated token the first sign-in under UAC lacks;
   each user's HKCU Run value is removed (Default-hive registration). */
static DWORD usos_display_flags(DWORD version) {
    return CDS_UPDATEREGISTRY|((version&255)==5?CDS_GLOBAL:0);
}
static int usos_display_user_run(DWORD version) {return (version&0x80000000UL)==0 && (version&255)>=6;}
static LONG usos_display_change(UsosChangeMode change,DEVMODEA *mode,DWORD flags) {
    LONG result=change(mode,flags);
    if(result==DISP_CHANGE_BADFLAGS&&(flags&CDS_GLOBAL))result=change(mode,flags&~CDS_GLOBAL);
    return result;
}
/* Refresh policy (docs/display-policy.md): progressive modes only, at 60 Hz
   or the driver default (0 / 1). One exception: a driver that reports a
   single refresh value for every progressive mode of its list sets no timing
   of its own (Microsoft Basic Display on the VBIOS VBE via CSMWrap, X470
   Win10 x86 2026-10-22: 15 modes, none at 60 / default, "no tested mode").
   That value is the driver's own, not a guessed refresh, so the modes
   count; CDS_TEST still gates each one. Lists with several refresh values
   keep the strict rule. Returns 1 and the shared value when uniform. */
static int usos_display_uniform_refresh(const DEVMODEA *s,unsigned count,DWORD *hz) {
    unsigned i; int seen=0; DWORD value=0;
    for(i=0;i<count;i++) {
        if(s[i].dmDisplayFlags&DM_INTERLACED) continue;
        if(!seen) {value=s[i].dmDisplayFrequency;seen=1;}
        else if(s[i].dmDisplayFrequency!=value) return 0;
    }
    *hz=value; return seen;
}
static int usos_display_refresh_ok(const DEVMODEA *mode,int uniform,DWORD uniform_hz) {
    if(mode->dmDisplayFlags&DM_INTERLACED) return 0;
    if(mode->dmDisplayFrequency<=1 || mode->dmDisplayFrequency==60) return 1;
    return uniform && mode->dmDisplayFrequency==uniform_hz;
}
static int usos_display_retry(DWORD current_bpp,int state,LONG result,int permissions) {
    return current_bpp<16 || (state==3&&result==DISP_CHANGE_NOTUPDATED) || (state==0&&permissions);
}
#endif
