/*
 * USOSLOG.EXE - silent diagnostics logger for Windows 98 / 98 SE / Me test
 * installs (X470 under CSMWrap). Win32, no visible window (a hidden one
 * for the end of the Windows session), no C runtime.
 * Copyright (C) 2026 Maksymilian and the USOS Authors. GPL-3.0-or-later.
 *
 * Started from the Startup folder (one instance: a named mutex). It writes
 * a short start record at once, a full snapshot about 3 minutes after the
 * start and then every 5 minutes, appended to LOGS\USOSLOG.TXT beside EXE
 * (over 256 KiB: renamed to USOSLOG.OLD, one generation kept). Each write
 * is flushed and the file closed, so a normal shutdown loses nothing.
 *
 * A full snapshot:
 *   SYS    Windows version, memory, uptime
 *   MOUSE  system metrics (mouse / wheel present, buttons, wheel lines),
 *          the input this logger saw through a journal record hook (wheel
 *          messages, moves, clicks: proves whether WM_MOUSEWHEEL reaches
 *          USER; journal records carry no wheel delta, so no direction is
 *          claimed: USOSDBG's WHEEL USOSKEY lines have the real delta and
 *          what USOSKEY.DRV did with it), per WM_MOUSEWHEEL the focus
 *          window, the window under the pointer and the foreground window
 *          (class, WS_VSCROLL), SYSTEM.INI
 *          mouse lines, and USOSDBG.EXE /L (log mode of
 *          the Win16 diagnostics: USOSKEY / USOSMOUS / SeaBIOS USOSMWHL
 *          record, packets, descriptor, PCI once)
 *   NET    the usosnet adapter's registry values (Class\Net\00nn), its live
 *          statistics page (usosnet 0.4: per protocol RX / TX, drops,
 *          TransferData, last frames, last DNS frames; through
 *          UsosnetStatsVa, else USOSDBG's physical dump of UsosnetStatsPa),
 *          MSTCP / NetTrans / DHCP / Internet Settings registry, HOSTS,
 *          IPHLPAPI (DNS servers as the resolver sees them, adapters, IP /
 *          UDP / TCP / ICMP statistics before and after the tests), then the
 *          active tests: gethostbyname, raw UDP DNS queries (1.1.1.1,
 *          8.8.8.8, the gateway, the configured servers), a DNS query over
 *          TCP, TCP connect to the gateway port 80, HTTP GET frogfind.com
 *          (by the resolved address or the one embedded below), and a UDP
 *          broadcast that asks usosnet 0.4 for one NDIS log round; the new
 *          part of C:\WINDOWS\NDISLOG.TXT
 *   PROC   processes (Toolhelp32), visible top-level windows, and what the
 *          watcher saw since the last snapshot (processes every 250 ms,
 *          diffed by PID; windows on a change, else every second): processes
 *          started / ended with PID, parent PID and exe, windows shown /
 *          gone with class, title, PID and exe (a console flashing up is a
 *          "tty" window, "ConsoleWindowClass" on NT), each line with wall
 *          time and t+seconds.ms since the logger started; at most 1000
 *          event lines per session, then a counter
 *   START  Startup folders, Run keys, WIN.INI load= / run=, SYSTEM.INI
 *          shell=, AUTOEXEC.BAT / CONFIG.SYS (start record and every 6th)
 *   DISK   every drive letter (GetDriveType, file system, label, volume
 *          serial, free space); in the start record also C:\WINDOWS\IOS.LOG
 *          (copied to LOGS, its real mode / MS-DOS compatibility lines),
 *          the IOS / KRNL386 / port driver lines of C:\BOOTLOG.TXT, the
 *          registry (Enum\Root\SCSIAdapter, Enum\SCSI\* drive letter /
 *          Removable / HardwareID, Class\SCSIAdapter PortDriver) and one
 *          USOSDBG /D snapshot (SeaBIOS USB disk service record, channel 1,
 *          USOSUSB.MPD status page). A disk watcher thread diffs
 *          GetLogicalDrives every 250 ms (+drive / -drive) and the volume
 *          serials of removable letters every 2 s (media changed); each
 *          change is written at once as a "disk change" record with one
 *          USOSDBG /D snapshot (at most one per 2 s)
 *
 * Wheel record: a few seconds after the wheel was used (at most one per
 * WHEEL_REC_GAP s, WHEEL_REC_MAX per session) a short record with the MOUSE
 * part, USOSDBG and the WM_MOUSEWHEEL lines, so a wheel test is in the
 * log even when Windows is shut down before the next snapshot.
 *
 * Own files stay in the application directory (normally C:\USOS9X) or the
 * explicitly selected /out file. No profile-directory fallback. Network
 * tests include one bounded ICMP echo to the configured gateway.
 *
 * Options (testing): /once (one full snapshot, then exit), /out <file>,
 * /first <s>, /every <s>, /nonet (no active network tests), /nodbg (no
 * USOSDBG), /nohook (no journal hook), /nodisk (no DISK section, no disk
 * watcher), /dbgfile <file> (decode a saved USOSDBG /L output instead of
 * running USOSDBG: host tests).
 *
 * Compatibility: Windows 95 (OSR2 and later; the 4.00.950 retail too as
 * far as the APIs go), 98, 98 SE, Me; NT 4.0, 2000, XP for reuse. Static
 * imports are the Windows 95 subset of KERNEL32 / USER32 / ADVAPI32 only.
 * Looked up at run time, each part skipped with a log line when missing:
 * WSOCK32.DLL (Winsock 1.1; absent without TCP/IP: no network tests),
 * the drive APIs (GetLogicalDrives, GetDriveTypeA, GetVolumeInformationA,
 * GetDiskFreeSpaceA, SetErrorMode: Windows 95 KERNEL32, looked up so the
 * static list stays the checked one),
 * IPHLPAPI.DLL (98 and later: resolver view and IP / UDP / TCP / ICMP
 * counters; on 95 the registry sections stand in), Toolhelp32 (not on NT
 * 4.0: no process list there). On the NT family USOSDBG (Win16, DPMI,
 * port I/O: 9x only) and the usosnet page through the system arena are
 * skipped, and Services\Tcpip\Parameters is logged instead of MSTCP.
 *
 * Built with tools/build_win9x_support.py --usoslog (OpenWatcom wcc386 /
 * wlink, PE 4.00, no C runtime).
 */
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock.h>
#include <stdarg.h>

/* WSOCK32.DLL at run time (Windows 95 without TCP/IP has none) */
typedef int (PASCAL FAR *PFN_WSASTARTUP)(WORD, LPWSADATA);
typedef int (PASCAL FAR *PFN_INT0)(void);
typedef SOCKET (PASCAL FAR *PFN_SOCKET)(int, int, int);
typedef int (PASCAL FAR *PFN_CLOSE)(SOCKET);
typedef int (PASCAL FAR *PFN_CONNECT)(SOCKET, const struct sockaddr FAR *, int);
typedef struct hostent FAR *(PASCAL FAR *PFN_GHBN)(const char FAR *);
typedef int (PASCAL FAR *PFN_IOCTL)(SOCKET, long, u_long FAR *);
typedef int (PASCAL FAR *PFN_RECV)(SOCKET, char FAR *, int, int);
typedef int (PASCAL FAR *PFN_RECVFROM)(SOCKET, char FAR *, int, int, struct sockaddr FAR *, int FAR *);
typedef int (PASCAL FAR *PFN_SELECT)(int, fd_set FAR *, fd_set FAR *, fd_set FAR *, const struct timeval FAR *);
typedef int (PASCAL FAR *PFN_SEND)(SOCKET, const char FAR *, int, int);
typedef int (PASCAL FAR *PFN_SENDTO)(SOCKET, const char FAR *, int, int, const struct sockaddr FAR *, int);
typedef int (PASCAL FAR *PFN_SETSOCKOPT)(SOCKET, int, int, const char FAR *, int);
static PFN_WSASTARTUP ws_startup;
static PFN_INT0 ws_lasterror;
static PFN_SOCKET ws_socket;
static PFN_CLOSE ws_close;
static PFN_CONNECT ws_connect;
static PFN_GHBN ws_ghbn;
static PFN_IOCTL ws_ioctl;
static PFN_RECV ws_recv;
static PFN_RECVFROM ws_recvfrom;
static PFN_SELECT ws_select;
static PFN_SEND ws_send;
static PFN_SENDTO ws_sendto;
static PFN_SETSOCKOPT ws_setsockopt;
#define WSAStartup ws_startup
#define WSAGetLastError ws_lasterror
#define socket ws_socket
#define closesocket ws_close
#define connect ws_connect
#define gethostbyname ws_ghbn
#define ioctlsocket ws_ioctl
#define recv ws_recv
#define recvfrom ws_recvfrom
#define select ws_select
#define send ws_send
#define sendto ws_sendto
#define setsockopt ws_setsockopt
#define htons(x) ((u_short)((((x) & 0xFF) << 8) | (((x) >> 8) & 0xFF)))
#define ntohs(x) htons(x)
#define inet_addr ip_addr

#ifndef WM_MOUSEWHEEL
#define WM_MOUSEWHEEL 0x020A
#endif
#ifndef WM_CANCELJOURNAL
#define WM_CANCELJOURNAL 0x004B
#endif
#ifndef SM_MOUSEWHEELPRESENT
#define SM_MOUSEWHEELPRESENT 75
#endif
#ifndef SPI_GETWHEELSCROLLLINES
#define SPI_GETWHEELSCROLLLINES 0x0068
#endif

#define VERSION     "1.0"
static char app_dir[MAX_PATH], log_dir[MAX_PATH], log_file[MAX_PATH], dbg_exe[MAX_PATH],
            dbg_tmp[MAX_PATH], dbg_tmp_disk[MAX_PATH];
#define LOGDIR      log_dir
#define DBGEXE      dbg_exe
#define DBGTMP      dbg_tmp
#define ROTATE      (256UL * 1024)
/* frogfind.com A record, resolved 2026-10-18 through 1.1.1.1 and 8.8.8.8 */
#define FALLBACK_IP "64.227.13.248"
#define TEST_HOST   "frogfind.com"
/* control site, plain HTTP too (2026-10-18 from the dev PC: frogfind.com
 * did not answer on port 80 or 443 at all, 68k.news answered 200) */
#define CONTROL_HOST "68k.news"
#define CONTROL_IP  "134.209.213.152"
#define LOG_PORT    21843           /* usosnet 0.4 USNS_LOG_PORT */

/* ------------------------------------------------------------------ */
/* usosnet 0.4 statistics page: same layout as USNS_BLOCK in
 * tools/nt/usosnet/src/usosnet_proto.h (branch feature/usosnet) */
#define USNS_MAGIC  0x534E5355UL
#define USNS_CLASSES 16
#define USNS_DROPS  16
#define USNS_TDS    8
#define USNS_CORES  31
#define USNS_HIST   32
#define USNS_DUMP   128
typedef struct {
    DWORD Magic, Version, Size, Seconds;
    DWORD Rx[USNS_CLASSES];
    DWORD Tx[USNS_CLASSES];
    DWORD Drop[USNS_DROPS];
    DWORD Td[USNS_TDS];
    DWORD Core[USNS_CORES];
    DWORD Seq;
    DWORD Hist[USNS_HIST][6];
    DWORD LastDnsRxLen, LastDnsTxLen;
    BYTE LastDnsRx[USNS_DUMP];
    BYTE LastDnsTx[USNS_DUMP];
} USNS;

static const char *const usns_class[USNS_CLASSES] = {
    "bcast", "mcast", "arp", "ipv4", "icmp", "udp", "tcp", "dns", "dhcp", "http", "frag", "ipv6",
    "other", "short", "ipopt", "netbios" };
static const char *const usns_drop[USNS_DROPS] = {
    "drop:not_eop", "drop:crc", "drop:symbol", "drop:seq", "drop:carrier_ext", "drop:rx_data",
    "drop:length", "drop:no_filter", "note:l4e", "note:ipe", "note:l4e_udp", "note:l4e_dns",
    "note:ipcs", "note:l4cs", "note:udpcs", "note:loopback" };
static const char *const usns_td[USNS_TDS] = {
    "calls", "outside_indication", "short_copy", "bytes", "max_offset", "max_len", "udp", "dns" };
static const char *const usns_core[USNS_CORES] = {
    "isr_calls", "isr_claimed", "dpc", "rx_ok", "rx_by_timer", "tx_ok", "tx_done", "tx_err", "tx_full",
    "rx_err", "rx_crc", "hw_tpr", "hw_gprc", "hw_gptc", "hw_mpc", "hw_rnbc", "hw_crcerrs", "filter",
    "lookahead", "pollmode", "linkflags", "STATUS", "RCTL", "RXCSUM", "RDH", "RDT", "TDH", "TDT",
    "tx_busy", "logs", "log_requests" };

/* ------------------------------------------------------------------ */
/* IPHLPAPI (run-time lookup; layouts of iptypes.h / iprtrmib.h)       */
typedef struct _IPSTRING { char String[16]; } IPSTRING;
typedef struct _IPADDRSTR {
    struct _IPADDRSTR *Next;
    IPSTRING IpAddress, IpMask;
    DWORD Context;
} IPADDRSTR;
typedef struct {
    char HostName[132];
    char DomainName[132];
    IPADDRSTR *CurrentDnsServer;
    IPADDRSTR DnsServerList;
    UINT NodeType;
    char ScopeId[260];
    UINT EnableRouting, EnableProxy, EnableDns;
} FIXEDINFO;
typedef struct _ADAPTERINFO {
    struct _ADAPTERINFO *Next;
    DWORD ComboIndex;
    char AdapterName[260];
    char Description[132];
    UINT AddressLength;
    BYTE Address[8];
    DWORD Index;
    UINT Type;
    UINT DhcpEnabled;
    IPADDRSTR *CurrentIpAddress;
    IPADDRSTR IpAddressList, GatewayList, DhcpServer;
    BOOL HaveWins;
    IPADDRSTR PrimaryWinsServer, SecondaryWinsServer;
    DWORD LeaseObtained, LeaseExpires;   /* time_t (32-bit on 9x); not printed */
} ADAPTERINFO;
typedef DWORD (WINAPI *PFN_BUF)(void *, ULONG *);
typedef DWORD (WINAPI *PFN_STAT)(void *);

/* Toolhelp32 (run-time lookup) */
typedef struct {
    DWORD dwSize, cntUsage, th32ProcessID, th32DefaultHeapID, th32ModuleID, cntThreads,
          th32ParentProcessID;
    LONG pcPriClassBase;
    DWORD dwFlags;
    char szExeFile[260];
} PROCENTRY;
typedef HANDLE (WINAPI *PFN_SNAP)(DWORD, DWORD);
typedef BOOL (WINAPI *PFN_PROC)(HANDLE, PROCENTRY *);

/* ------------------------------------------------------------------ */
/* options and state                                                   */
static DWORD opt_first = 180, opt_every = 300;
static int opt_once, opt_nonet, opt_nodbg, opt_nohook, opt_custom_out;
static volatile LONG g_ending;         /* WM_QUERYENDSESSION seen: no new USOSDBG / disk polls */
static char opt_dbgfile[MAX_PATH];
static char out_path[MAX_PATH];
static DWORD main_tid;
static DWORD t_start;
static int snap_no;

