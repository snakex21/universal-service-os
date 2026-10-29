/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright (C) 2026 USOS Authors
 * Reuse USOS's own BOOT.INI/USB/pagefile routines, not its NT3 service.
 * Native NT4 only. CMDLINES /early, POST.CMD /finish. No host execution.
 */
#define DIR "C:\\USOS\\NT4\\"
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static int boot_valid(void);
static BOOL WINAPI finish_delete(LPCSTR path);
static HANDLE WINAPI finish_create(LPCSTR,DWORD,DWORD,LPSECURITY_ATTRIBUTES,DWORD,DWORD,HANDLE);
static BOOL WINAPI finish_flush(HANDLE);
static HANDLE g_BootWrite=INVALID_HANDLE_VALUE;
static int g_BootFlushed;
#define DeleteFileA finish_delete
#define CreateFileA finish_create
#define FlushFileBuffers finish_flush
#define entry unused_nt3_entry
#include "../../nt3/usosnt3/src/usosnt3.c"
#undef entry
#undef DeleteFileA
#undef CreateFileA
#undef FlushFileBuffers

static HANDLE WINAPI finish_create(LPCSTR path,DWORD access,DWORD sharing,LPSECURITY_ATTRIBUTES security,DWORD mode,DWORD attrs,HANDLE template_file)
{
    HANDLE h=CreateFileA(path,access,sharing,security,mode,attrs,template_file);
    if(!lstrcmpiA(path,"C:\\BOOT.INI") && (access&GENERIC_WRITE)){
        g_BootWrite=h;g_BootFlushed=0;
    }
    return h;
}

static BOOL WINAPI finish_flush(HANDLE h)
{
    BOOL ok=FlushFileBuffers(h);
    if(h==g_BootWrite)g_BootFlushed=ok;
    return ok;
}

/* The VGA entry is matched by its /basevideo switch, not by its text:
   boot_ini_finish keeps the CD's own entry, whose description is
   localized ("[tryb VGA]" on the Polish CD; X470 2026-10-29 the
   "[vga mode]" test failed there, POST.CMD gave up before its restart). */
static int boot_valid(void)
{
    static char text[8192];
    int n = read_small("C:\\BOOT.INI", text, sizeof(text));
    return n>0 && has_ci(text,n,"timeout=5") && has_ci(text,n,"[usos /sos]") &&
        has_ci(text,n,"/basevideo") && !has_ci(text,n,"c:\\=");
}

static BOOL WINAPI finish_delete(LPCSTR path)
{
    /* BOOT.INI must be durable and valid before the reused routine removes
     * its fixed syslinux/Setup leftovers. No source deletion on write error. */
    return g_BootFlushed && boot_valid() ? DeleteFileA(path) : FALSE;
}

static void finish_boot(void)
{
    HANDLE h;
    /* A previous process may already have finished BOOT.INI and stopped
     * during cleanup. Revalidate and flush that existing file before retry.
     * Do not depend on a flag left by an earlier invocation in this process. */
    if (boot_valid()) {
        h=finish_create("C:\\BOOT.INI",GENERIC_READ|GENERIC_WRITE,0,NULL,OPEN_EXISTING,FILE_ATTRIBUTE_NORMAL,NULL);
        if(h!=INVALID_HANDLE_VALUE){finish_flush(h);CloseHandle(h);}
    }
    boot_ini_finish();
}

/* A/B fallback (round 2026-10-29): one more BOOT.INI entry, the default
 * entry's ARC path and options with /NUMPROC=1 and " [1 CPU]" in its
 * description, right after the default line. The default stays the
 * MPS multiprocessor pair with /NUMPROC=2. Idempotent; written and
 * flushed through finish_create / finish_flush like boot_ini_finish. */
