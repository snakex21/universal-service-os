/* USOSADD - USOS legacy post-install runner (Windows 95/98/Me/NT 4.0).
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 * Design: docs/design/legacy-compat-pack.md.
 *
 * Everything in this header except main.c is pure C with no library calls,
 * so the same files build with OpenWatcom (target, no C runtime) and with
 * the host compiler for the tests (tools/tests/addons). */
#ifndef USOSADD_UA_H
#define USOSADD_UA_H

#define UA_MAX_ENTRIES 4096
#define UA_MAX_PKGS 160
#define UA_MAX_LIST 48
#define UA_MAX_VER 6
#define UA_PATH 300
#define UA_LINE 1100

/* ---- strings (str.c) ---------------------------------------------------- */
int ua_len(const char *s);
int ua_ieq(const char *a, const char *b);
int ua_ieqn(const char *a, const char *b, int n);
int ua_starts(const char *s, const char *prefix); /* case-insensitive */
void ua_copy(char *dst, int cap, const char *src);
void ua_append(char *dst, int cap, const char *src);
void ua_append_n(char *dst, int cap, const char *src, int n);
char *ua_find(const char *s, const char *needle); /* case-sensitive */
int ua_atoi(const char *s);
void ua_itoa(char *dst, int cap, int v);
/* Versions: dotted or comma-separated numbers; a trailing letter is one
 * more component (9.0c = 9.0.3, 6a = 6.1). Returns <0, 0, >0. */
int ua_vercmp(const char *a, const char *b);
/* Splits a comma list in place-free fashion: copies item i into out. */
int ua_list_item(const char *list, int index, char *out, int cap);
int ua_list_has(const char *list, const char *item); /* case-insensitive */

/* ---- INI (ini.c) ---------------------------------------------------------- */
typedef struct {
    const char *section;
    const char *key;
    const char *value;
} ua_entry;

typedef struct {
    ua_entry e[UA_MAX_ENTRIES];
    int count;
    int overflow;
} ua_ini;

/* Parses buf (modified in place, NUL-terminated, len bytes). Lines:
 * [section], key=value, ';' comments. Keys and section names are compared
 * case-insensitively; values are trimmed. */
void ua_ini_parse(ua_ini *ini, char *buf, int len);
const char *ua_ini_get(const ua_ini *ini, const char *section, const char *key);

/* ---- system detection (detect.c) ------------------------------------------ */
typedef struct {
    int nt;            /* 0 = Windows 9x, 1 = NT */
    int major, minor, build;
    char csd[64];      /* szCSDVersion as returned */
    char subver[16];   /* 9x: HKLM\...\Windows\CurrentVersion SubVersionNumber */
    int ntkern_ver[4]; /* 9x: SYSTEM\VMM32\NTKERN.VXD file version, 0 if unknown */
    int sp6a_hotfix;   /* NT: Hotfix\Q246009 present */
    unsigned lang_id;  /* GetSystemDefaultLangID() */
} ua_facts;

typedef struct {
    char os[12];    /* token: 95RTM ... NT4, or "?" */
    char lang[4];   /* PL, EN or XX */
    char ntsp[4];   /* NT4 service pack: "0".."6", "6a"; "" on 9x */
} ua_system;

void ua_detect(const ua_facts *f, ua_system *out);
/* os= list match with the manifest's groups ([pack] group_<name>). */
int ua_os_match(const ua_ini *m, const char *list, const char *os);

/* ---- packages and plan (plan.c) ------------------------------------------- */
enum { UA_TIER_NONE, UA_TIER_FULL, UA_TIER_OPTION, UA_TIER_GROUP };
enum { UA_REBOOT_NO, UA_REBOOT_END, UA_REBOOT_NOW };

typedef struct {
    const char *id;       /* section name without "pkg:" */
    const char *section;  /* full section name */
    const char *dir;
    const char *os;
    const char *lang;
    const char *ntsp;
    const char *needs;
    const char *provides;
    const char *check;
    const char *status;
    const char *requires; /* run-time system components (requires=tcpip) */
    int tier;
    int order;
    int reboot;
} ua_pkg;