/* journal hook counters (main thread writes, worker reads) */
static HHOOK g_hook;
static volatile DWORD g_wheel, g_moves, g_ldown, g_rdown, g_mdown, g_xdown,
                      g_keys, g_cancels, g_installs, g_install_fail;
static volatile DWORD g_wheel_l, g_wheel_h, g_wheel_tick;

/* WM_MOUSEWHEEL detail lines (hook writes, worker prints; under ev_cs) */
#define WHEEL_LINES_MAX 300             /* per session, then only counted */
#define WHEEL_REC_QUIET 3000            /* ms without a wheel message before a wheel record */
#define WHEEL_REC_GAP   30              /* s between wheel records */
#define WHEEL_REC_MAX   10              /* wheel records per session */
static char wh_buf[24576];
static DWORD wh_len, wh_lines, wh_suppressed, wh_lost;
static volatile DWORD wh_pending;
typedef struct {
    DWORD cbSize, flags;
    HWND hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret;
    RECT rcCaret;
} GTINFO;                               /* GUITHREADINFO (98 / NT 4.0 SP3 and later) */
typedef BOOL (WINAPI *PFN_GTI)(DWORD, GTINFO *);
static PFN_GTI p_gti;
static int gti_looked;

static CRITICAL_SECTION ev_cs;
static char ev_buf[32768];
static DWORD ev_len, ev_lost;

static char obuf[393216];
static DWORD olen, olost;
static char dbuf[65536];                /* the disk watcher thread's records */
static DWORD dlen, dlost;
static DWORD disk_tid;
static CRITICAL_SECTION file_cs;        /* rotation and append of the log file */

static PFN_SNAP p_snap;
static PFN_PROC p_first, p_next;

/* ------------------------------------------------------------------ */
/* helpers without the C runtime                                       */
/* dotted quad -> network order (INADDR_NONE when malformed) */
static DWORD ip_addr(const char *p)
{
    DWORD v = 0, part;
    int i;
    for (i = 0; i < 4; i++) {
        if (*p < '0' || *p > '9') return INADDR_NONE;
        for (part = 0; *p >= '0' && *p <= '9'; p++) part = part * 10 + (DWORD)(*p - '0');
        if (part > 255) return INADDR_NONE;
        v |= part << (8 * i);
        if (i < 3) { if (*p != '.') return INADDR_NONE; p++; }
    }
    return *p ? INADDR_NONE : v;
}

static int winsock_load(void)
{
    static int tried;
    HMODULE w;
    if (tried) return ws_socket != 0;
    tried = 1;
    w = LoadLibraryA("WSOCK32.DLL");
    if (!w) return 0;
    ws_startup = (PFN_WSASTARTUP)GetProcAddress(w, "WSAStartup");
    ws_lasterror = (PFN_INT0)GetProcAddress(w, "WSAGetLastError");
    ws_close = (PFN_CLOSE)GetProcAddress(w, "closesocket");
    ws_connect = (PFN_CONNECT)GetProcAddress(w, "connect");
    ws_ghbn = (PFN_GHBN)GetProcAddress(w, "gethostbyname");
    ws_ioctl = (PFN_IOCTL)GetProcAddress(w, "ioctlsocket");
    ws_recv = (PFN_RECV)GetProcAddress(w, "recv");
    ws_recvfrom = (PFN_RECVFROM)GetProcAddress(w, "recvfrom");
    ws_select = (PFN_SELECT)GetProcAddress(w, "select");
    ws_send = (PFN_SEND)GetProcAddress(w, "send");
    ws_sendto = (PFN_SENDTO)GetProcAddress(w, "sendto");
    ws_setsockopt = (PFN_SETSOCKOPT)GetProcAddress(w, "setsockopt");
    ws_socket = (PFN_SOCKET)GetProcAddress(w, "socket");
    if (!ws_startup || !ws_lasterror || !ws_close || !ws_connect || !ws_ghbn || !ws_ioctl || !ws_recv ||
        !ws_recvfrom || !ws_select || !ws_send || !ws_sendto || !ws_setsockopt || !ws_socket) {
        ws_socket = 0;
        return 0;
    }
    return 1;
}

static int is_nt;                   /* VER_PLATFORM_WIN32_NT: no Win16 DPMI tools */

static int logger_paths(void)
{
    char app[MAX_PATH];
    DWORD length = GetModuleFileNameA(0, app, sizeof(app)), i;
    if (!length || length >= sizeof(app)) return 0;
    for (i = length; i && app[i - 1] != '\\' && app[i - 1] != '/'; i--) ;
    if (!i || i > MAX_PATH - 32) return 0;
    app[i] = 0;
    lstrcpyA(app_dir, app);
    lstrcpyA(log_dir, app); lstrcatA(log_dir, "LOGS");
    lstrcpyA(log_file, log_dir); lstrcatA(log_file, "\\USOSLOG.TXT");
    lstrcpyA(dbg_exe, app); lstrcatA(dbg_exe, "USOSDBG.EXE");
    lstrcpyA(dbg_tmp, log_dir); lstrcatA(dbg_tmp, "\\USOSDBG.TMP");
    lstrcpyA(dbg_tmp_disk, log_dir); lstrcatA(dbg_tmp_disk, "\\USOSDBGD.TMP");
    lstrcpyA(out_path, log_file);
    return 1;
}

static void mset(void *d, int c, DWORD n)
{
    volatile BYTE *p = (volatile BYTE *)d;
    while (n--) *p++ = (BYTE)c;
}

static void mcpy(void *d, const void *s, DWORD n)
{
    BYTE *a = (BYTE *)d;
    const BYTE *b = (const BYTE *)s;
    while (n--) *a++ = *b++;
}

#include "usoslog_compat.h"

