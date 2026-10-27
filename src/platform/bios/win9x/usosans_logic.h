/*
 * USOSANS.EXE decisions (src/platform/bios/win9x/usosans.c), kept free of
 * Windows calls so the host test (tools/tests/legacy_bios/test_usosans.py)
 * compiles them with zig cc.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Titles and control IDs, read from the dialog templates of the user's
 * Windows media (read-only: tools/tests/legacy_bios/test_usosans.py checks
 * them again when the ISOs are present). The strings are the bytes
 * GetWindowTextA / WM_GETTEXT return: code page 1250 for the Polish
 * systems (0x9F = z with acute, 0xB3 = l with stroke, 0xEA = e with ogonek).
 *
 * MPRSERV.DLL (the Windows Logon dialogs; PL 95 RTM 4.00.950, 95 OSR2.1,
 * 98 4.10.1998, 98 SE 4.10.2222, Me 4.90.3000; EN 95 OSR1):
 *   dialog 13, first logon of a user without a password list:
 *     PL 98/98 SE/Me "Wprowadz haslo systemu Windows", PL 95 "Wprowadz
 *     haslo Windows", EN "Enter Windows Password". Its hint: no password
 *     typed = the prompt does not come back at the next start.
 *   dialog 2, a user with a list: PL 98/98 SE/Me "System Windows -
 *     Zapraszamy", PL 95 "Zapraszamy do systemu Windows", EN "Welcome to
 *     Windows".
 *   Both: Edit 30 user name, Edit 31 password, OK 1, Cancel 2.
 *   dialog 3, confirm a new Windows password: PL 98/98 SE/Me "Ustaw haslo
 *     systemu Windows", PL 95 "Ustaw haslo Windows", EN "Set Windows
 *     Password"; Edit 40 new, Edit 41 confirm, OK 1, Cancel 2.
 *   ("Enter Network Password", dialog 1, is a different shape: not handled.)
 *
 * SYSDM.CPL (the device installer's wizard; PL 98, 98 SE: the same IDs;
 * Me: other page layouts, the same IDs per role), frame title STR 1777 PL
 * "Kreator dodawania nowego sprzetu", EN "Add New Hardware Wizard"; the
 * device name of the stock monitor is MONITOR.INF *PNP09FF.DeviceDesc,
 * PL "Monitor Plug and Play", EN "Plug and Play Monitor":
 *   intro (98: 4000, Me: 3300): Static 4004 the device name; Me also the
 *     radio buttons 3317 "automatic search (recommended)" / 3318
 *   choice (98: 3301, Me: 3301): radio buttons 3315 "search for a better
 *     driver (recommended)" / 3316 "list the drivers"
 *   search places (98: 3490): check boxes 3494..3497 (shown as they are)
 *   ready (98: 3300, Me: 3299): Statics 4101 "searching ... for:", 4104
 *     "driver location:" and the found file (e.g. C:\WINDOWS\INF\MONITOR.INF)
 *   finish (4120): Static 4121 icon, 4122 the device name, 4123 the result
 *   anything else (not found 3299 / 3298, 3460, 3430 ...): nothing pressed.
 * Wizard frame buttons (property sheet): Back 0x3023, Next 0x3024,
 * Finish 0x3025.
 */
#ifndef USOSANS_LOGIC_H
#define USOSANS_LOGIC_H

#define AN_USER_ID       30
#define AN_PASS_ID       31
#define AN_NEW_ID        40
#define AN_CONFIRM_ID    41
#define AN_OK_ID         1
#define AN_CANCEL_ID     2

#define HW_NEXT_ID       0x3024
#define HW_FINISH_ID     0x3025
#define HW_NAME_ID       4004
#define HW_ME_AUTO_ID    3317
#define HW_ME_MANUAL_ID  3318
#define HW_SEARCH_ID     3315
#define HW_LIST_ID       3316
#define HW_PLACE1_ID     3494
#define HW_PLACE4_ID     3497
#define HW_READY_ID      4101
#define HW_LOCATION_ID   4104
#define HW_FIN_ICON_ID   4121
#define HW_FIN_NAME_ID   4122

/* 250 ms ticks. A dialog / page is acted on after it has been shown,
 * unchanged, for 1 s; at most 10 s for its button to be enabled; a page
 * still shown 20 s after Next / Finish is left alone. */
