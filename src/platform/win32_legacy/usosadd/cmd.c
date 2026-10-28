/* USOSADD command expansion, builtins and installed-checks (pure).
 * GPL-3.0-or-later. */
#include "ua.h"

void ua_expand(const ua_vars *v, const char *in, char *out, int cap) {
    out[0] = 0;
    while (*in) {
        if (*in == '%') {
            const char *end = in + 1;
            while (*end && *end != '%' && *end != ' ') end++;
            if (*end == '%') {
                int n = (int)(end - in - 1);
                if (n == 0) { ua_append(out, cap, "%"); in = end + 1; continue; }
                if (n == 3 && ua_ieqn(in + 1, "PKG", 3)) {
                    ua_append(out, cap, v->root); ua_append(out, cap, "\\PKG\\"); ua_append(out, cap, v->dir);
                    in = end + 1; continue;
                }
                if (n == 3 && ua_ieqn(in + 1, "TMP", 3)) {
                    ua_append(out, cap, v->root); ua_append(out, cap, "\\TMP\\"); ua_append(out, cap, v->dir);
                    in = end + 1; continue;
                }
                if (n == 3 && ua_ieqn(in + 1, "WIN", 3)) { ua_append(out, cap, v->win); in = end + 1; continue; }
                if (n == 3 && ua_ieqn(in + 1, "SYS", 3)) { ua_append(out, cap, v->sys); in = end + 1; continue; }
                if (n == 3 && ua_ieqn(in + 1, "ADD", 3)) { ua_append(out, cap, v->root); in = end + 1; continue; }
                if (n == 2 && ua_ieqn(in + 1, "PF", 2)) { ua_append(out, cap, v->pf); in = end + 1; continue; }
            }
        }
        ua_append_n(out, cap, in, 1);
        in++;
    }
}

/* Next token (quotes removed) into tok; returns the rest (spaces skipped). */
static const char *token(const char *s, char *tok, int cap) {
    int n = 0;
    while (*s == ' ') s++;
    if (*s == '"') {
        s++;
        while (*s && *s != '"') { if (n < cap - 1) tok[n++] = *s; s++; }
        if (*s == '"') s++;
    } else {
        while (*s && *s != ' ') { if (n < cap - 1) tok[n++] = *s; s++; }
    }
    tok[n] = 0;
    while (*s == ' ') s++;
    return s;
}

unsigned long ua_command_exit(const char *command, unsigned long code) {
    char exe[UA_LINE];
    const char *base, *p;
    if (code != 1) return code;
    token(command, exe, sizeof exe);
    base = exe;
    for (p = exe; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
    return ua_ieq(base, "DXSETUP.EXE") ? 3010 : code;
}

void ua_parse_cmd(const char *line, ua_cmd *out) {
    char verb[16];
    const char *rest = token(line, verb, sizeof verb);
    out->a[0] = 0;
    out->b[0] = 0;
    if (ua_ieq(verb, "copy") || ua_ieq(verb, "force")) {
        out->kind = ua_ieq(verb, "copy") ? UA_CMD_COPY : UA_CMD_FORCE;
        rest = token(rest, out->a, sizeof out->a);
        token(rest, out->b, sizeof out->b);
    } else if (ua_ieq(verb, "attrib")) {
        out->kind = UA_CMD_ATTRIB;
        token(rest, out->a, sizeof out->a);
    } else if (ua_ieq(verb, "append") || ua_ieq(verb, "cd") || ua_ieq(verb, "msi")) {
        out->kind = ua_ieq(verb, "append") ? UA_CMD_APPEND : ua_ieq(verb, "cd") ? UA_CMD_CD : UA_CMD_MSI;
        rest = token(rest, out->a, sizeof out->a);
        ua_copy(out->b, sizeof out->b, rest);
    } else if (ua_ieq(verb, "inf")) {
        out->kind = UA_CMD_INF;
        rest = token(rest, out->a, sizeof out->a);
        ua_copy(out->b, sizeof out->b, *rest ? rest : "DefaultInstall");
    } else {
        out->kind = UA_CMD_RUN;
        ua_copy(out->b, sizeof out->b, line);
    }
}

/* Splits "<path>>=<min>" at the last ">=". */
static void split_min(const char *s, char *path, int pcap, char *min, int mcap) {
    const char *ge = 0, *p;
    for (p = s; *p; p++) if (p[0] == '>' && p[1] == '=') ge = p;
    if (ge) {
        int n = (int)(ge - s);
        if (n > pcap - 1) n = pcap - 1;
        ua_copy(path, n + 1, s);
        ua_copy(min, mcap, ge + 2);
    } else {
        ua_copy(path, pcap, s);
        min[0] = 0;
    }
}

/* "HKLM\key,value" -> hive, key, value */
static int reg_split(const char *s, ua_check *out) {
    char full[UA_PATH];
    int i, comma = -1, n;
    ua_copy(full, sizeof full, s);
    for (i = 0; full[i]; i++) if (full[i] == ',') comma = i;
    out->value[0] = 0;
    if (comma >= 0) { ua_copy(out->value, sizeof out->value, full + comma + 1); full[comma] = 0; }
    if (ua_starts(full, "HKLM\\")) { out->hive = 0; n = 5; }
    else if (ua_starts(full, "HKCU\\")) { out->hive = 1; n = 5; }
    else if (ua_starts(full, "HKEY_LOCAL_MACHINE\\")) { out->hive = 0; n = 19; }
    else return 0;
    ua_copy(out->path, sizeof out->path, full + n);
    return 1;
}

int ua_parse_check(const char *s, ua_check *out) {
    char body[UA_PATH];
    out->kind = UA_CHK_NONE;
    out->path[0] = out->value[0] = out->min[0] = 0;
    out->hive = 0;
    if (!s || !*s) return 1;
    if (ua_starts(s, "file:")) {
        out->kind = UA_CHK_FILE;
        split_min(s + 5, out->path, sizeof out->path, out->min, sizeof out->min);
        return out->path[0] != 0;
    }
    if (ua_starts(s, "ntsp:")) {
        out->kind = UA_CHK_NTSP;
        ua_copy(out->min, sizeof out->min, s + 5);
        return out->min[0] != 0;
    }
    if (ua_starts(s, "regver:") || ua_starts(s, "regdw:")) {
        out->kind = ua_starts(s, "regver:") ? UA_CHK_REGVER : UA_CHK_REGDW;
        split_min(s + (out->kind == UA_CHK_REGVER ? 7 : 6), body, sizeof body, out->min, sizeof out->min);
        return reg_split(body, out) && out->value[0] && out->min[0];
    }
    if (ua_starts(s, "reg:")) {
        out->kind = UA_CHK_REG;
        return reg_split(s + 4, out);
    }
    return 0;
}
