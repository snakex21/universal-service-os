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

#include "win95_ui_classify.h"

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

int main(int argc, char **argv)
{
    FILE *f;
    char word[40];
    unsigned width, height, maximum;
    size_t bytes;
    unsigned char *pixels;
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
    role = win95_classify(pixels, width, height);
    free(pixels);
    puts(role);
    return 0;
}
