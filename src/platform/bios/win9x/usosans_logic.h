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
 *   search places (98: 3490): check boxes 3494 floppy drives, 3495 CD-ROM
 *     drive, 3496 "Microsoft Windows Update", 3497 a location; 3495 and
 *     3496 are cleared before Next (X470 98 FE PL 2026-10-27: Windows
 *     Update was checked and its box stopped the wizard), the rest stays
 *   Windows Update offer (SYSDM.CPL STR 4200 / 4201, a message box): PL / EN
 *     title "Microsoft Windows Update", "... register now?" Yes 6 / No 7;
 *     after No STR 4202 / 4203 "... will not use Windows Update" with OK 1
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
#define HW_PLACE_CD_ID   3495
#define HW_PLACE_WU_ID   3496
#define AN_YES_ID        6
#define AN_NO_ID         7
#define HW_READY_ID      4101
#define HW_LOCATION_ID   4104
#define HW_FIN_ICON_ID   4121
#define HW_FIN_NAME_ID   4122

/* 250 ms ticks. A dialog / page is acted on after it has been shown,
 * unchanged, for 1 s; at most 10 s for its button to be enabled; a page
 * still shown 20 s after Next / Finish (the search places page: 120 s,
 * the driver search runs behind it) is logged once and only watched from
 * then on: the next page of that wizard gets its turn (X470 98 FE PL,
 * 2026-10-27: places stayed while searching, the wizard was given up and
 * the ready / finish pages stayed). */
#define AN_TICK_MS       250
#define AN_STABLE_TICKS  4
#define AN_WAIT_TICKS    40
#define AN_GONE_TICKS    80
#define AN_PLACES_GONE_TICKS 480
#define AN_LIFETIME_MS   (10UL * 60UL * 1000UL)
/* OK presses per start (logon dialogs), whatever the dialogs. */
#define AN_LOGON_MAX     3
/* Starts with the RunServices value: removed at the start after the
 * AN_MAX_BOOTS-th one at the latest; earlier once AN_DESK_BOOTS starts
 * reached the desktop and the add-on chain is over (no USOSAddons Run
 * value). */
#define AN_MAX_BOOTS     4
#define AN_DESK_BOOTS    2
/* While the 95 / 98 first-desktop coordinator still owns the start
 * (C:\USOS9X\FIRSTBT.ON, neither FIRSTBT.OK nor FIRSTBT.ERR: X470 98 FE PL
 * 2026-10-27 needed five package boots, and the value was gone at the 5th
 * start before the desktop came) the value stays, up to this many starts. */
#define AN_HARD_MAX_BOOTS 12
/* Unchecks of the search places check boxes per page, then it is the user's. */
#define AN_UNCHECK_MAX   3

/* Logon dialog kinds. */
enum { AK_NONE, AK_ENTER, AK_WELCOME, AK_SET };
/* Actions. */
enum { AA_NONE, AA_OK, AA_NEXT, AA_FINISH, AA_LEAVE, AA_UNCHECK, AA_NO, AA_CANCEL };
/* Why a dialog / wizard is left to the user (logged with AA_LEAVE). */
enum { AE_NONE, AE_SHAPE, AE_TYPED, AE_NO_USER, AE_NO_BUTTON, AE_OTHER_DEVICE, AE_CHANGED,
       AE_UNCONFIRMED, AE_NO_INF, AE_STUCK, AE_LIMIT, AE_PLACES };

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
static const char *const an_wu_titles[] = {
    "Microsoft Windows Update",                 /* SYSDM.CPL STR 4200 / 4202, PL 98 (the product name) */
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
static int an_is_wu_box(const char *title) { return an_in(an_wu_titles, title); }

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
    unsigned char cd_on;        /* places: 3495 (CD-ROM drive) checked */
    unsigned char wu_on;        /* places: 3496 (Microsoft Windows Update) checked */
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
    unsigned short gone;        /* ticks since then */
    unsigned char stuck;        /* that page stayed: logged, only watched */
    unsigned char stop;         /* this wizard is the user's */
    unsigned char event;
    unsigned char seen;         /* HP_* kinds already logged (bit per kind) */
    unsigned char why;          /* AW_*: why this tick pressed nothing */
    unsigned char unchecks;     /* AA_UNCHECK given on this page */
} HWSTATE;

/* Why a tick pressed nothing (usosans.c logs every change). */
enum { AW_NONE, AW_NO_PAGE, AW_UNKNOWN_PAGE, AW_SETTLING, AW_WAIT_BUTTON, AW_AFTER_PRESS, AW_STAYED,
       AW_STOPPED };

