/* Versioned binary handoff from the NT3 miniport, GPL-3.0-or-later.
 * ULONG is 32 bits in both producer/consumer i386 builds. No pointers. */
#ifndef USOS_DISPLAY_MODES_H
#define USOS_DISPLAY_MODES_H
#define USOS_DISPLAY_MODES_MAGIC 0x314D4455UL
#define USOS_DISPLAY_MODES_COUNT 64
typedef struct { unsigned long width, height, bpp; } UsosDisplayRecord;
typedef struct {
    unsigned long magic, count;
    UsosDisplayRecord modes[USOS_DISPLAY_MODES_COUNT];
} UsosDisplayModeList;
#endif