/* Why a package is in or out of the plan. */
enum {
    UA_WHY_FULL = 1,     /* in: tier=full */
    UA_WHY_OPTION,       /* in: chosen option */
    UA_WHY_NEEDED,       /* in: pulled in by needs= */
    UA_OUT_SYSTEM,       /* out: os/lang/ntsp do not fit */
    UA_OUT_NEEDS,        /* out: a need stays unmet */
    UA_OUT_STATUS,       /* out: status= set (missing file / needs-iss) */
    UA_OUT_UNKNOWN       /* out: option id not in the manifest */
};

typedef struct {
    ua_pkg pkg[UA_MAX_PKGS];
    int count;
} ua_pkgs;

typedef struct {
    int idx[UA_MAX_PKGS];  /* plan order, index into ua_pkgs */
    int count;
    int why[UA_MAX_PKGS];  /* per package index: UA_WHY_* / UA_OUT_* / 0 */
    char unmet[UA_MAX_PKGS][40]; /* UA_OUT_NEEDS: first unmet capability */
    char eff_ntsp[4];      /* NT SP level assumed for applicability */
} ua_plan;

int ua_load_pkgs(const ua_ini *m, ua_pkgs *out);
int ua_pkg_find(const ua_pkgs *p, const char *id);
/* USOSADD /setup (the Windows 95 first-boot coordinator USOSFB, builds 950
 * and OSR2): reboot_setup= and check_setup= of a package replace its reboot= and
 * check=. Other systems and the ordinary Run flow never read them. Returns
 * the number of replaced values. */
int ua_setup_overrides(const ua_ini *m, ua_pkgs *p);
int ua_applicable(const ua_ini *m, const ua_pkg *p, const ua_system *s, const char *ntsp);
/* Capability "name:version" satisfied by the OS ([os:<token>] provides=,
 * plus ntsp:<level> on NT). */
int ua_os_provides(const ua_ini *m, const ua_system *s, const char *cap);
int ua_cap_satisfies(const char *provided, const char *needed);
/* exclude: ids never planned (not even as providers of a need). */
void ua_resolve(const ua_ini *m, const ua_pkgs *p, const ua_system *s,
                int full, const char *options, const char *exclude, ua_plan *out);

/* The choice from SELECT.INI [select]: preset= (default [presets]
 * default=), full= overrides the preset's, options= adds to the preset's,
 * exclude= removes. options/exclude are written as comma lists. */
typedef struct {
    char preset[24];
    int full;
    char options[1024];
    char exclude[1024];
} ua_choice;
void ua_selection(const ua_ini *m, const ua_ini *sel, ua_choice *out);

/* ---- commands (cmd.c) ------------------------------------------------------ */
typedef struct {
    const char *root;  /* C:\USOS\ADDONS */
    const char *win;
    const char *sys;
    const char *pf;
    const char *dir;   /* package 8.3 dir */
} ua_vars;

/* Expands %PKG% %TMP% %WIN% %SYS% %PF% %ADD% and %%; unknown %X% kept. */
void ua_expand(const ua_vars *v, const char *in, char *out, int cap);

enum { UA_CMD_RUN, UA_CMD_COPY, UA_CMD_FORCE, UA_CMD_ATTRIB, UA_CMD_APPEND,
       UA_CMD_CD, UA_CMD_INF, UA_CMD_MSI };
typedef struct {
    int kind;
    char a[UA_PATH];     /* first argument (or the whole command line) */
    char b[UA_LINE];     /* rest */
} ua_cmd;
/* Classifies an expanded command line. */
void ua_parse_cmd(const char *line, ua_cmd *out);
/* DXSETUP's success-with-restart value 1 uses the common 3010 policy.
 * Other executables' value 1 remains an error. */
unsigned long ua_command_exit(const char *command, unsigned long code);