#define AN_TICK_MS       250
#define AN_STABLE_TICKS  4
#define AN_WAIT_TICKS    40
#define AN_GONE_TICKS    80
#define AN_LIFETIME_MS   (10UL * 60UL * 1000UL)
/* OK presses per start (logon dialogs), whatever the dialogs. */
#define AN_LOGON_MAX     3
/* Starts with the RunServices value: removed at the start after the
 * AN_MAX_BOOTS-th one at the latest; earlier once AN_DESK_BOOTS starts
 * reached the desktop and the add-on chain is over (no USOSAddons Run
 * value). */
#define AN_MAX_BOOTS     4
#define AN_DESK_BOOTS    2

/* Logon dialog kinds. */
enum { AK_NONE, AK_ENTER, AK_WELCOME, AK_SET };
/* Actions. */
enum { AA_NONE, AA_OK, AA_NEXT, AA_FINISH, AA_LEAVE };
/* Why a dialog / wizard is left to the user (logged with AA_LEAVE). */
enum { AE_NONE, AE_SHAPE, AE_TYPED, AE_NO_USER, AE_NO_BUTTON, AE_OTHER_DEVICE, AE_CHANGED,
       AE_UNCONFIRMED, AE_NO_INF, AE_STUCK, AE_LIMIT };

static const char *const an_enter_titles[] = {
    "Wprowad\x9f has\xb3o systemu Windows",     /* PL 98 / 98 SE / Me */
    "Wprowad\x9f has\xb3o Windows",             /* PL 95 */
    "Enter Windows Password",                   /* EN */
    0 };
static const char *const an_welcome_titles[] = {
    "System Windows - Zapraszamy",              /* PL 98 / 98 SE / Me */
    "Zapraszamy do systemu Windows",            /* PL 95 */
    "Welcome to Windows",                       /* EN */
    0 };
static const char *const an_set_titles[] = {
    "Ustaw has\xb3o systemu Windows",           /* PL 98 / 98 SE / Me */
    "Ustaw has\xb3o Windows",                   /* PL 95 */
    "Set Windows Password",                     /* EN */
    0 };
static const char *const an_hw_titles[] = {
    "Kreator dodawania nowego sprz\xeatu",      /* PL 98 / 98 SE / Me */
    "Add New Hardware Wizard",                  /* EN (no EN 98 / Me medium here: unverified) */
    0 };
static const char *const an_monitor_names[] = {
    "Monitor Plug and Play",                    /* PL MONITOR.INF *PNP09FF */
    "Plug and Play Monitor",                    /* EN (unverified, as above) */
    0 };

static int an_in(const char *const *list, const char *s)
{
    int i, k;
    for (i = 0; list[i]; i++) {
        for (k = 0; list[i][k] && list[i][k] == s[k]; k++) ;
        if (!list[i][k] && !s[k]) return 1;
    }
    return 0;
}

static int an_logon_kind(const char *title)
{
    if (an_in(an_enter_titles, title)) return AK_ENTER;
    if (an_in(an_welcome_titles, title)) return AK_WELCOME;
    if (an_in(an_set_titles, title)) return AK_SET;
    return AK_NONE;
}

static int an_is_hw_frame(const char *title) { return an_in(an_hw_titles, title); }

/* The device name of a wizard Static: exact, blanks around it ignored. */
static int an_is_monitor(const char *text)
{
    char t[64];
    int a = 0, b, n = 0;
    while (text[a] == ' ' || text[a] == '\t') a++;
    for (b = a; text[b]; b++) ;
    while (b > a && (text[b - 1] == ' ' || text[b - 1] == '\t' || text[b - 1] == '\r' || text[b - 1] == '\n')) b--;
    if (b - a >= (int)sizeof(t)) return 0;
    while (a < b) t[n++] = text[a++];
    t[n] = 0;
    return an_in(an_monitor_names, t);
}

/* A text naming the stock monitor INF: "...\MONITOR.INF" (any case) at
 * its end or followed by a blank / line break (the ready page shows the
 * full path). Not MONITOR2.INF / MONITOR3.INF / an OEM file. */
static int an_names_monitor_inf(const char *text)
{
    static const char want[] = "\\monitor.inf";
    int i, k;
    for (i = 0; text[i]; i++) {
        for (k = 0; want[k]; k++) {
            char c = text[i + k];
            if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
            if (c != want[k]) break;
        }
        if (!want[k]) {
            char e = text[i + k];
            if (!e || e == ' ' || e == '\r' || e == '\n' || e == '\t' || e == '"') return 1;
        }
    }
    return 0;
}

/* ---- logon dialogs ---- */

