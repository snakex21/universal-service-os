/* EDID preferred timing (VESA E-EDID 1.3/1.4 base block: the first detailed
 * timing descriptor at offset 54 is the preferred / native mode).
 * USOS, Copyright 2026 Maksymilian and the USOS Authors, GPL-3.0-or-later.
 * Same rules as src/display/edid.zig (UEFI menu). Pure: no OS calls. */
#ifndef USOS_DISPLAY_EDID_H
#define USOS_DISPLAY_EDID_H

static int usos_edid_native(const unsigned char *e, unsigned long n,
                            unsigned long *width, unsigned long *height)
{
    static const unsigned char header[8] = {0, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0};
    unsigned i, sum = 0;
    unsigned long w, h;
    if (!e || n < 128) return 0;
    for (i = 0; i < 8; i++) if (e[i] != header[i]) return 0;
    for (i = 0; i < 128; i++) sum += e[i];
    if (sum & 255) return 0;
    if (!e[54] && !e[55]) return 0; /* pixel clock 0: not a timing */
    w = (unsigned long)e[56] | ((unsigned long)(e[58] & 0xF0) << 4);
    h = (unsigned long)e[59] | ((unsigned long)(e[61] & 0xF0) << 4);
    if (e[71] & 0x80) h *= 2; /* interlaced: the field height */
    if (w < 320 || h < 200 || w > 8192 || h > 8192) return 0;
    *width = w; *height = h;
    return 1;
}
#endif