/* Checks: file:, regver:, reg:, regdw:, ntsp: */
enum { UA_CHK_NONE, UA_CHK_FILE, UA_CHK_REGVER, UA_CHK_REG, UA_CHK_REGDW, UA_CHK_NTSP };
typedef struct {
    int kind;
    char path[UA_PATH];  /* file path or registry key (after HKLM\ etc.) */
    int hive;            /* 0 = HKLM, 1 = HKCU */
    char value[80];      /* registry value name ("" = key only) */
    char min[40];        /* minimum version / number ("" = presence only) */
} ua_check;
int ua_parse_check(const char *expanded, ua_check *out);

/* ---- state (state.c) ------------------------------------------------------- */
enum { UA_ST_NEW, UA_ST_RUNNING, UA_ST_DONE, UA_ST_PRESENT, UA_ST_FAILED, UA_ST_SKIPPED };
typedef struct {
    int st[UA_MAX_PKGS];
    int tries[UA_MAX_PKGS];
    char why[UA_MAX_PKGS][80]; /* reason for failed / skipped (STATE.INI [why]) */
    int pending_reboot;
    int starts;
} ua_state;
void ua_state_load(ua_state *s, const ua_ini *ini, const ua_pkgs *p);
/* Writes STATE.INI text into out; returns its length. */
int ua_state_write(const ua_state *s, const ua_pkgs *p, char *out, int cap);
const char *ua_state_name(int st);

/* Decision for a package found in state RUNNING at start (it restarted the
 * PC itself or the runner was killed): 1 = done (check true), 2 = run again,
 * 3 = failed (second time). */
int ua_resume_decision(int tries, int has_check, int check_true);
/* Decision after a package's commands ran (ok = its check or exit code
 * passed; tries counts this run). Restarts are batched: only reboot=now
 * restarts at once, reboot=end only marks one as pending for the final
 * restart, and nothing restarts before a package merely because a restart
 * is pending. A package that failed while a restart is pending (another
 * package's, or its own reboot=now/end kind, whose check may only turn true
 * after it) gets one more try after that restart instead of failing. */
enum { UA_AFTER_CONTINUE, UA_AFTER_PENDING, UA_AFTER_RESTART, UA_AFTER_RETRY };
int ua_after_run(int ok, int reboot, int pending_reboot, int tries);
/* reboot=now as it applies to one run (before ua_after_run): on 9x a
 * restart at once only when the installer asked for one (asked: an exit
 * code 3010 / 1641, DXSETUP's 1 mapped to 3010 by ua_command_exit), else
 * it is batched like reboot=end (X470 98 FE PL 2026-10-27: MDAC 2.8 exit
 * 0 still restarted). forced (NT, and the 95 first-desktop coordinator's
 * reboot_setup=now for DCOM95 / IE 5.5 SP2 on 950): now stays now. */
int ua_reboot_for_run(int reboot, int asked, int forced);
/* Recheck NDIS only after an attempted Winsock2 install on Windows 95. */
int ua_ndis_repair_needed(const ua_pkgs *p, const ua_plan *plan,
                           const ua_state *state, const ua_system *system);
/* requires= (run time, before the package's commands): the first listed
 * component that is absent, copied into item; 0 = all present. Known:
 * tcpip (TCP/IP installed and bound, as W95WS2's setup checks). An unknown
 * name counts as absent (fail closed: the package is skipped). */
const char *ua_requires_missing(const ua_pkg *p, int tcpip, char *item, int cap);
/* Runtime need check: satisfied by the OS or by a provider in state
 * DONE/PRESENT. Writes the first unmet capability into unmet. */
int ua_needs_met(const ua_ini *m, const ua_pkgs *p, const ua_state *st,
                 const ua_system *s, int pkg, char *unmet, int cap);
/* /setup: a package whose retry after a restart was deferred to the end of
 * the chain (deferred[i] != 0) provides the capability cap: a package that
 * needs it waits for the next start instead of being skipped. */
int ua_deferred_provides(const ua_pkgs *p, const char *deferred, const char *cap);

#endif
