/*
 * USOSPG.DRV decisions (src/platform/bios/win9x/usospg.c), kept free of
 * Windows calls so the host test (tools/tests/legacy_bios/test_usospg.py)
 * compiles them with zig cc.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Control IDs, read from the dialog templates of the user's Windows 98 PL
 * (4.10.1998) and 98 SE PL OEM (4.10.2222) Setup files, both identical:
 *   SETUPX.DLL (the pages of Setup's wizard in the mini-Windows):
 *     User information (dialog 112): Edit 1025 name, Edit 1011 company.
 *     Licence agreement (dialog 600): Edit 617 (the text), radio buttons
 *       618 "accept" and 619 "do not accept".
 *     Product key (dialogs 607 / 608): five Edits 1058..1062 (5 characters
 *       each). The Certificate of Authenticity pages 604 / 387 have only
 *       1058..1060: not a key page here.
 *     "Start the wizard" (dialog 4205, the last one: "click Finish"): a
 *       title Static 1070, the bitmap 145 and plain Statics, nothing to
 *       click on the page. 4203 / 4204 / 1201 and SUWIN's 386 / 389 / 488
 *       look the same; the frame tells them apart: 4205 alone gets Finish
 *       instead of Next.
 *     No other dialog of SETUPX.DLL or SUWIN.EXE has 1025 with 1011, 617
 *     with 618 / 619 or the five key Edits (the test checks that).
 *   KOMMCTRL.DLL (the property sheet, wizard frame dialog 1020):
 *     Back 0x3023, Next 0x3024, Finish 0x3025.
 */
#ifndef USOSPG_LOGIC_H
#define USOSPG_LOGIC_H

#define PG_BACK_ID       0x3023
#define PG_NEXT_ID       0x3024
#define PG_FINISH_ID     0x3025
#define PG_TITLE_ID      1070
#define PG_NAME_ID       1025
#define PG_ORG_ID        1011
#define PG_EULA_TEXT_ID  617
#define PG_EULA_YES_ID   618
#define PG_EULA_NO_ID    619
#define PG_KEY1_ID       1058      /* ..1062 */
#define PG_KEY_FIELDS    5
#define PG_KEY_PART_LEN  5
/* 500 ms ticks: a page is judged after it has been shown for 2 s (Setup's
 * own batch mode moves on first when it does); at most 5 s for Next to be
 * enabled; a page still shown 10 s after Next / Finish is left alone. */
#define PG_STABLE_TICKS  4
#define PG_NEXT_TICKS    10
#define PG_GONE_TICKS    20
#define PG_LIFETIME_MS   (30UL * 60UL * 1000UL)
#define PG_SKIP          8

/* Page kinds. */
enum { PG_OTHER, PG_USER, PG_EULA, PG_KEY, PG_FINISH };
/* Actions for usospg.c. */
enum { PA_NONE, PA_NEXT, PA_FINISH, PA_ACCEPT, PA_STOP };
/* What the driver logs after a step (besides the action). */
enum { PE_NONE, PE_LEFT, PE_NO_NEXT, PE_STUCK, PE_TIMEOUT };

/* The controls of one visible child page of a wizard frame. */
typedef struct {
    unsigned char title;        /* Static 1070 */
    unsigned char name;         /* Edit 1025 */
    unsigned char org;          /* Edit 1011 */
    unsigned char eula_text;    /* Edit 617 */
    unsigned char eula_yes;     /* Button 618 */
    unsigned char eula_no;      /* Button 619 */
    unsigned char key_edits;    /* Edits among 1058..1062 */
    unsigned char clickable;    /* visible Edit / Button / ListBox / ComboBox children */
    unsigned char next_shown;   /* the frame's Next is visible */
    unsigned char finish_shown; /* the frame's Finish is visible */
} PGSHAPE;

static unsigned char pg_classify(const PGSHAPE *p)
{
    if (p->eula_text && p->eula_yes && p->eula_no) return PG_EULA;
    if (p->key_edits == PG_KEY_FIELDS) return PG_KEY;
    if (p->name && p->org && !p->eula_text && !p->key_edits) return PG_USER;
    if (p->title && !p->clickable && p->finish_shown && !p->next_shown) return PG_FINISH;
    return PG_OTHER;
}

/* C:\USOS9X\USOSPG.CFG: "mode=auto" at the start of a line (CR LF / LF,
 * any case). Anything else: 0 (the driver does not load). The target
 * script writes it only for a USOS answer in automatic mode (Express=1,
 * ShowEula=0): the licence page is accepted only then. */
