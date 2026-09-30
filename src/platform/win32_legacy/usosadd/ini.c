/* USOSADD INI parser (in place, no C library). GPL-3.0-or-later. */
#include "ua.h"

static int is_space(char c) { return c == ' ' || c == '\t' || c == '\r'; }

static char *trim(char *s, char *end) {
    while (s < end && is_space(*s)) s++;
    while (end > s && is_space(end[-1])) end--;
    *end = 0;
    return s;
}

void ua_ini_parse(ua_ini *ini, char *buf, int len) {
    const char *section = "";
    char *p = buf, *limit = buf + len;
    ini->count = 0;
    ini->overflow = 0;
    /* UTF-8 byte order mark */
    if (len >= 3 && (unsigned char)p[0] == 0xEF && (unsigned char)p[1] == 0xBB && (unsigned char)p[2] == 0xBF) p += 3;
    while (p < limit) {
        char *line = p, *eol = p, *eq;
        while (eol < limit && *eol != '\n' && *eol != 0) eol++;
        p = eol < limit ? eol + 1 : limit;
        line = trim(line, eol);
        if (*line == 0 || *line == ';' || *line == '#') continue;
        if (*line == '[') {
            char *close = line + 1;
            while (*close && *close != ']') close++;
            section = trim(line + 1, close);
            continue;
        }
        eq = line;
        while (*eq && *eq != '=') eq++;
        if (*eq != '=') continue;
        if (ini->count >= UA_MAX_ENTRIES) { ini->overflow = 1; continue; }
        {
            char *vend = eq + 1;
            while (*vend) vend++;
            ini->e[ini->count].section = section;
            ini->e[ini->count].key = trim(line, eq);
            ini->e[ini->count].value = trim(eq + 1, vend);
            ini->count++;
        }
    }
}

const char *ua_ini_get(const ua_ini *ini, const char *section, const char *key) {
    int i;
    for (i = 0; i < ini->count; i++)
        if (ua_ieq(ini->e[i].section, section) && ua_ieq(ini->e[i].key, key))
            return ini->e[i].value;
    return 0;
}
