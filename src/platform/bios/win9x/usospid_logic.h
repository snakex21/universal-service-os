/*
 * USOSPID.DRV decisions (src/platform/bios/win9x/usospid.c), kept free of
 * Windows calls so the host test (tools/tests/legacy_bios/test_usospid.py)
 * compiles them with zig cc.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Control IDs (read from the dialog templates of the user's 95 RTM PL and
 * OSR1 EN SUWIN.EXE 4.00.950 and the mini-Windows COMMCTRL.DLL, both
 * language versions identical):
 *   OEM Product ID page (dialog 604): one Edit 526 for the whole
 *     xxxxx-OEM-xxxxxxx-xxxxx, its label Static 1010; no control 1097.
 *     The retail pages 601 / 602 / 612 have 526 plus the hidden
 *     "Advanced..." button 1097: the page for a CD key (below), never
 *     for an OEM ID.
 *   OSR2 (SETUP 4.00.1111; read from the user's 95 OSR2.1 PL SUWIN.EXE):
 *     the Certificate of Authenticity page (dialog 604 there) has three
 *     Edits 1125 / 1126 / 1127 for the 5 + 7 + 5 digits ("-OEM-" and "-"
 *     are Statics between them) and no 526; no other dialog of that
 *     SUWIN, and none of the 950 ones, has 1125..1127.
 *   "Invalid Product ID" box (dialog 156): OK 1, Ignore 1118, Exit 2
 *     (950 and OSR2.1 alike).
 *   Wizard frame (COMMCTRL property sheet): Back 0x3023, Next 0x3024.
 *   Which page: SUWIN passes SETUPPP.INF [Data] ProductType to SETUPX
 *     PIDValidate (950 SETUPX.DLL, read from OSR1 EN): 1..6 check a
 *     ddd-ddddddd key (2/4/6 also refuse the sites 333..999), 7..9 the
 *     ddddd-OEM-ddddddd-ddddd ID (23 characters, dashes at 5/9/17, mod-7
 *     digits). The retail ("CD Key", "10-digit Key") pages 601/602/612
 *     take the ddd-ddddddd key in their one Edit 526 (with the dash, as on
 *     the sticker: PIDValidate reads 3 digits, the dash, 7 digits). Every
 *     local 95 CD (RTM PL, OSR1 EN win95_a_oem.iso, OSR2.1 PL) and the
 *     98/98SE/Me CDs have ProductType=9: an OEM page.
 */
#ifndef USOSPID_LOGIC_H
#define USOSPID_LOGIC_H

#define PID_EDIT_ID      526
#define PID_LABEL_ID     1010
#define PID_ADVANCED_ID  1097
#define PID_IGNORE_ID    1118
#define PID_NEXT_ID      0x3024
#define PID_COA1_ID      1125
#define PID_COA2_ID      1126
#define PID_COA3_ID      1127
#define PID_KEY_LEN      23      /* the OEM ID; also the key buffer size */
#define PID_CD_KEY_LEN   11      /* ddd-ddddddd */
/* What pid_key_parse found. */
#define PID_KEY_OEM      1
#define PID_KEY_CD       2
/* Typed on the first tick that sees the empty page (or at once when the
 * page's field gets the focus, pid_focus); at most 10 ticks of 500 ms
 * waiting for an enabled Next after typing; 30 minutes in all. */
#define PID_STABLE_TICKS 1
#define PID_NEXT_TICKS   10
#define PID_LIFETIME_MS  (30UL * 60UL * 1000UL)

/* ddddd-OEM-ddddddd-ddddd (OEM in any case; returns PID_KEY_OEM) or the
 * CD key ddd-ddddddd (PID_KEY_CD) at the start of buf[0..len), followed
 * only by CR, LF, space, tab or NUL: out (room for PID_KEY_LEN + 1) gets
 * the characters (OEM upper case) and a NUL. Anything else: 0, out
 * emptied. */
static int pid_key_parse(const unsigned char *buf, int len, char *out)
{
    static const char oem_shape[PID_KEY_LEN + 1] = "ddddd-OEM-ddddddd-ddddd";
    static const char cd_shape[PID_CD_KEY_LEN + 1] = "ddd-ddddddd";
    const char *shape = oem_shape;
    int i, n = PID_KEY_LEN, kind = PID_KEY_OEM;
    out[0] = 0;
    if (len >= 4 && buf[3] == '-') { shape = cd_shape; n = PID_CD_KEY_LEN; kind = PID_KEY_CD; }
    if (len < n) return 0;
    for (i = 0; i < n; i++) {
        unsigned char c = buf[i], want = (unsigned char)shape[i];
        if (want == 'd') {
            if (c < '0' || c > '9') goto bad;
        } else if (want == '-') {
            if (c != '-') goto bad;
        } else {
            if (c >= 'a' && c <= 'z') c = (unsigned char)(c - 32);
            if (c != want) goto bad;
        }
        out[i] = (char)c;
    }
    for (; i < len; i++) {
        unsigned char c = buf[i];
        if (c != '\r' && c != '\n' && c != ' ' && c != '\t' && c != 0) goto bad;
    }
    out[n] = 0;
    return kind;
bad:
    for (i = 0; i < PID_KEY_LEN + 1; i++) out[i] = 0;
    return 0;
}

