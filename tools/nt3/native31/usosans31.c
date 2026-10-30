/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 USOS Authors
 * Own NT31 GUI answerer; controls measured on the original CD:
 * MAIN.CPL dialog7; NCPA.CPL dialogs 6330 (AS domain), 6310 (WS workgroup),
 * 6290 (TCP/IP, fallback Cancel), the workgroup welcome box. No generic Enter/Alt+N.
 * Logs/config beside the executable. No Edit control text is logged.
 */
#define entry record_only_entry
#include "../usosans3/usosans3.c"
#undef entry
#include "gui_policy.h"

static char config[MAX_PATH],domain[16],workgroup[16];
static HWND last_window;
static DWORD last_action;

static int control(HWND w,int id,const char *kind)
{
    char cls[64];HWND c=GetDlgItem(w,id);
    return c && IsWindowVisible(c) && GetClassNameA(c,cls,sizeof cls) && !lstrcmpiA(cls,kind);
}
/* A Static child of w whose text contains part. */
static int has_static(HWND w,const char *part)
{
    char text[160],cls[16];HWND c=GetWindow(w,GW_CHILD);int i,j,n;
    for(n=0;c && n<64;n++,c=GetWindow(c,GW_HWNDNEXT)) {
        if(!GetClassNameA(c,cls,sizeof cls) || lstrcmpiA(cls,"Static"))continue;
        if(!GetWindowTextA(c,text,sizeof text))continue;
        for(i=0;text[i];i++){for(j=0;part[j] && text[i+j]==part[j];j++);if(!part[j])return 1;}
    }
    return 0;
}
static BOOL CALLBACK answer_window(HWND w,LPARAM unused)
{
    char title[80],cls[32],year[8];HWND ok;DWORD now=GetTickCount();
    (void)unused;
    if(!IsWindowVisible(w) || !IsWindowEnabled(w))return TRUE;
    if(w==last_window && now-last_action<30000)return TRUE;
    GetClassNameA(w,cls,sizeof cls);GetWindowTextA(w,title,sizeof title);
    if(lstrcmpA(cls,"#32770"))return TRUE;
    /* NCPA after joining the workgroup: "Welcome to the <name> workgroup."
       (a message box with one OK button). */
    if(has_static(w,"Welcome to the ") && has_static(w," workgroup")) {
        HWND b=GetDlgItem(w,IDOK);
        if(!b)b=GetDlgItem(w,IDCANCEL);
        if(b && IsWindowEnabled(b) && GetWindowTextA(b,cls,sizeof cls) && !lstrcmpiA(cls,"OK")) {
            log_str("action: NT31 workgroup welcome -> OK\r\n");
            last_window=w;last_action=now;PostMessageA(b,BM_CLICK,0,0);
        }
        return TRUE;
    }
    /* Fallback only: the patched OEMNXPTC.INF skips this dialog during
       Setup; if it shows anyway, Cancel (USOSNT3 /net31 writes the address
       at the end of GUI Setup). NCPA.CPL dialog 6290. */
    if(!lstrcmpA(title,"TCP/IP Configuration") && control(w,2001,"Button") && control(w,IDCANCEL,"Button")) {
        HWND c=GetDlgItem(w,IDCANCEL);
        if(!IsWindowEnabled(c))return TRUE;
        log_str("action: NT31 TCP/IP Configuration -> Cancel (address from USOSNT3 /net31)\r\n");
        last_window=w;last_action=now;PostMessageA(c,BM_CLICK,0,0);
        return TRUE;
    }
    ok=GetDlgItem(w,IDOK);
    if(!control(w,IDOK,"Button") || !IsWindowEnabled(ok))return TRUE;
    if(!lstrcmpA(title,"Date/Time") && control(w,701,"Edit") && control(w,704,"Edit") &&
        control(w,706,"Edit") && control(w,740,"ComboBox")) {
        GetDlgItemTextA(w,706,year,sizeof year);
        if(!nt31_year(year) || SendDlgItemMessageA(w,740,CB_GETCURSEL,0,0)==CB_ERR)return TRUE;
        log_str("action: NT31 Date/Time -> OK (existing date and selected zone)\r\n");
    } else if(!lstrcmpA(title,"Domain Settings") && control(w,1213,"Button") &&
        control(w,1211,"Edit") && control(w,1212,"Edit")) {
        HWND radio=GetDlgItem(w,1213);
        if(!IsWindowEnabled(radio))return TRUE;
        SendMessageA(radio,BM_CLICK,0,0);
        if(IsDlgButtonChecked(w,1213)!=BST_CHECKED || !IsWindowEnabled(GetDlgItem(w,1211)))return TRUE;
        if(!SetDlgItemTextA(w,1211,domain))return TRUE;
        log_str("action: NT31 AS -> controller in new configured domain\r\n");
    } else if(!lstrcmpA(title,"Domain/Workgroup Settings") && control(w,1194,"Button") &&
        control(w,1192,"Edit")) {
        /* NCPA.CPL dialog 6310 (Workstation, native LAN): member of the
           configured workgroup, no computer account. */
        HWND radio=GetDlgItem(w,1194);
        if(!IsWindowEnabled(radio))return TRUE;
        SendMessageA(radio,BM_CLICK,0,0);
        if(IsDlgButtonChecked(w,1194)!=BST_CHECKED || !IsWindowEnabled(GetDlgItem(w,1192)))return TRUE;
        if(!SetDlgItemTextA(w,1192,workgroup))return TRUE;
        log_str("action: NT31 WS -> member of configured workgroup\r\n");
    } else return TRUE;
    last_window=w;last_action=now;PostMessageA(ok,BM_CLICK,0,0);
    return TRUE;
}

void entry(void)
{
    DWORD version=GetVersion(),start=GetTickCount(),n;char *cut,configured[64];int i;
    /* GetVersionEx does not exist on NT31; its low WORD is 0x0A03. */
    if((version&0xffff)!=0x0a03 || (version&0x80000000UL))ExitProcess(3);
    n=GetModuleFileNameA(NULL,config,sizeof config);
    if(!n || n>=sizeof(config)-16)ExitProcess(3);
    cut=NULL;for(i=0;config[i];i++)if(config[i]=='\\')cut=config+i+1;
    if(!cut)ExitProcess(3);lstrcpyA(cut,"NATIVE31.INI");
    GetPrivateProfileStringA("native","domain","USOSDOMAIN",configured,sizeof configured,config);
    if(!nt31_domain(configured))ExitProcess(3);
    lstrcpyA(domain,configured);
    GetPrivateProfileStringA("native","workgroup","WORKGROUP",configured,sizeof configured,config);
    if(!nt31_domain(configured))lstrcpyA(configured,"WORKGROUP");
    lstrcpyA(workgroup,configured);
    log_next_to_exe();CreateMutexA(NULL,TRUE,"USOSANS31");if(GetLastError()==ERROR_ALREADY_EXISTS)ExitProcess(0);
    log_str("USOSANS31 candidate: exact NT31 GUI rules; runtime unqualified\r\n");
    while(GetTickCount()-start<6UL*3600UL*1000UL && g_logged<LOG_MAX) {
        g_len=0;g_dump[0]=0;EnumWindows(top_proc,0);
        if(lstrcmpA(g_dump,g_last)) {write_log(g_dump,g_len);copy(g_last,g_dump,g_len+1);}
        EnumWindows(answer_window,0);Sleep(1000);
    }
    ExitProcess(0);
}