/* What one tick sees on a visible top-level #32770 with a logon title. */
typedef struct {
    unsigned char kind;         /* AK_* from the title */
    unsigned char shape;        /* its Edits and OK are there (30 / 31 or 40 / 41) */
    unsigned char ok_ready;     /* OK visible and enabled */
    int user_len;               /* Edit 30 (AK_SET: unused) */
    int pass_len;               /* Edit 31 (AK_SET: Edit 40) */
    int confirm_len;            /* AK_SET: Edit 41 */
} ANLOGON;

typedef struct {
    unsigned long cur;          /* the dialog watched (its HWND) */
    unsigned char ticks;
    unsigned char waited;
    unsigned char done;         /* 1 OK pressed, 2 left to the user */
    unsigned char event;        /* AE_* of the last AA_LEAVE */
    unsigned char presses;      /* OK presses this start */
} ANLOGSTATE;

/* One tick for dialog `wnd`. OK only when the password field(s) stayed
 * empty, a user name is there (not AK_SET), OK is enabled, for
 * AN_STABLE_TICKS in a row; once per dialog, AN_LOGON_MAX per start.
 * Anything typed into a password field: the dialog is the user's. */
static int an_logon_step(ANLOGSTATE *s, unsigned long wnd, const ANLOGON *v)
{
    if (wnd != s->cur) { s->cur = wnd; s->ticks = 0; s->waited = 0; s->done = 0; s->event = AE_NONE; }
    if (s->done) return AA_NONE;
    s->event = AE_NONE;
    if (v->kind == AK_NONE || !v->shape) { s->done = 2; s->event = AE_SHAPE; return AA_LEAVE; }
    if (v->pass_len || (v->kind == AK_SET && v->confirm_len)) { s->done = 2; s->event = AE_TYPED; return AA_LEAVE; }
    if (s->presses >= AN_LOGON_MAX) { s->done = 2; s->event = AE_LIMIT; return AA_LEAVE; }
    if ((v->kind != AK_SET && v->user_len <= 0) || !v->ok_ready) {
        s->ticks = 0;
        if (++s->waited >= AN_WAIT_TICKS) {
            s->done = 2;
            s->event = (v->kind != AK_SET && v->user_len <= 0) ? AE_NO_USER : AE_NO_BUTTON;
            return AA_LEAVE;
        }
        return AA_NONE;
    }
    if (++s->ticks < AN_STABLE_TICKS) return AA_NONE;
    s->done = 1;
    s->presses++;
    return AA_OK;
}

/* ---- the new hardware wizard ---- */

enum { HP_NONE, HP_OTHER, HP_INTRO, HP_CHOICE, HP_PLACES, HP_READY, HP_FINISH };

/* The visible page of a wizard frame with a new-hardware title. */
typedef struct {
    unsigned char name;         /* Static 4004 present */
    unsigned char me_auto;      /* radio 3317 present */
    unsigned char me_auto_on;   /* 3317 checked */
    unsigned char me_manual_on; /* 3318 checked */
    unsigned char search;       /* radio 3315 present */
    unsigned char search_on;
    unsigned char list;         /* radio 3316 present */
    unsigned char list_on;
    unsigned char places;       /* 3494 and 3497 present */
    unsigned char ready;        /* 4101 and 4104 present */
    unsigned char fin;          /* 4121 and 4122 present */
    unsigned char monitor;      /* the device name Static of this page (4004 / 4122,
                                   or a Static of the ready page) is the stock monitor */
    unsigned char monitor_inf;  /* a Static / Edit of the page names ...\MONITOR.INF */
    unsigned char next_ready;   /* the frame's Next visible and enabled */
    unsigned char finish_ready; /* the frame's Finish visible and enabled */
} HWPAGE;

static int hw_classify(const HWPAGE *p)
{
    if (p->fin) return HP_FINISH;
    if (p->ready) return HP_READY;
    if (p->name) return HP_INTRO;
    if (p->search && p->list) return HP_CHOICE;
    if (p->places) return HP_PLACES;
    return HP_OTHER;
}

typedef struct {
    unsigned long frame;        /* the wizard watched */
    unsigned long page;         /* its visible page */
    unsigned char kind;
    unsigned char confirmed;    /* an earlier page named the stock monitor */
    unsigned char ticks;
    unsigned char waited;
    unsigned char pressed;      /* Next / Finish pressed on this page */
    unsigned char gone;         /* ticks since then */
    unsigned char stop;         /* this wizard is the user's */
    unsigned char event;
    unsigned char seen;         /* HP_* kinds already logged (bit per kind) */
} HWSTATE;