static int boot_one_cpu(void)
{
    static char in[8192], out[9000], line[700];
    int n, i = 0, o = 0, done = 0, l, k, q;
    DWORD attr, w;
    HANDLE h;
    BOOL ok;
    n = read_small("C:\\BOOT.INI", in, sizeof in);
    if (n <= 0) return 0;
    if (has_ci(in, n, "[1 cpu]")) { say("boot.ini: 1 CPU entry already there\r\n"); return 1; }
    while (i < n) {
        int s = i;
        while (i < n && in[i] != '\n') i++;
        if (i < n) i++;
        out_add(out, &o, sizeof out, in + s, i - s);
        if (done) continue;
        l = 0;
        for (k = s; k < i && in[k] != '\r' && in[k] != '\n' && l < (int)sizeof line - 40; k++) line[l++] = in[k];
        if (l < 6 || !has_ci(line, 6, "multi(") || has_ci(line, l, "/sos") || has_ci(line, l, "/basevideo")) continue;
        for (k = 0; k + 1 < l && !(line[k] == '=' && line[k + 1] == '"'); k++) ;
        for (q = k + 2; q < l && line[q] != '"'; q++) ;
        if (k + 1 >= l || q >= l) continue;
        if (in[i - 1] != '\n') out_add(out, &o, sizeof out, "\r\n", 2);
        out_add(out, &o, sizeof out, line, q);
        out_add(out, &o, sizeof out, " [1 CPU]", 8);
        for (k = q; k < l; k++) {
            if (k + 9 < l && has_ci(line + k, 9, "/numproc=")) {
                out_add(out, &o, sizeof out, "/NUMPROC=1", 10);
                for (k += 9; k < l && line[k] >= '0' && line[k] <= '9'; k++) ;
                k--;
            } else {
                out_add(out, &o, sizeof out, line + k, 1);
            }
        }
        if (!has_ci(line, l, "/numproc=")) out_add(out, &o, sizeof out, " /NUMPROC=1", 11);
        out_add(out, &o, sizeof out, "\r\n", 2);
        done = 1;
    }
    if (!done) { say("boot.ini: no default entry for the 1 CPU line\r\n"); return 0; }
    attr = GetFileAttributesA("C:\\BOOT.INI");
    SetFileAttributesA("C:\\BOOT.INI", FILE_ATTRIBUTE_NORMAL);
    h = finish_create("C:\\BOOT.INI", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    ok = h != INVALID_HANDLE_VALUE && WriteFile(h, out, (DWORD)o, &w, NULL) && w == (DWORD)o && finish_flush(h);
    if (h != INVALID_HANDLE_VALUE) CloseHandle(h);
    if (attr != 0xFFFFFFFF) SetFileAttributesA("C:\\BOOT.INI", attr);
    say(ok ? "boot.ini: 1 CPU entry (/NUMPROC=1) added\r\n" : "boot.ini: 1 CPU entry WRITE FAILED\r\n");
    return ok;
}

/* usosrst (bin/nt4n: shutdown log, quiesce, CF9h full reset) from the first
 * installed-system boot on, so POST.CMD's single restart already goes
 * through it; POST.CMD's DRIVERS.REG writes the same values again. */
static int rst_early(void)
{
    char system[MAX_PATH];
    if (!GetSystemDirectoryA(system, sizeof(system))) return 0;
    lstrcatA(system, "\\drivers\\usosrst.sys");
    if (!CopyFileA(DIR "USOSRST.SYS", system, FALSE)) return 0;
    set_dword("usosrst", NULL, "Type", 1);
    set_dword("usosrst", NULL, "Start", 0);
    set_dword("usosrst", NULL, "ErrorControl", 0);
    set_sz("usosrst", "Group", REG_SZ, "System Bus Extender");
    set_dword("usosrst", "Parameters", "HpetLegacyOff", 1);
    set_dword("usosrst", "Parameters", "RtcFix", 1);
    return 1;
}

/* POST.CMD gave up (no restart follows): close the finishing screen. */
static void notice_close(void)
{
    typedef HWND (WINAPI *FIND_WINDOW)(LPCSTR, LPCSTR);
    typedef BOOL (WINAPI *POST_MESSAGE)(HWND, UINT, WPARAM, LPARAM);
    HMODULE user32 = LoadLibraryA("user32.dll");
    FIND_WINDOW find = user32 ? (FIND_WINDOW)GetProcAddress(user32, "FindWindowA") : NULL;
    POST_MESSAGE post = user32 ? (POST_MESSAGE)GetProcAddress(user32, "PostMessageA") : NULL;
    HWND w = find ? find("UsosNt3Notice", NULL) : NULL;
    if (w && post) post(w, WM_ENDSESSION, 1, 0);
}

/* usosnetc (USOSNT4.EXE /netcheck): the one-shot NETCHECK.TXT record of the
 * first boot with usosnet4 on NDISLoop1, registered only after the
 * POST.CMD takeover put usosnet4.sys in place. */
static void netcheck_register(void)
{
    char system[MAX_PATH];
    HKEY h;
    if (!GetSystemDirectoryA(system, sizeof(system))) return;
    lstrcatA(system, "\\drivers\\usosnet4.sys");
    if (GetFileAttributesA(system) == INVALID_FILE_ATTRIBUTES ||
        RegOpenKeyExA(HKEY_LOCAL_MACHINE, SVC_KEY "NDISLoop1", 0, KEY_READ, &h) != ERROR_SUCCESS) {
        say("netcheck: no usosnet4 takeover, not registered\r\n");
        return;
    }
    RegCloseKey(h);
    set_sz("usosnetc", "ImagePath", REG_EXPAND_SZ, DIR "USOSNT4.EXE /netcheck");
    set_sz("usosnetc", "ObjectName", REG_SZ, "LocalSystem");
    set_sz("usosnetc", "DisplayName", REG_SZ, "USOS network check");
    set_dword("usosnetc", NULL, "Type", SERVICE_WIN32_OWN_PROCESS);
    set_dword("usosnetc", NULL, "ErrorControl", SERVICE_ERROR_IGNORE);
    set_dword("usosnetc", NULL, "Start", SERVICE_AUTO_START);
    say("netcheck: usosnetc registered (NETCHECK.TXT after the next boot)\r\n");
}

static int service_value(const char *service,const char *part,const char *name,DWORD wanted)
{
    char path[MAX_PATH];HKEY key;DWORD value,type,size=sizeof(value);LONG rc;
    lstrcpyA(path,SVC_KEY);lstrcatA(path,service);
    if(part){lstrcatA(path,"\\");lstrcatA(path,part);}
    if(RegOpenKeyExA(HKEY_LOCAL_MACHINE,path,0,KEY_READ,&key)!=ERROR_SUCCESS)return 0;
    rc=RegQueryValueExA(key,name,NULL,&type,(BYTE *)&value,&size);RegCloseKey(key);
    return rc==ERROR_SUCCESS && type==REG_DWORD && size==sizeof(value) && value==wanted;
}

static int usb_ready(void)
{
    char system[MAX_PATH];
    if(!GetSystemDirectoryA(system,sizeof system))return 0;
    lstrcatA(system,"\\drivers\\usosusb.sys");
    return GetFileAttributesA(system)!=INVALID_FILE_ATTRIBUTES &&
        service_value("usosusb",NULL,"Type",1) && service_value("usosusb",NULL,"Start",1) &&
        service_value("Kbdclass","Parameters","ConnectMultiplePorts",1) &&
        service_value("Mouclass","Parameters","ConnectMultiplePorts",1);
}

static int erase_tree(const char *path, int depth)
{
    WIN32_FIND_DATAA fd;
    HANDLE find;
    char pattern[MAX_PATH], child[MAX_PATH];
    int ok = 1;
    if (depth > 24 || len(path) > MAX_PATH - 4) return 0;
    if (GetFileAttributesA(path) == INVALID_FILE_ATTRIBUTES) {
        DWORD error=GetLastError();return error==ERROR_FILE_NOT_FOUND || error==ERROR_PATH_NOT_FOUND;
    }
    if (GetFileAttributesA(path) & 0x400) return 0; /* never traverse a reparse point */
    lstrcpyA(pattern, path); lstrcatA(pattern, "\\*");
    find = FindFirstFileA(pattern, &fd);
    if (find == INVALID_HANDLE_VALUE) return 0;
    do {
        if (!lstrcmpA(fd.cFileName, ".") || !lstrcmpA(fd.cFileName, "..")) continue;
        if (len(path) + len(fd.cFileName) + 2 >= MAX_PATH || fd.dwFileAttributes & 0x400) { ok = 0; break; }
        lstrcpyA(child, path); lstrcatA(child, "\\"); lstrcatA(child, fd.cFileName);
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!erase_tree(child, depth + 1)) ok = 0;
        } else {
            SetFileAttributesA(child, FILE_ATTRIBUTE_NORMAL);
            if (!DeleteFileA(child)) ok = 0;
        }
    } while (FindNextFileA(find, &fd));
    if (GetLastError() != ERROR_NO_MORE_FILES) ok = 0;
    FindClose(find);
    return ok && RemoveDirectoryA(path);
}

