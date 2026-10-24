/* Copyright (C) 2026 Maksymilian and the USOS Authors
 * SPDX-License-Identifier: GPL-3.0-or-later */
/* Log the actual Windows mode, then launch the unmodified browser.
 * Interactive browser: one bounded final capture, visual and PCAP validation.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later. */
#include <windows.h>
#include <string.h>
int PASCAL WinMain(HANDLE instance,HANDLE previous,LPSTR command,int show)
{
    HFILE log_file;
    MSG msg;
    char flags[80], launch[256];
    UINT launched;
    (void)instance;(void)previous;(void)show;
    log_file=_lcreat("C:\\NET\\WIN16\\MOSAIC.LOG",0);
    if(log_file==HFILE_ERROR) return 1;
    wsprintf(flags,"GetWinFlags=%lu mode=%s\r\n",GetWinFlags(),
        (GetWinFlags()&WF_STANDARD) && !(GetWinFlags()&WF_ENHANCED)?"STANDARD":"OTHER");
    _lwrite(log_file,flags,(UINT)strlen(flags));
    _lclose(log_file); /* Persist before WinExec can yield to the browser. */
    strcpy(launch,"C:\\NET\\WIN16\\MOSAIC.EXE ");
    if(!strncmp(command,"http://",7) && strlen(command)<180) strcat(launch,command);
    else strcat(launch,"http://68k.news/");
    launched=WinExec(launch,SW_SHOWMAXIMIZED);
    if(launched<32) return 1;
    while(GetMessage(&msg,NULL,0,0)) { TranslateMessage(&msg);DispatchMessage(&msg); }
    return 0;
}
