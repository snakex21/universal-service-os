/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <windows.h>
#include "page_policy.h"
#include "gui_policy.h"
static char page[2000];
static void text(const char *s){unsigned int n=0;for(n=0;n<2000;n++)page[n]=' ';for(n=0;s[n] && n<2000;n++)page[n]=s[n];}
void entry(void)
{
    struct nt31_page_state state={NT31_NONE,0,0};
    text("Welcome to Setup.");if(nt31_answer(&state,page,2000,1)!=NT31_WELCOME)ExitProcess(1);
    if(nt31_answer(&state,page,2000,20)!=NT31_NONE)ExitProcess(2);
    if(nt31_answer(&state,page,2000,31)!=NT31_WELCOME)ExitProcess(3);
    if(nt31_page(page,1999)!=NT31_NONE)ExitProcess(4);
    text("select the partition where you would like to install D: NTFS");if(nt31_page(page,2000)!=NT31_NONE)ExitProcess(5);
    text("select the partition where you would like to install C: FAT");if(nt31_page(page,2000)!=NT31_PARTITION)ExitProcess(6);
    text("select a file system option FAT");if(nt31_page(page,2000)!=NT31_FILESYSTEM)ExitProcess(7);
    text("Choose the location \\WINNT");if(nt31_page(page,2000)!=NT31_LOCATION)ExitProcess(8);
    text("Press CTRL+ALT+DELETE to restart");if(nt31_answer(&state,page,2000,32)!=NT31_RESTART)ExitProcess(9);
    if(nt31_answer(&state,page,2000,21601)!=NT31_NONE)ExitProcess(10);
    text("Unrecognized Setup failure");if(nt31_page(page,2000)!=NT31_NONE)ExitProcess(11);
    text("Express Setup (recommended)");if(nt31_page(page,2000)!=NT31_EXPRESS)ExitProcess(12);
    if(!nt31_year("2026") || !nt31_year("1990") || !nt31_year("2099"))ExitProcess(13);
    if(nt31_year("26") || nt31_year("20261") || nt31_year("20x6") || nt31_year("1990extra"))ExitProcess(14);
    if(!nt31_domain("USOSDOMAIN") || !nt31_domain("USOS-NT31") || !nt31_domain("ABCDEFGHIJKLMNO"))ExitProcess(15);
    if(nt31_domain("") || nt31_domain("ABCDEFGHIJKLMNOP") || nt31_domain("-BAD") || nt31_domain("BAD-") || nt31_domain("lower") || nt31_domain("BAD\\NAME"))ExitProcess(16);
    ExitProcess(0);
}
