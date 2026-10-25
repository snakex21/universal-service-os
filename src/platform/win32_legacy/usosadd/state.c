/* USOSADD resumable state (pure). GPL-3.0-or-later.
 * STATE.INI:  [state] starts=N  pending_reboot=0|1  <id>=<state>[:<tries>] */
#include "ua.h"

static const char *const names[] = { "new", "running", "done", "present", "failed", "skipped" };

const char *ua_state_name(int st) { return (st >= 0 && st <= UA_ST_SKIPPED) ? names[st] : "?"; }

void ua_state_load(ua_state *s, const ua_ini *ini, const ua_pkgs *p) {
    int i;
    const char *v;
    s->pending_reboot = 0;
    s->starts = 0;
    for (i = 0; i < p->count; i++) { s->st[i] = UA_ST_NEW; s->tries[i] = 0; s->why[i][0] = 0; }
    if (!ini) return;
    v = ua_ini_get(ini, "state", "starts");
    if (v) s->starts = ua_atoi(v);
    v = ua_ini_get(ini, "state", "pending_reboot");
    if (v) s->pending_reboot = ua_atoi(v);
    for (i = 0; i < p->count; i++) {
        int k;
        v = ua_ini_get(ini, "why", p->pkg[i].id);
        if (v) ua_copy(s->why[i], sizeof s->why[i], v);
        v = ua_ini_get(ini, "state", p->pkg[i].id);
        if (!v) continue;
        for (k = 0; k <= UA_ST_SKIPPED; k++) {
            int n = ua_len(names[k]);
            if (ua_ieqn(v, names[k], n) && (v[n] == 0 || v[n] == ':')) {
                s->st[i] = k;
                if (v[n] == ':') s->tries[i] = ua_atoi(v + n + 1);
                break;
            }
        }
    }
}

int ua_state_write(const ua_state *s, const ua_pkgs *p, char *out, int cap) {
    char num[16];
    int i;
    out[0] = 0;
    ua_append(out, cap, "; USOSADD state - written by C:\\USOS\\ADDONS\\USOSADD.EXE\r\n[state]\r\nstarts=");
    ua_itoa(num, sizeof num, s->starts);
    ua_append(out, cap, num);
    ua_append(out, cap, "\r\npending_reboot=");
    ua_append(out, cap, s->pending_reboot ? "1" : "0");
    ua_append(out, cap, "\r\n");
    for (i = 0; i < p->count; i++) {
        if (s->st[i] == UA_ST_NEW) continue;
        ua_append(out, cap, p->pkg[i].id);
        ua_append(out, cap, "=");
        ua_append(out, cap, ua_state_name(s->st[i]));
        if (s->tries[i]) {
            ua_itoa(num, sizeof num, s->tries[i]);
            ua_append(out, cap, ":");
            ua_append(out, cap, num);
        }
        ua_append(out, cap, "\r\n");
    }
    ua_append(out, cap, "[why]\r\n");
    for (i = 0; i < p->count; i++) {
        if (!s->why[i][0] || (s->st[i] != UA_ST_FAILED && s->st[i] != UA_ST_SKIPPED)) continue;
        ua_append(out, cap, p->pkg[i].id);
        ua_append(out, cap, "=");
        ua_append(out, cap, s->why[i]);
        ua_append(out, cap, "\r\n");
    }
    return ua_len(out);
}

int ua_resume_decision(int tries, int has_check, int check_true) {
    if (has_check && check_true) return 1;
    if (tries >= 2) return 3;
    return 2;
}

int ua_after_run(int ok, int reboot, int pending_reboot, int tries) {
    if (ok) return reboot == UA_REBOOT_NOW ? UA_AFTER_RESTART : reboot == UA_REBOOT_END ? UA_AFTER_PENDING : UA_AFTER_CONTINUE;
    if (tries < 2 && (pending_reboot || reboot != UA_REBOOT_NO)) return UA_AFTER_RETRY;
    return UA_AFTER_CONTINUE;
}

int ua_needs_met(const ua_ini *m, const ua_pkgs *p, const ua_state *st,
                 const ua_system *s, int pkg, char *unmet, int cap) {
    char item[48];
    int k;
    unmet[0] = 0;
    for (k = 0; ua_list_item(p->pkg[pkg].needs, k, item, sizeof item); k++) {
        int i, found = 0;
        if (ua_os_provides(m, s, item)) continue;
        for (i = 0; i < p->count && !found; i++) {
            char cap2[48];
            int j;
            if (st->st[i] != UA_ST_DONE && st->st[i] != UA_ST_PRESENT) continue;
            for (j = 0; !found && ua_list_item(p->pkg[i].provides, j, cap2, sizeof cap2); j++)
                if (ua_cap_satisfies(cap2, item)) found = 1;
        }
        if (!found) { ua_copy(unmet, cap, item); return 0; }
    }
    return 1;
}
