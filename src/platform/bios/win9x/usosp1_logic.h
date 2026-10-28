/*
 * USOSP1.DRV text edits (src/platform/bios/win9x/usosp1.c), kept free of
 * Windows calls so the host test (tools/tests/legacy_bios/test_usosp1.py)
 * compiles them with zig cc. The same two edits as the VM path's
 * w9x_phase1_patch_c (tools/w9x_phase1_qemu.sh) does on the VM path:
 *   SYSTEM.INI  every [386Enh] line `mouse=` (any case, leading blanks)
 *               goes; the section starts at a line `[386Enh]...` (leading
 *               blanks allowed) and ends at the next line starting with `[`.
 *   MSDOS.SYS   with a line starting `[Options]` (any case) and no line
 *               `logo=` anywhere (leading blanks allowed): `Logo=0` CR LF
 *               then `BootLog=1` CR LF right after the first `[Options]`
 *               line. BootLog=1 writes C:\BOOTLOG.TXT on every boot, so an
 *               unexplained power-off at boot under CSMWrap names the last
 *               VxD (valid on Me / 98; 95 950 PL rejects it, but 95/98 take
 *               Logo=0 from INSTALL.BAT in real mode and never reach here,
 *               their MSDOS.SYS already has a logo= line). A user's own
 *               logo= line leaves the file untouched.
 * Lines end at LF (a CR before it stays part of the line); a last line
 * without LF is a line too.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 */
#ifndef USOSP1_LOGIC_H
#define USOSP1_LOGIC_H

/* P1_MAX: the largest file handled (SYSTEM.INI after Setup's phase 1 is
 * about 2 KiB, MSDOS.SYS about 1.7 KiB); larger ones are left alone. */
#define P1_MAX   16000u
#define P1_SLACK 32u     /* "Logo=0\r\nBootLog=1\r\n" (20) or
                            "mouse.drv=usosmous.drv\r\n" (24), + a leading CR LF */

enum { P1_SAME = 0, P1_CHANGED = 1, P1_PRESENT = 2, P1_NO_OPTIONS = 3, P1_TOO_BIG = 4 };

static unsigned char p1_low(unsigned char c)
{
    return (unsigned char)(c >= 'A' && c <= 'Z' ? c + 32 : c);
}

/* Line [s, s+n): after `skip_blanks` spaces/tabs, does it start with word
 * (lower case) in any case? */
static int p1_starts(const char *s, unsigned n, int skip_blanks, const char *word)
{
    unsigned i = 0, k;
    if (skip_blanks)
        while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    for (k = 0; word[k]; k++, i++)
        if (i >= n || p1_low((unsigned char)s[i]) != (unsigned char)word[k]) return 0;
    return 1;
}

/* `key[ \t]*=` after leading blanks. */
static int p1_is_key(const char *s, unsigned n, const char *key)
{
    unsigned i = 0, k;
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    for (k = 0; key[k]; k++, i++)
        if (i >= n || p1_low((unsigned char)s[i]) != (unsigned char)key[k]) return 0;
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    return i < n && s[i] == '=';
}

static unsigned p1_line(const char *in, unsigned n, unsigned at)
{
    unsigned e = at;
    while (e < n && in[e] != '\n') e++;
    return e < n ? e + 1 : e;           /* one past the LF, or the end */
}

/* SYSTEM.INI: out (room for n) gets in without its [386Enh] mouse= lines.
 * *len = the new length, *removed = lines removed. P1_CHANGED or P1_SAME
 * (P1_TOO_BIG for n > P1_MAX, out untouched). */
static int p1_drop_mouse(const char *in, unsigned n, char *out, unsigned *len, unsigned *removed)
{
    unsigned at = 0, o = 0, e, i;
    int in386 = 0;
    *len = 0;
    *removed = 0;
    if (n > P1_MAX) return P1_TOO_BIG;
    while (at < n) {
        e = p1_line(in, n, at);
        if (p1_starts(in + at, e - at, 1, "[")) in386 = p1_starts(in + at, e - at, 1, "[386enh]");
        else if (in386 && p1_is_key(in + at, e - at, "mouse")) { (*removed)++; at = e; continue; }
        for (i = at; i < e; i++) out[o++] = in[i];
        at = e;
    }
    *len = o;
    return *removed ? P1_CHANGED : P1_SAME;
}

