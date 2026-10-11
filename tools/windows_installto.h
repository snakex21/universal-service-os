/* InstallTo edit of a Windows Setup answer file (UTF-8), shared by the
 * WinPE helpers of the CSMWrap paths that prepare the target disk in
 * micro-Linux (usos-x86-csmwrap.exe, usos-vista-install.exe in CSMWrap mode;
 * docs/design/csmwrap-integration.md sections 10-12). The user picked and
 * confirmed that disk in the USOS menu, so Setup must not ask again and must
 * not touch any other disk:
 *   1. every disk setting of the answer is removed (DiskConfiguration,
 *      InstallTo, InstallToAvailablePartition): only the prepared disk counts;
 *   2. ImageInstall/OSImage/InstallTo = the prepared disk and Windows
 *      partition is added to every Microsoft-Windows-Setup component (answer
 *      files often carry one per architecture; Setup reads its own);
 *   3. without such a component one is added (windowsPE pass) for `arch`.
 * Before that: an answer with components only for the other architecture is
 * retargeted to `arch` (usos_it_arch), and the Setup component's product key
 * is made acceptable to this Setup (usos_it_key: never an empty <Key>; 8.x /
 * 10 without a key get Setup's own key/edition page instead of the
 * "cannot read the <ProductKey> setting" stop seen on the X470 2026-10-11).
 * No C runtime: the caller provides memcpy/memset. Returns the output length,
 * or 0 when the input is not a usable answer or the output does not fit.
 * `*note` says what was done (for the log). */
#ifndef USOS_WINDOWS_INSTALLTO_H
#define USOS_WINDOWS_INSTALLTO_H

static DWORD usos_it_len(const char *s) { DWORD n = 0; while (s[n]) n++; return n; }
static BOOL usos_it_at(const char *p, DWORD left, const char *word) {
    DWORD n = usos_it_len(word);
    if (left < n) return FALSE;
    for (DWORD i = 0; i < n; i++) if (p[i] != word[i]) return FALSE;
    return TRUE;
}
static long usos_it_find(const char *text, DWORD len, DWORD from, const char *word) {
    for (DWORD i = from; i < len; i++) if (usos_it_at(text + i, len - i, word)) return (long)i;
    return -1;
}
/* "<name" followed by a space, '>' or '/' (not a longer element name). */
static long usos_it_element(const char *text, DWORD len, DWORD from, const char *open) {
    DWORD n = usos_it_len(open);
    for (long at = usos_it_find(text, len, from, open); at >= 0; at = usos_it_find(text, len, (DWORD)at + 1, open)) {
        char c = (DWORD)at + n < len ? text[at + n] : 0;
        if (c == ' ' || c == '>' || c == '/' || c == '\t' || c == '\r' || c == '\n') return at;
    }
    return -1;
}
/* End (exclusive) of the element that starts at `at`: "<x .../>" or
 * "<x ...>...</x>". -1 when it does not end. */
static long usos_it_element_end(const char *text, DWORD len, long at, const char *close) {
    long gt = usos_it_find(text, len, (DWORD)at, ">");
    if (gt < 0) return -1;
    if (gt > at && text[gt - 1] == '/') return gt + 1;
    long end = usos_it_find(text, len, (DWORD)gt, close);
    return end < 0 ? -1 : end + (long)usos_it_len(close);
}