static char lower(char c)
{
    return (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
}

static int has_text(const char *hay, const char *needle)
{
    int i, j;
    for (i = 0; hay[i]; i++) {
        for (j = 0; needle[j] && lower(hay[i + j]) == lower(needle[j]); j++) ;
        if (!needle[j]) return 1;
    }
    return 0;
}

static DWORD hexval(const char *p, int n)
{
    DWORD v = 0;
    for (; n-- > 0; p++) {
        char c = *p;
        if (c >= '0' && c <= '9') v = (v << 4) | (DWORD)(c - '0');
        else if (c >= 'a' && c <= 'f') v = (v << 4) | (DWORD)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v = (v << 4) | (DWORD)(c - 'A' + 10);
        else break;
    }
    return v;
}

static DWORD decval(const char *p)
{
    DWORD v = 0;
    while (*p >= '0' && *p <= '9') v = v * 10 + (DWORD)(*p++ - '0');
    return v;
}

/* ------------------------------------------------------------------ */
/* output buffer: one snapshot, written in one go                      */
static int on_disk_thread(void)
{
    return disk_tid && GetCurrentThreadId() == disk_tid;
}

static void oput(const char *s, DWORD n)
{
    if (on_disk_thread()) {
        if (dlen + n + 2 > sizeof(dbuf)) { dlost += n; return; }
        mcpy(dbuf + dlen, s, n);
        dlen += n;
        return;
    }
    if (olen + n + 2 > sizeof(obuf)) { olost += n; return; }
    mcpy(obuf + olen, s, n);
    olen += n;
}

static void o(const char *fmt, ...)
{
    char t[1100];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = wvsprintfA(t, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    oput(t, (DWORD)n);
    oput("\r\n", 2);
}

/* printable copy of up to Max bytes (CR / LF / TAB kept or made spaces) */
static void otext(const char *prefix, const char *s, DWORD n)
{
    char line[300];
    DWORD i, k = 0;
    for (i = 0; i <= n; i++) {
        char c = i < n ? s[i] : '\n';
        if (c == '\r') continue;
        if (c == '\n' || k >= sizeof(line) - 1) {
            line[k] = 0;
            if (k || i < n) o("%s%s", (LPSTR)prefix, (LPSTR)line);
            k = 0;
            if (c == '\n') continue;
        }
        line[k++] = (c == '\t') ? ' ' : (c < 32 || c == 127) ? '.' : c;
    }
}

static void ohex(const char *prefix, const BYTE *b, DWORD n)
{
    char line[200];
    DWORD r, i;
    int k;
    for (r = 0; r < n; r += 32) {
        k = wsprintfA(line, "%s+%03lX:", (LPSTR)prefix, r);
        for (i = r; i < n && i < r + 32; i++) k += wsprintfA(line + k, " %02X", (unsigned)b[i]);
        o("%s", (LPSTR)line);
    }
}

static void stamp(char *t)
{
    SYSTEMTIME st;
    GetLocalTime(&st);
    wsprintfA(t, "%04u-%02u-%02u %02u:%02u:%02u", st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
}

static void ipstr(char *t, DWORD a)   /* network order */
{
    wsprintfA(t, "%u.%u.%u.%u", (unsigned)(a & 0xFF), (unsigned)((a >> 8) & 0xFF), (unsigned)((a >> 16) & 0xFF),
              (unsigned)(a >> 24));
}

static void flush_out(void)
{
    HANDLE f;
    DWORD w, size;
    int disk = on_disk_thread();
    char *buf = disk ? dbuf : obuf;
    DWORD *len = disk ? &dlen : &olen, *lost = disk ? &dlost : &olost;
    if (*lost) o("(output truncated: %lu bytes lost)", *lost);
    EnterCriticalSection(&file_cs);
    if (!opt_custom_out) CreateDirectoryA(LOGDIR, 0);
    f = CreateFileA(out_path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
    if (f != INVALID_HANDLE_VALUE) {
        size = GetFileSize(f, 0);
        CloseHandle(f);
        if (size != 0xFFFFFFFFUL && size > ROTATE) {
            char old[MAX_PATH];
            int n;
            compat_strcopy(old, out_path, MAX_PATH - 4);
            n = lstrlenA(old);
            if (n > 4 && old[n - 4] == '.') old[n - 4] = 0;
            lstrcatA(old, ".OLD");
            DeleteFileA(old);
            MoveFileA(out_path, old);
        }
    }
    f = CreateFileA(out_path, GENERIC_WRITE, FILE_SHARE_READ, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (f != INVALID_HANDLE_VALUE) {
        SetFilePointer(f, 0, 0, FILE_END);
        WriteFile(f, buf, *len, &w, 0);
        FlushFileBuffers(f);
        CloseHandle(f);
    }
    LeaveCriticalSection(&file_cs);
    *len = 0;
    *lost = 0;
}

/* whole small file into Buf (NUL-terminated), returns length or -1 */
static int read_file(const char *path, char *buf, DWORD cap, DWORD from)
{
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
    DWORD r = 0;
    if (f == INVALID_HANDLE_VALUE) return -1;
    if (from) SetFilePointer(f, (LONG)from, 0, FILE_BEGIN);
    if (!ReadFile(f, buf, cap - 1, &r, 0)) r = 0;
    CloseHandle(f);
    buf[r] = 0;
    return (int)r;
}

static DWORD file_size(const char *path)
{
    HANDLE f = CreateFileA(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, 0, OPEN_EXISTING, 0, 0);
    DWORD s;
    if (f == INVALID_HANDLE_VALUE) return 0xFFFFFFFFUL;
    s = GetFileSize(f, 0);
    CloseHandle(f);
    return s;
}

static void dump_file(const char *label, const char *path, DWORD max)
{
    static char fb[8192];
    int n;
    if (max > sizeof(fb)) max = sizeof(fb);
    n = read_file(path, fb, max, 0);
    if (n < 0) { o("%s %s: missing", (LPSTR)label, (LPSTR)path); return; }
    o("%s %s (%d bytes shown, size %lu):", (LPSTR)label, (LPSTR)path, n, file_size(path));
    otext("    | ", fb, (DWORD)n);
}

/* ------------------------------------------------------------------ */
/* registry                                                            */
static BYTE rdata[4096];

static void reg_dump(HKEY root, const char *rootname, const char *path, DWORD maxbin)
{
    HKEY k;
    DWORD i, nl, dl, type;
    char name[256];
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &k) != ERROR_SUCCESS) {
        o("  [%s\\%s] (missing)", (LPSTR)rootname, (LPSTR)path);
        return;
    }
    o("  [%s\\%s]", (LPSTR)rootname, (LPSTR)path);
    for (i = 0; i < 400; i++) {
        nl = sizeof(name);
        dl = sizeof(rdata) - 1;
        if (RegEnumValueA(k, i, name, &nl, 0, &type, rdata, &dl) != ERROR_SUCCESS) break;
        rdata[dl < sizeof(rdata) ? dl : sizeof(rdata) - 1] = 0;
        if (!name[0]) lstrcpyA(name, "(default)");
        if (type == REG_SZ || type == REG_EXPAND_SZ) {
            char t[600];
            compat_strcopy(t, (char *)rdata, sizeof(t));
            o("    %s = \"%s\"", (LPSTR)name, (LPSTR)t);
        } else if (type == REG_DWORD && dl == 4) {
            DWORD v = *(DWORD *)rdata;
            o("    %s = dword:%08lX (%lu)", (LPSTR)name, v, v);
        } else {
            char t[700];
            DWORD j, n = dl > maxbin ? maxbin : dl;
            int m = wsprintfA(t, "    %s = type %lu, %lu bytes:", (LPSTR)name, type, dl);
            for (j = 0; j < n && m < (int)sizeof(t) - 4; j++) m += wsprintfA(t + m, " %02X", (unsigned)rdata[j]);
            if (n < dl) lstrcatA(t, " ...");
            o("%s", (LPSTR)t);
        }
    }
    RegCloseKey(k);
}

static int reg_str(HKEY root, const char *path, const char *name, char *buf, DWORD cap)
{
    HKEY k;
    DWORD type, dl = cap - 1;
    buf[0] = 0;
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
    if (RegQueryValueExA(k, (LPSTR)name, 0, &type, (BYTE *)buf, &dl) != ERROR_SUCCESS) dl = 0;
    RegCloseKey(k);
    buf[dl < cap ? dl : cap - 1] = 0;
    return dl != 0;
}

static DWORD reg_dword(HKEY root, const char *path, const char *name)
{
    HKEY k;
    DWORD type, v = 0, dl = 4;
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &k) != ERROR_SUCCESS) return 0;
    if (RegQueryValueExA(k, (LPSTR)name, 0, &type, (BYTE *)&v, &dl) != ERROR_SUCCESS || dl != 4) v = 0;
    RegCloseKey(k);
    return v;
}

/* subkeys of Path, each dumped */
static void reg_dump_sub(HKEY root, const char *rootname, const char *path, DWORD maxbin, int max)
{
    HKEY k;
    DWORD i, nl;
    char sub[128], full[400];
    FILETIME ft;
    if (RegOpenKeyExA(root, path, 0, KEY_READ, &k) != ERROR_SUCCESS) {
        o("  [%s\\%s] (missing)", (LPSTR)rootname, (LPSTR)path);
        return;
    }
    for (i = 0; i < (DWORD)max; i++) {
        nl = sizeof(sub);
        if (RegEnumKeyExA(k, i, sub, &nl, 0, 0, 0, &ft) != ERROR_SUCCESS) break;
        wsprintfA(full, "%s\\%s", (LPSTR)path, (LPSTR)sub);
        reg_dump(root, rootname, full, maxbin);
    }
    RegCloseKey(k);
}

/* ------------------------------------------------------------------ */
/* journal record hook (main thread)                                   */
/* "hwnd class[ V]" (V: WS_VSCROLL), "-" without a window */
static void win_desc(char *t, HWND w)
{
    char cls[48];
    if (!w) { lstrcpyA(t, "-"); return; }
    cls[0] = 0;
    GetClassNameA(w, cls, sizeof(cls));
    wsprintfA(t, "%08lX %s%s", (DWORD)w, (LPSTR)cls, (LPSTR)((GetWindowLongA(w, GWL_STYLE) & WS_VSCROLL) ? " V" : ""));
}

/* Where the wheel message goes (USER: the focus window of the foreground
 * thread) and what is under the pointer; one line per WM_MOUSEWHEEL. */
static void wheel_detail(const EVENTMSG *e)
{
    char t[400], ts[48], fo[72], hv[72], fg[72];
    HWND fgw = GetForegroundWindow(), fow = 0, hvw;
    POINT pt;
    GTINFO gi;
    SYSTEMTIME st;
    DWORD rel = GetTickCount() - t_start;
    int n, m;
    if (!gti_looked) {
        HMODULE u = GetModuleHandleA("USER32.DLL");
        gti_looked = 1;
        if (u) p_gti = (PFN_GTI)GetProcAddress(u, "GetGUIThreadInfo");
    }
    if (p_gti && fgw) {
        mset(&gi, 0, sizeof(gi));
        gi.cbSize = sizeof(gi);
        if (p_gti(GetWindowThreadProcessId(fgw, 0), &gi)) fow = gi.hwndFocus;
    }
    pt.x = pt.y = 0;
    GetCursorPos(&pt);
    hvw = WindowFromPoint(pt);
    win_desc(fo, fow);
    win_desc(hv, hvw);
    win_desc(fg, fgw);
    GetLocalTime(&st);
    m = wsprintfA(ts, "%02u:%02u:%02u.%03u t+%lu.%03lu ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                  rel / 1000, rel % 1000);
    n = wsprintfA(t, "wheel L=%08lX H=%08lX at %ld,%ld  focus %s%s  under pointer %s%s  foreground %s",
                  e->paramL, e->paramH, pt.x, pt.y, (LPSTR)fo, (LPSTR)(p_gti ? "" : " (no GetGUIThreadInfo)"),
                  (LPSTR)hv, (LPSTR)(hvw && hvw == fow ? " (= focus)" : ""), (LPSTR)fg);
    EnterCriticalSection(&ev_cs);
    if (wh_lines >= WHEEL_LINES_MAX) {
        wh_suppressed++;
    } else if (wh_len + (DWORD)(m + n) + 8 < sizeof(wh_buf)) {
        wh_lines++;
        mcpy(wh_buf + wh_len, "    ", 4); wh_len += 4;
        mcpy(wh_buf + wh_len, ts, (DWORD)m); wh_len += (DWORD)m;
        mcpy(wh_buf + wh_len, t, (DWORD)n); wh_len += (DWORD)n;
        mcpy(wh_buf + wh_len, "\r\n", 2); wh_len += 2;
    } else {
        wh_lost++;
    }
    wh_pending = 1;
    LeaveCriticalSection(&ev_cs);
}

LRESULT CALLBACK journal(int code, WPARAM wp, LPARAM lp)
{
    if (code == HC_ACTION && lp) {
        const EVENTMSG *e = (const EVENTMSG *)lp;
        switch (e->message) {
        case WM_MOUSEWHEEL:
            g_wheel++;
            g_wheel_l = e->paramL;
            g_wheel_h = e->paramH;
            g_wheel_tick = GetTickCount();
            /* No direction here: a journal record carries no wheel delta
             * (98 / Me: paramL / paramH are the pointer x / y). The delta
             * and what was done with it: USOSDBG's "WHEEL USOSKEY" lines. */
            wheel_detail(e);
            break;
        case WM_MOUSEMOVE: g_moves++; break;
        case WM_LBUTTONDOWN: g_ldown++; break;
        case WM_RBUTTONDOWN: g_rdown++; break;
        case WM_MBUTTONDOWN: g_mdown++; break;
        case 0x020B: g_xdown++; break;             /* WM_XBUTTONDOWN */
        case WM_KEYDOWN: case WM_SYSKEYDOWN: g_keys++; break;
        }
    }
    return CallNextHookEx(g_hook, code, wp, lp);
}

static void hook_install(void)
{
    if (opt_nohook || g_hook) return;
    g_hook = SetWindowsHookExA(WH_JOURNALRECORD, journal, GetModuleHandleA(0), 0);
    if (g_hook) g_installs++;
    else g_install_fail++;
}

/* ------------------------------------------------------------------ */
/* process / window watcher (main thread, every 250 ms)                */
/* Every tick: one Toolhelp32 process snapshot, diffed by PID against the
 * previous one. EnumWindows (visible top-level windows) on every tick for
 * WATCH_HOT ticks after the process set changed (a console flashing up
 * comes with CONAGENT / WINOA386 / the program itself), otherwise on every
 * WATCH_WIN_EVERY-th tick; without Toolhelp32 (NT 4.0) every 2nd tick.
 * At most WATCH_EV_MAX event lines per session, then only counted. */
#define WATCH_MS        250
#define WATCH_WIN_EVERY 4               /* quiet: windows once a second */
#define WATCH_HOT       8               /* 2 s of per-tick window scans after a change */
#define WATCH_EV_MAX    1000
#define MAXP 512
#define MAXW 256
typedef struct { DWORD pid, ppid, born; char exe[80]; } PROCREC;
typedef struct { HWND w; DWORD pid, born; char cls[32]; } WINREC;
static PROCREC procs[MAXP], procs_new[MAXP];
static int nprocs, watch_primed;
static WINREC wins[MAXW], wins_new[MAXW];
static HWND win_handles[MAXW];
static int nwins, nwins_new;
static DWORD watch_ticks, watch_hot, watch_enums;
static DWORD ev_total, ev_suppressed;   /* under ev_cs */

static void ev(const char *fmt, ...)
{
    char t[600], ts[48];
    va_list ap;
    int n, m;
    SYSTEMTIME st;
    DWORD rel = GetTickCount() - t_start;
    GetLocalTime(&st);
    m = wsprintfA(ts, "%02u:%02u:%02u.%03u t+%lu.%03lu ", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds,
                  rel / 1000, rel % 1000);
    va_start(ap, fmt);
    n = wvsprintfA(t, fmt, ap);
    va_end(ap);
    EnterCriticalSection(&ev_cs);
    if (ev_total >= WATCH_EV_MAX) {
        ev_suppressed++;
    } else if (ev_len + (DWORD)(m + n) + 8 < sizeof(ev_buf)) {
        ev_total++;
        mcpy(ev_buf + ev_len, "    ", 4); ev_len += 4;
        mcpy(ev_buf + ev_len, ts, (DWORD)m); ev_len += (DWORD)m;
        mcpy(ev_buf + ev_len, t, (DWORD)n); ev_len += (DWORD)n;
        mcpy(ev_buf + ev_len, "\r\n", 2); ev_len += 2;
    } else {
        ev_lost++;
    }
    LeaveCriticalSection(&ev_cs);
}

/* 9x: WinOldAp's "tty" hosts DOS boxes and Win32 consoles; NT: conhost */
static int console_class(const char *cls)
{
    return !lstrcmpiA(cls, "tty") || !lstrcmpiA(cls, "ConsoleWindowClass");
}

static const char *base_name(const char *p)
{
    const char *b = p;
    for (; *p; p++) if (*p == '\\' || *p == '/' || *p == ':') b = p + 1;
    return b;
}

static int proc_list(PROCREC *out, int max)
{
    HANDLE h;
    PROCENTRY pe;
    int n = 0;
    if (!p_snap || !p_first || !p_next) return -1;
    h = p_snap(2 /* TH32CS_SNAPPROCESS */, 0);
    if (h == INVALID_HANDLE_VALUE || !h) return -1;
    mset(&pe, 0, sizeof(pe));
    pe.dwSize = sizeof(pe);
    if (p_first(h, &pe)) {
        do {
            if (n < max) {
                out[n].pid = pe.th32ProcessID;
                out[n].ppid = pe.th32ParentProcessID;
                out[n].born = 0;
                compat_strcopy(out[n].exe, pe.szExeFile, sizeof(out[n].exe));
                n++;
            }
            pe.dwSize = sizeof(pe);
        } while (p_next(h, &pe));
    }
    CloseHandle(h);
    return n;
}

/* exe of Pid in the current list, else in the other one (ended / not yet
 * merged), else "?" */
static const char *exe_in(const PROCREC *a, int na, const PROCREC *b, int nb, DWORD pid)
{
    int i;
    for (i = 0; i < na; i++) if (a[i].pid == pid) return base_name(a[i].exe);
    for (i = 0; i < nb; i++) if (b[i].pid == pid) return base_name(b[i].exe);
    return "?";
}

/* the last processes that ended: their windows go after them */
#define GONE 16
static PROCREC gone[GONE];
static int ngone, gone_next;

static const char *exe_of(DWORD pid)
{
    return exe_in(procs, nprocs, gone, ngone, pid);
}

typedef struct { HWND *w; int n; } WINLIST;

BOOL CALLBACK collect_win(HWND w, LPARAM lp)
{
    WINLIST *l = (WINLIST *)lp;
    if (IsWindowVisible(w) && l->n < MAXW) l->w[l->n++] = w;
    return TRUE;
}

static int win_list(HWND *out)
{
    WINLIST l;
    l.w = out;
    l.n = 0;
    EnumWindows(collect_win, (LPARAM)&l);
    return l.n;
}

/* 1 = the process set changed */
static int watch_procs(DWORD now)
{
    int n = proc_list(procs_new, MAXP), i, j, changed = 0;
    if (n < 0) return 0;
    for (i = 0; i < n; i++) {
        for (j = 0; j < nprocs && procs[j].pid != procs_new[i].pid; j++) ;
        if (j < nprocs) { procs_new[i].born = procs[j].born; continue; }
        procs_new[i].born = watch_primed ? now : 0;     /* 0: running before the logger */
        changed = 1;
        if (watch_primed)
            ev("+proc %08lX %s  parent %08lX %s", procs_new[i].pid, (LPSTR)procs_new[i].exe, procs_new[i].ppid,
               (LPSTR)exe_in(procs_new, n, procs, nprocs, procs_new[i].ppid));
    }
    for (j = 0; j < nprocs; j++) {
        for (i = 0; i < n && procs_new[i].pid != procs[j].pid; i++) ;
        if (i < n) continue;
        changed = 1;
        mcpy(&gone[gone_next], &procs[j], sizeof(PROCREC));
        gone_next = (gone_next + 1) % GONE;
        if (ngone < GONE) ngone++;
        if (watch_primed)
            ev("-proc %08lX %s  parent %08lX %s  ran %lu ms%s", procs[j].pid, (LPSTR)base_name(procs[j].exe),
               procs[j].ppid, (LPSTR)exe_in(procs_new, n, procs, nprocs, procs[j].ppid),
               procs[j].born ? now - procs[j].born : now - t_start,
               (LPSTR)(procs[j].born ? "" : " at least (before the logger)"));
    }
    mcpy(procs, procs_new, sizeof(PROCREC) * (DWORD)n);
    nprocs = n;
    return changed;
}

static void watch_windows(DWORD now)
{
    int i, j, nh = win_list(win_handles);
    watch_enums++;
    nwins_new = 0;
    for (i = 0; i < nh; i++) {
        WINREC *r = &wins_new[nwins_new++];
        for (j = 0; j < nwins && wins[j].w != win_handles[i]; j++) ;
        if (j < nwins) { mcpy(r, &wins[j], sizeof(WINREC)); continue; }
        r->w = win_handles[i];
        r->pid = 0;
        r->born = watch_primed ? now : 0;
        r->cls[0] = 0;
        GetClassNameA(r->w, r->cls, sizeof(r->cls));
        GetWindowThreadProcessId(r->w, &r->pid);
        if (watch_primed) {
            char title[128];
            title[0] = 0;
            GetWindowTextA(r->w, title, sizeof(title));
            ev("+window %08lX class \"%s\" title \"%s\" pid %08lX %s%s", (DWORD)r->w, (LPSTR)r->cls, (LPSTR)title,
               r->pid, (LPSTR)exe_of(r->pid), (LPSTR)(console_class(r->cls) ? "  <- console / DOS box" : ""));
        }
    }
    for (j = 0; j < nwins; j++) {
        for (i = 0; i < nwins_new && wins_new[i].w != wins[j].w; i++) ;
        if (i == nwins_new && watch_primed)
            ev("-window %08lX class \"%s\" pid %08lX %s  shown %lu ms%s%s", (DWORD)wins[j].w, (LPSTR)wins[j].cls,
               wins[j].pid, (LPSTR)exe_of(wins[j].pid), now - (wins[j].born ? wins[j].born : t_start),
               (LPSTR)(wins[j].born ? "" : " at least"),
               (LPSTR)(console_class(wins[j].cls) ? "  <- console / DOS box" : ""));
    }
    mcpy(wins, wins_new, sizeof(WINREC) * (DWORD)nwins_new);
    nwins = nwins_new;
}

static void watch_tick(void)
{
    DWORD now = GetTickCount();
    int toolhelp = p_snap && p_first && p_next;
    if (watch_procs(now)) watch_hot = WATCH_HOT;
    if (!watch_primed || watch_hot || watch_ticks % (toolhelp ? WATCH_WIN_EVERY : 2) == 0) watch_windows(now);
    if (watch_hot) watch_hot--;
    watch_ticks++;
    watch_primed = 1;
}

/* ------------------------------------------------------------------ */
/* sections                                                            */
static void sec_sys(void)
{
    OSVERSIONINFOA v;
    MEMORYSTATUS m;
    char t[64];
    DWORD up = GetTickCount();
    mset(&v, 0, sizeof(v));
    v.dwOSVersionInfoSize = sizeof(v);
    compat_os_version(&v);
    mset(&m, 0, sizeof(m));
    m.dwLength = sizeof(m);
    GlobalMemoryStatus(&m);
    t[0] = 0;
    {
        DWORD n = sizeof(t);
        GetComputerNameA(t, &n);
    }
    o("[SYS] Windows %lu.%lu build %lu platform %lu \"%s\"  computer \"%s\"", v.dwMajorVersion, v.dwMinorVersion,
      v.dwBuildNumber & 0xFFFF, v.dwPlatformId, (LPSTR)v.szCSDVersion, (LPSTR)t);
    o("[SYS] memory load %lu%%  phys %lu/%lu KiB free  page %lu/%lu KiB free  uptime %lu s  screen %dx%d",
      m.dwMemoryLoad, m.dwAvailPhys / 1024, m.dwTotalPhys / 1024, m.dwAvailPageFile / 1024, m.dwTotalPageFile / 1024,
      up / 1000, GetSystemMetrics(SM_CXSCREEN), GetSystemMetrics(SM_CYSCREEN));
}

/* --- USOSDBG /L ------------------------------------------------------ */
static HANDLE dbg_proc;
static int dbg_pci_done;
static BYTE usns_raw[4096];
static DWORD usns_raw_len;
static char dbg_text[65536];

static void run_usosdbg(DWORD stats_pa)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char cmd[MAX_PATH * 2 + 64];
    DWORD t0, w;
    int n, i, ended;
    usns_raw_len = 0;
    if (opt_dbgfile[0]) {
        n = read_file(opt_dbgfile, dbg_text, sizeof(dbg_text), 0);
        o("[MOUSE] USOSDBG output from %s (/dbgfile)", (LPSTR)opt_dbgfile);
        if (n <= 0) return;
        otext("  ", dbg_text, (DWORD)n);
        goto parse;
    }
    if (opt_nodbg) { o("[MOUSE] USOSDBG skipped (/nodbg)"); return; }
    if (g_ending) { o("[MOUSE] USOSDBG skipped: Windows is ending the session"); return; }
    if (is_nt) { o("[MOUSE] USOSDBG skipped: Windows NT family (Win16 DPMI diagnostics are 9x only)"); return; }
    if (file_size(DBGEXE) == 0xFFFFFFFFUL) { o("[MOUSE] %s missing", (LPSTR)DBGEXE); return; }
    if (dbg_proc) {
        if (WaitForSingleObject(dbg_proc, 0) == WAIT_TIMEOUT) {
            o("[MOUSE] the previous USOSDBG /L is still running: skipped this time");
            return;
        }
        CloseHandle(dbg_proc);
        dbg_proc = 0;
    }
    DeleteFileA(DBGTMP);
    n = wsprintfA(cmd, "\"%s\" /L \"%s\"", (LPSTR)DBGEXE, (LPSTR)DBGTMP);
    if (!dbg_pci_done) n += wsprintfA(cmd + n, " /F");
    if (stats_pa) n += wsprintfA(cmd + n, " /N %08lX", stats_pa);
    mset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    t0 = GetTickCount();
    if (!CreateProcessA(0, cmd, 0, 0, FALSE, 0, 0, app_dir, &si, &pi)) {
        o("[MOUSE] %s: CreateProcess failed, error %lu", (LPSTR)cmd, GetLastError());
        return;
    }
    CloseHandle(pi.hThread);
    dbg_proc = pi.hProcess;
    w = WaitForSingleObject(dbg_proc, 20000);
    /* a Win16 task's handle may signal early: the END line decides */
    ended = 0;
    for (;;) {
        n = read_file(DBGTMP, dbg_text, sizeof(dbg_text), 0);
        if (n > 0 && has_text(dbg_text, "USOSDBG END")) { ended = 1; break; }
        if (GetTickCount() - t0 > 25000) break;
        Sleep(500);
    }
    if (!dbg_pci_done) dbg_pci_done = 1;
    o("[MOUSE] %s  (%lu ms, wait %s, %s)", (LPSTR)cmd, GetTickCount() - t0,
      (LPSTR)(w == WAIT_OBJECT_0 ? "exited" : "timeout"), (LPSTR)(ended ? "complete" : "INCOMPLETE"));
    if (n <= 0) { o("[MOUSE]   no output file"); return; }
    otext("  ", dbg_text, (DWORD)n);
parse:
    /* USNS+ooo:hex lines (usosnet statistics page through DPMI) */
    for (i = 0; i < n; i++) {
        if ((i == 0 || dbg_text[i - 1] == '\n') && dbg_text[i] == 'U' && i + 9 < n &&
            dbg_text[i + 1] == 'S' && dbg_text[i + 2] == 'N' && dbg_text[i + 3] == 'S' && dbg_text[i + 4] == '+') {
            DWORD off = hexval(dbg_text + i + 5, 3);
            int k = i + 9;
            if (dbg_text[k] == ':') k++;
            while (k + 1 < n && off < sizeof(usns_raw) && dbg_text[k] != '\r' && dbg_text[k] != '\n') {
                usns_raw[off++] = (BYTE)hexval(dbg_text + k, 2);
                k += 2;
            }
            if (off > usns_raw_len) usns_raw_len = off;
        }
    }
}

static void sec_mouse(void)
{
    char a[80], b[80], c[80];
    UINT lines = 0;
    SystemParametersInfoA(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
    o("[MOUSE] metrics: mouse present %d  buttons %d  wheel present %d  wheel scroll lines %u  swap %d",
      GetSystemMetrics(SM_MOUSEPRESENT), GetSystemMetrics(SM_CMOUSEBUTTONS), GetSystemMetrics(SM_MOUSEWHEELPRESENT),
      lines, GetSystemMetrics(SM_SWAPBUTTON));
    o("[MOUSE] journal hook: %s (installs %lu, failed %lu, cancelled %lu)  WM_MOUSEWHEEL %lu (last %lu s ago L=%08lX H=%08lX; no delta in journal records: see WHEEL USOSKEY)",
      (LPSTR)(opt_nohook ? "off (/nohook)" : g_hook ? "on" : "not installed"), g_installs, g_install_fail, g_cancels,
      g_wheel, g_wheel_tick ? (GetTickCount() - g_wheel_tick) / 1000 : 0, g_wheel_l, g_wheel_h);
    o("[MOUSE] journal hook: moves %lu  left %lu  right %lu  middle %lu  x-buttons %lu  keys %lu",
      g_moves, g_ldown, g_rdown, g_mdown, g_xdown, g_keys);
    GetPrivateProfileStringA("boot", "mouse.drv", "(none)", a, sizeof(a), "SYSTEM.INI");
    GetPrivateProfileStringA("386Enh", "mouse", "(none)", b, sizeof(b), "SYSTEM.INI");
    GetPrivateProfileStringA("boot", "drivers", "(none)", c, sizeof(c), "SYSTEM.INI");
    o("[MOUSE] SYSTEM.INI [boot] mouse.drv=%s  [386Enh] mouse=%s  [boot] drivers=%s", (LPSTR)a, (LPSTR)b, (LPSTR)c);
    GetPrivateProfileStringA("mouse", "wheel", "(none)", a, sizeof(a), "SYSTEM.INI");
    GetPrivateProfileStringA("boot.description", "mouse.drv", "(none)", b, sizeof(b), "SYSTEM.INI");
    o("[MOUSE] SYSTEM.INI [mouse] wheel=%s  [boot.description] mouse.drv=%s", (LPSTR)a, (LPSTR)b);
}

/* the WM_MOUSEWHEEL lines since the last record (worker thread) */
static void sec_wheel(void)
{
    EnterCriticalSection(&ev_cs);
    o("[MOUSE] WM_MOUSEWHEEL lines since the last record (focus = where USER sends it; V = WS_VSCROLL; %lu lost):",
      wh_lost);
    oput(wh_buf, wh_len);
    if (wh_suppressed)
        o("[MOUSE] wheel lines: session limit of %u reached, %lu more not logged", WHEEL_LINES_MAX, wh_suppressed);
    wh_len = 0;
    wh_lost = 0;
    wh_pending = 0;
    LeaveCriticalSection(&ev_cs);
}

/* --- usosnet ----------------------------------------------------------- */
static char net_key[96];
static DWORD stats_va, stats_pa;
static USNS usns_now, usns_prev;
static int usns_prev_ok;

static void find_usosnet(int dump)
{
    int i;
    char path[96], vxd[128], desc[160];
    net_key[0] = 0;
    stats_va = stats_pa = 0;
    for (i = 0; i < 32; i++) {
        wsprintfA(path, "System\\CurrentControlSet\\Services\\Class\\Net\\%04u", i);
        if (!reg_str(HKEY_LOCAL_MACHINE, path, "DriverDesc", desc, sizeof(desc))) continue;
        reg_str(HKEY_LOCAL_MACHINE, path, "DeviceVxDs", vxd, sizeof(vxd));
        if (has_text(vxd, "usosnet") && !net_key[0]) {
            lstrcpyA(net_key, path);
            stats_va = reg_dword(HKEY_LOCAL_MACHINE, path, "UsosnetStatsVa");
            stats_pa = reg_dword(HKEY_LOCAL_MACHINE, path, "UsosnetStatsPa");
            if (dump) reg_dump(HKEY_LOCAL_MACHINE, "HKLM", path, 64);
        } else if (dump) {
            o("  [HKLM\\%s] \"%s\" DeviceVxDs=%s", (LPSTR)path, (LPSTR)desc, (LPSTR)vxd);
        }
    }
    if (dump && !net_key[0]) o("[NET] no adapter with DeviceVxDs usosnet.sys");
}

static void class_line(const char *label, const DWORD *v, const DWORD *prev)
{
    char t[900];
    int i, m = wsprintfA(t, "%s", (LPSTR)label);
    for (i = 0; i < USNS_CLASSES; i++) {
        DWORD d = prev ? v[i] - prev[i] : v[i];
        if (prev && !d) continue;
        m += wsprintfA(t + m, " %s=%lu", (LPSTR)usns_class[i], d);
    }
    o("%s", (LPSTR)t);
}

static void classes_str(char *t, DWORD c)
{
    int i, m = 0;
    t[0] = 0;
    for (i = 0; i < USNS_CLASSES; i++)
        if (c & (1UL << i)) m += wsprintfA(t + m, "%s%s", (LPSTR)(m ? "," : ""), (LPSTR)usns_class[i]);
}

static void dns_frame(const char *label, const BYTE *f, DWORD len)
{
    DWORD n = len > USNS_DUMP ? USNS_DUMP : len;
    char a[20], b[20];
    if (!len) { o("  %s: none yet", (LPSTR)label); return; }
    if (n >= 14 + 20 + 8 + 12 && f[12] == 8 && f[13] == 0) {
        const BYTE *ip = f + 14, *u = ip + (ip[0] & 15) * 4, *d = u + 8;
        ipstr(a, *(const DWORD *)(ip + 12));
        ipstr(b, *(const DWORD *)(ip + 16));
        if ((DWORD)(d + 12 - f) <= n)
            o("  %s: %lu bytes  %s:%u -> %s:%u  ip proto %u  dns id %04X flags %04X qd %u an %u ns %u ar %u",
              (LPSTR)label, len, (LPSTR)a, (unsigned)((u[0] << 8) | u[1]), (LPSTR)b, (unsigned)((u[2] << 8) | u[3]),
              (unsigned)ip[9], (unsigned)((d[0] << 8) | d[1]), (unsigned)((d[2] << 8) | d[3]),
              (unsigned)((d[4] << 8) | d[5]), (unsigned)((d[6] << 8) | d[7]), (unsigned)((d[8] << 8) | d[9]),
              (unsigned)((d[10] << 8) | d[11]));
    } else {
        o("  %s: %lu bytes", (LPSTR)label, len);
    }
    ohex("    ", f, n);
}

static void usns_print(const USNS *s, const char *source)
{
    DWORD i, first;
    char t[900], cl[200], peer[20];
    int m;
    const USNS *p = usns_prev_ok && usns_prev.Seconds <= s->Seconds ? &usns_prev : 0;
    o("[NET] usosnet statistics (%s): version %lu size %lu  driver up %lu s", (LPSTR)source, s->Version, s->Size,
      s->Seconds);
    class_line("  RX  ", s->Rx, 0);
    class_line("  TX  ", s->Tx, 0);
    if (p) { class_line("  RX since last snapshot:", s->Rx, p->Rx); class_line("  TX since last snapshot:", s->Tx, p->Tx); }
    m = wsprintfA(t, "  RX drops / notes:");
    for (i = 0; i < USNS_DROPS; i++) m += wsprintfA(t + m, " %s=%lu", (LPSTR)usns_drop[i], s->Drop[i]);
    o("%s", (LPSTR)t);
    m = wsprintfA(t, "  TransferData:");
    for (i = 0; i < USNS_TDS; i++) m += wsprintfA(t + m, " %s=%lu", (LPSTR)usns_td[i], s->Td[i]);
    o("%s", (LPSTR)t);
    m = wsprintfA(t, "  core:");
    for (i = 0; i < USNS_CORES; i++) {
        if (i >= 21 && i <= 23) m += wsprintfA(t + m, " %s=%08lX", (LPSTR)usns_core[i], s->Core[i]);
        else m += wsprintfA(t + m, " %s=%lu", (LPSTR)usns_core[i], s->Core[i]);
        if (m > 700) { o("%s", (LPSTR)t); m = wsprintfA(t, "  core:"); }
    }
    o("%s", (LPSTR)t);
    first = s->Seq > USNS_HIST ? s->Seq - USNS_HIST : 0;
    o("  last frames (seq dir classes ports length status peer), %lu frames seen:", s->Seq);
    for (i = first; i < s->Seq; i++) {
        const DWORD *h = s->Hist[i % USNS_HIST];
        DWORD dir = h[0] & 0xFF;
        classes_str(cl, h[1]);
        ipstr(peer, h[5]);
        o("    %6lu %s %-24s %5lu>%-5lu len %4lu st %08lX %s %s", h[0] >> 8,
          (LPSTR)(dir == 1 ? "RX" : dir == 2 ? "TX" : dir == 3 ? "RX-DROP" : "?"), (LPSTR)cl, h[2] >> 16,
          h[2] & 0xFFFF, h[3], h[4], (LPSTR)(dir == 2 ? "to" : "from"), (LPSTR)peer);
    }
    dns_frame("last DNS frame received", s->LastDnsRx, s->LastDnsRxLen);
    dns_frame("last DNS frame sent", s->LastDnsTx, s->LastDnsTxLen);
}

/* through the linear address (9x system arena); 1 = read */
static int usns_read_va(USNS *s)
{
    const USNS *v = (const USNS *)stats_va;
    if (is_nt || !stats_va || IsBadReadPtr(v, sizeof(USNS))) return 0;
    if (v->Magic != USNS_MAGIC || v->Version != 1) return 0;
    mcpy(s, v, sizeof(USNS));
    return 1;
}

static void sec_usns(int after)
{
    if (!net_key[0] && !(opt_dbgfile[0] && !after)) return;
    if (!stats_va && !stats_pa && !opt_dbgfile[0]) {
        o("[NET] usosnet: no UsosnetStatsVa / UsosnetStatsPa (driver older than 0.4, or no page)");
        return;
    }
    if (usns_read_va(&usns_now)) {
        usns_print(&usns_now, after ? "after the tests, VA" : "VA");
    } else if (!after && usns_raw_len >= sizeof(USNS) && ((USNS *)usns_raw)->Magic == USNS_MAGIC) {
        mcpy(&usns_now, usns_raw, sizeof(USNS));
        usns_print(&usns_now, "PA through USOSDBG");
    } else {
        o("[NET] usosnet statistics: VA %08lX not readable%s; PA %08lX%s", stats_va,
          (LPSTR)(stats_va && IsBadReadPtr((void *)stats_va, 4) ? " (IsBadReadPtr)" : ""), stats_pa,
          (LPSTR)(after ? "" : usns_raw_len ? " dump without magic" : " no USOSDBG dump"));
        return;
    }
    mcpy(&usns_prev, &usns_now, sizeof(USNS));
    usns_prev_ok = 1;
}

/* --- IPHLPAPI ----------------------------------------------------------- */
static HMODULE iphlp;
static PFN_BUF p_gnp, p_gai;
static PFN_STAT p_ips, p_udps, p_tcps, p_icmps;
static BYTE ipbuf[16384];
static DWORD dns_cfg[8];
static int ndns_cfg;
static DWORD gateway;

static void iphlp_load(void)
{
    if (iphlp) return;
    iphlp = LoadLibraryA("IPHLPAPI.DLL");
    if (!iphlp) return;
    p_gnp = (PFN_BUF)GetProcAddress(iphlp, "GetNetworkParams");
    p_gai = (PFN_BUF)GetProcAddress(iphlp, "GetAdaptersInfo");
    p_ips = (PFN_STAT)GetProcAddress(iphlp, "GetIpStatistics");
    p_udps = (PFN_STAT)GetProcAddress(iphlp, "GetUdpStatistics");
    p_tcps = (PFN_STAT)GetProcAddress(iphlp, "GetTcpStatistics");
    p_icmps = (PFN_STAT)GetProcAddress(iphlp, "GetIcmpStatistics");
}

static void add_dns(DWORD a)
{
    int i;
    if (a == INADDR_NONE || !a) return;
    for (i = 0; i < ndns_cfg; i++) if (dns_cfg[i] == a) return;
    if (ndns_cfg < 8) dns_cfg[ndns_cfg++] = a;
}

#ifdef USOS_NT3_RAW_ICMP
static void raw_ping_gateway(void);
#endif
#include "usoslog_net.h"

static void sec_iphlp_config(void)
{
    ULONG len;
    DWORD r;
    gateway = 0;
    ndns_cfg = 0;
    iphlp_load();
    if (!iphlp) {
        o("[NET] IPHLPAPI.DLL: not loadable (error %lu)", GetLastError());
        if (is_nt) nt_tcpip_config();
        return;
    }
    if (p_gnp) {
        len = sizeof(ipbuf);
        r = p_gnp(ipbuf, &len);
        if (r == 0) {
            FIXEDINFO *f = (FIXEDINFO *)ipbuf;
            IPADDRSTR *d;
            char t[600];
            int m = wsprintfA(t, "[NET] GetNetworkParams: host \"%s\" domain \"%s\" node %u routing %u proxy %u dns %u  servers:",
                              (LPSTR)f->HostName, (LPSTR)f->DomainName, f->NodeType, f->EnableRouting, f->EnableProxy,
                              f->EnableDns);
            for (d = &f->DnsServerList; d && m < 500; d = d->Next) {
                m += wsprintfA(t + m, " %s", (LPSTR)d->IpAddress.String);
                add_dns(inet_addr(d->IpAddress.String));
            }
            o("%s", (LPSTR)t);
        } else {
            o("[NET] GetNetworkParams: error %lu", r);
        }
    } else {
        o("[NET] GetNetworkParams: not exported");
    }
    if (p_gai) {
        len = sizeof(ipbuf);
        r = p_gai(ipbuf, &len);
        if (r == 0) {
            ADAPTERINFO *a;
            for (a = (ADAPTERINFO *)ipbuf; a; a = a->Next) {
                IPADDRSTR *x;
                char t[700];
                int m = wsprintfA(t, "[NET] adapter %lu \"%s\" type %u mac", a->Index, (LPSTR)a->Description, a->Type);
                UINT i;
                for (i = 0; i < a->AddressLength && i < 8; i++) m += wsprintfA(t + m, "%s%02X", (LPSTR)(i ? "-" : " "), (unsigned)a->Address[i]);
                m += wsprintfA(t + m, " dhcp %u server %s  ip", a->DhcpEnabled, (LPSTR)a->DhcpServer.IpAddress.String);
                for (x = &a->IpAddressList; x && m < 550; x = x->Next)
                    m += wsprintfA(t + m, " %s/%s", (LPSTR)x->IpAddress.String, (LPSTR)x->IpMask.String);
                m += wsprintfA(t + m, "  gw");
                for (x = &a->GatewayList; x && m < 650; x = x->Next) {
                    m += wsprintfA(t + m, " %s", (LPSTR)x->IpAddress.String);
                    if (!gateway) {
                        DWORD g = inet_addr(x->IpAddress.String);
                        if (g && g != INADDR_NONE) gateway = g;
                    }
                }
                o("%s", (LPSTR)t);
            }
        } else {
            o("[NET] GetAdaptersInfo: error %lu", r);
        }
    }
    if (is_nt) nt_tcpip_config();
}

static DWORD st_ip[23], st_udp[5], st_tcp[15], st_icmp[26];
static DWORD st_ip0[23], st_udp0[5], st_tcp0[15], st_icmp0[26];

static void stats_line(const char *label, PFN_STAT fn, DWORD *v, DWORD *before, int n, const char *const *names,
                       int after)
{
    char t[1000];
    int i, m;
    DWORD r;
    if (!fn) { o("[NET] %s: not exported", (LPSTR)label); return; }
    mset(v, 0, (DWORD)n * 4);
    r = fn(v);
    if (r) { o("[NET] %s: error %lu", (LPSTR)label, r); return; }
    m = wsprintfA(t, "[NET] %s%s:", (LPSTR)label, (LPSTR)(after ? " after the tests (change)" : ""));
    for (i = 0; i < n; i++) {
        if (after) {
            if (v[i] == before[i]) continue;
            m += wsprintfA(t + m, " %s=%lu(%s%ld)", (LPSTR)names[i], v[i], (LPSTR)(v[i] >= before[i] ? "+" : ""),
                           (long)(v[i] - before[i]));
        } else {
            m += wsprintfA(t + m, " %s=%lu", (LPSTR)names[i], v[i]);
        }
        if (m > 850) { o("%s", (LPSTR)t); m = wsprintfA(t, "[NET] %s (cont.):", (LPSTR)label); }
    }
    o("%s", (LPSTR)t);
    if (!after) mcpy(before, v, (DWORD)n * 4);
}

static const char *const n_ip[23] = { "forwarding", "ttl", "InReceives", "InHdrErrors", "InAddrErrors",
    "ForwDatagrams", "InUnknownProtos", "InDiscards", "InDelivers", "OutRequests", "RoutingDiscards",
    "OutDiscards", "OutNoRoutes", "ReasmTimeout", "ReasmReqds", "ReasmOks", "ReasmFails", "FragOks",
    "FragFails", "FragCreates", "NumIf", "NumAddr", "NumRoutes" };
static const char *const n_udp[5] = { "InDatagrams", "NoPorts", "InErrors", "OutDatagrams", "NumAddrs" };
static const char *const n_tcp[15] = { "RtoAlgorithm", "RtoMin", "RtoMax", "MaxConn", "ActiveOpens",
    "PassiveOpens", "AttemptFails", "EstabResets", "CurrEstab", "InSegs", "OutSegs", "RetransSegs", "InErrs",
    "OutRsts", "NumConns" };
static const char *const n_icmp[26] = { "in.Msgs", "in.Errors", "in.DestUnreachs", "in.TimeExcds",
    "in.ParmProbs", "in.SrcQuenchs", "in.Redirects", "in.Echos", "in.EchoReps", "in.Timestamps",
    "in.TimestampReps", "in.AddrMasks", "in.AddrMaskReps", "out.Msgs", "out.Errors", "out.DestUnreachs",
    "out.TimeExcds", "out.ParmProbs", "out.SrcQuenchs", "out.Redirects", "out.Echos", "out.EchoReps",
    "out.Timestamps", "out.TimestampReps", "out.AddrMasks", "out.AddrMaskReps" };

static void sec_iphlp_stats(int after)
{
    iphlp_load();
    if (!iphlp) return;
    stats_line("IP", p_ips, st_ip, st_ip0, 23, n_ip, after);
    stats_line("UDP", p_udps, st_udp, st_udp0, 5, n_udp, after);
    stats_line("TCP", p_tcps, st_tcp, st_tcp0, 15, n_tcp, after);
    stats_line("ICMP", p_icmps, st_icmp, st_icmp0, 26, n_icmp, after);
}

/* --- Winsock tests ------------------------------------------------------- */
static int ws_ok;
static BYTE pkt[2048];

static int sock_wait(SOCKET s, int write, DWORD ms)
{
    fd_set r, w, e;
    struct timeval tv;
    r.fd_count = w.fd_count = e.fd_count = 0;
    if (write) { w.fd_count = 1; w.fd_array[0] = s; e.fd_count = 1; e.fd_array[0] = s; }
    else { r.fd_count = 1; r.fd_array[0] = s; }
    tv.tv_sec = (long)(ms / 1000);
    tv.tv_usec = (long)((ms % 1000) * 1000);
    if (select(0, &r, &w, &e, &tv) <= 0) return 0;
    if (write) return w.fd_count ? 1 : -1;      /* except set: connect failed */
    return 1;
}

static int dns_query(BYTE *q, WORD id, const char *name)
{
    int n = 12, lab = 0, i;
    mset(q, 0, 12);
    q[0] = (BYTE)(id >> 8); q[1] = (BYTE)id;
    q[2] = 0x01;                                /* RD */
    q[5] = 1;                                   /* QDCOUNT */
    lab = n++;
    for (i = 0; name[i]; i++) {
        if (name[i] == '.') { q[lab] = (BYTE)(n - lab - 1); lab = n++; }
        else q[n++] = (BYTE)name[i];
    }
    q[lab] = (BYTE)(n - lab - 1);
    q[n++] = 0;
    q[n++] = 0; q[n++] = 1;                     /* A */
    q[n++] = 0; q[n++] = 1;                     /* IN */
    return n;
}

static int dns_skip_name(const BYTE *r, int n, int p)
{
    while (p < n) {
        if (r[p] == 0) return p + 1;
        if ((r[p] & 0xC0) == 0xC0) return p + 2;
        p += r[p] + 1;
    }
    return n;
}

/* summary of a DNS reply; *First = first A record (network order) */
static void dns_answer(char *t, const BYTE *r, int n, WORD id, DWORD *first)
{
    int p, an, i, m;
    *first = 0;
    if (n < 12) { wsprintfA(t, "short reply (%d bytes)", n); return; }
    an = (r[6] << 8) | r[7];
    m = wsprintfA(t, "%d bytes id %s rcode %u an %d ns %d ar %d tc %u:", n,
                  (LPSTR)(((r[0] << 8) | r[1]) == id ? "ok" : "MISMATCH"), (unsigned)(r[3] & 15), an,
                  (r[8] << 8) | r[9], (r[10] << 8) | r[11], (unsigned)((r[2] >> 1) & 1));
    p = dns_skip_name(r, n, 12) + 4;
    for (i = 0; i < an && p + 10 <= n && m < 400; i++) {
        int type, len;
        p = dns_skip_name(r, n, p);
        if (p + 10 > n) break;
        type = (r[p] << 8) | r[p + 1];
        len = (r[p + 8] << 8) | r[p + 9];
        p += 10;
        if (type == 1 && len == 4 && p + 4 <= n) {
            char a[20];
            DWORD v = *(const DWORD *)(r + p);
            ipstr(a, v);
            m += wsprintfA(t + m, " A %s", (LPSTR)a);
            if (!*first) *first = v;
        } else {
            m += wsprintfA(t + m, " type %d (%d bytes)", type, len);
        }
        p += len;
    }
}

static DWORD resolved;      /* frogfind.com from any test, network order */

static void udp_dns(DWORD server, const char *why)
{
    SOCKET s;
    struct sockaddr_in a, from;
    int n, fl = sizeof(from), q;
    WORD id = (WORD)(GetTickCount() ^ server);
    DWORD t0, first;
    char srv[20], t[600];
    ipstr(srv, server);
    s = socket(AF_INET, SOCK_DGRAM, 0);
    if (s == INVALID_SOCKET) { o("[NET] UDP DNS %s (%s): socket error %d", (LPSTR)srv, (LPSTR)why, WSAGetLastError()); return; }
    mset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(53);
    a.sin_addr.s_addr = server;
    q = dns_query(pkt, id, TEST_HOST);
    t0 = GetTickCount();
    if (sendto(s, (char *)pkt, q, 0, (struct sockaddr *)&a, sizeof(a)) != q) {
        o("[NET] UDP DNS %s (%s): sendto error %d", (LPSTR)srv, (LPSTR)why, WSAGetLastError());
        closesocket(s);
        return;
    }
    if (sock_wait(s, 0, 3000) <= 0) {
        o("[NET] UDP DNS %s (%s): query %d bytes sent, NO REPLY in 3000 ms", (LPSTR)srv, (LPSTR)why, q);
        closesocket(s);
        return;
    }
    n = recvfrom(s, (char *)pkt, sizeof(pkt), 0, (struct sockaddr *)&from, &fl);
    if (n <= 0) {
        o("[NET] UDP DNS %s (%s): recvfrom error %d after %lu ms", (LPSTR)srv, (LPSTR)why, WSAGetLastError(),
          GetTickCount() - t0);
    } else {
        char f[20];
        dns_answer(t, pkt, n, id, &first);
        ipstr(f, from.sin_addr.s_addr);
        o("[NET] UDP DNS %s (%s): reply after %lu ms from %s:%u: %s", (LPSTR)srv, (LPSTR)why, GetTickCount() - t0,
          (LPSTR)f, (unsigned)ntohs(from.sin_port), (LPSTR)t);
        ohex("[NET]   reply", pkt, (DWORD)(n > 96 ? 96 : n));
        if (first && !resolved) resolved = first;
    }
    closesocket(s);
}

/* TCP connect with a timeout; INVALID_SOCKET on failure (reason logged) */
static SOCKET tcp_open(DWORD ip, WORD port, const char *label, DWORD *ms)
{
    SOCKET s = socket(AF_INET, SOCK_STREAM, 0);
    struct sockaddr_in a;
    u_long nb = 1;
    DWORD t0 = GetTickCount();
    int r;
    char t[20];
    ipstr(t, ip);
    if (s == INVALID_SOCKET) { o("[NET] %s %s:%u: socket error %d", (LPSTR)label, (LPSTR)t, port, WSAGetLastError()); return s; }
    ioctlsocket(s, FIONBIO, &nb);
    mset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(port);
    a.sin_addr.s_addr = ip;
    r = connect(s, (struct sockaddr *)&a, sizeof(a));
    if (r == SOCKET_ERROR && WSAGetLastError() != WSAEWOULDBLOCK) {
        o("[NET] %s %s:%u: connect error %d", (LPSTR)label, (LPSTR)t, port, WSAGetLastError());
        closesocket(s);
        return INVALID_SOCKET;
    }
    if (r == SOCKET_ERROR) {
        r = sock_wait(s, 1, 4000);
        if (r <= 0) {
            o("[NET] %s %s:%u: %s after %lu ms", (LPSTR)label, (LPSTR)t, port,
              (LPSTR)(r < 0 ? "connect REFUSED / failed" : "connect TIMEOUT"), GetTickCount() - t0);
            closesocket(s);
            return INVALID_SOCKET;
        }
    }
    nb = 0;
    ioctlsocket(s, FIONBIO, &nb);
    *ms = GetTickCount() - t0;
    return s;
}

static int recv_wait(SOCKET s, BYTE *b, int cap, DWORD ms)
{
    int got = 0, n;
    DWORD t0 = GetTickCount();
    while (got < cap) {
        DWORD left = GetTickCount() - t0;
        if (left >= ms) break;
        if (sock_wait(s, 0, ms - left) <= 0) break;
        n = recv(s, (char *)b + got, cap - got, 0);
        if (n <= 0) break;
        got += n;
        if (got >= 2 && b == pkt && (DWORD)got >= 2 + (DWORD)((pkt[0] << 8) | pkt[1]) && cap == sizeof(pkt)) break;
    }
    return got;
}

static void tcp_dns(DWORD server)
{
    DWORD ms, first;
    SOCKET s = tcp_open(server, 53, "TCP DNS", &ms);
    WORD id = (WORD)(GetTickCount() ^ 0x5A5A);
    int q, n;
    char t[600], srv[20];
    if (s == INVALID_SOCKET) return;
    ipstr(srv, server);
    q = dns_query(pkt + 2, id, TEST_HOST);
    pkt[0] = (BYTE)(q >> 8); pkt[1] = (BYTE)q;
    send(s, (char *)pkt, q + 2, 0);
    n = recv_wait(s, pkt, sizeof(pkt), 4000);
    if (n > 2) {
        dns_answer(t, pkt + 2, n - 2, id, &first);
        o("[NET] TCP DNS %s:53: connected in %lu ms, reply: %s", (LPSTR)srv, ms, (LPSTR)t);
        if (first && !resolved) resolved = first;
    } else {
        o("[NET] TCP DNS %s:53: connected in %lu ms, NO REPLY (%d bytes)", (LPSTR)srv, ms, n);
    }
    closesocket(s);
}

static void http_get(const char *host, DWORD ip, const char *how)
{
    static BYTE page[4096];
    DWORD ms;
    SOCKET s;
    char req[200];
    int n, i;
    char t[20];
    ipstr(t, ip);
    o("[NET] HTTP GET http://%s/ at %s (%s):", (LPSTR)host, (LPSTR)t, (LPSTR)how);
    s = tcp_open(ip, 80, "  HTTP", &ms);
    if (s == INVALID_SOCKET) return;
    n = wsprintfA(req, "GET / HTTP/1.0\r\nHost: %s\r\nUser-Agent: USOSLOG/" VERSION "\r\nConnection: close\r\n\r\n",
                  (LPSTR)host);
    send(s, req, n, 0);
    n = recv_wait(s, page, sizeof(page) - 1, 6000);
    for (i = 0; i < n && page[i] != '\r' && page[i] != '\n'; i++) ;
    page[i < n ? i : (n > 0 ? n : 0)] = 0;
    o("[NET]   connected in %lu ms, %d bytes, status line \"%s\"", ms, n, (LPSTR)page);
    closesocket(s);
}

static void http_site(const char *host, DWORD ip, const char *fallback)
{
    if (ip) http_get(host, ip, "resolved");
    if (!ip || ip != inet_addr(fallback)) http_get(host, inet_addr(fallback), "embedded address");
}

static void log_request(void)
{
    SOCKET s = socket(AF_INET, SOCK_DGRAM, 0);
    struct sockaddr_in a;
    BOOL on = TRUE;
    int r;
    if (s == INVALID_SOCKET) return;
    setsockopt(s, SOL_SOCKET, SO_BROADCAST, (char *)&on, sizeof(on));
    mset(&a, 0, sizeof(a));
    a.sin_family = AF_INET;
    a.sin_port = htons(LOG_PORT);
    a.sin_addr.s_addr = INADDR_BROADCAST;
    r = sendto(s, "USOSLOG", 7, 0, (struct sockaddr *)&a, sizeof(a));
    o("[NET] usosnet log request broadcast (UDP 255.255.255.255:%u): %s", LOG_PORT,
      (LPSTR)(r == 7 ? "sent" : "sendto failed"));
    closesocket(s);
}

static void sec_tests(void)
{
    WSADATA wd;
    struct hostent *h;
    DWORD t0, a;
    char t[20], cfg[256];
    int i;
    if (opt_nonet) { o("[NET] active tests skipped (/nonet)"); return; }
    if (!winsock_load()) { o("[NET] WSOCK32.DLL not loadable (no TCP/IP installed?): tests skipped"); return; }
    if (!ws_ok) {
        int r = WSAStartup(0x0101, &wd);
        if (r) { o("[NET] WSAStartup error %d", r); return; }
        ws_ok = 1;
        o("[NET] Winsock \"%s\" version %04X", (LPSTR)wd.szDescription, (unsigned)wd.wVersion);
    }
    ping_gateway();
    t0 = GetTickCount();
    h = gethostbyname(TEST_HOST);
    if (h && h->h_addr_list && h->h_addr_list[0]) {
        mcpy(&a, h->h_addr_list[0], 4);
        ipstr(t, a);
        o("[NET] gethostbyname(%s): %s after %lu ms", (LPSTR)TEST_HOST, (LPSTR)t, GetTickCount() - t0);
        resolved = a;
    } else {
        o("[NET] gethostbyname(%s): FAILED error %d after %lu ms", (LPSTR)TEST_HOST, WSAGetLastError(), GetTickCount() - t0);
    }
    t0 = GetTickCount();
    h = gethostbyname("example.com");
    o("[NET] gethostbyname(example.com): %s error %d after %lu ms", (LPSTR)(h ? "ok" : "FAILED"),
      h ? 0 : WSAGetLastError(), GetTickCount() - t0);
    /* configured servers: IPHLPAPI + MSTCP NameServer (comma / space list) */
    if (reg_str(HKEY_LOCAL_MACHINE, is_nt ? "System\\CurrentControlSet\\Services\\Tcpip\\Parameters" :
                "System\\CurrentControlSet\\Services\\VxD\\MSTCP", "NameServer", cfg, sizeof(cfg))) {
        char *p = cfg;
        while (*p) {
            char one[20];
            int k = 0;
            while (*p == ',' || *p == ' ') p++;
            while (*p && *p != ',' && *p != ' ' && k < 19) one[k++] = *p++;
            one[k] = 0;
            if (k) add_dns(inet_addr(one));
        }
    }
    udp_dns(inet_addr("1.1.1.1"), "fixed");
    udp_dns(inet_addr("8.8.8.8"), "fixed");
    if (gateway) udp_dns(gateway, "gateway");
    else udp_dns(inet_addr("192.168.0.1"), "fixed gateway");
    for (i = 0; i < ndns_cfg; i++) {
        if (dns_cfg[i] == inet_addr("1.1.1.1") || dns_cfg[i] == inet_addr("8.8.8.8") || dns_cfg[i] == gateway) continue;
        udp_dns(dns_cfg[i], "configured");
    }
    tcp_dns(inet_addr("1.1.1.1"));
    {
        DWORD ms;
        SOCKET s = tcp_open(gateway ? gateway : inet_addr("192.168.0.1"), 80, "TCP connect", &ms);
        if (s != INVALID_SOCKET) {
            ipstr(t, gateway ? gateway : inet_addr("192.168.0.1"));
            o("[NET] TCP connect %s:80: connected in %lu ms", (LPSTR)t, ms);
            closesocket(s);
        }
    }
    http_site(TEST_HOST, resolved, FALLBACK_IP);
    t0 = GetTickCount();
    h = gethostbyname(CONTROL_HOST);
    a = 0;
    if (h && h->h_addr_list && h->h_addr_list[0]) mcpy(&a, h->h_addr_list[0], 4);
    o("[NET] gethostbyname(%s): %s error %d after %lu ms", (LPSTR)CONTROL_HOST, (LPSTR)(a ? "ok" : "FAILED"),
      a ? 0 : WSAGetLastError(), GetTickCount() - t0);
    http_site(CONTROL_HOST, a, CONTROL_IP);
}

static DWORD ndis_off = 0xFFFFFFFFUL;

static void sec_ndislog(void)
{
    static char nb[16384];
    DWORD size = file_size("C:\\WINDOWS\\NDISLOG.TXT");
    int n;
    if (size == 0xFFFFFFFFUL) { o("[NET] C:\\WINDOWS\\NDISLOG.TXT: missing"); return; }
    if (ndis_off == 0xFFFFFFFFUL) ndis_off = size > 4096 ? size - 4096 : 0;
    if (size < ndis_off) ndis_off = 0;
    if (size == ndis_off) { o("[NET] NDISLOG.TXT: %lu bytes, nothing new", size); return; }
    n = read_file("C:\\WINDOWS\\NDISLOG.TXT", nb, sizeof(nb), ndis_off);
    o("[NET] NDISLOG.TXT: %lu bytes, new from %lu:", size, ndis_off);
    if (n > 0) { otext("    | ", nb, (DWORD)n); ndis_off += (DWORD)n; }
}

#ifdef USOS_NT3_RAW_ICMP
#include "usoslog_rawicmp.h"
#endif

static void sec_net_config(void)
{
    HKEY k;
    DWORD i, nl;
    char sub[64], path[160], desc[160];
    FILETIME ft;
    o("[NET] adapters (Class\\Net):");
    find_usosnet(1);
    o("[NET] MSTCP / NetTrans / DHCP / proxy:");
    if (is_nt) {
        reg_dump(HKEY_LOCAL_MACHINE, "HKLM", "System\\CurrentControlSet\\Services\\Tcpip\\Parameters", 64);
        reg_dump_sub(HKEY_LOCAL_MACHINE, "HKLM", "System\\CurrentControlSet\\Services\\Tcpip\\Parameters\\Interfaces", 64, 16);
        reg_dump(HKEY_CURRENT_USER, "HKCU", "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 32);
        return;
    }
    reg_dump(HKEY_LOCAL_MACHINE, "HKLM", "System\\CurrentControlSet\\Services\\VxD\\MSTCP", 64);
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "System\\CurrentControlSet\\Services\\Class\\NetTrans", 0, KEY_READ, &k) == ERROR_SUCCESS) {
        for (i = 0; i < 32; i++) {
            nl = sizeof(sub);
            if (RegEnumKeyExA(k, i, sub, &nl, 0, 0, 0, &ft) != ERROR_SUCCESS) break;
            wsprintfA(path, "System\\CurrentControlSet\\Services\\Class\\NetTrans\\%s", (LPSTR)sub);
            reg_str(HKEY_LOCAL_MACHINE, path, "DriverDesc", desc, sizeof(desc));
            if (has_text(desc, "TCP")) reg_dump(HKEY_LOCAL_MACHINE, "HKLM", path, 64);
            else o("  [HKLM\\%s] \"%s\"", (LPSTR)path, (LPSTR)desc);
        }
        RegCloseKey(k);
    }
    reg_dump_sub(HKEY_LOCAL_MACHINE, "HKLM", "System\\CurrentControlSet\\Services\\VxD\\DHCP", 96, 8);
    reg_dump(HKEY_CURRENT_USER, "HKCU", "Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings", 32);
    dump_file("[NET] HOSTS", "C:\\WINDOWS\\HOSTS", 2048);
}

/* --- DISK: drive letters, IOS, SCSI registry, USOSDBG DISK -------------- */
/* docs/usb9x-hotswap-design-2026-10-19.md section 4. The drive APIs are
 * the Windows 95 KERNEL32 ones, looked up at run time like Toolhelp32 (the
 * static import list stays as it is). Floppy letters (A:, B:) and network
 * letters are never asked for a volume (no seek, no hang on a dead
 * server); critical errors are failed, not shown (SetErrorMode), so an
 * empty card reader or CD drive gives an error code, not a dialog.
 * GetDiskFreeSpaceA reports at most 2 GiB on 95 OSR2 / 98 / Me (the Ex
 * call is not used): "free" is a lower bound there. */
typedef DWORD (WINAPI *PFN_DRIVES)(void);
typedef UINT (WINAPI *PFN_DTYPE)(LPCSTR);
typedef BOOL (WINAPI *PFN_VOLINFO)(LPCSTR, LPSTR, DWORD, DWORD *, DWORD *, DWORD *, LPSTR, DWORD);
typedef BOOL (WINAPI *PFN_FREE)(LPCSTR, DWORD *, DWORD *, DWORD *, DWORD *);
typedef UINT (WINAPI *PFN_ERRMODE)(UINT);
static PFN_DRIVES p_drives;
static PFN_DTYPE p_dtype;
static PFN_VOLINFO p_volinfo;
static PFN_FREE p_free;
static PFN_ERRMODE p_errmode;

#define DBGTMPD     dbg_tmp_disk
#define DISK_SNAP_MS 2000               /* at most one USOSDBG DISK snapshot per 2 s */
#define DISK_VOL_EVERY 8                /* removable volume serials every 8 ticks (2 s) */

static CRITICAL_SECTION dbg_cs;         /* one USOSDBG at a time (worker / disk watcher) */
static void header(const char *kind);
static int opt_nodisk;

static void disk_api_load(HMODULE k32)
{
    if (!k32) return;
    p_drives = (PFN_DRIVES)GetProcAddress(k32, "GetLogicalDrives");
    p_dtype = (PFN_DTYPE)GetProcAddress(k32, "GetDriveTypeA");
    p_volinfo = (PFN_VOLINFO)GetProcAddress(k32, "GetVolumeInformationA");
    p_free = (PFN_FREE)GetProcAddress(k32, "GetDiskFreeSpaceA");
    p_errmode = (PFN_ERRMODE)GetProcAddress(k32, "SetErrorMode");
    if (p_errmode) p_errmode(0x0001 /* SEM_FAILCRITICALERRORS */);
}

static const char *drive_type_name(UINT t)
{
    switch (t) {
    case 0: return "unknown";
    case 1: return "no-root";
    case 2: return "removable";
    case 3: return "fixed";
    case 4: return "remote";
    case 5: return "cdrom";
    case 6: return "ramdisk";
    }
    return "?";
}

typedef struct {
    UINT type;
    int vol;                    /* 1 volume read, 0 failed (err), -1 not asked */
    DWORD serial, err;
    char fs[16], label[16];
} DRIVEINFO;

/* the volume of a letter is asked only for local non-floppy letters */
static int vol_wanted(int i, UINT t)
{
    return !(t == 4 || t == 1 || (t == 2 && i < 2));
}

static void drive_info(int i, DRIVEINFO *d, int with_vol)
{
    char root[4];
    DWORD maxc = 0, flags = 0;
    root[0] = (char)('A' + i); root[1] = ':'; root[2] = '\\'; root[3] = 0;
    mset(d, 0, sizeof(*d));
    d->type = p_dtype ? p_dtype(root) : 0;
    d->vol = -1;
    if (!with_vol || !p_volinfo || !vol_wanted(i, d->type)) return;
    if (p_volinfo(root, d->label, sizeof(d->label), &d->serial, &maxc, &flags, d->fs, sizeof(d->fs))) d->vol = 1;
    else { d->vol = 0; d->err = GetLastError(); d->label[0] = d->fs[0] = 0; d->serial = 0; }
}

/* "removable FAT32 serial 1A2B-3C4D label "X"" */
static void drive_text(char *t, const DRIVEINFO *d)
{
    int n = wsprintfA(t, "%s", (LPSTR)drive_type_name(d->type));
    if (d->vol < 0) wsprintfA(t + n, " (volume not asked)");
    else if (!d->vol) wsprintfA(t + n, " no volume (error %lu)", d->err);
    else wsprintfA(t + n, " %s serial %04lX-%04lX label \"%s\"", (LPSTR)(d->fs[0] ? d->fs : "?"), d->serial >> 16,
                   d->serial & 0xFFFF, (LPSTR)d->label);
}

/* cluster count * cluster size in MiB without 64-bit arithmetic */
static DWORD clusters_mib(DWORD clusters, DWORD cl)
{
    if (!cl) return 0;
    if (cl >= 0x100000UL) return clusters * (cl >> 20);
    return clusters / (0x100000UL / cl);
}

static void sec_drives(void)
{
    DWORD mask;
    int i;
    if (!p_drives) { o("[DISK] GetLogicalDrives not available"); return; }
    mask = p_drives();
    o("[DISK] drive letters (GetLogicalDrives %08lX):", mask);
    for (i = 0; i < 26; i++) {
        DRIVEINFO d;
        char t[200], root[4];
        DWORD spc = 0, bps = 0, fc = 0, tc = 0;
        int n;
        if (!(mask & (1UL << i))) continue;
        drive_info(i, &d, 1);
        drive_text(t, &d);
        n = lstrlenA(t);
        root[0] = (char)('A' + i); root[1] = ':'; root[2] = '\\'; root[3] = 0;
        if (d.vol == 1 && p_free && p_free(root, &spc, &bps, &fc, &tc))
            wsprintfA(t + n, "  free %lu/%lu MiB (%lu B clusters)",
                      clusters_mib(fc, spc * bps), clusters_mib(tc, spc * bps), spc * bps);
        else if (d.vol == 1)
            wsprintfA(t + n, "  free space: error %lu", GetLastError());
        o("[DISK] %c: %s", 'A' + i, (LPSTR)t);
    }
}

/* lines of a text file that contain one of Keys (case-insensitive) */
static void grep_lines(const char *label, const char *buf, int n, const char *const *keys, int max)
{
    char l[300];
    int i = 0, k, shown = 0, total = 0;
    while (i < n) {
        int j = 0, m;
        while (i < n && buf[i] != '\n' && buf[i] != '\r') { if (j < (int)sizeof(l) - 1) l[j++] = buf[i]; i++; }
        while (i < n && (buf[i] == '\n' || buf[i] == '\r')) i++;
        l[j] = 0;
        for (m = 0; m < j; m++) if ((BYTE)l[m] < 32) l[m] = ' ';
        for (k = 0; keys[k]; k++) if (has_text(l, keys[k])) break;
        if (!keys[k]) continue;
        total++;
        if (shown < max) { o("    | %s", (LPSTR)l); shown++; }
    }
    if (total > shown) o("%s (%d more matching lines not shown)", (LPSTR)label, total - shown);
    if (!total) o("%s (no matching line)", (LPSTR)label);
}

static char disk_fb[65536];

static void copy_file(const char *to, const char *buf, int n)
{
    HANDLE f;
    DWORD w = 0;
    f = CreateFileA(to, GENERIC_WRITE, FILE_SHARE_READ, 0, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (f == INVALID_HANDLE_VALUE) { o("[DISK]   copy to %s failed, error %lu", (LPSTR)to, GetLastError()); return; }
    WriteFile(f, buf, (DWORD)n, &w, 0);
    FlushFileBuffers(f);
    CloseHandle(f);
    o("[DISK]   copied to %s (%lu bytes)", (LPSTR)to, w);
}

static void sec_ios(void)
{
    static const char *const ios_keys[] = { "real mode", "real-mode", "compatibility", "MS-DOS compat", 0 };
    static const char *const boot_keys[] = { "[IOS]", "KRNL386", "IOSUBSYS", ".MPD", ".PDR", 0 };
    DWORD size;
    int n;
    size = file_size("C:\\WINDOWS\\IOS.LOG");
    if (size == 0xFFFFFFFFUL) {
        o("[DISK] C:\\WINDOWS\\IOS.LOG: none (no unit in MS-DOS compatibility mode logged)");
    } else {
        n = read_file("C:\\WINDOWS\\IOS.LOG", disk_fb, sizeof(disk_fb), 0);
        o("[DISK] C:\\WINDOWS\\IOS.LOG: %lu bytes%s", size, (LPSTR)(size >= sizeof(disk_fb) ? " (first 64 KiB read)" : ""));
        if (n > 0) {
            char ios_copy[MAX_PATH];
            lstrcpyA(ios_copy, LOGDIR); lstrcatA(ios_copy, "\\IOS.LOG");
            copy_file(ios_copy, disk_fb, n);
            o("[DISK] IOS.LOG real mode / MS-DOS compatibility lines:");
            grep_lines("[DISK] IOS.LOG", disk_fb, n, ios_keys, 40);
        }
    }
    size = file_size("C:\\BOOTLOG.TXT");
    if (size == 0xFFFFFFFFUL) {
        o("[DISK] C:\\BOOTLOG.TXT: none");
    } else {
        DWORD from = size > sizeof(disk_fb) - 1 ? size - (sizeof(disk_fb) - 1) : 0;
        n = read_file("C:\\BOOTLOG.TXT", disk_fb, sizeof(disk_fb), from);
        o("[DISK] C:\\BOOTLOG.TXT: %lu bytes, IOS / KRNL386 / port driver lines from +%lu:", size, from);
        if (n > 0) grep_lines("[DISK] BOOTLOG.TXT", disk_fb, n, boot_keys, 80);
    }
}

/* one value of Key as text (string, dword, binary bytes); "-" missing */
static void reg_value_text(HKEY k, const char *name, char *t, int cap)
{
    DWORD type = 0, dl = sizeof(rdata) - 1, j;
    int m = 0;
    if (RegQueryValueExA(k, (LPSTR)name, 0, &type, rdata, &dl) != ERROR_SUCCESS) { lstrcpyA(t, "-"); return; }
    rdata[dl < sizeof(rdata) ? dl : sizeof(rdata) - 1] = 0;
    if (type == REG_SZ || type == REG_EXPAND_SZ) { t[0] = '"'; compat_strcopy(t + 1, (char *)rdata, cap - 2); lstrcatA(t, "\""); return; }
    if (type == REG_DWORD && dl == 4) { wsprintfA(t, "dword:%08lX", *(DWORD *)rdata); return; }
    m = wsprintfA(t, "hex:");
    for (j = 0; j < dl && j < 16 && m < cap - 4; j++) m += wsprintfA(t + m, "%02X", (unsigned)rdata[j]);
}

static void sec_scsi_registry(void)
{
    HKEY k, k2, k3;
    DWORD i, j, nl;
    char a[128], b[128], path[400], v1[64], v2[64], v3[300];
    FILETIME ft;
    o("[DISK] registry Enum\\Root\\SCSIAdapter:");
    reg_dump_sub(HKEY_LOCAL_MACHINE, "HKLM", "Enum\\Root\\SCSIAdapter", 32, 16);
    o("[DISK] registry Enum\\SCSI (CurrentDriveLetterAssignment, Removable, HardwareID):");
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "Enum\\SCSI", 0, KEY_READ, &k) != ERROR_SUCCESS) {
        o("  [HKLM\\Enum\\SCSI] (missing)");
    } else {
        for (i = 0; i < 64; i++) {
            nl = sizeof(a);
            if (RegEnumKeyExA(k, i, a, &nl, 0, 0, 0, &ft) != ERROR_SUCCESS) break;
            if (RegOpenKeyExA(k, a, 0, KEY_READ, &k2) != ERROR_SUCCESS) continue;
            for (j = 0; j < 16; j++) {
                nl = sizeof(b);
                if (RegEnumKeyExA(k2, j, b, &nl, 0, 0, 0, &ft) != ERROR_SUCCESS) break;
                if (RegOpenKeyExA(k2, b, 0, KEY_READ, &k3) != ERROR_SUCCESS) continue;
                reg_value_text(k3, "CurrentDriveLetterAssignment", v1, sizeof(v1));
                reg_value_text(k3, "Removable", v2, sizeof(v2));
                reg_value_text(k3, "HardwareID", v3, sizeof(v3));
                o("  SCSI\\%s\\%s  letter %s  removable %s  hwid %s", (LPSTR)a, (LPSTR)b, (LPSTR)v1, (LPSTR)v2, (LPSTR)v3);
                RegCloseKey(k3);
            }
            RegCloseKey(k2);
        }
        RegCloseKey(k);
    }
    o("[DISK] registry Services\\Class\\SCSIAdapter (PortDriver):");
    if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, "System\\CurrentControlSet\\Services\\Class\\SCSIAdapter", 0, KEY_READ, &k) !=
        ERROR_SUCCESS) {
        o("  [HKLM\\System\\CurrentControlSet\\Services\\Class\\SCSIAdapter] (missing)");
        return;
    }
    for (i = 0; i < 64; i++) {
        nl = sizeof(a);
        if (RegEnumKeyExA(k, i, a, &nl, 0, 0, 0, &ft) != ERROR_SUCCESS) break;
        wsprintfA(path, "System\\CurrentControlSet\\Services\\Class\\SCSIAdapter\\%s", (LPSTR)a);
        if (RegOpenKeyExA(HKEY_LOCAL_MACHINE, path, 0, KEY_READ, &k2) != ERROR_SUCCESS) continue;
        reg_value_text(k2, "PortDriver", v1, sizeof(v1));
        reg_value_text(k2, "DriverDesc", v3, sizeof(v3));
        o("  SCSIAdapter\\%s  PortDriver %s  DriverDesc %s", (LPSTR)a, (LPSTR)v1, (LPSTR)v3);
        RegCloseKey(k2);
    }
    RegCloseKey(k);
}