/* SYSTEM.INI [boot] mouse.drv=usosmous.drv (Me, X470 2026-10-28: the
 * first start after phase 1 ran with Setup's mouse.drv=mouse.drv, BOOTLOG
 * "No mouse driver installed", so the hardware setup and the first-start
 * wizard had no USB mouse; 98 / 98 SE get the same line from U9FIX /CSM in
 * real mode at every start). Every mouse.drv= line of [boot] (any case,
 * leading blanks) gets the value; with none, one is added right after the
 * first [boot] line. Other sections stay. out has room for n + P1_SLACK.
 * P1_CHANGED, P1_SAME (already usosmous.drv), P1_NO_OPTIONS (no [boot])
 * or P1_TOO_BIG; *len = the new length (0 unless changed). */
static int p1_value_is(const char *s, unsigned n, const char *want)
{
    unsigned i = 0, k;
    while (i < n && s[i] != '=') i++;
    if (i >= n) return 0;
    i++;
    while (i < n && (s[i] == ' ' || s[i] == '\t')) i++;
    for (k = 0; want[k]; k++, i++)
        if (i >= n || p1_low((unsigned char)s[i]) != (unsigned char)want[k]) return 0;
    while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
    return i == n;
}

static int p1_set_mousedrv(const char *in, unsigned n, char *out, unsigned *len)
{
    static const char line[] = "mouse.drv=usosmous.drv\r\n";
    unsigned at, e, o = 0, i, boot_end = n + 1;
    int inboot = 0, found = 0, changed = 0;
    *len = 0;
    if (n > P1_MAX) return P1_TOO_BIG;
    for (at = 0; at < n; at = e) {
        e = p1_line(in, n, at);
        if (p1_starts(in + at, e - at, 1, "[")) {
            inboot = p1_starts(in + at, e - at, 1, "[boot]");
            if (inboot && boot_end > n) boot_end = e;
        } else if (inboot && p1_is_key(in + at, e - at, "mouse.drv")) {
            found = 1;
            if (!p1_value_is(in + at, e - at, "usosmous.drv")) {
                for (i = 0; line[i]; i++) out[o++] = line[i];
                changed = 1;
                continue;
            }
        }
        for (i = at; i < e; i++) out[o++] = in[i];
    }
    if (boot_end > n) return P1_NO_OPTIONS;
    if (!found) {
        /* again, with the line right after the [boot] header */
        o = 0;
        for (i = 0; i < boot_end; i++) out[o++] = in[i];
        if (boot_end == n && (n == 0 || in[n - 1] != '\n')) { out[o++] = '\r'; out[o++] = '\n'; }
        for (i = 0; line[i]; i++) out[o++] = line[i];
        for (i = boot_end; i < n; i++) out[o++] = in[i];
        changed = 1;
    }
    if (!changed) return P1_SAME;
    *len = o;
    return P1_CHANGED;
}

/* MSDOS.SYS: out (room for n + P1_SLACK) gets in with Logo=0 and BootLog=1
 * added (see the top). Returns P1_CHANGED, P1_PRESENT (a logo= line exists),
 * P1_NO_OPTIONS or P1_TOO_BIG; *len = the new length (0 unless changed). */
static int p1_add_logo(const char *in, unsigned n, char *out, unsigned *len)
{
    static const char add[] = "Logo=0\r\nBootLog=1\r\n";
    unsigned at, e, o = 0, i, opt = n + 1;
    *len = 0;
    if (n > P1_MAX) return P1_TOO_BIG;
    for (at = 0; at < n; at = e) {
        e = p1_line(in, n, at);
        if (p1_is_key(in + at, e - at, "logo")) return P1_PRESENT;
        if (opt > n && p1_starts(in + at, e - at, 0, "[options]")) opt = e;
    }
    if (opt > n) return P1_NO_OPTIONS;
    for (i = 0; i < opt; i++) out[o++] = in[i];
    if (opt == n && (n == 0 || in[n - 1] != '\n')) { out[o++] = '\r'; out[o++] = '\n'; }
    for (i = 0; add[i]; i++) out[o++] = add[i];
    for (i = opt; i < n; i++) out[o++] = in[i];
    *len = o;
    return P1_CHANGED;
}

#endif
