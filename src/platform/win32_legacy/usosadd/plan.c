/* USOSADD packages and plan resolution (pure). GPL-3.0-or-later.
 * Algorithm: docs/design/legacy-compat-pack.md section 2.3; mirrored by
 * tools/addons/legacy_manifest.py (the tests compare both). */
#include "ua.h"

static const char *get(const ua_ini *m, const char *section, const char *key) {
    const char *v = ua_ini_get(m, section, key);
    return v ? v : "";
}

int ua_load_pkgs(const ua_ini *m, ua_pkgs *out) {
    int i;
    out->count = 0;
    for (i = 0; i < m->count; i++) {
        const char *sec = m->e[i].section;
        ua_pkg *p;
        const char *tier, *reboot;
        int j, dup = 0;
        if (!ua_starts(sec, "pkg:")) continue;
        for (j = 0; j < out->count; j++) if (out->pkg[j].section == sec || ua_ieq(out->pkg[j].section, sec)) { dup = 1; break; }
        if (dup) continue;
        if (out->count >= UA_MAX_PKGS) return -1;
        p = &out->pkg[out->count++];
        p->section = sec;
        p->id = sec + 4;
        p->dir = get(m, sec, "dir");
        p->os = get(m, sec, "os");
        p->lang = get(m, sec, "lang");
        p->ntsp = get(m, sec, "ntsp");
        p->needs = get(m, sec, "needs");
        p->provides = get(m, sec, "provides");
        p->check = get(m, sec, "check");
        p->status = get(m, sec, "status");
        p->order = ua_atoi(get(m, sec, "order"));
        tier = get(m, sec, "tier");
        p->tier = ua_ieq(tier, "full") ? UA_TIER_FULL : ua_ieq(tier, "option") ? UA_TIER_OPTION
                : ua_ieq(tier, "group") ? UA_TIER_GROUP : UA_TIER_NONE;
        reboot = get(m, sec, "reboot");
        p->reboot = ua_ieq(reboot, "now") ? UA_REBOOT_NOW : ua_ieq(reboot, "end") ? UA_REBOOT_END : UA_REBOOT_NO;
    }
    return out->count;
}

int ua_setup_overrides(const ua_ini *m, ua_pkgs *p) {
    int i, n = 0;
    for (i = 0; i < p->count; i++) {
        ua_pkg *k = &p->pkg[i];
        const char *v = ua_ini_get(m, k->section, "reboot_setup");
        if (v && *v) {
            k->reboot = ua_ieq(v, "now") ? UA_REBOOT_NOW : ua_ieq(v, "end") ? UA_REBOOT_END : UA_REBOOT_NO;
            n++;
        }
        v = ua_ini_get(m, k->section, "check_setup");
        if (v && *v) { k->check = v; n++; }
    }
    return n;
}

int ua_pkg_find(const ua_pkgs *p, const char *id) {
    int i;
    for (i = 0; i < p->count; i++) if (ua_ieq(p->pkg[i].id, id)) return i;
    return -1;
}

/* ntsp condition: "" (any), "6a+" (at least), "<6a" (below). "<" is
 * judged by the detected level (a service pack still to install), "+" by
 * the effective one (raised by a service pack in the plan). */
static int ntsp_ok(const char *cond, const char *detected, const char *level) {
    char v[8];
    int n;
    if (!cond || !*cond) return 1;
    if (!detected || !*detected) return 0; /* NT condition on a non-NT system */
    if (!level || !*level) level = detected;
    if (cond[0] == '<') return ua_vercmp(detected, cond + 1) < 0;
    n = ua_len(cond);
    ua_copy(v, sizeof v, cond);
    if (n > 0 && v[n - 1] == '+') v[n - 1] = 0;
    return ua_vercmp(level, v) >= 0;
}

int ua_applicable(const ua_ini *m, const ua_pkg *p, const ua_system *s, const char *ntsp) {
    if (!ua_os_match(m, p->os, s->os)) return 0;
    if (!(ua_ieq(p->lang, "*") || ua_ieq(p->lang, s->lang))) return 0;
    return ntsp_ok(p->ntsp, s->ntsp, ntsp);
}

