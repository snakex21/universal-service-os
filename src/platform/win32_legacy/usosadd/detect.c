/* USOSADD system detection (pure). GPL-3.0-or-later.
 * Table: docs/design/legacy-compat-pack.md section 2.2. */
#include "ua.h"

/* First non-space character of the CSD string, upper case, or 0. */
static char csd_letter(const char *csd) {
    while (*csd == ' ') csd++;
    if (*csd >= 'a' && *csd <= 'z') return (char)(*csd - 32);
    return *csd;
}

static void nt_sp(const ua_facts *f, char *out) {
    /* "Service Pack 6" (also localized: the number is the last digit run) */
    const char *s = f->csd;
    int sp = 0, seen = 0;
    for (; *s; s++) {
        if (*s >= '0' && *s <= '9') {
            if (!seen) sp = 0;
            sp = sp * 10 + (*s - '0');
            seen = 1;
        } else if (seen) {
            break;
        }
    }
    ua_itoa(out, 4, sp);
    if (sp == 6 && f->sp6a_hotfix) ua_copy(out, 4, "6a");
    if (sp == 6 && (s[0] == 'a' || s[0] == 'A')) ua_copy(out, 4, "6a");
}

void ua_detect(const ua_facts *f, ua_system *out) {
    unsigned primary = f->lang_id & 0x3ff;
    ua_copy(out->os, sizeof out->os, "?");
    out->ntsp[0] = 0;
    if (primary == 0x15) ua_copy(out->lang, sizeof out->lang, "PL");
    else if (primary == 0x09) ua_copy(out->lang, sizeof out->lang, "EN");
    else ua_copy(out->lang, sizeof out->lang, "XX");

    if (f->nt) {
        if (f->major == 4 && f->minor == 0) {
            ua_copy(out->os, sizeof out->os, "NT4");
            nt_sp(f, out->ntsp);
        }
        return;
    }
    if (f->major == 4 && f->minor == 0) {
        int build = f->build & 0xffff;
        char letter = csd_letter(f->csd);
        if (build < 1000) {
            ua_copy(out->os, sizeof out->os, letter == 'A' ? "95OSR1" : "95RTM");
        } else if (letter == 'C') {
            ua_copy(out->os, sizeof out->os, "95OSR25");
        } else {
            /* OSR2 vs OSR2.1: the USB supplement brings NTKERN.VXD 4.03. */
            int usb = f->ntkern_ver[0] > 4 || (f->ntkern_ver[0] == 4 && f->ntkern_ver[1] >= 3);
            ua_copy(out->os, sizeof out->os, usb ? "95OSR21" : "95OSR2");
        }
    } else if (f->major == 4 && f->minor == 10) {
        int build = f->build & 0xffff;
        ua_copy(out->os, sizeof out->os, build >= 2222 ? "98SE" : "98FE");
    } else if (f->major == 4 && f->minor == 90) {
        ua_copy(out->os, sizeof out->os, "ME");
    }
}

int ua_os_match(const ua_ini *m, const char *list, const char *os) {
    char item[32], key[40];
    int i;
    if (!list || !*list) return 0;
    for (i = 0; ua_list_item(list, i, item, sizeof item); i++) {
        const char *group;
        if (ua_ieq(item, os)) return 1;
        key[0] = 0;
        ua_append(key, sizeof key, "group_");
        ua_append(key, sizeof key, item);
        group = ua_ini_get(m, "pack", key);
        if (group && ua_list_has(group, os)) return 1;
    }
    return 0;
}