/* The OSR2 COA page's field `part` (0, 1, 2) of a parsed key: the 5, 7
 * and 5 digits without "OEM" and the dashes, into out (NUL-terminated,
 * room for 8). Returns the length (5, 7, 5), 0 for another part. */
static int pid_key_part(const char *key, int part, char *out)
{
    static const unsigned char start[3] = { 0, 10, 18 }, len[3] = { 5, 7, 5 };
    int i;
    out[0] = 0;
    if (part < 0 || part > 2) return 0;
    for (i = 0; i < len[part]; i++) out[i] = key[start[part] + i];
    out[len[part]] = 0;
    return len[part];
}

enum { PA_NONE, PA_TYPE, PA_NEXT, PA_DISMISS, PA_STOP };

typedef struct {
    unsigned char typed;        /* the key is in the field */
    unsigned char stable;       /* ticks the untouched page has been seen */
    unsigned char waited;       /* ticks waited for Next after typing */
    unsigned char dismissed;    /* the invalid-ID box was answered once */
    unsigned char done;         /* nothing more to do (key gone) */
} PIDSTATE;

/* What one timer tick sees on the window it runs for. */
typedef struct {
    unsigned char expired;      /* PID_LIFETIME_MS over */
    unsigned char active;       /* this window is the active window */
    unsigned char box;          /* it is the invalid-ID box */
    unsigned char page;         /* it is the wizard frame showing the OEM page */
    unsigned char edit_empty;   /* the page's field (OSR2: all three) is empty */
    unsigned char edit_full;    /* the page's field holds the key's length
                                   (OSR2: the three hold 5, 7 and 5) */
    unsigned char edit_ours;    /* ... and it is exactly the key (filled
                                   earlier, at the focus, or by Setup) */
    unsigned char next_ready;   /* Next is visible and enabled */
} PIDVIEW;

/* One tick: the action for usospid.c. The key is typed at most once and
 * only into an empty field; Next is pressed only right after that; the
 * invalid-ID box is answered (OK, back to the page) only before typing,
 * once. A rejected key, a field the user is typing in, a page that never
 * comes or Next that stays disabled: STOP, Setup waits for the user. */
static unsigned char pid_step(PIDSTATE *s, const PIDVIEW *v)
{
    if (s->done) return PA_STOP;
    if (v->expired) { s->done = 1; return PA_STOP; }
    /* Every armed window ticks; only the active one decides (a frame
     * behind a box, or Setup's background window, changes nothing). */
    if (!v->active) return PA_NONE;
    if (v->box) {
        if (s->typed) { s->done = 1; return PA_STOP; }      /* the key was rejected */
        if (s->dismissed) return PA_NONE;
        s->dismissed = 1;
        return PA_DISMISS;
    }
    if (!v->page) {
        s->stable = 0;
        if (s->typed) { s->done = 1; return PA_STOP; }      /* the page went on without us */
        return PA_NONE;
    }
    if (!s->typed) {
        if (v->edit_ours) {
            s->typed = 1;                                   /* already there: on to Next */
        } else {
            if (!v->edit_empty) { s->done = 1; return PA_STOP; } /* the user types */
            if (++s->stable < PID_STABLE_TICKS) return PA_NONE;
            s->typed = 1;
            return PA_TYPE;
        }
    }
    if (!v->edit_full) { s->done = 1; return PA_STOP; }
    if (v->next_ready) { s->done = 1; return PA_NEXT; }
    if (++s->waited >= PID_NEXT_TICKS) { s->done = 1; return PA_STOP; }
    return PA_NONE;
}

/* The page's field gets the focus (CBT hook, before Setup's batch mode
 * can press Next on it): type at once into an empty field, nothing else.
 * The ticks then go on as after PA_TYPE (Next, or stop when Setup moved
 * on by itself). */
static unsigned char pid_focus(PIDSTATE *s, const PIDVIEW *v)
{
    if (s->done || s->typed || v->expired || v->box || !v->page || !v->edit_empty) return PA_NONE;
    s->typed = 1;
    return PA_TYPE;
}

#endif
