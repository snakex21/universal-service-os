"""USOSLOG.EXE (src/platform/bios/win9x/usoslog.c): the silent Win32 logger
for Windows 98 / Me test installs, and USOSDBG.EXE's log mode (/L) it
runs. Host checks: the statistics page layout matches usosnet 0.4
(usosnet_proto.h on feature/usosnet, when that branch is in the repo), the
binary is PE 4.00 GUI with imports from the 9x list only, and a run on this
host decodes a USOSDBG dump of the page and writes a complete snapshot.
Nothing here runs Windows 9x: the 9x behaviour is not tested.

Universal Service OS (USOS), GPL-3.0-or-later."""
from pathlib import Path
import os, re, shutil, struct, subprocess, sys, tempfile, unittest

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'src/platform/bios/win9x'
sys.path.insert(0, str(ROOT / 'tools'))


def host_cc():
    return shutil.which('gcc') or shutil.which('cc') or (
        'C:/msys64/mingw64/bin/gcc.exe' if Path('C:/msys64/mingw64/bin/gcc.exe').exists() else None)


def proto_header():
    """usosnet_proto.h from feature/usosnet (same repository), or None."""
    r = subprocess.run(['git', '-C', str(ROOT), 'show', 'feature/usosnet:tools/nt/usosnet/src/usosnet_proto.h'],
                       capture_output=True, text=True)
    return r.stdout if r.returncode == 0 and 'USNS_BLOCK' in r.stdout else None


def usns_bytes(seq=3):
    """A page as usosnet 0.4 fills it (USNS_BLOCK, version 1)."""
    rx = [0] * 16; tx = [0] * 16
    rx[3], rx[4], rx[5], rx[7] = 120, 10, 7, 5        # ipv4 icmp udp dns
    tx[3], tx[5], tx[7] = 90, 9, 6
    drop = [0] * 16; drop[10] = 2                       # note:l4e_udp
    td = [44, 1, 0, 3000, 300, 1480, 7, 5]
    core = list(range(31))
    hist = [[0] * 6 for _ in range(32)]
    for i in range(seq):
        hist[i] = [(i << 8) | (1 if i % 2 else 2), 0x00A8, (53 << 16) | 1025, 90 + i, 0x00000003, 0x01010101]
    dns = bytes(range(128))
    body = struct.pack('<4I', 0x534E5355, 1, 1400, 77) + struct.pack('<16I', *rx) + struct.pack('<16I', *tx)
    body += struct.pack('<16I', *drop) + struct.pack('<8I', *td) + struct.pack('<31I', *core)
    body += struct.pack('<I', seq) + b''.join(struct.pack('<6I', *h) for h in hist)
    body += struct.pack('<2I', 90, 72) + dns + dns
    assert len(body) == 1400
    return body