/* "name:version" -> name and version (version "" when absent). */
static void cap_split(const char *cap, char *name, int ncap, const char **ver) {
    int i = 0;
    while (cap[i] && cap[i] != ':' && i < ncap - 1) { name[i] = cap[i]; i++; }
    name[i] = 0;
    while (cap[i] && cap[i] != ':') i++;
    *ver = cap[i] == ':' ? cap + i + 1 : "";
}

int ua_cap_satisfies(const char *provided, const char *needed) {
    char pn[40], nn[40];
    const char *pv, *nv;
    cap_split(provided, pn, sizeof pn, &pv);
    cap_split(needed, nn, sizeof nn, &nv);
    if (!ua_ieq(pn, nn)) return 0;
    if (!*nv) return 1;
    return ua_vercmp(pv, nv) >= 0;
}

static int list_satisfies(const char *list, const char *need) {
    char item[48];
    int i;
    for (i = 0; ua_list_item(list, i, item, sizeof item); i++)
        if (ua_cap_satisfies(item, need)) return 1;
    return 0;
}

int ua_os_provides(const ua_ini *m, const ua_system *s, const char *cap) {
    char sec[24];
    const char *list;
    sec[0] = 0;
    ua_append(sec, sizeof sec, "os:");
    ua_append(sec, sizeof sec, s->os);
    list = ua_ini_get(m, sec, "provides");
    if (list && list_satisfies(list, cap)) return 1;
    if (s->ntsp[0]) {
        char own[16];
        own[0] = 0;
        ua_append(own, sizeof own, "ntsp:");
        ua_append(own, sizeof own, s->ntsp);
        if (ua_cap_satisfies(own, cap)) return 1;
    }
    return 0;
}

/* Provider of need among in[] (in = 1), or a new applicable one (in = 0,
 * status empty, lowest order), or -1. */
static int provider(const ua_ini *m, const ua_pkgs *p, const ua_system *s, const char *ntsp,
                    const int *in, const char *need, int want_new, const char *exclude) {
    int i, best = -1;
    if (!exclude) exclude = "";
    for (i = 0; i < p->count; i++) {
        const ua_pkg *q = &p->pkg[i];
        if (!list_satisfies(q->provides, need)) continue;
        if (!want_new) { if (in[i]) return i; continue; }
        if (in[i] || *q->status || ua_list_has(exclude, q->id) || !ua_applicable(m, q, s, ntsp)) continue;
        if (best < 0 || q->order < p->pkg[best].order) best = i;
    }
    return best;
}

static void select_candidates(const ua_ini *m, const ua_pkgs *p, const ua_system *s, const char *ntsp,
                              int full, const char *options, const char *exclude, int *in, ua_plan *out) {
    int i, changed;
    char item[48];
    for (i = 0; i < p->count; i++) { in[i] = 0; out->why[i] = 0; out->unmet[i][0] = 0; }
    for (i = 0; i < p->count; i++) {
        const ua_pkg *q = &p->pkg[i];
        int wanted = (full && (q->tier == UA_TIER_FULL || q->tier == UA_TIER_GROUP)) ? UA_WHY_FULL : 0;
        if (ua_list_has(exclude, q->id)) continue;
        if (!wanted && ua_list_has(options, q->id)) wanted = UA_WHY_OPTION;
        if (!wanted) continue;
        if (!ua_applicable(m, q, s, ntsp)) { out->why[i] = UA_OUT_SYSTEM; continue; }
        if (*q->status) { out->why[i] = UA_OUT_STATUS; continue; }
        in[i] = 1;
        out->why[i] = wanted;
    }
    /* Pull in providers of unmet needs until nothing changes. */
    do {
        changed = 0;
        for (i = 0; i < p->count; i++) {
            int k;
            if (!in[i]) continue;
            for (k = 0; ua_list_item(p->pkg[i].needs, k, item, sizeof item); k++) {
                int q;
                if (ua_os_provides(m, s, item)) continue;
                if (provider(m, p, s, ntsp, in, item, 0, exclude) >= 0) continue;
                q = provider(m, p, s, ntsp, in, item, 1, exclude);
                if (q >= 0) { in[q] = 1; out->why[q] = UA_WHY_NEEDED; changed = 1; }
            }
        }
    } while (changed);
}

