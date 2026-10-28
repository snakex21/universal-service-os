/* USOSADD string helpers (no C library). GPL-3.0-or-later. */
#include "ua.h"

static int lower(int c) { return (c >= 'A' && c <= 'Z') ? c + 32 : c; }

int ua_len(const char *s) { int n = 0; while (s[n]) n++; return n; }

int ua_ieq(const char *a, const char *b) {
    while (*a && *b) { if (lower((unsigned char)*a) != lower((unsigned char)*b)) return 0; a++; b++; }
    return *a == 0 && *b == 0;
}

int ua_ieqn(const char *a, const char *b, int n) {
    int i;
    for (i = 0; i < n; i++) {
        if (lower((unsigned char)a[i]) != lower((unsigned char)b[i])) return 0;
        if (a[i] == 0) return 1;
    }
    return 1;
}

int ua_starts(const char *s, const char *prefix) { return ua_ieqn(s, prefix, ua_len(prefix)) && ua_len(s) >= ua_len(prefix); }

void ua_copy(char *dst, int cap, const char *src) {
    int i = 0;
    if (cap <= 0) return;
    while (src[i] && i < cap - 1) { dst[i] = src[i]; i++; }
    dst[i] = 0;
}

void ua_append_n(char *dst, int cap, const char *src, int n) {
    int d = ua_len(dst), i = 0;
    while (i < n && src[i] && d < cap - 1) dst[d++] = src[i++];
    dst[d] = 0;
}

void ua_append(char *dst, int cap, const char *src) { ua_append_n(dst, cap, src, 0x7fffffff); }

char *ua_find(const char *s, const char *needle) {
    int n = ua_len(needle), i;
    if (n == 0) return (char *)s;
    for (; *s; s++) {
        for (i = 0; i < n && s[i] == needle[i]; i++) ;
        if (i == n) return (char *)s;
    }
    return 0;
}

int ua_atoi(const char *s) {
    int v = 0, neg = 0;
    while (*s == ' ') s++;
    if (*s == '-') { neg = 1; s++; }
    while (*s >= '0' && *s <= '9') { v = v * 10 + (*s - '0'); s++; }
    return neg ? -v : v;
}

void ua_itoa(char *dst, int cap, int v) {
    char tmp[16];
    int n = 0, i = 0;
    unsigned u = v < 0 ? (unsigned)(-v) : (unsigned)v;
    do { tmp[n++] = (char)('0' + u % 10); u /= 10; } while (u && n < 15);
    if (v < 0 && i < cap - 1) dst[i++] = '-';
    while (n && i < cap - 1) dst[i++] = tmp[--n];
    dst[i] = 0;
}

/* Parses up to max components; returns the count. */
static int ver_parts(const char *s, long *out, int max) {
    int n = 0, have = 0;
    long v = 0;
    for (;; s++) {
        char c = *s, l = (char)(c | 32);
        if (c >= '0' && c <= '9') { v = v * 10 + (c - '0'); have = 1; continue; }
        if (have && n < max) out[n++] = v;
        v = 0;
        have = 0;
        if (l >= 'a' && l <= 'z') { if (n < max) out[n++] = l - 'a' + 1; continue; }
        if (c == '.' || c == ',') continue;
        if (c == ' ' && n == 0) continue;
        break;
    }
    return n;
}

int ua_vercmp(const char *a, const char *b) {
    long pa[8], pb[8];
    int na = ver_parts(a, pa, 8), nb = ver_parts(b, pb, 8), i;
    for (i = 0; i < na || i < nb; i++) {
        long x = i < na ? pa[i] : 0, y = i < nb ? pb[i] : 0;
        if (x != y) return x < y ? -1 : 1;
    }
    return 0;
}

int ua_list_item(const char *list, int index, char *out, int cap) {
    int i = 0;
    const char *p = list;
    if (!list) return 0;
    for (;;) {
        const char *start, *end;
        while (*p == ' ' || *p == '\t') p++;
        start = p;
        while (*p && *p != ',') p++;
        end = p;
        while (end > start && (end[-1] == ' ' || end[-1] == '\t')) end--;
        if (end > start) {
            if (i == index) {
                int n = (int)(end - start);
                if (n > cap - 1) n = cap - 1;
                ua_copy(out, n + 1, start);
                return 1;
            }
            i++;
        }
        if (!*p) return 0;
        p++;
    }
}

int ua_list_has(const char *list, const char *item) {
    char buf[64];
    int i;
    for (i = 0; ua_list_item(list, i, buf, sizeof buf); i++)
        if (ua_ieq(buf, item)) return 1;
    return 0;
}