/* USOSNT4.EXE /logon (HKLM Run "USOSAutoLogon", from the native DONE.REG):
 * automatic logon only while the installation still restarts by itself
 * (user decision 2026-10-29). NT 4.0 msgina takes an empty DefaultPassword
 * as a one-shot logon and writes AutoAdminLogon=0 at that logon, so while
 * the add-on chain is pending (its Run value "USOSAddons" exists) this
 * re-arms AutoAdminLogon=1 for the next restart. When the chain has ended
 * (the value is gone, now or while this waits) the installation is over:
 * AutoAdminLogon=0, DefaultPassword and this Run value are removed, and the
 * next start shows the normal Ctrl+Alt+Del logon. Windows subsystem: no
 * console window. LOGON.LOG gets one line per step. */
#define WINLOGON_KEY "SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Winlogon"
#define RUN_KEY "SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run"
static int run_value(const char *name)
{
    HKEY h; LONG rc;
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUN_KEY, 0, KEY_READ, &h) != ERROR_SUCCESS) return 0;
    rc = RegQueryValueExA(h, name, NULL, NULL, NULL, NULL);
    RegCloseKey(h);
    return rc == ERROR_SUCCESS;
}

static void logon_main(void)
{
    HKEY h;
    int waited;
    open_log("LOGON.LOG");
    if (run_value("USOSAddons")) {
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, WINLOGON_KEY, 0, KEY_WRITE, &h) == ERROR_SUCCESS) {
            RegSetValueExA(h, "AutoAdminLogon", 0, REG_SZ, (const BYTE *)"1", 2);
            RegSetValueExA(h, "DefaultPassword", 0, REG_SZ, (const BYTE *)"", 1);
            RegFlushKey(h);
            RegCloseKey(h);
        }
        say("logon: add-on chain pending, automatic logon re-armed for its restart\r\n");
        /* The chain ends in this session when USOSADD removes its Run value;
           a restart ends this process first (the re-arm above covers it). */
        for (waited = 0; run_value("USOSAddons"); waited++) {
            if (waited > 6 * 3600 / 2) { say("logon: still pending after 6 h, automatic logon kept\r\n"); ExitProcess(0); }
            Sleep(2000);
        }
    }
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, WINLOGON_KEY, 0, KEY_WRITE, &h) == ERROR_SUCCESS) {
        RegSetValueExA(h, "AutoAdminLogon", 0, REG_SZ, (const BYTE *)"0", 2);
        RegDeleteValueA(h, "DefaultPassword");
        RegFlushKey(h);
        RegCloseKey(h);
    }
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, RUN_KEY, 0, KEY_WRITE, &h) == ERROR_SUCCESS) {
        RegDeleteValueA(h, "USOSAutoLogon");
        RegFlushKey(h);
        RegCloseKey(h);
    }
    say(run_value("USOSAutoLogon") ? "logon: Run value removal FAILED\r\n"
                                   : "logon: installation finished, automatic logon off (AutoAdminLogon=0, no DefaultPassword)\r\n");
    ExitProcess(0);
}