void ua_resolve(const ua_ini *m, const ua_pkgs *p, const ua_system *s,
                int full, const char *options, const char *exclude, ua_plan *out) {
    int in[UA_MAX_PKGS];
    int i, j, pass;
    char item[48];
    ua_copy(out->eff_ntsp, sizeof out->eff_ntsp, s->ntsp);
    /* A selected service pack raises the level later packages are judged by
     * (the runner re-resolves after its restart anyway). */
    for (pass = 0; pass < 2; pass++) {
        char best[8];
        select_candidates(m, p, s, out->eff_ntsp, full, options, exclude ? exclude : "", in, out);
        if (!s->ntsp[0]) break;
        best[0] = 0;
        for (i = 0; i < p->count; i++) {
            char cap[48];
            int k;
            if (!in[i]) continue;
            for (k = 0; ua_list_item(p->pkg[i].provides, k, cap, sizeof cap); k++)
                if (ua_ieqn(cap, "ntsp:", 5) && ua_vercmp(cap + 5, out->eff_ntsp) > 0 &&
                    (!best[0] || ua_vercmp(cap + 5, best) > 0))
                    ua_copy(best, sizeof best, cap + 5);
        }
        if (!best[0]) break;
        ua_copy(out->eff_ntsp, sizeof out->eff_ntsp, best);
    }
    /* Order: by order=, then manifest position (stable insertion sort). */
    out->count = 0;
    for (i = 0; i < p->count; i++) {
        if (!in[i]) continue;
        j = out->count++;
        while (j > 0 && p->pkg[out->idx[j - 1]].order > p->pkg[i].order) { out->idx[j] = out->idx[j - 1]; j--; }
        out->idx[j] = i;
    }
    /* Drop packages whose needs are neither built in nor provided by an
     * earlier kept package. */
    j = 0;
    for (i = 0; i < out->count; i++) {
        int x = out->idx[i], k, ok = 1;
        for (k = 0; ok && ua_list_item(p->pkg[x].needs, k, item, sizeof item); k++) {
            int y, found = 0;
            if (ua_os_provides(m, s, item)) continue;
            for (y = 0; y < j && !found; y++)
                if (p->pkg[out->idx[y]].order < p->pkg[x].order && list_satisfies(p->pkg[out->idx[y]].provides, item)) found = 1;
            if (!found) { ok = 0; ua_copy(out->unmet[x], sizeof out->unmet[x], item); }
        }
        if (ok) out->idx[j++] = x;
        else out->why[x] = UA_OUT_NEEDS;
    }
    out->count = j;
}

static void list_add(char *list, int cap, const char *items) {
    char item[48];
    int i;
    for (i = 0; ua_list_item(items, i, item, sizeof item); i++) {
        if (ua_list_has(list, item)) continue;
        if (*list) ua_append(list, cap, ",");
        ua_append(list, cap, item);
    }
}

void ua_selection(const ua_ini *m, const ua_ini *sel, ua_choice *out) {
    const char *v = sel ? ua_ini_get(sel, "select", "preset") : 0;
    char sec[40];
    out->options[0] = out->exclude[0] = 0;
    if (!v || !*v) v = ua_ini_get(m, "presets", "default");
    ua_copy(out->preset, sizeof out->preset, v ? v : "");
    sec[0] = 0;
    ua_append(sec, sizeof sec, "preset:");
    ua_append(sec, sizeof sec, out->preset);
    v = ua_ini_get(m, sec, "full");
    out->full = v ? ua_atoi(v) == 1 : 0;
    v = ua_ini_get(m, sec, "options");
    if (v) list_add(out->options, sizeof out->options, v);
    if (!sel) return;
    v = ua_ini_get(sel, "select", "full");
    if (v && *v) out->full = ua_atoi(v) == 1;
    v = ua_ini_get(sel, "select", "options");
    if (v) list_add(out->options, sizeof out->options, v);
    v = ua_ini_get(sel, "select", "exclude");
    if (v) list_add(out->exclude, sizeof out->exclude, v);
}