class Layout(unittest.TestCase):
    def test_usns_matches_usosnet_proto(self):
        cc = host_cc()
        hdr = proto_header()
        if not cc or not hdr:
            self.skipTest('no host compiler or no feature/usosnet branch')
        src = (SRC / 'usoslog.c').read_text(encoding='utf-8')
        defs = re.search(r'#define USNS_MAGIC.*?\} USNS;\n', src, re.S).group(0)
        fields = ('Rx', 'Tx', 'Drop', 'Td', 'Core', 'Seq', 'Hist', 'LastDnsRxLen', 'LastDnsRx', 'LastDnsTx')
        probe = ''.join(f'printf("%u %u\\n", (unsigned)offsetof(USNS, {f}), (unsigned)offsetof(USNS_BLOCK, {f}));'
                        for f in fields)
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / 'usosnet_proto.h').write_text(hdr)
            c = Path(d) / 't.c'
            c.write_text('#include <stdio.h>\n#include <stddef.h>\n#define __inline inline\n'
                         'typedef unsigned long DWORD; typedef unsigned char BYTE;\n'
                         '#include "usosnet_proto.h"\n' + defs.replace('#define USNS_MAGIC', '#define USNS_MAGIC_LOG') +
                         'int main(void) {' + probe + 'printf("%u %u\\n", (unsigned)sizeof(USNS), (unsigned)sizeof(USNS_BLOCK));'
                         'return 0; }\n')
            exe = Path(d) / 't.exe'
            r = subprocess.run([cc, '-I', d, '-o', str(exe), str(c)], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            out = subprocess.run([str(exe)], capture_output=True, text=True).stdout.split('\n')
            for line in filter(None, out):
                a, b = line.split()
                self.assertEqual(a, b, line)
            self.assertIn('1400 1400', out)


class Sources(unittest.TestCase):
    def test_usosdbg_log_mode(self):
        dbg = (SRC / 'usosdbg.c').read_text(encoding='utf-8')
        self.assertIn('USOSDBG 1.7', dbg)
        self.assertIn("else if (c == 'D') disk_only = 1;", dbg)   # USOSLOG's disk snapshots
        self.assertIn('USOSDBG END', dbg)
        self.assertIn('if (!log_mode || log_pci) show_pci();', dbg)
        # the knock (C202h rate commands) only from the W key, never in log mode
        self.assertEqual(dbg.count('knock_now = 1'), 1)
        self.assertIn("else if (wp == 'w' || wp == 'W') { knock_now = 1;", dbg)
        self.assertIn('if (prev && !log_mode) return;', dbg)
        run_log = re.search(r'static void run_log\(HINSTANCE inst\)\n\{(.*?)\n\}', dbg, re.S).group(1)
        self.assertNotIn('ShowWindow', run_log)           # hidden window: timer only
        self.assertIn('SetTimer(w, 1, 1000, 0)', run_log)

    def test_usoslog_contract(self):
        log = (SRC / 'usoslog.c').read_text(encoding='utf-8')
        lnk = (SRC / 'usoslog.lnk').read_text(encoding='utf-8')
        self.assertIn('runtime windows=4.0', lnk)         # GUI subsystem: no console window
        self.assertIn('option norelocs', lnk)
        self.assertIn('#define ROTATE      (256UL * 1024)', log)
        self.assertIn('LOGDIR      "C:\\\\USOS9X\\\\LOGS"', log)
        self.assertIn('opt_first = 180, opt_every = 300', log)
        self.assertIn('CreateMutexA(0, FALSE, "USOSLOG-instance")', log)
        self.assertIn('si.wShowWindow = SW_HIDE', log)
        self.assertIn('FlushFileBuffers(f)', log)
        self.assertIn('#define FALLBACK_IP "64.227.13.248"', log)
        self.assertIn('#define LOG_PORT    21843', log)
        self.assertNotIn('CreateWindow', log)             # no window of its own
        # Windows 95 .. Me and NT: Winsock, IPHLPAPI, Toolhelp32 at run time only
        self.assertNotIn('wsock32', lnk.lower())
        for dll in ('"WSOCK32.DLL"', '"IPHLPAPI.DLL"', '"CreateToolhelp32Snapshot"'):
            self.assertIn(dll, log)
        self.assertIn('if (is_nt) { o("[MOUSE] USOSDBG skipped', log)
        self.assertIn('if (is_nt || !stats_va', log)


def grab(src: str, pattern: str) -> str:
    m = re.search(pattern, src, re.S | re.M)
    assert m, pattern
    return m.group(0)


def dbg_func(src: str, name: str) -> str:
    """One top-level function of usosdbg.c (signature line to the closing brace)."""
    return grab(src, r'^static [^\n(]*\b' + name + r'\([^\n]*\)\n\{.*?\n\}\n')


# usosdbg.c compiled on the host: Win16 types and the few USER calls the
# decoders use (line() as in USOSDBG, wsprintf = sprintf).
HOST_SHIM = r'''#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned char BYTE; typedef unsigned short WORD; typedef unsigned long DWORD; typedef char *LPSTR;
#define FAR
#define wsprintf sprintf
#define lstrlen(s) ((int)strlen(s))
#define lstrcat strcat
static char text[96][256];
static int nlines;
static LPSTR line(void) { text[nlines][0] = 0; return text[nlines++]; }
static void dump(void) { int i; for (i = 0; i < nlines; i++) printf("%s\n", text[i]); }
static BYTE *load(const char *path, long size)
{
    BYTE *b = calloc(1, size);
    FILE *f = fopen(path, "rb");
    if (f) { fread(b, 1, size, f); fclose(f); }
    return b;
}
'''


def host_run(tmp: Path, name: str, source: str, *args) -> str:
    cc = host_cc()
    if not cc or os.name != 'nt':
        raise unittest.SkipTest('no host compiler (or not Windows: DWORD as unsigned long)')
    c = tmp / f'{name}.c'
    c.write_text(HOST_SHIM + source, encoding='utf-8')
    exe = tmp / f'{name}.exe'
    r = subprocess.run([cc, '-O1', '-w', '-o', str(exe), str(c)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return subprocess.run([str(exe), *map(str, args)], capture_output=True, text=True, check=True).stdout


def c2_record(entries, count=None, head=None, magic=0x47523243):
    """A 512-byte USOSMWHL record with the patch 0020 ring after +312."""
    rec = bytearray(512)
    rec[0:9] = b'USOSMWHL\x01'
    count = len(entries) if count is None else count
    head = len(entries) % 16 if head is None else head
    struct.pack_into('<IHBB', rec, 312, magic, count & 0xFFFF, head, 0)
    for slot, e in entries:
        ax, bx, es, cs, ip, ident, res = e
        struct.pack_into('<5HBB', rec, 320 + 12 * slot, ax, bx, es, cs, ip, ident, res)
    return bytes(rec)


class Usosdbg(unittest.TestCase):
    """USOSDBG 1.6 / 1.7: the C2 ring (CSMWrap patch 0020) and the NIC / IRQ /
    $PIR section; the decoders run on the host with crafted memory."""

    @classmethod
    def setUpClass(cls):
        cls.src = (SRC / 'usosdbg.c').read_text(encoding='utf-8')
        cls.tmp = Path(tempfile.mkdtemp(prefix='usosdbg-'))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_c2_layout_constants(self):
        d = dict(re.findall(r'^#define (C2RG_\w+|MDIAG_MAP)\s+(\w+)', self.src, re.M))
        self.assertEqual(int(d['C2RG_OFF']), 312)               # SeaBIOS sizeof(usb_mouse_diag) 312
        self.assertEqual(int(d['C2RG_COUNT']), 316)
        self.assertEqual(int(d['C2RG_HEAD']), 318)
        self.assertEqual(int(d['C2RG_RING']), 320)
        self.assertEqual(int(d['C2RG_ENTRY']), 12)
        self.assertEqual(int(d['C2RG_SLOTS']), 16)
        self.assertEqual(int(d['MDIAG_MAP']), 320 + 16 * 12)
        self.assertEqual(struct.pack('<I', int(d['C2RG_MAGIC'].rstrip('L'), 16)), b'C2RG')
        # the ring is read through a 512-byte mapping, the record scan is unchanged
        find = dbg_func(self.src, 'find_mdiag')
        self.assertIn('mdiag_mapped = mdiag_at + MDIAG_MAP <= 0x100000L ? MDIAG_MAP : sizeof(MDIAG);', find)
        self.assertIn('physical(mdiag_at, mdiag_mapped)', find)
        self.assertIn('a < 0x100000L - sizeof(MDIAG)', find)
        self.assertIn('[1] == 0x4C48574DL && ((BYTE FAR *)q)[8] == 1)', find)   # version byte stays 1
        # entry: id after the call at +10, result at +11
        c2 = dbg_func(self.src, 'show_c2')
        self.assertIn('BYTE res = e[i][11];', c2)
        self.assertIn('(WORD)e[i][10]', c2)
        # the old record lines come first, unchanged; the ring after them
        wheel = dbg_func(self.src, 'show_wheel')
        self.assertTrue(wheel.rstrip().endswith('show_c2((BYTE FAR *)d);\n}'), wheel[-200:])
        self.assertIn('"WHEEL SeaBIOS at %05lX: mice:%u  wheel mouse:%u  ID:%u  rates:%u,%u  packets:%lu', wheel)

    def test_c2_layout_matches_patch_0020(self):
        patch = ROOT / 'tools/vendor/csmwrap/3.1.2-usos15/patches/0020-usb-mouse-wheel-z-always-c2-ring.patch'
        if not patch.is_file():
            self.skipTest('no CSMWrap 3.1.2-usos15 patch 0020')
        p = patch.read_text(encoding='utf-8')
        self.assertIn('+#define USB_MOUSE_C2_RING 16', p)
        entry = grab(p, r'^\+struct usb_mouse_c2 \{\n(.*?)^\+\};')
        self.assertIn('u16 ax, bx, es;', entry)
        self.assertIn('u16 cs, ip;', entry)
        self.assertLess(entry.index('u8 id;'), entry.index('u8 res;'))
        self.assertIn('u32 c2_magic;', p)
        self.assertIn('0x47523243', p)
        self.assertIn('(+312; the version byte stays 1)', p)

    def run_c2(self, rec: bytes, mapped=512) -> str:
        defs = grab(self.src, r'^#define C2RG_OFF.*?^static WORD mdiag_mapped;[^\n]*\n')
        body = defs + grab(self.src, r'^static const WORD c2_rates\[7\].*?\n') + dbg_func(self.src, 'c2_name') + \
            dbg_func(self.src, 'show_c2')
        main = ('int main(int argc, char **argv) { BYTE *r = load(argv[1], 512);'
                ' mdiag_mapped = (WORD)atoi(argv[2]); show_c2(r); dump(); return 0; }\n')
        f = self.tmp / 'rec.bin'
        f.write_bytes(rec)
        return host_run(self.tmp, 'c2', body + main, f, mapped)

    def test_c2_ring_none_and_unmapped(self):
        self.assertEqual(self.run_c2(c2_record([], magic=0)).strip(), 'WHEEL  C2 ring: none (CSMWrap before usos15)')
        self.assertIn('C2 ring: not mapped', self.run_c2(c2_record([]), mapped=310))

    def test_c2_ring_knock_then_reset(self):
        calls = [(0xC205, 0x0300, 0, 0xC800, 0x0010, 0, 0),
                 (0xC207, 0x1234, 0x0F00, 0xC800, 0x0020, 0, 0),
                 (0xC202, 0x0600, 0, 0x2000, 0x0100, 0, 0),
                 (0xC202, 0x0500, 0, 0x2000, 0x0108, 0, 0),
                 (0xC202, 0x0400, 0, 0x2000, 0x0110, 3, 0),
                 (0xC204, 0x0000, 0, 0x2000, 0x0118, 3, 0),
                 (0xC201, 0x0000, 0, 0xF000, 0x1234, 0, 0),
                 (0xC200, 0x0100, 0, 0xF000, 0x1240, 0, 0x86)]
        out = self.run_c2(c2_record(list(enumerate(calls))))
        self.assertIn('WHEEL  C2 ring: 8 INT 15h AH=C2h calls since boot, last 8', out)
        self.assertIn('WHEEL  C2 #0:  C205 init pkt 3 bx=0300 es=0000 @C800:0010 id0 ok  C207 handler bx=1234 es=0F00', out)
        self.assertIn('C202 rate 200 bx=0600', out)
        self.assertIn('C202 rate 80 bx=0400 es=0000 @2000:0110 id3 ok', out)
        self.assertIn('WHEEL  C2 #4:  C202 rate 80', out)
        self.assertIn('C200 on bx=0100 es=0000 @F000:1240 id0 err06', out)
        self.assertIn('WHEEL  C2 after the last knock (#4, id3): resets C201 1  inits C205 0  off C200 0  other 2  ID now 0'
                      '  -> first reset/init after it: C201 from F000:1234', out)
        for l in out.splitlines():
            self.assertLess(len(l), 256, l)                     # USOSDBG's line width

    def test_c2_ring_wrapped_oldest_first(self):
        # 20 calls: slots 4..15 then 0..3 hold calls 4..19; head 4 is the oldest
        entries = [(n % 16, (0xC204, 0, 0, 0x1000, n, 0, 0)) for n in range(4, 20)]
        out = self.run_c2(c2_record(entries, count=20, head=4))
        self.assertIn('calls since boot, last 16', out)
        self.assertIn('WHEEL  C2 #4:  C204 getid bx=0000 es=0000 @1000:0004', out)
        self.assertIn('WHEEL  C2 #16:  C204 getid bx=0000 es=0000 @1000:0010', out)
        self.assertIn('C2 knock (rate 200,100,80) not in the ring', out)
        ips = re.findall(r'@1000:(\w{4})', out)
        self.assertEqual([int(x, 16) for x in ips], list(range(4, 20)))

    def test_pir_decode_marks_nic(self):
        body = (grab(self.src, r'^#define MAXNIC.*?^static int nnic, nbr;\n') + dbg_func(self.src, 'irq_list') +
                dbg_func(self.src, 'pir_mark') + dbg_func(self.src, 'show_pir'))
        main = (
                'int main(int argc, char **argv) { fseg = load(argv[1], 0x10000L);'
                ' nic_at[0] = 0x80050000UL; nnic = 1; br_at[0] = 0x80000900UL; br_sec[0] = 5; br_sub[0] = 5; nbr = 1;'
                ' show_pir(); dump(); return 0; }\n')
        shim = 'static BYTE *fseg;\nstatic BYTE *physical(DWORD a, DWORD s) { (void)a; (void)s; return fseg; }\n'
        f = bytearray(0x10000)
        f[0x40:0x48] = b'$PIR\x00\x01\x05\x00'          # size 5: not a table, skipped
        entries = [(0, 1 << 3, [(0x60, 0xDEB8), (0x61, 0xDEB8), (0x62, 0xDEB8), (0x63, 0xDEB8)], 0),
                   (5, 0, [(0x61, 0x0E20), (0, 0), (0, 0), (0, 0)], 2),
                   (0, 0x14 << 3, [(0x62, 0xDEB8), (0, 0), (0, 0), (0, 0)], 0)]
        t = bytearray(b'$PIR' + struct.pack('<HHBBHHHI', 0x0100, 32 + 16 * len(entries), 0, 0x14 << 3 | 3, 0x0800,
                                            0x1022, 0x790B, 0) + bytes(11) + b'\0')
        for bus, devfn, links, slot in entries:
            t += bytes([bus, devfn]) + b''.join(struct.pack('<BH', *x) for x in links) + bytes([slot, 0])
        t[31] = (-sum(t)) & 0xFF
        f[0x3E0:0x3E0 + len(t)] = t
        fp = self.tmp / 'fseg.bin'
        fp.write_bytes(bytes(f))
        out = host_run(self.tmp, 'pir', shim + body + main, fp)
        self.assertIn('PIR  at F03E0: version 1.0 size 80 (3 entries) router 00:14.3 compatible 1022:790B '
                      'miniport 00000000 checksum ok  exclusive IRQs 0800: 11', out)
        self.assertIn(' 00:01 slot 0 A:60/DEB8 B:61/DEB8 C:62/DEB8 D:63/DEB8 <-bridge above NIC', out)
        self.assertIn(' 05:00 slot 2 A:61/0E20 B:00/0000 C:00/0000 D:00/0000 <-NIC', out)
        self.assertRegex(out, r'\n?PIR  00:14 slot 0 A:62/DEB8 [^<\n]*\n')
        t[31] ^= 1
        f[0x3E0:0x3E0 + len(t)] = t
        fp.write_bytes(bytes(f))
        self.assertIn('checksum BAD', host_run(self.tmp, 'pir2', shim + body + main, fp))

    def test_irq_section_read_only(self):
        irq = dbg_func(self.src, 'show_irq') + dbg_func(self.src, 'show_nic') + dbg_func(self.src, 'find_nics')
        self.assertNotIn('out ', irq.replace('cfg(', ''))      # no port writes besides cfg()'s CF8h index
        self.assertNotIn('outp', irq)
        inb = dbg_func(self.src, 'inb')
        self.assertNotIn('out', inb)
        for port in ('inb(0x4D0)', 'inb(0x4D1)', 'inb(0x21)', 'inb(0xA1)'):
            self.assertIn(port, irq)
        self.assertNotIn('0x20,', irq)                          # no OCW3 (IRR / ISR)
        self.assertIn("id == 0x15398086L", irq)                  # the I211 even outside class 02h
        self.assertIn('(cls >> 16) == 0x02', irq)
        self.assertIn('(cmd & 0x400) ? "DISABLED" : "on"', irq)  # command bit 10 INTx disable
        self.assertIn('(sts >> 3) & 1', irq)                    # status bit 3 interrupt status
        refresh = dbg_func(self.src, 'refresh')
        self.assertIn('show_map();\n    show_irq();\n    if (!log_mode || log_pci) show_pci();', refresh)


class Watcher(unittest.TestCase):
    def test_watcher_contract(self):
        log = (SRC / 'usoslog.c').read_text(encoding='utf-8')
        self.assertIn('#define WATCH_MS        250', log)
        self.assertIn('#define WATCH_EV_MAX    1000', log)
        self.assertIn('timer = SetTimer(0, 0, WATCH_MS, 0);', log)
        self.assertIn('if (++ticks % (60000 / WATCH_MS) == 0) hook_install();', log)   # still once a minute
        self.assertIn('"%02u:%02u:%02u.%03u t+%lu.%03lu "', log)                        # ms timestamps
        tick = grab(log, r'^static void watch_tick\(void\)\n\{.*?\n\}\n')
        self.assertIn('if (watch_procs(now)) watch_hot = WATCH_HOT;', tick)
        self.assertIn('watch_ticks % (toolhelp ? WATCH_WIN_EVERY : 2) == 0', tick)
        self.assertIn('session limit of %u event lines reached, %lu more not logged', log)
        self.assertIn('"ConsoleWindowClass"', log)
        self.assertIn('!lstrcmpiA(cls, "tty")', log)

    def test_wheel_detail_contract(self):
        """Each WM_MOUSEWHEEL: focus window (GetGUIThreadInfo, looked up at run
        time: not on 95), window under the pointer, foreground window; a short
        wheel record after the wheel was used, so a test before shutdown is kept."""
        log = (SRC / 'usoslog.c').read_text(encoding='utf-8').replace('\r\n', '\n')
        hook = grab(log, r'^LRESULT CALLBACK journal\(.*?\n\}\n')
        self.assertIn('wheel_detail(e);', hook)
        det = grab(log, r'^static void wheel_detail\(const EVENTMSG \*e\)\n\{.*?\n\}\n')
        self.assertIn('GetProcAddress(u, "GetGUIThreadInfo")', det)
        self.assertNotIn('GetGUIThreadInfo(', det)            # never a static import
        self.assertIn('fow = gi.hwndFocus', det)
        self.assertIn('hvw = WindowFromPoint(pt)', det)
        self.assertIn('if (wh_lines >= WHEEL_LINES_MAX)', det)
        self.assertIn('#define WHEEL_LINES_MAX 300', log)
        self.assertIn('#define WHEEL_REC_MAX   10', log)
        snap = grab(log, r'^static void snapshot\(void\)\n\{.*?\n\}\n')
        self.assertIn('sec_mouse();\n    sec_wheel();', snap)
        wait = grab(log, r'^static void wait_s\(DWORD s\)\n\{.*?\n\}\n')
        self.assertIn('GetTickCount() - g_wheel_tick >= WHEEL_REC_QUIET', wait)
        self.assertIn('recs < WHEEL_REC_MAX', wait)
        work = grab(log, r'^DWORD WINAPI worker\(LPVOID arg\)\n\{.*?\n\}\n')
        self.assertIn('wait_s(opt_first);', work)
        self.assertIn('wait_s(opt_every);', work)
        self.assertNotIn('Sleep(opt_', work)

    def test_disk_contract(self):
        '''DISK (docs/usb9x-hotswap-design-2026-10-19.md section 4): the drive
        APIs at run time (the static list stays the Windows 95 one), the start
        record parts, the watcher thread and the USOSDBG /D rate limit.'''
        log = (SRC / 'usoslog.c').read_text(encoding='utf-8').replace('\r\n', '\n')
        for api in ('GetLogicalDrives', 'GetDriveTypeA', 'GetVolumeInformationA', 'GetDiskFreeSpaceA', 'SetErrorMode'):
            self.assertIn(f'GetProcAddress(k32, "{api}")', log)
        self.assertNotIn('GetDiskFreeSpaceEx', log)
        self.assertIn('p_errmode(0x0001 /* SEM_FAILCRITICALERRORS */)', log)
        self.assertIn('return !(t == 4 || t == 1 || (t == 2 && i < 2));', log)    # no floppy seek, no network wait
        start = grab(log, r'^static void start_record\(void\)\n\{.*?\n\}\n')
        self.assertIn('sec_disk();\n    flush_out();', start)
        disk = grab(log, r'^static void sec_disk\(void\)\n\{.*?\n\}\n')
        for part in ('sec_drives();', 'sec_ios();', 'sec_scsi_registry();', 'run_usosdbg_disk("start");'):
            self.assertIn(part, disk)
        ios = grab(log, r'^static void sec_ios\(void\)\n\{.*?\n\}\n')
        self.assertIn('copy_file(LOGDIR "\\\\IOS.LOG", disk_fb, n);', ios)
        self.assertIn('"real mode", "real-mode", "compatibility"', ios)
        self.assertIn('"[IOS]", "KRNL386"', ios)
        reg = grab(log, r'^static void sec_scsi_registry\(void\)\n\{.*?\n\}\n')
        for key in ('"Enum\\\\Root\\\\SCSIAdapter"', '"Enum\\\\SCSI"', '"CurrentDriveLetterAssignment"', '"Removable"',
                    '"HardwareID"', '"System\\\\CurrentControlSet\\\\Services\\\\Class\\\\SCSIAdapter"', '"PortDriver"'):
            self.assertIn(key, reg)
        self.assertNotIn('RegSetValue', log)
        self.assertNotIn('RegCreateKey', log)
        dbg = grab(log, r'^static void run_usosdbg_disk\(const char \*why\)\n\{.*?\n\}\n')
        self.assertIn('wsprintfA(cmd, "%s /L %s /D", (LPSTR)DBGEXE, (LPSTR)DBGTMPD);', dbg)
        self.assertIn('EnterCriticalSection(&dbg_cs);', dbg)
        self.assertIn('si.wShowWindow = SW_HIDE;', dbg)
        snap = grab(log, r'^static void snapshot\(void\)\n\{.*?\n\}\n')
        self.assertIn('EnterCriticalSection(&dbg_cs);\n    run_usosdbg(stats_pa);\n    LeaveCriticalSection(&dbg_cs);', snap)
        self.assertIn('#define DISK_SNAP_MS 2000', log)
        watch = grab(log, r'^DWORD WINAPI disk_watch\(LPVOID arg\)\n\{.*?\n\}\n')
        self.assertIn('disk_tid = GetCurrentThreadId();', watch)
        self.assertIn('Sleep(WATCH_MS);', watch)
        self.assertIn('if (pending && (!have_snap || now - last_snap >= DISK_SNAP_MS)) {', watch)
        for line in ('o("[DISK] +drive %c: %s"', 'o("[DISK] -drive %c:"', 'o("[DISK] media %c: changed: %s (was %s)"',
                     'ev("+drive %c: %s"', 'ev("-drive %c:"'):
            self.assertIn(line, watch)
        self.assertIn('ticks % DISK_VOL_EVERY == 0 && cur[i].type == 2 && i >= 2', watch)
        main = grab(log, r'^void __cdecl usos_entry\(void\)\n\{.*?\n\}\n')
        self.assertIn('if (!opt_once && !opt_nodisk && p_drives) {', main)
        self.assertLess(main.index('InitializeCriticalSection(&dbg_cs);'), main.index('CreateThread(0, 0, worker'))
        # its own output buffer, one writer of the file at a time
        self.assertIn('if (on_disk_thread()) {', log)
        flush = grab(log, r'^static void flush_out\(void\)\n\{.*?\n\}\n')
        self.assertIn('EnterCriticalSection(&file_cs);', flush)
        self.assertIn('LeaveCriticalSection(&file_cs);', flush)


def build(tmp: Path) -> Path:
    import build_win9x_support as b
    try:
        from build_win3_usb_keyboard import OW_CACHE, OW_SNAPSHOT
    except Exception:
        raise unittest.SkipTest('OpenWatcom build helper not importable')
    if not ((OW_CACHE / OW_SNAPSHOT['file']).is_file() or
            (ROOT / 'tools/cache/buildkit-downloads' / OW_SNAPSHOT['file']).is_file() or
            (OW_CACHE / ('ow-' + OW_SNAPSHOT['sha256'][:12]) / 'lib386/nt/kernel32.lib').is_file()):
        raise unittest.SkipTest('no OpenWatcom snapshot in tools/cache')
    work = tmp / 'work'
    work.mkdir()
    return b.build_usoslog(tmp, work)


class Binary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = Path(tempfile.mkdtemp(prefix='usoslog-'))
        cls.exe = build(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_pe_header(self):
        import build_win9x_support as b
        d = self.exe.read_bytes()
        p = struct.unpack_from('<I', d, 60)[0]
        o = p + 24
        self.assertEqual(struct.unpack_from('<H', d, p + 4)[0], 0x14C)
        self.assertTrue(struct.unpack_from('<H', d, p + 22)[0] & 1)      # relocations stripped
        self.assertEqual(struct.unpack_from('<H', d, o + 68)[0], 2)      # GUI
        self.assertEqual((d[o + 40], d[o + 42], d[o + 48], d[o + 50]), (4, 0, 4, 0))
        self.assertEqual(struct.unpack_from('<I', d, o + 28)[0], 0x400000)
        imports = b.pe_imports(d)
        self.assertEqual(set(imports), set(b.USOSLOG_IMPORTS))
        for dll, names in imports.items():
            self.assertLessEqual(names, b.USOSLOG_IMPORTS[dll], dll)

    @unittest.skipUnless(os.name == 'nt', 'runs the Win32 program')
    def test_host_run_decodes_usosdbg_dump(self):
        page = usns_bytes()
        lines = ['USOSDBG 1.7 log mode  tick:1  pci:no (first run only)',
                 'WHEEL USOSMOUS: wanted:yes  knock answered ID:03  wheel:ON',
                 'USNS 1A2B3000: version 1 size 1400']
        lines += ['USNS+%03X:%s' % (r, page[r:r + 64].hex().upper()) for r in range(0, len(page), 64)]
        lines.append('USOSDBG END')
        dump = self.tmp / 'dbg.txt'
        dump.write_bytes(('\r\n'.join(lines) + '\r\n').encode('ascii'))
        out = self.tmp / 'run.txt'
        r = subprocess.run([str(self.exe), '/once', '/nonet', '/nohook', '/dbgfile', str(dump), '/out', str(out)],
                           timeout=120)
        self.assertEqual(r.returncode, 0)
        text = out.read_text(encoding='latin-1')
        self.assertIn('=== USOSLOG 1.0 snapshot #1', text)
        self.assertIn('=== end of snapshot #1', text)
        self.assertIn('WHEEL USOSMOUS: wanted:yes', text)
        self.assertIn('usosnet statistics (PA through USOSDBG): version 1 size 1400  driver up 77 s', text)
        self.assertIn('RX   bcast=0 mcast=0 arp=0 ipv4=120 icmp=10 udp=7 tcp=0 dns=5', text)
        self.assertIn('TX   bcast=0 mcast=0 arp=0 ipv4=90 icmp=0 udp=9 tcp=0 dns=6', text)
        self.assertIn('note:l4e_udp=2', text)
        self.assertIn('TransferData: calls=44 outside_indication=1', text)
        self.assertRegex(text, r'\n\s+2 TX\s+ipv4,udp,dns\s+53>1025\s+len\s+92 st 00000003 to 1\.1\.1\.1')
        self.assertIn('last DNS frame received: 90 bytes', text)
        self.assertIn('[PROC] processes', text)
        self.assertIn('[NET] active tests skipped (/nonet)', text)
        self.assertIn('[DISK] drive letters (GetLogicalDrives ', text)
        self.assertRegex(text, r'\[DISK\] C: fixed \S+ serial [0-9A-F]{4}-[0-9A-F]{4} label "[^"]*"  free \d+/\d+ MiB')

    @unittest.skipUnless(os.name == 'nt', 'runs the Win32 program')
    def test_host_watcher_sees_short_console_process(self):
        """The 250 ms watcher: a console program of about one second shows up
        with PID, parent and exe, its end with the run time, its console
        window with class and owner (Windows 10 conhost: ConsoleWindowClass)."""
        import time
        out = self.tmp / 'watch.txt'
        log = subprocess.Popen([str(self.exe), '/first', '4', '/every', '600', '/nonet', '/nohook', '/nodbg',
                                '/out', str(out)])
        try:
            time.sleep(1.5)                                       # primed: the first tick only records
            si = subprocess.STARTUPINFO()
            si.dwFlags = subprocess.STARTF_USESHOWWINDOW
            si.wShowWindow = 7                                    # SW_SHOWMINNOACTIVE
            child = subprocess.Popen(['cmd.exe', '/c', 'ping -n 2 127.0.0.1 >nul'],
                                     creationflags=subprocess.CREATE_NEW_CONSOLE, startupinfo=si)
            child.wait(timeout=30)
            t0 = time.time()
            text = ''
            while time.time() - t0 < 90:
                text = out.read_text(encoding='latin-1') if out.exists() else ''
                if '=== end of snapshot #1' in text:
                    break
                time.sleep(0.5)
        finally:
            log.kill()
            log.wait()
        self.assertIn('=== end of snapshot #1', text)
        self.assertIn('[PROC] watcher events since the last record (processes every 250 ms, windows on a change or '
                      'every 1000 ms;', text)
        me = re.escape(Path(sys.executable).name)
        ts = r'(?i)\d\d:\d\d:\d\d\.\d{3} t\+\d+\.\d{3} '
        self.assertRegex(text, ts + r'\+proc %08X cmd\.exe  parent %08X %s' % (child.pid, os.getpid(), me))
        self.assertRegex(text, ts + r'\+proc [0-9A-F]{8} PING\.EXE  parent %08X cmd\.exe' % child.pid)
        self.assertRegex(text, ts + r'-proc [0-9A-F]{8} PING\.EXE  parent %08X cmd\.exe  ran \d+ ms\n' % child.pid)
        self.assertRegex(text, ts + r'\+window [0-9A-F]{8} class "ConsoleWindowClass" title "[^"]*" pid [0-9A-F]{8} '
                               r'\S+  <- console / DOS box')
        self.assertRegex(text, ts + r'-window [0-9A-F]{8} class "ConsoleWindowClass" pid [0-9A-F]{8} \S+  shown \d+ ms'
                               r'  <- console / DOS box')


    @unittest.skipUnless(os.name == 'nt', 'runs the Win32 program')
    def test_host_disk_watcher_sees_subst_letter(self):
        '''The disk watcher: a SUBST letter added and removed while it runs
        gives one "disk change" record each (+drive / -drive), written at
        once, with the USOSDBG DISK snapshot line (skipped here: /nodbg).'''
        import string
        import time
        used = {c for c in string.ascii_uppercase if os.path.exists(c + ':\\')}
        free = [c for c in 'RSTUVWXY' if c not in used]
        if not free:
            self.skipTest('no free drive letter for SUBST')
        letter = free[-1]
        target = self.tmp / 'substdir'
        target.mkdir(exist_ok=True)
        out = self.tmp / 'disk.txt'
        log = subprocess.Popen([str(self.exe), '/first', '600', '/every', '600', '/nonet', '/nohook', '/nodbg',
                                '/out', str(out)])
        added = False
        text = ''
        try:
            time.sleep(2)
            r = subprocess.run(['subst', f'{letter}:', str(target)], capture_output=True, text=True)
            if r.returncode:
                self.skipTest('subst failed: ' + r.stdout + r.stderr)
            added = True
            time.sleep(2)
            subprocess.run(['subst', f'{letter}:', '/d'], check=True, capture_output=True)
            added = False
            t0 = time.time()
            while time.time() - t0 < 20:
                text = out.read_text(encoding='latin-1') if out.exists() else ''
                if f'[DISK] -drive {letter}:' in text:
                    break
                time.sleep(0.5)
        finally:
            if added:
                subprocess.run(['subst', f'{letter}:', '/d'], capture_output=True)
            log.kill()
            log.wait()
        self.assertIn('=== USOSLOG 1.0 start', text)
        self.assertIn('[DISK] drive letters (GetLogicalDrives', text)
        self.assertEqual(text.count('=== USOSLOG 1.0 disk change'), 2, text[-3000:])
        self.assertRegex(text, r'\[DISK\] \+drive %s: fixed \S+ serial [0-9A-F]{4}-[0-9A-F]{4} label' % letter)
        self.assertIn(f'[DISK] -drive {letter}:', text)
        self.assertEqual(text.count('[DISK] USOSDBG DISK snapshot skipped (/nodbg)'), 3)   # start + 2 changes


if __name__ == '__main__':
    unittest.main()
