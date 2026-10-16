/* SPDX-License-Identifier: GPL-3.0-or-later
 * Private Windows 95 PL Setup page guard. Own code; no Windows source code.
 * The profile contains hashes of static labels, never key/owner fields.
 * Unknown, busy and malformed screens must never receive a product key.
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <ctype.h>

typedef struct {
    const char *role;
    uint64_t heading;
    uint64_t detail;
    int detail_x, detail_y, detail_w, detail_h;
} Page;

#include "win95_ui_profile.h"

static int token(FILE *f, char *out, unsigned capacity)
{
    int c;
    unsigned n = 0;
    for (;;) {
        c = fgetc(f);
        if (c == EOF) return 0;
        if (isspace((unsigned char)c)) continue;
        if (c == '#') {
            do { c = fgetc(f); } while (c != '\n' && c != EOF);
            continue;
        }
        break;
    }
    do {
        if (n + 1 >= capacity) return 0;
        out[n++] = (char)c;
        c = fgetc(f);
    } while (c != EOF && !isspace((unsigned char)c));
    out[n] = 0;
    if (c == '\r') {
        c = fgetc(f);
        if (c != '\n' && c != EOF) ungetc(c, f);
    }
    return n != 0;
}

static uint64_t fingerprint(const unsigned char *pixels, unsigned width,
                            int x, int y, int w, int h)
{
    uint64_t value = UINT64_C(14695981039346656037);
    int row, col;
    for (row = y; row < y + h; ++row) {
        const unsigned char *p = pixels + ((size_t)row * width + (unsigned)x) * 3;
        for (col = 0; col < w * 3; ++col) {
            value ^= p[col];
            value *= UINT64_C(1099511628211);
        }
    }
    return value;
}

int main(int argc, char **argv)
{
    FILE *f;
    char word[40];
    unsigned width, height, maximum;
    size_t bytes, i;
    unsigned char *pixels;
    uint64_t heading;
    const char *role = "unknown";
    if (argc != 2) return 2;
    f = fopen(argv[1], "rb");
    if (!f) return 2;
    if (!token(f, word, sizeof word) || strcmp(word, "P6") ||
        !token(f, word, sizeof word) || sscanf(word, "%u", &width) != 1 ||
        !token(f, word, sizeof word) || sscanf(word, "%u", &height) != 1 ||
        !token(f, word, sizeof word) || sscanf(word, "%u", &maximum) != 1 ||
        width != 640 || height != 480 || maximum != 255) {
        fclose(f);
        puts("unknown");
        return 0;
    }
    bytes = (size_t)width * height * 3;
    pixels = (unsigned char *)malloc(bytes);
    if (!pixels) { fclose(f); return 2; }
    if (fread(pixels, 1, bytes, f) != bytes) {
        free(pixels); fclose(f); return 2;
    }
    fclose(f);
    heading = fingerprint(pixels, width, 104, 90, 480, 24);
    for (i = 0; i < sizeof pages / sizeof pages[0]; ++i) {
        if (pages[i].heading != heading) continue;
        if (pages[i].detail && pages[i].detail != fingerprint(pixels, width,
                pages[i].detail_x, pages[i].detail_y,
                pages[i].detail_w, pages[i].detail_h)) continue;
        role = pages[i].role;
        break;
    }
    free(pixels);
    puts(role);
    return 0;
}