/* One tick for wizard frame `frame` showing page `page` (0: none visible).
 * Every page is judged on its own after AN_STABLE_TICKS; a page that does
 * not match its rule ends the automation of this wizard for good (AA_LEAVE
 * with the reason); a page of an unknown kind (searching, not found,
 * other results) is only watched; a page that stays after its press is
 * reported once (AA_LEAVE, AE_STUCK) and watched, the wizard stays ours. */
static int hw_step(HWSTATE *s, unsigned long frame, unsigned long page, const HWPAGE *p)
{
    int kind = page ? hw_classify(p) : HP_NONE, ok = 0, ready = 0;
    if (frame != s->frame) {
        s->frame = frame; s->page = 0; s->kind = HP_NONE; s->confirmed = 0; s->ticks = 0;
        s->waited = 0; s->pressed = 0; s->gone = 0; s->stop = 0; s->event = AE_NONE; s->seen = 0;
        s->unchecks = 0;
    }
    s->why = AW_NONE;
    if (s->stop) { s->why = AW_STOPPED; return AA_NONE; }
    s->event = AE_NONE;
    if (page != s->page || kind != s->kind) {
        s->page = page; s->kind = (unsigned char)kind; s->ticks = 0; s->waited = 0; s->pressed = 0; s->gone = 0;
        s->stuck = 0; s->unchecks = 0;
    }
    if (s->pressed) {
        /* not final: logged once (AA_LEAVE + AE_STUCK), the next page gets its turn */
        if (s->stuck) { s->why = AW_STAYED; return AA_NONE; }
        s->why = AW_AFTER_PRESS;
        if (++s->gone >= (kind == HP_PLACES ? AN_PLACES_GONE_TICKS : AN_GONE_TICKS)) {
            s->stuck = 1; s->event = AE_STUCK; return AA_LEAVE;
        }
        return AA_NONE;
    }
    if (kind == HP_NONE) { s->why = AW_NO_PAGE; return AA_NONE; }
    if (kind == HP_OTHER) { s->why = AW_UNKNOWN_PAGE; return AA_NONE; }
    if (++s->ticks < AN_STABLE_TICKS) { s->why = AW_SETTLING; return AA_NONE; }
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
        /* Windows Update / CD-ROM cleared first (BM_SETCHECK + BN_CLICKED to
         * the page), then the page settles again before Next */
        if (p->wu_on || p->cd_on) {
            if (s->unchecks >= AN_UNCHECK_MAX) { s->stop = 1; s->event = AE_PLACES; return AA_LEAVE; }
            s->unchecks++;
            s->ticks = 0;
            return AA_UNCHECK;
        }
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
        s->why = AW_WAIT_BUTTON;
        return AA_NONE;
    }
    s->pressed = 1;
    return kind == HP_FINISH ? AA_FINISH : AA_NEXT;
}

/* ---- the Windows Update offer of the device installer ----
 * A visible #32770 titled "Microsoft Windows Update" while the new
 * hardware wizard is shown: the register-now question (Yes / No) gets No,
 * an OK + Cancel box Cancel, the notice that follows it (OK alone) OK;
 * after AN_STABLE_TICKS, once per box, at most AN_WU_MAX per start. Any
 * other shape, or no wizard: the box is the user's. Declining is what
 * keeps the wizard off the network (Windows Update stays unused). */
#define AN_WU_MAX        4
typedef struct {
    unsigned char yes, no, ok, cancel;  /* buttons 6 / 7 / 1 / 2 present and enabled */
    unsigned char wizard;               /* the new hardware wizard is visible */
} ANWUBOX;
typedef struct {
    unsigned long cur;
    unsigned char ticks;
    unsigned char done;                 /* 1 pressed, 2 left to the user */
    unsigned char presses;              /* this start */
} ANWUSTATE;

static int an_wu_step(ANWUSTATE *s, unsigned long wnd, const ANWUBOX *v)
{
    if (wnd != s->cur) { s->cur = wnd; s->ticks = 0; s->done = 0; }
    if (s->done) return AA_NONE;
    if (!v->wizard || s->presses >= AN_WU_MAX) { s->done = 2; return AA_LEAVE; }
    if (++s->ticks < AN_STABLE_TICKS) return AA_NONE;
    s->done = 1;
    if (v->yes && v->no && !v->ok) { s->presses++; return AA_NO; }
    if (v->ok && v->cancel && !v->yes && !v->no) { s->presses++; return AA_CANCEL; }
    if (v->ok && !v->cancel && !v->yes && !v->no) { s->presses++; return AA_OK; }
    s->done = 2;
    return AA_LEAVE;
}

