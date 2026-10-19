/* Shared display selection, Win32 and DOS. USOS, GPL-3.0-or-later. */
#ifndef USOS_DISPLAY_POLICY_H
#define USOS_DISPLAY_POLICY_H

#define USOS_DISPLAY_MAX 256
typedef struct {
    unsigned long width, height, bpp, pitch, vram;
    int valid;
} UsosDisplayMode;
typedef struct { unsigned long width, height, bpp; } UsosDisplayRequest;
typedef struct { int index; const char *reason; } UsosDisplayChoice;

static int usos_display_number(const char **p, unsigned long *out)
{
    unsigned long n = 0;
    const char *s = *p;
    if (*s < '0' || *s > '9') return 0;
    while (*s >= '0' && *s <= '9') {
        n = n * 10 + (unsigned long)(*s++ - '0');
        if (n > 8192) return 0;
    }
    *p = s; *out = n; return 1;
}

/* One token, e.g. 1920x1080x32 or autoxauto. No shell/registry syntax. */
static int usos_display_parse(const char *p, UsosDisplayRequest *r)
{
    r->width = r->height = r->bpp = 0;
    if (p[0]=='a' && p[1]=='u' && p[2]=='t' && p[3]=='o') p += 4;
    else {
        if (!usos_display_number(&p, &r->width) || *p++ != 'x' ||
            !usos_display_number(&p, &r->height) || r->width < 320 || r->height < 200) return 0;
    }
    if (*p++ != 'x') return 0;
    if (p[0]=='a' && p[1]=='u' && p[2]=='t' && p[3]=='o') p += 4;
    else if (!usos_display_number(&p, &r->bpp) || (r->bpp != 16 && r->bpp != 32)) return 0;
    while (*p == '\r' || *p == '\n') p++;
    return *p == 0;
}

static int usos_display_usable(const UsosDisplayMode *m, int double_buffer)
{
    if (!m->valid || m->width < 320 || m->height < 200 || m->width > 8192 || m->height > 8192 ||
        (m->bpp != 16 && m->bpp != 32)) return 0;
    if (double_buffer) {
        unsigned long memory = m->vram;
        if (memory > 128UL * 1024 * 1024) memory = 128UL * 1024 * 1024; /* INF VRAMLimit */
        if (!memory || m->pitch < m->width * (m->bpp / 8) ||
            m->pitch > memory / m->height / 2) return 0; /* no multiply overflow */
    }
    return 1;
}

static UsosDisplayChoice usos_display_choose(const UsosDisplayMode *m, unsigned count,
                                           const UsosDisplayRequest *r, int double_buffer)
{
    UsosDisplayChoice out;
    unsigned i;
    unsigned long maxw = r->width ? r->width : 1920, maxh = r->height ? r->height : 1080;
    unsigned long preferred = r->bpp ? r->bpp : 32, best_area = 0;
    int best_rank = 99;
    out.index = -1; out.reason = "current";
    if (!m || !count || count > USOS_DISPLAY_MAX) return out;
    for (i = 0; i < count; i++) {
        unsigned long area;
        int exact, rank;
        if (!usos_display_usable(&m[i], double_buffer) || m[i].width > maxw || m[i].height > maxh) continue;
        if (m[i].bpp != preferred && m[i].bpp != 16) continue;
        exact = r->width && m[i].width == maxw && m[i].height == maxh;
        /* Exact dimensions, preferred depth, then bounded smaller modes.
           Auto orders by area first, depth only breaks a resolution tie. */
        rank = r->width ? (exact ? 0 : 2) + (m[i].bpp == preferred ? 0 : 1) : 0;
        area = m[i].width * m[i].height;
        if (rank < best_rank || (rank == best_rank && (area > best_area ||
            (area == best_area && out.index >= 0 && m[i].bpp > m[out.index].bpp)))) {
            out.index = (int)i; best_rank = rank; best_area = area;
            out.reason = !r->width ? "auto" : !exact ? "smaller" : m[i].bpp != preferred ? "depth16" : "exact";
        }
    }
    if (out.index < 0) for (i = 0; i < count; i++) {
        if (usos_display_usable(&m[i], double_buffer) && m[i].width == 1024 && m[i].height == 768 && m[i].bpp == 16) {
            out.index = (int)i; out.reason = "safe1024"; break;
        }
    }
    return out;
}
#endif
