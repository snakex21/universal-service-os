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
        self.assertIn('USOSDBG 1.5', dbg)
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
        lines = ['USOSDBG 1.5 log mode  tick:1  pci:no (first run only)',
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


if __name__ == '__main__':
    unittest.main()