/* ---- Windows 98's first-start Setup wizard ----
 *
 * X470 98 FE PL run 3 (2026-10-27): the pages that stopped (user
 * information, licence, product key, "Finish") are not shown in Setup's
 * mini-Windows (SETUPLOG: dialogs skipped in phase 1) but at the first
 * start of the installed Windows 98 (FRUNLOG GetUserInfo), where this
 * helper already runs. The same SETUPX.DLL pages in the same KOMMCTRL
 * frame as in the mini-Windows: the page rules and IDs of USOSPG.DRV
 * (usospg_logic.h: pg_classify, pg_step) are used as they are, on 500 ms
 * ticks (every second scan). One more rule: Finish only in a frame that
 * showed a user / licence / key page before (another wizard's last page
 * looks the same). The licence is accepted only because this helper runs
 * only for a USOS answer in automatic mode. */
#ifndef PG_PAGES_ONLY
#define PG_PAGES_ONLY
#endif
#include "usospg_logic.h"

/* Why a Setup wizard tick pressed nothing (logged at every change). */
enum { SW_NONE, SW_NO_PAGE, SW_UNKNOWN_PAGE, SW_FINISH_UNCONFIRMED, SW_SETTLING, SW_WAIT_NEXT,
       SW_AFTER_PRESS, SW_LEFT };

typedef struct {
    PGSTATE pg;
    unsigned long frame;
    unsigned char confirmed;    /* this frame showed a user / licence / key page */
    unsigned char why;          /* SW_* of the last tick */
} SUSTATE;

/* One 500 ms tick for Setup frame `frame`; v as USOSPG.DRV fills it (page
 * 0: no page with the title Static). v->page is cleared for pages that
 * are not acted on. Returns a PA_* of usospg_logic.h. */
static unsigned char su_step(SUSTATE *s, unsigned long frame, PGVIEW *v)
{
    unsigned char act;
    if (frame != s->frame) {
        unsigned char *b = (unsigned char *)s;
        unsigned i;
        for (i = 0; i < sizeof *s; i++) b[i] = 0;
        s->frame = frame;
    }
    s->why = SW_NONE;
    if (v->page && v->kind != PG_OTHER && v->kind != PG_FINISH) s->confirmed = 1;
    if (!v->page) s->why = SW_NO_PAGE;
    else if (v->kind == PG_OTHER) { s->why = SW_UNKNOWN_PAGE; v->page = 0; }
    else if (v->kind == PG_FINISH && !s->confirmed) { s->why = SW_FINISH_UNCONFIRMED; v->page = 0; }
    act = pg_step(&s->pg, v);
    if (act == PA_NONE && s->why == SW_NONE && s->pg.event == PE_NONE) {
        if (pg_skipped(&s->pg, v->page)) s->why = SW_LEFT;
        else if (s->pg.acted == 2) s->why = SW_AFTER_PRESS;
        else if (s->pg.acted == 1) s->why = SW_WAIT_NEXT;
        else s->why = SW_SETTLING;
    }
    return act;
}

/* ---- the click recorder (diagnostics only) ----
 * While a Setup or new-hardware wizard is visible: every 50 ms the mouse
 * buttons and Enter / Tab / Esc (GetAsyncKeyState, high bit; Windows 9x has
 * no low-level hooks) and the cursor position. A press = up -> down. */
#define AN_POLL_MS       50
#define AN_REC_MAX       3000           /* recorder lines per start, then one notice */
/* After AN_LIFETIME_MS the helper goes on only while a wizard is shown,
 * never past AN_MAX_LIFETIME_MS (the first-start wizard can come late). */
#define AN_MAX_LIFETIME_MS (30UL * 60UL * 1000UL)

/* Keys of the recorder (virtual-key codes only, never text): every code
 * except the mouse buttons (polled apart) and the left / right modifier
 * codes 9x does not report. A character key (digits, letters, numpad,
 * punctuation) is logged as "a character key" without its code unless Alt
 * or Ctrl is held (an accelerator such as Alt+D for "&Dalej"): the name
 * and product key are typed into the Setup wizard. */
static int an_key_polled(int vk)
{
    if (vk < 0x08 || vk > 0xFE) return 0;
    if (vk >= 0xA0 && vk <= 0xA5) return 0;
    return 1;
}

static int an_key_character(int vk)
{
    return (vk >= 0x30 && vk <= 0x39) || (vk >= 0x41 && vk <= 0x5A) || (vk >= 0x60 && vk <= 0x6F) ||
           (vk >= 0xBA && vk <= 0xC0) || (vk >= 0xDB && vk <= 0xDF) || vk == 0xE2 || vk == 0x20;
}

static int an_key_code_shown(int vk, int alt, int ctrl)
{
    return !an_key_character(vk) || alt || ctrl;
}

static int an_edge(unsigned char *prev, int down)
{
    int press = down && !*prev;
    *prev = (unsigned char)(down != 0);
    return press;
}

