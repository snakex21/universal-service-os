/* SPDX-License-Identifier: GPL-3.0-or-later
 * Exercise the real renderer in memory DIBs only. No desktop hooks, wallpaper
 * settings, registry writes or process attachment run on the development host.
 */
#include "../nt6/usoswm/common.h"
static MONITORINFO fixture;
static BOOL WINAPI fixture_monitor(HMONITOR monitor,MONITORINFO *out){(void)monitor;*out=fixture;return TRUE;}
#define GetMonitorInfoW fixture_monitor
#include "../nt6/usoswm/desktop.c"
#undef GetMonitorInfoW

static DWORD colour(COLORREF value){return (GetRValue(value)<<16)|(GetGValue(value)<<8)|GetBValue(value);}
static HBITMAP dib(HDC dc,int width,int height,DWORD **pixels){
 BITMAPINFO info={0};info.bmiHeader.biSize=sizeof(BITMAPINFOHEADER);info.bmiHeader.biWidth=width;info.bmiHeader.biHeight=-height;info.bmiHeader.biPlanes=1;info.bmiHeader.biBitCount=32;info.bmiHeader.biCompression=BI_RGB;
 return CreateDIBSection(dc,&info,DIB_RGB_COLORS,(void**)pixels,0,0);
}
static DWORD scene(DWORD style,int left,int top){
 HDC dc=CreateCompatibleDC(0);if(!dc)return 1;
 DWORD *pixels=0,*source=0;HBITMAP destination=dib(dc,32,32,&pixels);wallpaper=dib(dc,3,2,&source);
 if(!destination||!wallpaper)return 2;
 HGDIOBJ old=SelectObject(dc,destination);GetObjectW(wallpaper,sizeof(wallpaper_info),&wallpaper_info);wallpaper_style=style;
 const DWORD colours[6]={0x00ff0000,0x0000ff00,0x000000ff,0x00ffff00,0x0000ffff,0x00ff00ff};
 for(unsigned i=0;i<6;i++)source[i]=style==WPSTYLE_STRETCH?0x00ff8844:colours[i];
 for(unsigned i=0;i<32*32;i++)pixels[i]=0x00112233;
 fixture=(MONITORINFO){sizeof(fixture),{left,top,left+10,top+8},{left,top,left+10,top+8},MONITORINFOF_PRIMARY};
 POINT origin={left-2,top-4};SetWindowOrgEx(dc,origin.x,origin.y,0);
 RECT update={left+2,top+2,left+8,top+6};
 if(!paint_background((HMONITOR)1,dc,&update))return 3;
 /* Stretch: the second paint must come from the cached scaled bitmap. */
 if(style==WPSTYLE_STRETCH&&(!scaled||scaled_width!=10||scaled_height!=8||!paint_background((HMONITOR)1,dc,&update)))return 7;
 GdiFlush();POINT after={0};GetWindowOrgEx(dc,&after);if(after.x!=origin.x||after.y!=origin.y)return 4;
 RECT clipping;GetClipBox(dc,&clipping);if(clipping.left!=origin.x||clipping.top!=origin.y||clipping.right!=origin.x+32||clipping.bottom!=origin.y+32)return 5;
 for(int y=0;y<32;y++)for(int x=0;x<32;x++){
  int logical_x=x+origin.x,logical_y=y+origin.y;DWORD expected=0x00112233;
  if(logical_x>=update.left&&logical_x<update.right&&logical_y>=update.top&&logical_y<update.bottom){
   expected=colour(GetSysColor(COLOR_DESKTOP));
   if(style==WPSTYLE_TILE)expected=colours[((logical_y-top)%2)*3+(logical_x-left)%3];
   else if(style==WPSTYLE_STRETCH)expected=0x00ff8844;
   else if(logical_x>=left+3&&logical_x<left+6&&logical_y>=top+3&&logical_y<top+5)expected=colours[(logical_y-top-3)*3+logical_x-left-3];
  }
  if((pixels[y*32+x]&0x00ffffff)!=expected)return 6;
 }
 SelectObject(dc,old);DeleteObject(destination);DeleteDC(dc);reset_background();return 0;
}
void entry(void){
 const WCHAR zeroes[]=L"0 0 0 0 0 0 0 0",empty[]=L"",nonzero[]=L"0 0 0 1 0 0 0 0",short_pattern[]=L"0 0",unterminated[]={L'0',L'0'};
 if(!blank_pattern(zeroes,sizeof(zeroes))||!blank_pattern(empty,sizeof(empty))||blank_pattern(nonzero,sizeof(nonzero))||blank_pattern(short_pattern,sizeof(short_pattern))||blank_pattern(unterminated,sizeof(unterminated)))ExitProcess(100);
 const WCHAR dword_zero[]={0,0},dword_nonzero[]={1,0};
 if(!no_desktop_pattern(dword_zero,REG_DWORD,4)||no_desktop_pattern(dword_nonzero,REG_DWORD,4)||no_desktop_pattern(dword_zero,REG_BINARY,4)||!no_desktop_pattern(zeroes,REG_SZ,sizeof(zeroes)))ExitProcess(101);
 for(DWORD style=WPSTYLE_CENTER;style<=WPSTYLE_STRETCH;style++){
  DWORD result=scene(style,10,20);if(result)ExitProcess(10+style*10+result);
  result=scene(style,-12,-10);if(result)ExitProcess(50+style*10+result);
 }
 if(FAILED(CoInitializeEx(0,COINIT_APARTMENTTHREADED)))ExitProcess(110);
 const WCHAR *files[]={L"decode.jpg",L"decode.png",L"decode-alpha.png",L"decode-bad.dat"};
 for(unsigned file=0;file<4;file++){
  WCHAR path[MAX_PATH];if(!wm_directory(0,path))ExitProcess(111);lstrcatW(path,files[file]);BOOL loaded=load_wic_bitmap(path);
  if(file<2){
   if(!loaded)ExitProcess(112);BITMAP bitmap;if(GetObjectW(wallpaper,sizeof(bitmap),&bitmap)!=sizeof(bitmap)||bitmap.bmWidth!=8||bitmap.bmHeight!=4||!bitmap.bmBits)ExitProcess(113);
   DWORD pixel=*(DWORD*)bitmap.bmBits;if((pixel>>24)!=255)ExitProcess(114);
   int red=(pixel>>16)&255,green=(pixel>>8)&255,blue=pixel&255;
   if(red<9||red>15||green<31||green>37||blue<53||blue>59)ExitProcess(115);
  }else if(loaded)ExitProcess(116);
  reset_background();
 }
 CoUninitialize();
 ExitProcess(0);
}
