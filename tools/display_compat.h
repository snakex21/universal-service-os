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
static LONG usos_display_change(UsosChangeMode change,DEVMODEA *mode,DWORD flags) {
    LONG result=change(mode,flags);
    if(result==DISP_CHANGE_BADFLAGS&&(flags&CDS_GLOBAL))result=change(mode,flags&~CDS_GLOBAL);
    return result;
}
static int usos_display_retry(DWORD current_bpp,int state,LONG result,int permissions) {
    return current_bpp<16 || (state==3&&result==DISP_CHANGE_NOTUPDATED) || (state==0&&permissions);
}
#endif