/* USOSDBG /L <tmp> /D: the DISK section from one snapshot, lines indented */
static char dbgd_text[32768];

static void run_usosdbg_disk(const char *why)
{
    STARTUPINFOA si;
    PROCESS_INFORMATION pi;
    char cmd[MAX_PATH * 2 + 64];
    DWORD t0, w;
    int n, ended;
    if (opt_nodbg || opt_dbgfile[0]) { o("[DISK] USOSDBG DISK snapshot skipped (%s)", (LPSTR)(opt_nodbg ? "/nodbg" : "/dbgfile")); return; }
    if (is_nt) { o("[DISK] USOSDBG DISK snapshot skipped: Windows NT family"); return; }
    if (g_ending) { o("[DISK] USOSDBG DISK snapshot skipped: Windows is ending the session"); return; }
    if (file_size(DBGEXE) == 0xFFFFFFFFUL) { o("[DISK] %s missing", (LPSTR)DBGEXE); return; }
    EnterCriticalSection(&dbg_cs);
    DeleteFileA(DBGTMPD);
    wsprintfA(cmd, "\"%s\" /L \"%s\" /D", (LPSTR)DBGEXE, (LPSTR)DBGTMPD);
    mset(&si, 0, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    t0 = GetTickCount();
    if (!CreateProcessA(0, cmd, 0, 0, FALSE, 0, 0, app_dir, &si, &pi)) {
        LeaveCriticalSection(&dbg_cs);
        o("[DISK] %s: CreateProcess failed, error %lu", (LPSTR)cmd, GetLastError());
        return;
    }
    CloseHandle(pi.hThread);
    w = WaitForSingleObject(pi.hProcess, 10000);
    CloseHandle(pi.hProcess);
    ended = 0;
    for (;;) {                          /* a Win16 task's handle may signal early: the END line decides */
        n = read_file(DBGTMPD, dbgd_text, sizeof(dbgd_text), 0);
        if (n > 0 && has_text(dbgd_text, "USOSDBG END")) { ended = 1; break; }
        if (GetTickCount() - t0 > 12000) break;
        Sleep(250);
    }
    LeaveCriticalSection(&dbg_cs);
    o("[DISK] USOSDBG DISK snapshot (%s): %s  (%lu ms, wait %s, %s)", (LPSTR)why, (LPSTR)cmd, GetTickCount() - t0,
      (LPSTR)(w == WAIT_OBJECT_0 ? "exited" : "timeout"), (LPSTR)(ended ? "complete" : "INCOMPLETE"));
    if (n > 0) otext("  ", dbgd_text, (DWORD)n);
    else o("[DISK]   no output file");
}

static void sec_disk(void)
{
    if (opt_nodisk) { o("[DISK] skipped (/nodisk)"); return; }
    sec_drives();
    sec_ios();
    sec_scsi_registry();
    run_usosdbg_disk("start");
}

/* the watcher thread: GetLogicalDrives every WATCH_MS (as the process
 * watcher), removable volume serials every DISK_VOL_EVERY ticks; volume
 * calls can wait for the drive, so they run here, not on the main thread
 * (the journal hook's thread). A change is written at once as its own
 * record (with ev() lines for the PROC timeline) and followed by a USOSDBG
 * DISK snapshot, at most one per DISK_SNAP_MS; one that falls inside the
 * interval is taken when it ends. */

DWORD WINAPI disk_watch(LPVOID arg)
{
    DRIVEINFO cur[26];
    DWORD mask = 0, last_snap = 0, ticks = 0;
    int i, pending = 0, have_snap = 0;
    (void)arg;
    disk_tid = GetCurrentThreadId();
    if (!p_drives) return 0;
    mask = p_drives();
    for (i = 0; i < 26; i++) if (mask & (1UL << i)) drive_info(i, &cur[i], 1);
    for (;;) {
        DWORD now, m;
        int changed = 0;
        Sleep(WATCH_MS);
        if (g_ending) continue;         /* no volume calls while Windows shuts the drives down */
        ticks++;
        now = GetTickCount();
        m = p_drives();
        for (i = 0; i < 26; i++) {
            DWORD bit = 1UL << i;
            char t[200];
            if ((m & bit) && !(mask & bit)) {
                drive_info(i, &cur[i], 1);
                drive_text(t, &cur[i]);
                if (!changed++) { header("disk change"); }
                o("[DISK] +drive %c: %s", 'A' + i, (LPSTR)t);
                ev("+drive %c: %s", 'A' + i, (LPSTR)t);
            } else if (!(m & bit) && (mask & bit)) {
                if (!changed++) { header("disk change"); }
                o("[DISK] -drive %c:", 'A' + i);
                ev("-drive %c:", 'A' + i);
            } else if ((m & bit) && ticks % DISK_VOL_EVERY == 0 && cur[i].type == 2 && i >= 2) {
                DRIVEINFO d;
                drive_info(i, &d, 1);
                if (d.vol != cur[i].vol || d.serial != cur[i].serial) {
                    char was[200];
                    drive_text(was, &cur[i]);
                    drive_text(t, &d);
                    if (!changed++) { header("disk change"); }
                    o("[DISK] media %c: changed: %s (was %s)", 'A' + i, (LPSTR)t, (LPSTR)was);
                    ev("media %c: changed: %s (was %s)", 'A' + i, (LPSTR)t, (LPSTR)was);
                    mcpy(&cur[i], &d, sizeof(d));
                }
            }
        }
        mask = m;
        if (changed) pending = 1;
        if (pending && (!have_snap || now - last_snap >= DISK_SNAP_MS)) {
            if (!changed) { header("disk change (delayed snapshot)"); }
            run_usosdbg_disk(changed ? "drive change" : "drive change, delayed by the 2 s limit");
            last_snap = GetTickCount();
            have_snap = 1;
            pending = 0;
            changed = 1;
        }
        if (changed) flush_out();
    }
}

/* --- PROC / START -------------------------------------------------------- */
static PROCREC snap_procs[MAXP];     /* worker thread only */
static HWND snap_wins[MAXW];

static void sec_proc(void)
{
    int n, i, nw;
    n = proc_list(snap_procs, MAXP);
    if (n < 0) o("[PROC] Toolhelp32 not available");
    else o("[PROC] processes (%d):", n);
    for (i = 0; i < n; i++)
        o("    %08lX parent %08lX %s", snap_procs[i].pid, snap_procs[i].ppid, (LPSTR)snap_procs[i].exe);
    nw = win_list(snap_wins);
    o("[PROC] visible top-level windows (%d):", nw);
    for (i = 0; i < nw; i++) {
        char cls[64], title[128];
        DWORD pid = 0;
        cls[0] = title[0] = 0;
        GetClassNameA(snap_wins[i], cls, sizeof(cls));
        GetWindowTextA(snap_wins[i], title, sizeof(title));
        GetWindowThreadProcessId(snap_wins[i], &pid);
        o("    %08lX class \"%s\" title \"%s\" process %08lX%s", (DWORD)snap_wins[i], (LPSTR)cls, (LPSTR)title, pid,
          (LPSTR)(console_class(cls) ? "  <- console / DOS box" : ""));
    }
    EnterCriticalSection(&ev_cs);
    o("[PROC] watcher events since the last record (processes every %u ms%s, windows on a change or every %u ms; %lu ticks, %lu window scans; %lu lost):",
      WATCH_MS, (LPSTR)(p_snap ? "" : ": no Toolhelp32, windows only"),
      WATCH_MS * (p_snap ? WATCH_WIN_EVERY : 2), watch_ticks, watch_enums, ev_lost);
    oput(ev_buf, ev_len);
    if (ev_suppressed)
        o("[PROC] watcher: session limit of %u event lines reached, %lu more not logged", WATCH_EV_MAX, ev_suppressed);
    ev_len = 0;
    ev_lost = 0;
    LeaveCriticalSection(&ev_cs);
}

static void list_dir(const char *label, const char *dir)
{
    WIN32_FIND_DATAA fd;
    HANDLE h;
    char pat[MAX_PATH + 4];
    int n = 0;
    if (!dir[0]) { o("[START] %s: (no path)", (LPSTR)label); return; }
    compat_strcopy(pat, dir, MAX_PATH);
    lstrcatA(pat, "\\*.*");
    o("[START] %s: %s", (LPSTR)label, (LPSTR)dir);
    h = FindFirstFileA(pat, &fd);
    if (h == INVALID_HANDLE_VALUE) { o("    (empty or missing)"); return; }
    do {
        if (fd.cFileName[0] == '.') continue;
        o("    %s  %lu bytes%s", (LPSTR)fd.cFileName, fd.nFileSizeLow,
          (LPSTR)((fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) ? "  <dir>" : ""));
        n++;
    } while (FindNextFileA(h, &fd) && n < 100);
    FindClose(h);
}

static void sec_start(int full)
{
    char p[MAX_PATH], a[300];
    reg_str(HKEY_CURRENT_USER, "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders", "Startup", p, sizeof(p));
    list_dir("Startup (HKCU Shell Folders)", p);
    reg_str(HKEY_LOCAL_MACHINE, "Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Shell Folders", "Common Startup", p, sizeof(p));
    list_dir("Common Startup (HKLM Shell Folders)", p);
    o("[START] Run keys:");
    reg_dump(HKEY_LOCAL_MACHINE, "HKLM", "Software\\Microsoft\\Windows\\CurrentVersion\\Run", 32);
    reg_dump(HKEY_LOCAL_MACHINE, "HKLM", "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", 32);
    reg_dump(HKEY_LOCAL_MACHINE, "HKLM", "Software\\Microsoft\\Windows\\CurrentVersion\\RunServices", 32);
    reg_dump(HKEY_LOCAL_MACHINE, "HKLM", "Software\\Microsoft\\Windows\\CurrentVersion\\RunServicesOnce", 32);
    reg_dump(HKEY_CURRENT_USER, "HKCU", "Software\\Microsoft\\Windows\\CurrentVersion\\Run", 32);
    reg_dump(HKEY_CURRENT_USER, "HKCU", "Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", 32);
    GetProfileStringA("windows", "load", "", a, sizeof(a));
    o("[START] WIN.INI [windows] load=%s", (LPSTR)a);
    GetProfileStringA("windows", "run", "", a, sizeof(a));
    o("[START] WIN.INI [windows] run=%s", (LPSTR)a);
    GetPrivateProfileStringA("boot", "shell", "", a, sizeof(a), "SYSTEM.INI");
    o("[START] SYSTEM.INI [boot] shell=%s", (LPSTR)a);
    if (full) {
        dump_file("[START]", "C:\\AUTOEXEC.BAT", 3072);
        dump_file("[START]", "C:\\CONFIG.SYS", 3072);
        dump_file("[START]", "C:\\WINDOWS\\WINSTART.BAT", 2048);
    }
}

/* ------------------------------------------------------------------ */
static void header(const char *kind)
{
    char t[32];
    stamp(t);
    o("");
    o("=== USOSLOG %s %s #%d  %s  tick %lu  (running %lu s) ===", (LPSTR)VERSION, (LPSTR)kind, snap_no, (LPSTR)t,
      GetTickCount(), (GetTickCount() - t_start) / 1000);
}

static void start_record(void)
{
    header("start");
    sec_sys();
    sec_disk();
    flush_out();
    sec_start(1);
    sec_proc();
    flush_out();
}

static void snapshot(void)
{
    DWORD t0 = GetTickCount();
    snap_no++;
    header("snapshot");
    sec_sys();
    if (!opt_nodisk) sec_drives();
    sec_mouse();
    sec_wheel();
    find_usosnet(0);
    EnterCriticalSection(&dbg_cs);
    run_usosdbg(stats_pa);
    LeaveCriticalSection(&dbg_cs);
    flush_out();                        /* the mouse part is safe even if a test hangs */
    sec_net_config();
    sec_usns(0);
    sec_iphlp_config();
    sec_iphlp_stats(0);
    flush_out();
    sec_tests();
    sec_iphlp_stats(1);
    if (net_key[0]) sec_usns(1);
    if (!opt_nonet && ws_ok) log_request();
    sec_ndislog();
    sec_proc();
    if (snap_no % 6 == 0) sec_start(0);
    o("=== end of snapshot #%d (%lu ms) ===", snap_no, GetTickCount() - t0);
    flush_out();
}

/* Short record after the wheel was used: MOUSE part, USOSDBG, wheel lines. */
static void wheel_record(void)
{
    header("wheel record");
    sec_mouse();
    run_usosdbg(stats_pa);
    sec_wheel();
    o("=== end of wheel record ===");
    flush_out();
}

/* Sleep S seconds in 1 s steps; a wheel record when wheel lines wait and
 * the wheel has been quiet for WHEEL_REC_QUIET ms. */
static void wait_s(DWORD s)
{
    static DWORD recs, last_rec;
    DWORD end = GetTickCount() + s * 1000;
    while ((long)(end - GetTickCount()) > 0) {
        Sleep(1000);
        if (wh_pending && recs < WHEEL_REC_MAX && GetTickCount() - g_wheel_tick >= WHEEL_REC_QUIET &&
            (!recs || GetTickCount() - last_rec >= WHEEL_REC_GAP * 1000UL)) {
            recs++;
            wheel_record();
            last_rec = GetTickCount();
        }
    }
}

DWORD WINAPI worker(LPVOID arg)
{
    (void)arg;
    if (!opt_once) {
        start_record();
        wait_s(opt_first);
    }
    for (;;) {
        if (!g_ending) snapshot();
        if (opt_once) break;
        wait_s(opt_every);
    }
    PostThreadMessageA(main_tid, WM_QUIT, 0, 0);
    return 0;
}

/* ------------------------------------------------------------------ */
static void parse_args(void)
{
    char *c = GetCommandLineA(), arg[MAX_PATH];
    int n, first = 1, want = 0;
    for (;;) {
        while (*c == ' ' || *c == '\t') c++;
        if (!*c) break;
        n = 0;
        if (*c == '"') {
            c++;
            while (*c && *c != '"') { if (n < MAX_PATH - 1) arg[n++] = *c; c++; }
            if (*c) c++;
        } else {
            while (*c && *c != ' ' && *c != '\t') { if (n < MAX_PATH - 1) arg[n++] = *c; c++; }
        }
        arg[n] = 0;
        if (first) { first = 0; continue; }       /* program name */
        if (want == 1) { compat_strcopy(out_path, arg, MAX_PATH); opt_custom_out = 1; want = 0; continue; }
        if (want == 2) { opt_first = decval(arg); want = 0; continue; }
        if (want == 3) { opt_every = decval(arg); if (opt_every < 10) opt_every = 10; want = 0; continue; }
        if (want == 4) { compat_strcopy(opt_dbgfile, arg, MAX_PATH); want = 0; continue; }
        if (!lstrcmpiA(arg, "/once")) opt_once = 1;
        else if (!lstrcmpiA(arg, "/nonet")) opt_nonet = 1;
        else if (!lstrcmpiA(arg, "/nodbg")) opt_nodbg = 1;
        else if (!lstrcmpiA(arg, "/nohook")) opt_nohook = 1;
        else if (!lstrcmpiA(arg, "/nodisk")) opt_nodisk = 1;
        else if (!lstrcmpiA(arg, "/out")) want = 1;
        else if (!lstrcmpiA(arg, "/first")) want = 2;
        else if (!lstrcmpiA(arg, "/every")) want = 3;
        else if (!lstrcmpiA(arg, "/dbgfile")) want = 4;
    }
}

/* ------------------------------------------------------------------ */
/* end of the Windows session                                          */
/* A hidden top-level window gets WM_QUERYENDSESSION / WM_ENDSESSION (a
 * windowless process is only terminated). On the query: no new USOSDBG
 * (Win16 + DPMI child) or drive polls, journal hook removed, and a short
 * record (processes, watcher events) written at once; on the end: one
 * line, then ExitProcess, so nothing of USOSLOG is left to the forced
 * termination. Windows 95 X470 2026-10-20: shutdown hung at "Please wait
 * while your computer shuts down" in the first session with USOSLOG
 * resident; this record says whether USOSLOG saw and left the session. */
static char end_buf[24576];
static DWORD end_len;
static PROCREC end_procs[MAXP];         /* main thread only */

static void eo(const char *fmt, ...)
{
    char t[600];
    va_list ap;
    int n;
    va_start(ap, fmt);
    n = wvsprintfA(t, fmt, ap);
    va_end(ap);
    if (n < 0) n = 0;
    if (end_len + (DWORD)n + 2 >= sizeof(end_buf)) return;
    mcpy(end_buf + end_len, t, (DWORD)n);
    end_len += (DWORD)n;
    mcpy(end_buf + end_len, "\r\n", 2);
    end_len += 2;
}

static void end_write(void)
{
    HANDLE f;
    DWORD w;
    EnterCriticalSection(&file_cs);
    f = CreateFileA(out_path, GENERIC_WRITE, FILE_SHARE_READ, 0, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
    if (f != INVALID_HANDLE_VALUE) {
        SetFilePointer(f, 0, 0, FILE_END);
        WriteFile(f, end_buf, end_len, &w, 0);
        FlushFileBuffers(f);
        CloseHandle(f);
    }
    LeaveCriticalSection(&file_cs);
    end_len = 0;
}

static void end_query(LPARAM lp)
{
    char t[32];
    int n, i;
    DWORD take;
    g_ending = 1;
    if (g_hook) { UnhookWindowsHookEx(g_hook); g_hook = 0; }
    watch_tick();                       /* the last process / window changes */
    stamp(t);
    eo("");
    eo("=== USOSLOG %s session end  %s  tick %lu  (running %lu s) ===", (LPSTR)VERSION, (LPSTR)t, GetTickCount(),
       (GetTickCount() - t_start) / 1000);
    eo("[END] WM_QUERYENDSESSION lParam %08lX: journal hook removed, no new USOSDBG or drive polls", (DWORD)lp);
    n = proc_list(end_procs, MAXP);
    if (n >= 0) eo("[END] processes (%d):", n);
    for (i = 0; i < n; i++) eo("    %08lX parent %08lX %s", end_procs[i].pid, end_procs[i].ppid, (LPSTR)end_procs[i].exe);
    EnterCriticalSection(&ev_cs);
    eo("[END] watcher events since the last record:");
    take = ev_len;
    if (end_len + take + 2 >= sizeof(end_buf)) take = sizeof(end_buf) - end_len - 2;
    mcpy(end_buf + end_len, ev_buf, take);
    end_len += take;
    ev_len = 0;
    LeaveCriticalSection(&ev_cs);
    end_write();
}

static LRESULT CALLBACK end_wndproc(HWND w, UINT m, WPARAM wp, LPARAM lp)
{
    if (m == WM_QUERYENDSESSION) {
        end_query(lp);
        return TRUE;
    }
    if (m == WM_ENDSESSION) {
        char t[32];
        stamp(t);
        if (!wp) {
            g_ending = 0;
            eo("[END] %s WM_ENDSESSION FALSE: the session goes on; watching again", (LPSTR)t);
            end_write();
            return 0;
        }
        eo("[END] %s WM_ENDSESSION TRUE: USOSLOG exits now", (LPSTR)t);
        end_write();
        ExitProcess(0);
    }
    return DefWindowProcA(w, m, wp, lp);
}

static void end_window(void)
{
    WNDCLASSA wc;
    HINSTANCE hi = GetModuleHandleA(0);
    mset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = end_wndproc;
    wc.hInstance = hi;
    wc.lpszClassName = "USOSLOGSession";
    if (RegisterClassA(&wc))
        CreateWindowExA(0, "USOSLOGSession", "USOSLOG", WS_POPUP, 0, 0, 0, 0, 0, 0, hi, 0);
}

void __cdecl usos_entry(void)
{
    MSG msg;
    HANDLE th, mutex;
    HMODULE k32;
    DWORD tid, ticks = 0;
    UINT timer;
    t_start = GetTickCount();
    if (!logger_paths()) ExitProcess(2); /* no fallback outside the application */
    parse_args();
    {
        OSVERSIONINFOA v;
        mset(&v, 0, sizeof(v));
        v.dwOSVersionInfoSize = sizeof(v);
        if (compat_os_version(&v)) is_nt = v.dwPlatformId == VER_PLATFORM_WIN32_NT;
    }
    mutex = CreateMutexA(0, FALSE, "USOSLOG-instance");
    if (!opt_once && mutex && GetLastError() == ERROR_ALREADY_EXISTS) ExitProcess(0);
    InitializeCriticalSection(&ev_cs);
    InitializeCriticalSection(&file_cs);
    InitializeCriticalSection(&dbg_cs);
    k32 = GetModuleHandleA("KERNEL32.DLL");
    disk_api_load(k32);
    if (k32) {
        p_snap = (PFN_SNAP)GetProcAddress(k32, "CreateToolhelp32Snapshot");
        p_first = (PFN_PROC)GetProcAddress(k32, "Process32First");
        p_next = (PFN_PROC)GetProcAddress(k32, "Process32Next");
    }
    main_tid = GetCurrentThreadId();
    PeekMessageA(&msg, 0, 0, 0, PM_NOREMOVE);  /* message queue before the worker posts */
    watch_tick();
    hook_install();
    if (!opt_once) end_window();
    timer = SetTimer(0, 0, WATCH_MS, 0);
    th = CreateThread(0, 0, worker, 0, 0, &tid);
    if (!th) ExitProcess(1);
    if (!opt_once && !opt_nodisk && p_drives) {
        HANDLE dt = CreateThread(0, 0, disk_watch, 0, 0, &tid);
        if (dt) CloseHandle(dt);
    }
    while (GetMessageA(&msg, 0, 0, 0) > 0) {
        if (msg.message == WM_CANCELJOURNAL) { g_hook = 0; g_cancels++; continue; }
        if (msg.message == WM_TIMER && !msg.hwnd) {
            watch_tick();
            if (++ticks % (60000 / WATCH_MS) == 0 && !g_ending) hook_install();   /* again a minute after Ctrl+Esc / Ctrl+Alt+Del */
            continue;
        }
        DispatchMessageA(&msg);
    }
    if (timer) KillTimer(0, timer);
    if (g_hook) UnhookWindowsHookEx(g_hook);
    ExitProcess(0);
}
