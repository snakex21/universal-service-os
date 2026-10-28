/* Read-only Win16 VBE query result for the Win32 display helper. GPL-3.0-or-later. */
#ifndef USOS_DISPLAY_VBE_H
#define USOS_DISPLAY_VBE_H
#define USOS_DISPLAY_VBE_MAGIC 0x31425655UL
#define USOS_DISPLAY_VBE_COUNT 64
typedef struct { unsigned long width,height,bpp,pitch,vram; } UsosDisplayVbeMode;
typedef struct { unsigned long magic,count; UsosDisplayVbeMode modes[USOS_DISPLAY_VBE_COUNT]; } UsosDisplayVbeList;
#endif
