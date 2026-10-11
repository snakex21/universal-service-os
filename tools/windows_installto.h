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

static DWORD usos_installto_answer(const char *in, DWORD in_len, char *scratch, DWORD scratch_cap, char *out, DWORD cap,
                                   DWORD disk, DWORD partition, const char *arch, const char **note) {
    static const char setup_name[] = "\"Microsoft-Windows-Setup\"";
    UsosItOut s = {scratch, 0, scratch_cap, FALSE}, o = {out, 0, cap, FALSE};
    *note = "";
    if (!in || !in_len) {
        usos_it_puts(&o, "<?xml version=\"1.0\" encoding=\"utf-8\"?>\r\n<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"><settings pass=\"windowsPE\">");
        usos_it_puts(&o, "<component name=\"Microsoft-Windows-Setup\" processorArchitecture=\""); usos_it_puts(&o, arch);
        usos_it_puts(&o, "\" publicKeyToken=\"31bf3856ad364e35\" language=\"neutral\" versionScope=\"nonSxS\"><ImageInstall><OSImage>");
        usos_it_install_to(&o, disk, partition);
        usos_it_puts(&o, "<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall></component></settings></unattend>\r\n");
        *note = "no answer supplied; InstallTo only";
        return o.full ? 0 : o.len;
    }
    DWORD removed = usos_it_strip(in, in_len, &s);
    if (removed == 0xffffffff || s.full) return 0;
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
        *note = removed ? "the answer's own disk settings removed; InstallTo added to Microsoft-Windows-Setup" : "InstallTo added to Microsoft-Windows-Setup";
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
    usos_it_puts(&o, "<WillShowUI>OnError</WillShowUI></OSImage></ImageInstall></component>");
    if (pe >= 0) usos_it_put(&o, t + pe + 27, n - (DWORD)pe - 27);
    else { usos_it_puts(&o, "</settings>"); usos_it_put(&o, t + at, n - at); }
    *note = pe >= 0 ? "Microsoft-Windows-Setup with InstallTo added to windowsPE" : "windowsPE settings with InstallTo added";
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