/* 1 = write, 2 = write the limit notice instead (once), 0 = nothing. */
static int an_rec_allow(unsigned *lines)
{
    if (*lines < AN_REC_MAX) { (*lines)++; return 1; }
    if (*lines == AN_REC_MAX) { (*lines)++; return 2; }
    return 0;
}

static int an_time_up(unsigned long since_start, int watching)
{
    if (since_start >= AN_MAX_LIFETIME_MS) return 1;
    return since_start >= AN_LIFETIME_MS && !watching;
}

/* With the 95 / 98 first-desktop coordinator (FIRSTBT.ON, no FIRSTBT.OK /
 * ERR) a start lasts as long as that boot's part of the chain, which ran
 * past 10 minutes (X470 98 FE PL 2026-10-28: "time over" at 12:00:58 while
 * the hotfixes still ran): the lifetime counts from the last tick that saw
 * the chain open (since_ref), and a start never runs past AN_CHAIN_MAX_MS
 * in all. Without a coordinator since_ref == since_start. */
#define AN_CHAIN_MAX_MS (120UL * 60UL * 1000UL)
static int an_chain_time_up(unsigned long since_start, unsigned long since_ref, int watching)
{
    if (since_start >= AN_CHAIN_MAX_MS) return 1;
    return an_time_up(since_ref, watching);
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
 * value is removed now and nothing is watched. chain_open: the first-desktop
 * coordinator still owns the starts (FIRSTBT.ON without FIRSTBT.OK /
 * FIRSTBT.ERR): kept up to AN_HARD_MAX_BOOTS. */
static int an_remove_now(unsigned boots, unsigned desk_boots, int addons_pending, int chain_open)
{
    if (boots > AN_HARD_MAX_BOOTS) return 1;
    if (chain_open) return 0;
    if (boots > AN_MAX_BOOTS) return 1;
    if (desk_boots >= AN_DESK_BOOTS && !addons_pending) return 1;
    return 0;
}

/* ---- Windows Me ----
 *
 * X470 Me PL OEM 4.90.3000, B261028-141536 (2026-10-28): no first-desktop
 * coordinator on Me; the add-ons run on the desktop (USOSAddons Run value).
 *
 * First-start Setup wizard: Me's SETUPX.DLL (PRECOPY1.CAB, the same file
 * the installed system runs) titles its user information (dialog 112),
 * licence (600) and product key (608) pages with Static 1072, not 1070 as
 * 98 / 98 SE; the last page (4205) keeps 1070. Every other control ID of
 * the page rules is the same (1025 / 1011, 617 / 618 / 619, 1058..1062).
 * The run logged "no page with the title Static 1070" and the user typed
 * the three pages through. */
#define AN_SETUP_TITLE_ME_ID 1072

/* GetVersion() on 9x: major in the low byte, minor in the next one;
 * Me = 4.90, platform bit 31 set. */
static int an_is_me_version(unsigned long v)
{
    return (v & 0x80000000UL) && (v & 0xFFUL) == 4 && ((v >> 8) & 0xFFUL) == 90;
}

/* The starts stay owned (the RunServices value is kept, up to
 * AN_HARD_MAX_BOOTS) while the 95 / 98 coordinator's chain is open, and on
 * Me while the add-on chain still has its USOSAddons Run value: the same
 * run had its *DisplayFallback dialog in a package boot after the value
 * was gone (start limit at the 5th start). */
static int an_starts_owned(int chain_open, int is_me, int addons_pending)
{
    return chain_open || (is_me && addons_pending);
}

/* Me mouse: SYSTEM.INI [boot] mouse.drv as USOSMOUS.INF sets it. The
 * first-start boots ran with Setup's mouse.drv=mouse.drv (BOOTLOG "No mouse
 * driver installed": no mouse at the wizard and the first sign-in), because
 * USOSMOUS.INF runs from machine RunOnce only at the first sign-in and
 * applies from the next start. Setup's hardware detection in the first
 * start after phase 1 writes mouse.drv=mouse.drv again (MSMOUSE.INF for the
 * *PNP0F0E it adds), so the value is checked every AN_ME_CHECK_TICKS and
 * set again, at most AN_ME_MOUSE_MAX times per start. */
#define AN_ME_CHECK_TICKS 20
#define AN_ME_MOUSE_MAX   4
static int an_is_usosmous(const char *v)
{
    static const char want[] = "usosmous.drv";
    int i;
    while (*v == ' ' || *v == '\t') v++;
    for (i = 0; want[i]; i++) {
        char c = v[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c + 32);
        if (c != want[i]) return 0;
    }
    for (; v[i]; i++)
        if (v[i] != ' ' && v[i] != '\t') return 0;
    return 1;
}

#endif