void __stdcall entry(void)
{
    OSVERSIONINFOA os;
    char opt[16];
    int ok, i;
    for (i = 0; i < sizeof(os); i++) ((volatile char *)&os)[i] = 0;
    os.dwOSVersionInfoSize = sizeof(os);
    if (!GetVersionExA(&os) || os.dwPlatformId != VER_PLATFORM_WIN32_NT || os.dwMajorVersion != 4 || os.dwMinorVersion != 0)
        ExitProcess(3);
    if (!native_install()) ExitProcess(3);
    first_option(GetCommandLineA(), opt);
    /* Before NATIVE.LOG: these run beside /finish and must not hold it. */
    if (!lstrcmpA(opt, "notice")) notice_main();     /* POST.CMD: start "" ... /notice */
    if (!lstrcmpA(opt, "nonotice")) { notice_close(); ExitProcess(0); }
    if (!lstrcmpA(opt, "logon")) logon_main();       /* HKLM Run USOSAutoLogon */
    if (!lstrcmpA(opt, "netcheck")) {
        static SERVICE_TABLE_ENTRYA table[] = { { "usosnetc", netcheck_main }, { NULL, NULL } };
        if (!StartServiceCtrlDispatcherA(table)) netcheck();
        ExitProcess(0);
    }
    open_log("NATIVE.LOG");
    if (!lstrcmpA(opt, "early")) {
        usb_early();
        say(rst_early() ? "native NT4: usosrst registered before first installed-system boot\r\n"
                        : "usosrst early copy FAILED (POST.CMD installs it)\r\n");
        {
            char system[MAX_PATH];
            if (!GetSystemDirectoryA(system, sizeof(system))) ExitProcess(3);
            lstrcatA(system, "\\drivers\\usosusb.sys");
            if (!CopyFileA(DIR "USOSUSB.SYS", system, FALSE)) ExitProcess(3);
        }
        ok=usb_ready();
        say(ok ? "native NT4: USB registered before first installed-system boot\r\n" : "USB readback FAILED\r\n");
        ExitProcess(ok ? 0 : 3);
    }
    if (lstrcmpA(opt, "finish")) ExitProcess(3);
    /* Do not remove the source until POST.CMD has completed its copies/SP. */
    if (GetFileAttributesA(DIR "POST.OK") == INVALID_FILE_ATTRIBUTES) ExitProcess(3);
    if(!usb_ready()){say("USB readback FAILED; no cleanup/restart\r\n");ExitProcess(3);}
    if (!CopyFileA("C:\\BOOT.INI", DIR "BOOT.OLD", TRUE) && GetLastError() != ERROR_FILE_EXISTS) ExitProcess(3);
    pagefile_cap();
    finish_boot();
    if (!g_BootFlushed || !boot_valid()) { say("BOOT.INI validation FAILED; source retained\r\n"); ExitProcess(3); }
    if (!boot_one_cpu() || !g_BootFlushed || !boot_valid()) { say("BOOT.INI 1 CPU entry FAILED; source retained\r\n"); ExitProcess(3); }
    netcheck_register();
    ok = erase_tree("C:\\$WIN_NT$.~BT", 0);
    if (!erase_tree("C:\\$WIN_NT$.~LS", 0)) ok = 0;
    say(ok ? "native finish complete\r\n" : "native finish cleanup FAILED\r\n");
    if (g_log != INVALID_HANDLE_VALUE) { FlushFileBuffers(g_log); CloseHandle(g_log); }
    ExitProcess(ok ? 0 : 3);
}
