/* Shared display selection, Win32 and DOS. USOS, GPL-3.0-or-later. */
#ifndef USOS_DISPLAY_POLICY_H
#define USOS_DISPLAY_POLICY_H

#define USOS_DISPLAY_MAX 256
/* Upper bound of auto (native or highest). 9x keeps 1920x1080: the VESA
   VxD path (vmdisp9x) was only proven up to there (docs/display-policy.md). */
#ifndef USOS_DISPLAY_AUTO_MAX_W
#define USOS_DISPLAY_AUTO_MAX_W 8192
#define USOS_DISPLAY_AUTO_MAX_H 8192
#endif
typedef struct {
    unsigned long width, height, bpp, pitch, vram;
    int valid;
} UsosDisplayMode;
/* native_*: the monitor's preferred timing (EDID), 0 = unknown. Only auto
   uses it (docs/display-policy.md): native, else the highest mode. */
typedef struct { unsigned long width, height, bpp, native_width, native_height; } UsosDisplayRequest;
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

/* Native size from EDID (preferred detailed timing) as WxH, 0 = none. */
static int usos_display_native(const char **p, UsosDisplayRequest *r)
{
    if (!usos_display_number(p, &r->native_width) || *(*p)++ != 'x' ||
        !usos_display_number(p, &r->native_height) || r->native_width < 320 || r->native_height < 200) {
        r->native_width = r->native_height = 0; return 0;
    }
    return 1;
}

/* One token, e.g. 1920x1080x32 or autoxauto, optionally followed by a line
   native=WxH (the monitor's EDID, read at preparation time). No shell or
   registry syntax. */
static int usos_display_parse(const char *p, UsosDisplayRequest *r)
{
    r->width = r->height = r->bpp = r->native_width = r->native_height = 0;
    if (p[0]=='a' && p[1]=='u' && p[2]=='t' && p[3]=='o') p += 4;
    else {
        if (!usos_display_number(&p, &r->width) || *p++ != 'x' ||
            !usos_display_number(&p, &r->height) || r->width < 320 || r->height < 200) return 0;
    }
    if (*p++ != 'x') return 0;
    if (p[0]=='a' && p[1]=='u' && p[2]=='t' && p[3]=='o') p += 4;
    else if (!usos_display_number(&p, &r->bpp) || (r->bpp != 16 && r->bpp != 32)) return 0;
    while (*p == '\r' || *p == '\n') p++;
    if (p[0]=='n' && p[1]=='a' && p[2]=='t' && p[3]=='i' && p[4]=='v' && p[5]=='e' && p[6]=='=') {
        p += 7;
        if (!usos_display_native(&p, r)) return 0;
        while (*p == '\r' || *p == '\n') p++;
    }
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
    /* Fixed request: that size. Auto: the monitor's native size when known
       (exact, else the largest mode within it), otherwise the highest mode. */
    int native = !r->width && r->native_width && r->native_height;
    unsigned long maxw = r->width ? r->width : native ? r->native_width : USOS_DISPLAY_AUTO_MAX_W;
    unsigned long maxh = r->height ? r->height : native ? r->native_height : USOS_DISPLAY_AUTO_MAX_H;
    if (!r->width && maxw > USOS_DISPLAY_AUTO_MAX_W) maxw = USOS_DISPLAY_AUTO_MAX_W;
    if (!r->width && maxh > USOS_DISPLAY_AUTO_MAX_H) maxh = USOS_DISPLAY_AUTO_MAX_H;
    unsigned long preferred = r->bpp ? r->bpp : 32, best_area = 0;
    int best_rank = 99;
    out.index = -1; out.reason = "current";
    if (!m || !count || count > USOS_DISPLAY_MAX) return out;
    for (i = 0; i < count; i++) {
        unsigned long area;
        int exact, rank;
        if (!usos_display_usable(&m[i], double_buffer) || m[i].width > maxw || m[i].height > maxh) continue;
        if (m[i].bpp != preferred && m[i].bpp != 16) continue;
        exact = (r->width || native) && m[i].width == maxw && m[i].height == maxh;
        /* Exact dimensions, preferred depth, then bounded smaller modes.
           Auto orders by area first (native exact first when known), depth
           only breaks a resolution tie. */
        rank = r->width ? (exact ? 0 : 2) + (m[i].bpp == preferred ? 0 : 1) : native && !exact ? 1 : 0;
        area = m[i].width * m[i].height;
        if (rank < best_rank || (rank == best_rank && (area > best_area ||
            (area == best_area && out.index >= 0 && m[i].bpp > m[out.index].bpp)))) {
            out.index = (int)i; best_rank = rank; best_area = area;
            out.reason = native ? (exact ? "native" : "below-native") : !r->width ? "highest" :!exact ? "smaller" : m[i].bpp != preferred ? "depth16" : "exact";
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
