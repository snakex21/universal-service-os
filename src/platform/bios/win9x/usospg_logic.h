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

#ifndef PG_PAGES_ONLY
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
#endif

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

#ifndef PG_PAGES_ONLY
/* Lifecycle. Setup's mini-Windows sends DRV_DISABLE / DRV_ENABLE around
 * its own work (X470 98 FE PL, 2026-10-27: DRV_DISABLE after the first
 * two pages, the driver then stopped for good and the next pages stayed):
 * DRV_DISABLE is a pause (timers and the hook go, this state stays: the
 * page being watched, what was pressed, the pages left to the user),
 * DRV_ENABLE resumes. Only the timeout and DRV_FREE / WEP end it. */
static int pg_may_start(const PGSTATE *s)
{
    return !s->done;
}
#endif

#ifndef PG_PAGES_ONLY
static void pg_end(PGSTATE *s)
{
    s->done = 1;
}
#endif

#ifndef PG_PAGES_ONLY
/* arm(): the slot for window w among n armed windows (armed[i] 0 = free,
 * alive[i] 0 = no longer a window, its slot reusable). *already = 1 when
 * w holds one. -1 = no slot. */
static int pg_arm_slot(const unsigned short *armed, const unsigned char *alive, int n,
                       unsigned short w, int *already)
{
    int i, slot = -1;
    *already = 0;
    for (i = 0; i < n; i++) {
        if (armed[i] == w && alive[i]) { *already = 1; return i; }
        if (slot < 0 && (!armed[i] || !alive[i])) slot = i;
    }
    return slot;
}
#endif

/* ---- the input recorder (diagnostics only: it never presses anything)
 *
 * X470 98 FE PL, 2026-10-27: the filled pages still stopped with
 * MSBATCH.INF loaded (Express=1); suspected: input from the USB bridge
 * (USOSKEY / VBMOUSE) that makes Setup leave its batch mode. usospg.c's
 * WH_MOUSE / WH_KEYBOARD hooks log every button press and key press (with
 * where it went) and a summary of pointer moves, so one install clicked by
 * hand shows what the user pressed and whether input came while nobody
 * touched anything. Never the text of an Edit: in an Edit (or a ComboBox)
 * a typing key is logged as "char" without its key code. */
#define PG_REC_MAX      2000        /* recorder lines per run, then one notice */
#define PG_MOVE_WINDOW  5000UL      /* ms: one "moves" summary at most this often */

#ifndef PG_PAGES_ONLY
/* 1 = write the line, 2 = write the limit notice instead (once), 0 = nothing. */
static int pg_rec_allow(unsigned *lines)
{
    if (*lines < PG_REC_MAX) { (*lines)++; return 1; }
    if (*lines == PG_REC_MAX) { (*lines)++; return 2; }
    return 0;
}
#endif

#ifndef PG_PAGES_ONLY
/* A key whose code would give away what is typed into an Edit: space,
 * digits, letters, the numeric pad, the OEM punctuation keys. Other keys
 * (Tab, Enter, Esc, arrows, Backspace, Shift / Ctrl / Alt, F keys) keep
 * their code. Outside an Edit nothing is hidden. */
static int pg_key_hidden(unsigned vk, int in_edit)
{
    if (!in_edit) return 0;
    if (vk == 0x20) return 1;
    if (vk >= 0x30 && vk <= 0x39) return 1;
    if (vk >= 0x41 && vk <= 0x5A) return 1;
    if (vk >= 0x60 && vk <= 0x6F) return 1;
    if (vk >= 0xBA && vk <= 0xC0) return 1;
    if (vk >= 0xDB && vk <= 0xDF) return 1;
    if (vk == 0xE2) return 1;
    return 0;
}
#endif

/* Pointer moves (WM_MOUSEMOVE / WM_NCMOUSEMOVE taken from a queue): a
 * window starts at the first move and is summarised once PG_MOVE_WINDOW
 * has passed: how many, how many with the pointer where it was ("still":
 * zero-delta reports, or Windows' own moves after a window change), and
 * the distance. No moves, no line. */
typedef struct {
    unsigned long since;        /* ms of the window's first move */
    unsigned long dist;         /* |dx| + |dy| */
    unsigned n;
    unsigned still;
    int x, y;                   /* the last position (kept across windows) */
    unsigned char have;
} PGMOVES;

static void pg_move_add(PGMOVES *m, int x, int y, unsigned long now)
{
    long dx, dy;
    if (!m->n) { m->since = now; m->dist = 0; m->still = 0; }
    if (m->n < 65535U) m->n++;
    if (m->have) {
        dx = (long)x - m->x;
        dy = (long)y - m->y;
        if (dx < 0) dx = -dx;
        if (dy < 0) dy = -dy;
        if (!dx && !dy) { if (m->still < 65535U) m->still++; }
        else m->dist += (unsigned long)(dx + dy);
    }
    m->x = x; m->y = y; m->have = 1;
}

/* 1: a summary is due now (force: whatever there is, e.g. at a pause). */
static int pg_move_due(const PGMOVES *m, unsigned long now, int force)
{
    if (!m->n) return 0;
    return force || now - m->since >= PG_MOVE_WINDOW;
}

static void pg_move_reset(PGMOVES *m)
{
    m->n = 0; m->still = 0; m->dist = 0;
}

/* The licence page's radio buttons (618 / 619), polled by the timer:
 * 1 when this page or its state (bit 0 accept, bit 1 decline) is new. */
typedef struct {
    unsigned short page;
    unsigned char state;
} PGRADIO;

#ifndef PG_PAGES_ONLY
static int pg_radio_note(PGRADIO *r, unsigned short page, unsigned char state)
{
    if (r->page == page && r->state == state) return 0;
    r->page = page;
    r->state = state;
    return 1;
}
#endif

#ifndef PG_PAGES_ONLY
/* Decimal of v into out (no 32-bit division: a 16-bit build has no C
 * runtime helper for it). Returns the length (1..10), out not terminated. */
static int pg_u32_dec(char *out, unsigned long v)
{
    static const unsigned long pow10[] = { 1000000000UL, 100000000UL, 10000000UL, 1000000UL, 100000UL,
                                           10000UL, 1000UL, 100UL, 10UL, 1UL };
    int i, n = 0;
    for (i = 0; i < 10; i++) {
        char d = '0';
        while (v >= pow10[i]) { v -= pow10[i]; d++; }
        if (d != '0' || n || i == 9) out[n++] = d;
    }
    return n;
}
#endif

#endif
