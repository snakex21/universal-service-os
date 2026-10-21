/* SPDX-License-Identifier: GPL-3.0-or-later */
#ifndef USOS_WIN95_UI_CLASSIFY_H
#define USOS_WIN95_UI_CLASSIFY_H
#include <stdint.h>
#include <stddef.h>
typedef struct {
    const char *role;
    uint64_t heading, detail;
    int detail_x, detail_y, detail_w, detail_h;
} Page;
#ifdef WIN95_UI_PROFILE_TEST_HEADER
#include WIN95_UI_PROFILE_TEST_HEADER
#else
#include "win95_ui_profile.h"
#endif
static uint64_t fingerprint(const unsigned char *pixels, unsigned width,
                            int x, int y, int w, int h)
{
    uint64_t value = UINT64_C(14695981039346656037);
    int row, col;
    for (row = y; row < y + h; ++row) {
        const unsigned char *p = pixels + ((size_t)row * width + (unsigned)x) * 3;
        for (col = 0; col < w * 3; ++col) { value ^= p[col]; value *= UINT64_C(1099511628211); }
    }
    return value;
}
static const char *win95_classify(const unsigned char *pixels, unsigned width, unsigned height)
{
    size_t i;
    uint64_t heading;
    if (width != 640 || height != 480) return "unknown";
    heading = fingerprint(pixels, width, 104, 90, 480, 24);
    for (i = 0; i < sizeof pages / sizeof pages[0]; ++i) {
        if (pages[i].heading != heading) continue;
        if (pages[i].detail && pages[i].detail != fingerprint(pixels, width,
            pages[i].detail_x, pages[i].detail_y, pages[i].detail_w, pages[i].detail_h)) continue;
        return pages[i].role;
    }
    return "unknown";
}
#endif