static int pg_cfg_auto(const unsigned char *buf, int len)
{
    static const char want[] = "mode=auto";
    int i = 0, k;
    while (i < len) {
        for (k = 0; want[k] && i + k < len; k++) {
            unsigned char c = buf[i + k];
            if (c >= 'A' && c <= 'Z') c = (unsigned char)(c + 32);
            if (c != (unsigned char)want[k]) break;
        }
        if (!want[k]) {
            if (i + k == len) return 1;
            if (buf[i + k] == '\r' || buf[i + k] == '\n' || buf[i + k] == ' ' || buf[i + k] == '\t') return 1;
        }
        while (i < len && buf[i] != '\n') i++;
        i++;
    }
    return 0;
}

typedef struct {
    unsigned short cur;         /* the page being watched (its HWND) */
    unsigned char kind;
    unsigned char stable;       /* ticks it has been shown */
    unsigned char acted;        /* 0 not yet, 1 ready for Next, 2 Next / Finish pressed */
    unsigned char waited;
    unsigned char done;
    unsigned char event;        /* PE_*, set by every step */
    unsigned char nskip;
    unsigned short skip[PG_SKIP];   /* pages left to the user / given up */
} PGSTATE;

/* What one timer tick sees on the window it runs for. */
typedef struct {
    unsigned char expired;      /* PG_LIFETIME_MS over */
    unsigned char active;       /* this window is the active window */
    unsigned short page;        /* the visible page of one of the kinds, else 0 */
    unsigned char kind;
    unsigned char filled;       /* user: name not empty; key: 5 x 5 characters;
                                   licence: always; finish: Finish enabled */
    unsigned char accepted;     /* licence: 618 checked */
    unsigned char declined;     /* licence: 619 checked */
    unsigned char next_ready;   /* Next visible and enabled */
} PGVIEW;

static int pg_skipped(const PGSTATE *s, unsigned short page)
{
    int i;
    for (i = 0; i < PG_SKIP; i++)
        if (s->skip[i] == page) return 1;
    return 0;
}

static void pg_leave(PGSTATE *s, unsigned char event)
{
    s->skip[s->nskip % PG_SKIP] = s->cur;
    s->nskip = (unsigned char)((s->nskip + 1) % PG_SKIP);
    s->event = event;
}

/* One tick. A page is acted on only after PG_STABLE_TICKS, only when what
 * Setup needs is already there (the MSBATCH.INF values), and at most once:
 * a page that is empty, declined, has no enabled Next or stays after Next
 * is left to the user for good. */
static unsigned char pg_step(PGSTATE *s, const PGVIEW *v)
{
    s->event = PE_NONE;
    if (s->done) return PA_STOP;
    if (v->expired) { s->done = 1; s->event = PE_TIMEOUT; return PA_STOP; }
    if (!v->active) return PA_NONE;
    if (!v->page) { s->cur = 0; return PA_NONE; }
    if (v->page != s->cur || v->kind != s->kind) {
        s->cur = v->page;
        s->kind = v->kind;
        s->stable = 0;
        s->acted = 0;
        s->waited = 0;
    }
    if (pg_skipped(s, v->page)) return PA_NONE;
    if (s->stable < PG_STABLE_TICKS) { s->stable++; return PA_NONE; }
    if (s->acted == 0) {
        if (!v->filled || (v->kind == PG_EULA && v->declined)) { pg_leave(s, PE_LEFT); return PA_NONE; }
        if (v->kind == PG_FINISH) { s->acted = 2; return PA_FINISH; }
        s->acted = 1;
        if (v->kind == PG_EULA && !v->accepted) return PA_ACCEPT;
    }
    if (s->acted == 1) {
        if (v->kind == PG_EULA && !v->accepted) {
            if (++s->waited >= PG_NEXT_TICKS) pg_leave(s, PE_NO_NEXT);
            return PA_NONE;
        }
        if (v->next_ready) { s->acted = 2; s->waited = 0; return PA_NEXT; }
        if (++s->waited >= PG_NEXT_TICKS) pg_leave(s, PE_NO_NEXT);
        return PA_NONE;
    }
    if (++s->waited >= PG_GONE_TICKS) pg_leave(s, PE_STUCK);
    return PA_NONE;
}

#endif