typedef struct { char *out; DWORD len, cap; BOOL full; } UsosItOut;
static void usos_it_put(UsosItOut *o, const char *p, DWORD n) {
    if (o->full || o->len + n > o->cap) { o->full = TRUE; return; }
    memcpy(o->out + o->len, p, n); o->len += n;
}
static void usos_it_puts(UsosItOut *o, const char *p) { usos_it_put(o, p, usos_it_len(p)); }
static void usos_it_number(UsosItOut *o, DWORD v) {
    char d[12]; int n = 0;
    do { d[n++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (n) { char c = d[--n]; usos_it_put(o, &c, 1); }
}
static void usos_it_install_to(UsosItOut *o, DWORD disk, DWORD partition) {
    usos_it_puts(o, "<InstallTo><DiskID>"); usos_it_number(o, disk);
    usos_it_puts(o, "</DiskID><PartitionID>"); usos_it_number(o, partition); usos_it_puts(o, "</PartitionID></InstallTo>");
}

/* Step 1: copy without the disk settings. Returns the number removed. */
static DWORD usos_it_strip(const char *in, DWORD len, UsosItOut *o) {
    static const char *const opens[] = {"<DiskConfiguration", "<InstallToAvailablePartition", "<InstallTo"};
    static const char *const closes[] = {"</DiskConfiguration>", "</InstallToAvailablePartition>", "</InstallTo>"};
    DWORD at = 0, removed = 0;
    for (;;) {
        long best = -1, best_end = -1;
        for (int k = 0; k < 3; k++) {
            long s = usos_it_element(in, len, at, opens[k]);
            if (s >= 0 && (best < 0 || s < best)) { long e = usos_it_element_end(in, len, s, closes[k]); if (e < 0) return 0xffffffff; best = s; best_end = e; }
        }
        if (best < 0) break;
        usos_it_put(o, in + at, (DWORD)best - at);
        at = (DWORD)best_end; removed++;
    }
    usos_it_put(o, in + at, len - at);
    return removed;
}

/* Architecture: Setup reads only the components of its own architecture. An
 * answer written for the other one (e.g. an amd64-only generator file used
 * with 32-bit media) would leave Setup with no ImageInstall and no product
 * key ("cannot read the <ProductKey> setting"). When the answer has no
 * component for `arch` but has some for the other architecture (x86 <->
 * amd64), those are retargeted to `arch`. Returns 1 when converted. */
static int usos_it_arch(const char *in, DWORD len, const char *arch, UsosItOut *o) {
    static const char pa[] = "processorArchitecture=\"";
    const char *other = usos_it_at(arch, 3, "x86") ? "amd64" : (usos_it_at(arch, 5, "amd64") ? "x86" : 0);
    char want[40], from[40]; DWORD wl = 0, fl = 0;
    for (const char *p = pa; *p; p++) { want[wl++] = *p; from[fl++] = *p; }
    for (const char *p = arch; *p && wl < 38; p++) want[wl++] = *p;
    want[wl++] = '"'; want[wl] = 0;
    if (other) { for (const char *p = other; *p; p++) from[fl++] = *p; }
    from[fl++] = '"'; from[fl] = 0;
    if (!other || usos_it_find(in, len, 0, want) >= 0 || usos_it_find(in, len, 0, from) < 0) { usos_it_put(o, in, len); return 0; }
    DWORD at = 0;
    for (long f = usos_it_find(in, len, 0, from); f >= 0; f = usos_it_find(in, len, at, from)) {
        usos_it_put(o, in + at, (DWORD)f - at); usos_it_puts(o, want); at = (DWORD)f + fl;
    }
    usos_it_put(o, in + at, len - at);
    return 1;
}

/* Product key of the Microsoft-Windows-Setup component for `arch`
 * (UserData/ProductKey; the Shell-Setup <ProductKey> string is not touched):
 *   - an empty <Key> is never passed on: Vista / 7 / 2008 Setup rejects it
 *     ("invalid product key"), 8.x / 10 Setup cannot validate it;
 *   - modern (Setup 6.2+, i.e. 8.x / 10): with /unattend and no key this Setup
 *     stops with "cannot read the <ProductKey> setting" (multi-edition media
 *     without ei.cfg). Missing or empty -> the all-zero key with
 *     WillShowUI=Always: Setup shows its own key / edition page, exactly as
 *     without an answer file;
 *   - Vista / 7 / 2008: an empty key is removed (Setup asks later).
 * Returns 1 when the key was added or replaced, 2 when removed, 0 otherwise. */
static const char usos_it_interactive_key[] =
    "<ProductKey><Key>00000-00000-00000-00000-00000</Key><WillShowUI>Always</WillShowUI></ProductKey>";
static BOOL usos_it_blank(const char *p, DWORD n) {
    for (DWORD i = 0; i < n; i++) if (p[i] != ' ' && p[i] != '\t' && p[i] != '\r' && p[i] != '\n') return FALSE;
    return TRUE;
}
static int usos_it_key(const char *t, DWORD n, const char *arch, int modern, UsosItOut *o) {
    static const char setup_name[] = "\"Microsoft-Windows-Setup\"";
    char want[40]; DWORD wl = 0;
    for (const char *p = "processorArchitecture=\""; *p; p++) want[wl++] = *p;
    for (const char *p = arch; *p && wl < 38; p++) want[wl++] = *p;
    want[wl++] = '"'; want[wl] = 0;
    for (long name = usos_it_find(t, n, 0, setup_name); name >= 0; name = usos_it_find(t, n, (DWORD)name + 1, setup_name)) {
        long open = name; while (open > 0 && t[open] != '<') open--;
        if (!usos_it_at(t + open, n - (DWORD)open, "<component")) continue;
        long open_end = usos_it_find(t, n, (DWORD)name, ">");
        if (open_end < 0 || t[open_end - 1] == '/') continue;
        long a = usos_it_find(t, (DWORD)open_end, (DWORD)open, want);
        if (a < 0) continue;
        long close = usos_it_find(t, n, (DWORD)open_end, "</component>");
        if (close < 0) break;
        long pk = usos_it_element(t, (DWORD)close, (DWORD)open_end, "<ProductKey");
        if (pk >= 0) {
            long pk_end = usos_it_element_end(t, (DWORD)close, pk, "</ProductKey>");
            if (pk_end < 0) break;
            long key = usos_it_element(t, (DWORD)pk_end, (DWORD)pk + 11, "<Key");
            BOOL empty = TRUE;
            if (key >= 0) {
                long gt = usos_it_find(t, (DWORD)pk_end, (DWORD)key, ">");
                if (gt > 0 && t[gt - 1] != '/') {
                    long kc = usos_it_find(t, (DWORD)pk_end, (DWORD)gt, "</Key>");
                    empty = kc < 0 || usos_it_blank(t + gt + 1, (DWORD)(kc - gt - 1));
                }
            }
            if (!empty) break;
            usos_it_put(o, t, (DWORD)pk);
            if (modern) usos_it_puts(o, usos_it_interactive_key);
            usos_it_put(o, t + pk_end, n - (DWORD)pk_end);
            return modern ? 1 : 2;
        }
        if (!modern) break;
        long ud = usos_it_element(t, (DWORD)close, (DWORD)open_end, "<UserData");
        long gt = ud >= 0 ? usos_it_find(t, (DWORD)close, (DWORD)ud, ">") : -1;
        if (gt > 0 && t[gt - 1] != '/') {
            usos_it_put(o, t, (DWORD)gt + 1); usos_it_puts(o, usos_it_interactive_key);
            usos_it_put(o, t + gt + 1, n - (DWORD)gt - 1);
        } else if (ud < 0) {
            usos_it_put(o, t, (DWORD)open_end + 1); usos_it_puts(o, "<UserData>"); usos_it_puts(o, usos_it_interactive_key);
            usos_it_puts(o, "</UserData>"); usos_it_put(o, t + open_end + 1, n - (DWORD)open_end - 1);
        } else break; /* self-closing UserData: not edited blindly */
        return 1;
    }
    usos_it_put(o, t, n);
    return 0;
}

/* `modern`: Setup is 6.2+ (Windows 8.x / 10), see usos_it_key. */
static DWORD usos_installto_answer(const char *in, DWORD in_len, char *scratch, DWORD scratch_cap, char *out, DWORD cap,
                                   DWORD disk, DWORD partition, const char *arch, int modern, const char **note) {
    static const char setup_name[] = "\"Microsoft-Windows-Setup\"";
    static const char *const notes[2][3][2] = {
        {{"the answer's own disk settings removed; InstallTo added to Microsoft-Windows-Setup", "InstallTo added to Microsoft-Windows-Setup"},
         {"the answer's own disk settings removed; InstallTo added; no product key -> Setup's own key/edition page", "InstallTo added; no product key -> Setup's own key/edition page"},
         {"the answer's own disk settings removed; InstallTo added; empty product key removed", "InstallTo added; empty product key removed"}},
        {{"components retargeted to this Setup's architecture; disk settings removed; InstallTo added", "components retargeted to this Setup's architecture; InstallTo added"},
         {"components retargeted to this Setup's architecture; disk settings removed; InstallTo added; no product key -> Setup's own key/edition page", "components retargeted to this Setup's architecture; InstallTo added; no product key -> Setup's own key/edition page"},
         {"components retargeted to this Setup's architecture; disk settings removed; InstallTo added; empty product key removed", "components retargeted to this Setup's architecture; InstallTo added; empty product key removed"}}};
    UsosItOut s = {scratch, 0, scratch_cap, FALSE}, o = {out, 0, cap, FALSE};
    *note = "";
    if (!in || !in_len) {
        usos_it_puts(&o, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"><settings pass=\"windowsPE\">");
        usos_it_puts(&o, "<component name=\"Microsoft-Windows-Setup\" processorArchitecture=\""); usos_it_puts(&o, arch);
        usos_it_puts(&o, "\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\"><ImageInstall><OSImage>");
        usos_it_install_to(&o, disk, partition);
        usos_it_puts(&o, "<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>");
        if (modern) { usos_it_puts(&o, "<UserData>"); usos_it_puts(&o, usos_it_interactive_key); usos_it_puts(&o, "</UserData>"); }
        usos_it_puts(&o, "</component></settings></unattend>\r\n");
        *note = modern ? "no answer supplied; InstallTo + Setup's own key/edition page" : "no answer supplied; InstallTo only";
        return o.full ? 0 : o.len;
    }
    /* in -> out (architecture) -> scratch (product key) -> out (disk
     * settings removed) -> scratch, then the InstallTo edit below writes out. */
    int retargeted = usos_it_arch(in, in_len, arch, &o);
    if (o.full) return 0;
    int keyed = usos_it_key(out, o.len, arch, modern, &s);
    if (s.full) return 0;
    o.len = 0;
    DWORD removed = usos_it_strip(scratch, s.len, &o);
    if (removed == 0xffffffff || o.full || o.len > scratch_cap) return 0;
    memcpy(scratch, out, o.len); s.len = o.len; o.len = 0;
    const char *t = scratch; DWORD n = s.len, at = 0, components = 0;
    if (usos_it_find(t, n, 0, "<unattend") < 0) return 0;
    /* Step 2: each Microsoft-Windows-Setup component. */
    for (long name = usos_it_find(t, n, 0, setup_name); name >= 0; name = usos_it_find(t, n, (DWORD)name + 1, setup_name)) {
        long open = name; while (open > 0 && t[open] != '<') open--;
        if (!usos_it_at(t + open, n - (DWORD)open, "<component")) continue;
        long open_end = usos_it_find(t, n, (DWORD)name, ">");
        if (open_end < 0 || t[open_end - 1] == '/') continue;
        long close = usos_it_find(t, n, (DWORD)open_end, "</component>");
        if (close < 0) return 0;
        long os = usos_it_element(t, (DWORD)close, (DWORD)open_end, "<OSImage");
        long image = usos_it_element(t, (DWORD)close, (DWORD)open_end, "<ImageInstall");
        long gt;
        if (os >= 0 && (gt = usos_it_find(t, (DWORD)close, (DWORD)os, ">")) >= 0 && t[gt - 1] != '/') {
            usos_it_put(&o, t + at, (DWORD)gt + 1 - at); usos_it_install_to(&o, disk, partition);
        } else if (image >= 0 && os < 0 && (gt = usos_it_find(t, (DWORD)close, (DWORD)image, ">")) >= 0 && t[gt - 1] != '/') {
            usos_it_put(&o, t + at, (DWORD)gt + 1 - at); usos_it_puts(&o, "<OSImage>"); usos_it_install_to(&o, disk, partition);
            usos_it_puts(&o, "<WillShowUI>OnError</WillShowUI></OSImage>");
        } else if (os < 0 && image < 0) {
            gt = open_end;
            usos_it_put(&o, t + at, (DWORD)gt + 1 - at); usos_it_puts(&o, "<ImageInstall><OSImage>"); usos_it_install_to(&o, disk, partition);
            usos_it_puts(&o, "<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>");
        } else return 0; /* self-closing OSImage/ImageInstall: not edited blindly */
        at = (DWORD)gt + 1; components++;
    }
    if (components) {
        usos_it_put(&o, t + at, n - at);
        *note = notes[retargeted][keyed][removed ? 0 : 1];
        return o.full ? 0 : o.len;
    }
    /* Step 3: no Setup component. */
    long pe = usos_it_find(t, n, 0, "<settings pass=\"windowsPE\">");
    if (pe >= 0) {
        DWORD after = (DWORD)pe + 27;
        usos_it_put(&o, t, after);
    } else {
        long end = usos_it_find(t, n, 0, "</unattend>");
        if (end < 0) return 0;
        usos_it_put(&o, t, (DWORD)end); usos_it_puts(&o, "<settings pass=\"windowsPE\">");
        at = (DWORD)end;
    }
    usos_it_puts(&o, "<component name=\"Microsoft-Windows-Setup\" processorArchitecture=\""); usos_it_puts(&o, arch);
    usos_it_puts(&o, "\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\"><ImageInstall><OSImage>");
    usos_it_install_to(&o, disk, partition);
    usos_it_puts(&o, "<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>");
    if (modern) { usos_it_puts(&o, "<UserData>"); usos_it_puts(&o, usos_it_interactive_key); usos_it_puts(&o, "</UserData>"); }
    usos_it_puts(&o, "</component>");
    if (pe >= 0) usos_it_put(&o, t + pe + 27, n - (DWORD)pe - 27);
    else { usos_it_puts(&o, "</settings>"); usos_it_put(&o, t + at, n - at); }
    *note = pe >= 0 ? (modern ? "Microsoft-Windows-Setup with InstallTo + Setup's own key/edition page added to windowsPE" : "Microsoft-Windows-Setup with InstallTo added to windowsPE")
                    : (modern ? "windowsPE settings with InstallTo + Setup's own key/edition page added" : "windowsPE settings with InstallTo added");
    return o.full ? 0 : o.len;
}

/* A UTF-16LE answer (BOM FF FE) as UTF-8, with the XML declaration's
 * encoding="utf-16" changed to utf-8. Returns the length or 0. */
static DWORD usos_it_utf16_to_utf8(const BYTE *in, DWORD in_len, char *out, DWORD cap) {
    if (in_len < 4 || in[0] != 0xff || in[1] != 0xfe || (in_len & 1)) return 0;
    int n = WideCharToMultiByte(CP_UTF8, 0, (const WCHAR *)(in + 2), (int)((in_len - 2) / 2), out, (int)cap, 0, 0);
    if (n <= 0) return 0;
    DWORD len = (DWORD)n;
    long decl = usos_it_find(out, len, 0, "?>");
    for (DWORD i = 0; decl > 0 && i + 6 <= (DWORD)decl; i++) {
        if ((out[i] | 32) == 'u' && (out[i + 1] | 32) == 't' && (out[i + 2] | 32) == 'f' && out[i + 3] == '-' && out[i + 4] == '1' && out[i + 5] == '6') {
            out[i + 4] = '8';
            for (DWORD j = i + 5; j + 1 < len; j++) out[j] = out[j + 1];
            len--;
            break;
        }
    }
    return len;
}
#endif