/* One tick for wizard frame `frame` showing page `page` (0: none visible).
 * Every page is judged on its own after AN_STABLE_TICKS; a page that does
 * not match its rule ends the automation of this wizard for good (AA_LEAVE
 * with the reason); a page of an unknown kind (searching, not found,
 * other results) is only watched. */
static int hw_step(HWSTATE *s, unsigned long frame, unsigned long page, const HWPAGE *p)
{
    int kind = page ? hw_classify(p) : HP_NONE, ok = 0, ready = 0;
    if (frame != s->frame) {
        s->frame = frame; s->page = 0; s->kind = HP_NONE; s->confirmed = 0; s->ticks = 0;
        s->waited = 0; s->pressed = 0; s->gone = 0; s->stop = 0; s->event = AE_NONE; s->seen = 0;
    }
    if (s->stop) return AA_NONE;
    s->event = AE_NONE;
    if (page != s->page || kind != s->kind) {
        s->page = page; s->kind = (unsigned char)kind; s->ticks = 0; s->waited = 0; s->pressed = 0; s->gone = 0;
    }
    if (s->pressed) {
        if (++s->gone >= AN_GONE_TICKS) { s->stop = 1; s->event = AE_STUCK; return AA_LEAVE; }
        return AA_NONE;
    }
    if (kind == HP_NONE || kind == HP_OTHER) return AA_NONE;
    if (++s->ticks < AN_STABLE_TICKS) return AA_NONE;
    switch (kind) {
    case HP_INTRO:
        if (!p->monitor) { s->stop = 1; s->event = AE_OTHER_DEVICE; return AA_LEAVE; }
        if (p->me_auto && (!p->me_auto_on || p->me_manual_on)) { s->stop = 1; s->event = AE_CHANGED; return AA_LEAVE; }
        s->confirmed = 1;
        ok = 1; ready = p->next_ready;
        break;
    case HP_CHOICE:
        if (!s->confirmed) { s->stop = 1; s->event = AE_UNCONFIRMED; return AA_LEAVE; }
        if (!p->search_on || p->list_on) { s->stop = 1; s->event = AE_CHANGED; return AA_LEAVE; }
        ok = 1; ready = p->next_ready;
        break;
    case HP_PLACES:
        if (!s->confirmed) { s->stop = 1; s->event = AE_UNCONFIRMED; return AA_LEAVE; }
        ok = 1; ready = p->next_ready;
        break;
    case HP_READY:
        if (!s->confirmed && !p->monitor) { s->stop = 1; s->event = AE_UNCONFIRMED; return AA_LEAVE; }
        if (!p->monitor_inf) { s->stop = 1; s->event = AE_NO_INF; return AA_LEAVE; }
        s->confirmed = 1;
        ok = 1; ready = p->next_ready;
        break;
    case HP_FINISH:
        if (!p->monitor) { s->stop = 1; s->event = s->confirmed ? AE_CHANGED : AE_OTHER_DEVICE; return AA_LEAVE; }
        ok = 1; ready = p->finish_ready;
        break;
    }
    if (!ok) return AA_NONE;
    if (!ready) {
        if (++s->waited >= AN_WAIT_TICKS) { s->stop = 1; s->event = AE_NO_BUTTON; return AA_LEAVE; }
        return AA_NONE;
    }
    s->pressed = 1;
    return kind == HP_FINISH ? AA_FINISH : AA_NEXT;
}

/* ---- the RunServices value's lifetime ---- */

/* C:\USOS9X\USOSANS.STA: "boots=N desk=M" (decimal, any order, other text
 * ignored). Missing / unreadable: 0 0. */
static unsigned an_field(const char *buf, int len, const char *key)
{
    int i, k;
    unsigned v;
    for (i = 0; i < len; i++) {
        if (i && buf[i - 1] != ' ' && buf[i - 1] != '\n' && buf[i - 1] != '\r') continue;
        for (k = 0; key[k] && i + k < len && buf[i + k] == key[k]; k++) ;
        if (key[k] || i + k >= len || buf[i + k] != '=') continue;
        v = 0;
        for (k = i + k + 1; k < len && buf[k] >= '0' && buf[k] <= '9' && v < 10000; k++) v = v * 10 + (unsigned)(buf[k] - '0');
        return v;
    }
    return 0;
}

/* At the start of a Windows start (boots = this start, counted). 1: the
 * value is removed now and nothing is watched. */
static int an_remove_now(unsigned boots, unsigned desk_boots, int addons_pending)
{
    if (boots > AN_MAX_BOOTS) return 1;
    if (desk_boots >= AN_DESK_BOOTS && !addons_pending) return 1;
    return 0;
}

#endif
