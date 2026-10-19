"""USOSDBG.EXE's DISK section (src/platform/bios/win9x/usosdbg.c, 1.7): the
SeaBIOS "USOS" "UDSK" record (CSMWrap 3.1.2-usos16 patch 0021), channel 1
after the CSMPPrxy mailbox and the USOSUSB.MPD status page, layouts from
src/platform/bios/win9x/usosuds.h (docs/usb9x-hotswap-design-2026-10-19.md
section 4). The decoder block (DISK-DECODE-BEGIN .. END) is compiled on the
host with zig cc against synthetic records built from the real header,
-Wformat as errors (wsprintf -> sprintf: a WORD passed to %lu or a DWORD to
%u is a format error here, as it would be a stack mismatch in Win16); the
scan / mapping glue is checked statically. Nothing here runs Windows 9x.
Usage: python -I tools/tests/usb9x/test_usosdbg_disk.py [zig]

Universal Service OS (USOS), GPL-3.0-or-later."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SRC = ROOT / 'src/platform/bios/win9x'
ARCHIVE = ROOT / 'tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz'


def find_zig() -> str:
    if len(sys.argv) > 1 and not sys.argv[1].startswith('-'):
        return sys.argv[1]
    for cand in (ROOT / 'tools/zig/zig.exe', ROOT.parent.parent / 'Desktop/Universal_Service_OS/tools/zig/zig.exe',
                 ROOT.parent.parent / 'Desktop/usos-x470-98se/tools/zig/zig.exe'):
        if cand.exists():
            return str(cand)
    z = shutil.which('zig')
    if z:
        return z
    raise SystemExit('zig not found (pass its path)')


def source() -> str:
    return (SRC / 'usosdbg.c').read_text(encoding='utf-8').replace('\r\n', '\n')


def func(src: str, name: str) -> str:
    m = re.search(r'^static [^\n(]*\b' + name + r'\([^\n]*\)\n\{.*?\n\}\n', src, re.S | re.M)
    assert m, name
    return m.group(0)


SHIM = r'''#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include "usosuds.h"
typedef unsigned char BYTE; typedef unsigned short WORD; typedef unsigned long DWORD; typedef char *LPSTR;
#define FAR
#define wsprintf sprintf
#define lstrlen(s) ((int)strlen(s))
#define LINES 160
static char text[LINES][256];
static int nlines;
static LPSTR line(void) { if (nlines >= LINES) nlines = LINES - 1; text[nlines][0] = 0; return text[nlines++]; }
'''

MAIN = r'''
static struct uds_diag d;
static struct uds_mp_status m;
static struct uds_channel c;

static void base(void)
{
    int i;
    memset(&d, 0, sizeof(d));
    d.sig[0] = UDS_DIAG_SIG0; d.sig[1] = UDS_DIAG_SIG1; d.version = UDS_DIAG_VERSION;
    d.devs = 2; d.disks = 3; d.services = 1234; d.badreq = 2; d.last_why = UDS_WHY_LEN; d.channel = 0xFE0F0UL;
    d.dev[0].state = UDS_DEV_PRESENT; d.dev[0].luns = 1; d.dev[0].port = 3; d.dev[0].vid = 0x0781;
    d.dev[0].pid = 0x5567; d.dev[0].slotid = 2; d.dev[0].speed = 3; d.dev[0].generation = 1;
    d.dev[0].block_size = 512; d.dev[0].last_lba_lo = 0x01DCFFFFUL;            /* 15264 MiB */
    d.dev[0].requests = 4000; d.dev[0].checks = 3; d.dev[0].kib_in = 70000; d.dev[0].kib_out = 12;
    d.dev[0].last_op = 0x28; d.dev[0].last_csw = 0; d.dev[0].last_status = UDS_S_OK;
    d.dev[1].state = UDS_DEV_GONE; d.dev[1].bios_drive = 0x81; d.dev[1].luns = 2; d.dev[1].port = 5;
    d.dev[1].vid = 0x0951; d.dev[1].pid = 0x1666; d.dev[1].speed = 2; d.dev[1].generation = 7;
    d.dev[1].block_size = 4096; d.dev[1].last_lba_lo = 0xFFFFFFFFUL; d.dev[1].last_lba_hi = 0;   /* 16 TiB */
    d.dev[1].gone = 9; d.dev[1].refused = 4; d.dev[1].timeouts = 1; d.dev[1].resets = 1;
    d.dev[1].last_op = 0x2A; d.dev[1].last_csw = 1; d.dev[1].last_key = 6; d.dev[1].last_asc = 0x28;
    d.dev[1].last_ascq = 0; d.dev[1].last_status = UDS_S_GONE;
    d.disk[0].bios = 0x80; d.disk[0].dtype = 0x91; d.disk[0].sectors_lo = 1000215216UL;
    d.disk[1].bios = 0x81; d.disk[1].dtype = 0x70; d.disk[1].uds = 2; d.disk[1].sectors_lo = 0x00E8E000UL;
    d.disk[2].bios = 0xE0; d.disk[2].dtype = 0x51; d.disk[2].sectors_hi = 1; d.disk[2].sectors_lo = 0;
    /* 20 events: slots 4..15 hold #4..#15, slots 0..3 hold #16..#19; next 4 */
    for (i = 4; i < 20; i++) {
        struct uds_diag_event *e = &d.ev[i % 16];
        e->ms = 100UL * i; e->dev = (uds_u8)(i % 2); e->port = 3; e->event = UDS_EV_RESET; e->result = 0;
    }
    d.ev[4].event = UDS_EV_PRESENT; d.ev[4].result = 1;
    d.ev[5].event = UDS_EV_TIMEOUT; d.ev[5].result = 2;
    d.ev[6].event = UDS_EV_PHASE; d.ev[6].result = 4;
    d.ev[7].event = UDS_EV_GONE; d.ev[7].result = 0x2A;
    d.ev[8].event = UDS_EV_BADREQ; d.ev[8].result = UDS_WHY_ADDR; d.ev[8].dev = 0xFF;
    d.ev[9].event = UDS_EV_HWFAIL; d.ev[9].result = 2;
    d.ev[10].event = UDS_EV_REGFAIL; d.ev[10].result = 2;
    d.ev[11].event = UDS_EV_STALL; d.ev[11].result = 3;
    d.ev[12].event = 77; d.ev[12].result = 9;
    d.ev[3].event = UDS_EV_EJECT; d.ev[3].result = 0;
    d.events = 20; d.next_event = 4;
}

static void mp(void)
{
    memset(&m, 0, sizeof(m));
    m.sig[0] = UDS_MP_SIG0; m.sig[1] = UDS_MP_SIG1; m.version = UDS_MP_VERSION; m.slots = 3;
    m.mp_major = 0; m.mp_minor = 3; m.srbs = 900; m.posted = 850; m.polled = 7; m.errors = 2; m.enums = 4;
    m.last_status = UDS_S_CHECK;
    m.slot[0].dev = 0; m.slot[0].present = 1; m.slot[0].last_op = 0x28; m.slot[0].generation = 1; m.slot[0].srbs = 800;
    m.slot[1].dev = 1; m.slot[1].present = 0; m.slot[1].ua_pending = 1; m.slot[1].generation = 7;
    m.slot[1].last_key = 2; m.slot[1].last_asc = 0x3A; m.slot[1].last_srb_status = 0x04;
    m.slot[2].dev = 0xFF;
}

int main(int argc, char **argv)
{
    const char *k = argc > 1 ? argv[1] : "full";
    int i;
    base();
    if (!strcmp(k, "full")) show_disk_record(&d, 0x9FC00UL, 0xFE0F0UL);
    else if (!strcmp(k, "differs")) show_disk_record(&d, 0x9FC00UL, 0xFE130UL);
    else if (!strcmp(k, "nochan")) show_disk_record(&d, 0x9FC00UL, 0);
    else if (!strcmp(k, "v2")) { d.version = 2; show_disk_record(&d, 0xE1230UL, 0); }
    else if (!strcmp(k, "hostile")) {
        d.devs = 200; d.disks = 99; d.events = 0xFFFFFFFFUL; d.next_event = 0xEE; d.last_why = 1000; d.channel = 0;
        for (i = 0; i < UDS_MAX_DEVS; i++) {
            d.dev[i].state = 0xEE; d.dev[i].speed = 9; d.dev[i].block_size = 3; d.dev[i].last_status = 0x77;
            d.dev[i].last_lba_lo = 0xFFFFFFFFUL; d.dev[i].last_lba_hi = 0xFFFFFFFFUL;
        }
        for (i = 0; i < UDS_DIAG_DISKS; i++) { d.disk[i].bios = 0x80 + i; d.disk[i].dtype = 0xEE; d.disk[i].uds = 0xFF; }
        show_disk_record(&d, 0x9FC00UL, 0xFE0F0UL);
    }
    else if (!strcmp(k, "empty")) { d.devs = 0; d.disks = 0; d.events = 0; d.next_event = 0; d.channel = 0;
        show_disk_record(&d, 0x9FC00UL, 0xFE0F0UL); }
    else if (!strcmp(k, "mp")) { mp(); show_disk_mp(&m, 0x01234080UL); }
    else if (!strcmp(k, "mpbad")) { mp(); m.sig[1] = 0x12345678UL; show_disk_mp(&m, 0x01234080UL); }
    else if (!strcmp(k, "mpv2")) { mp(); m.version = 2; m.slots = 200; show_disk_mp(&m, 0x01234080UL); }
    else if (!strcmp(k, "mphostile")) { mp(); m.slots = 200; m.last_status = UDS_S_PENDING; show_disk_mp(&m, 0x01234080UL); }
    else if (!strcmp(k, "chan")) {
        c.magic = UDS_CH1_MAGIC; c.req_phys = 0x01234000UL; c.doorbell = 41; c.done = 40;
        show_disk_channel(&c, 0xE0C0); c.magic = 0; c.doorbell = 41; c.done = 41; show_disk_channel(&c, 0xE0C0);
    }
    else if (!strcmp(k, "mib")) {
        printf("%lu %lu %lu %lu %lu %lu\n", uds_mib(0x01DD0000UL, 0, 512), uds_mib(0, 1, 4096), uds_mib(5, 0, 3),
               uds_mib(0, 0x100000UL, 512), uds_mib(7, 0, 1UL << 20), uds_mib(2048, 0, 512));
        return 0;
    }
    for (i = 0; i < nlines; i++) printf("%s\n", text[i]);
    return 0;
}
'''


def decoder_block(src: str) -> str:
    m = re.search(r'/\* DISK-DECODE-BEGIN[^\n]*\n(.*?)/\* DISK-DECODE-END \*/', src, re.S)
    assert m, 'DISK-DECODE markers'
    return m.group(1)


def static_checks(src: str) -> None:
    assert '#include "usosuds.h"' in src
    for t, n in (('uds_diag', 768), ('uds_diag_dev', 64), ('uds_diag_disk', 12), ('uds_mp_status', 100)):
        assert f'[sizeof(struct {t}) == {n} ? 1 : -1]' in src, t
    refresh = func(src, 'refresh')
    assert 'show_net();\n    show_disk();' in refresh                  # full /L and the window: last section
    assert 'if (disk_only) {' in refresh and 'show_disk();\n        return;' in refresh
    assert "else if (c == 'D') disk_only = 1;" in func(src, 'parse_args')
    run_log = func(src, 'run_log')
    assert run_log.index('if (disk_only)') < run_log.index('SetTimer(w, 1, 1000, 0)')
    assert 'USOSDBG 1.7 log mode (disk)' in src
    find = func(src, 'find_udsk')
    assert 'for (w = 0; w < 16; w++)' in find                           # the first MiB, 64 KiB windows
    assert 'physical((DWORD)w << 16, 0x10000L)' in find
    assert 'off += 16' in find and 'if (off == 0xFFF0) break;' in find
    assert 'q[0] == UDS_DIAG_SIG0 && q[1] == UDS_DIAG_SIG1 && p[off + 8] && p[off + 8] < 16' in find
    disk = func(src, 'show_disk')
    assert 'at + sizeof(disk_rec) <= 0x100000L ? physical(at, sizeof(disk_rec)) : 0' in disk
    assert 'disk_rec.sig[0] = 0;' in disk                               # the copy never matches a later scan
    assert 'physical(0xF0000L, 0x10000L)' in disk
    assert 'off <= 0xFFF8 - UDS_CH1_OFFSET - sizeof(struct uds_channel); off += 8' in disk
    assert 'fcopy(&disk_ch, p + UDS_CH1_OFFSET, sizeof(disk_ch));' in disk
    assert 'if (disk_ch.magic != UDS_CH1_MAGIC) return;' in disk
    assert 'req > 0xFFFFD000UL' in disk
    assert 'DWORD st = req + UDS_MP_STATUS_OFFSET' in disk
    assert 'physical(page, in + sizeof(disk_mp) > 0x1000 ? 0x2000 : 0x1000)' in disk
    assert 'fcopy(&disk_mp, p + in, sizeof(disk_mp));' in disk
    assert '"DISK: no USOSUDSK record (CSMWrap before 3.1.2-usos16)"' in disk
    # read only: no stores through a far pointer, no port output in the section
    sec = src[src.index('/* ---------------------------------------------------------- DISK */'):
              src.index('/* ---------------------------------------------------------- UI */')]
    assert '_asm' not in sec and 'outp(' not in sec
    assert not re.search(r'\b(p|q|f|r)\[[^\]]*\]\s*=[^=]', sec)
    assert '"USOSUDSK"' not in sec                                       # no signature-shaped data in DGROUP


def dtype_check(src: str) -> None:
    """The DTYPE names cover every DTYPE_* of SeaBIOS block.h (CSMWrap 3.1.2)."""
    if not ARCHIVE.is_file():
        print('[skip] no CSMWrap 3.1.2 source archive')
        return
    with tarfile.open(ARCHIVE) as t:
        block = t.extractfile('csmwrap-3.1.2/seabios/src/block.h').read().decode()
    want = {int(v, 16) for v in re.findall(r'^#define DTYPE_\w+\s+(0x[0-9a-fA-F]+)', block, re.M)}
    have = {int(v, 16) for v in re.findall(r'case (0x[0-9A-Fa-f]+): return', func(src, 'uds_dtype_name'))}
    assert want and want == have, (sorted(want - have), sorted(have - want))
    speeds = dict(re.findall(r'^#define USB_(\w+)SPEED\s+(\d)', t_read(ARCHIVE, 'seabios/src/hw/usb.h'), re.M))
    assert speeds == {'FULL': '0', 'LOW': '1', 'HIGH': '2', 'SUPER': '3'}, speeds


def t_read(archive: Path, name: str) -> str:
    with tarfile.open(archive) as t:
        return t.extractfile('csmwrap-3.1.2/' + name).read().decode()


def check(out: dict) -> None:
    full = out['full']
    assert ('DISK USOSUDSK at 9FC00: version 1  devs 2  disks 3  services 1234  badreq 2  last why 9 len  '
            'events 20 (next slot 4)  channel 000FE0F0 (= CSMPPrxy+48)') in full, full
    assert ('DISK  dev 0: present  not mapped  luns 1  port 3  0781:5567  slot 2  super speed  gen 1  block 512  '
            '15264 MiB (last LBA 1DCFFFF)') in full, full
    assert ('DISK  dev 0: requests 4000  checks 3  timeouts 0  resets 0  gone 0  refused 0  in 70000 KiB  out 12 KiB'
            in full)
    assert 'DISK  dev 0: last op 28h READ(10)  CSW 0  sense 0/00/00  status 0 ok' in full
    assert ('DISK  dev 1: GONE (removed)  BIOS 81h  luns 2  port 5  0951:1666  slot 0  high speed  gen 7  block 4096  '
            '16777216 MiB (last LBA FFFFFFFF)') in full, full
    assert 'DISK  dev 1: last op 2Ah WRITE(10)  CSW 1  sense 6/28/00  status 3 gone' in full
    assert 'DISK BIOS disk table: 3 entries\n' in full
    assert 'DISK  80h NVMe (91h)  1000215216 sectors (488386 MiB)' in full
    assert 'DISK  81h USB MSC (70h)  UDS stick 1  15261696 sectors (7452 MiB)' in full
    assert 'DISK  E0h AHCI ATAPI (51h)  100000000 sectors (2097152 MiB)' in full
    assert 'DISK events: 20 since boot, last 16 (oldest first; ms = SeaBIOS timer)' in full
    ev = re.findall(r' #(\d+) (\d+)ms dev (\S+) port (\d+) ([^(]+) \(([^)]*)\);', full)
    assert [int(e[0]) for e in ev] == list(range(4, 20)), ev
    assert [int(e[1]) for e in ev] == [100 * i for i in range(4, 20)]
    names = {int(e[0]): (e[4], e[5], e[2]) for e in ev}
    assert names[4] == ('present', 'luns 1', '0')
    assert names[5] == ('TIMEOUT', 'phase 2 data', '1')
    assert names[6] == ('PHASE', 'phase 4 CSW signature/tag', '0')
    assert names[7] == ('GONE', 'during op 2Ah', '1')
    assert names[8] == ('badreq', 'why 10 addr', '-')
    assert names[9] == ('HWFAIL', 'halted / host system error', '1')
    assert names[10] == ('REGFAIL', 'INQUIRY failed', '0')
    assert names[11] == ('stall', 'phase 3 CSW', '1')
    assert names[12] == ('?', 'result 9', '0')
    assert names[13] == ('reset', 'ok', '1')
    assert names[19] == ('eject', 'result 0', '1')                       # slot 3 = #19, the newest
    assert len(re.findall(r'^DISK  #\d+', full, re.M)) == 8   # two a line
    assert 'CSMPPrxy+48 is FE130: DIFFERS' in out['differs']
    assert '(no CSMPPrxy found)' in out['nochan']
    assert out['v2'].strip() == 'DISK USOSUDSK at E1230: version 2 not decoded (USOSDBG knows version 1)'
    h = out['hostile']
    assert 'last why 1000 ?' in h and '(no channel 1 request served yet)' in h
    assert 'DISK  devs 200 > 8: the first 8 shown' in h
    assert len(re.findall(r'^DISK  dev \d: \? ', h, re.M)) == 8
    assert 'block 3  ? MiB (last LBA FFFFFFFFFFFFFFFF)' in h               # wraps to 0: not a power of two anyway
    assert 'status 119 ?' in h
    assert 'DISK BIOS disk table: 99 entries (more than 8: 8 shown)' in h
    assert len(re.findall(r'^DISK  [8][0-7]h \? \(EEh\)  UDS stick 254', h, re.M)) == 8
    assert 'DISK events: 4294967295 since boot, last 16' in h
    assert len(re.findall(r' #\d+ ', h)) == 16
    e = out['empty']
    assert 'DISK  no entry in the UDS table' in e
    assert 'DISK BIOS disk table: 0 entries (filled at the first channel 1 request)' in e
    assert 'DISK events: 0 since boot, last 0' in e and ' #' not in e
    m = out['mp']
    assert ('DISK USOSUSB.MPD 0.3 status at 01234080: version 1  slots 3  srbs 900  posted 850  polled 7  errors 2  '
            'enums 4  last status 1 check condition') in m, m
    assert ('DISK  slot 0: dev 0 present gen 1 srbs 800 last op 28h SRB status 00 sense 0/00/00; '
            'slot 1: dev 1 absent UA pending gen 7 srbs 0 last op 00h SRB status 04 sense 2/3A/00;') in m, m
    assert 'DISK  slot 2: dev none absent gen 0' in m
    assert out['mpbad'].strip() == ('DISK USOSUSB.MPD status at 01234080: no USOSUMPS signature (534F5355 12345678)')
    assert 'status version 2: slots not decoded' in out['mpv2'] and 'slot 0' not in out['mpv2']
    assert 'last status 4294967295 pending' in out['mphostile']
    assert len(re.findall(r'slot \d:', out['mphostile'])) == 4                # clamped to UDS_MP_SLOTS
    c = out['chan'].splitlines()
    assert c[0] == ('DISK channel at FE0F0 (CSMPPrxy+48): magic 31534455 (UDS1)  req_phys 01234000  doorbell 41  '
                    'done 40  (request in flight)'), c
    assert c[1] == ('DISK channel at FE0F0 (CSMPPrxy+48): magic 00000000 (not UDS1: CSMWrap before usos16)  '
                    'req_phys 01234000  doorbell 41  done 41'), c
    assert out['mib'].split() == ['15264', '16777216', '4294967295', '4294967294', '7', '1'], out['mib']
    for text in out.values():
        for line in text.splitlines():
            assert len(line) < 256, line                                    # USOSDBG's line width


def run(zig: str) -> None:
    src = source()
    static_checks(src)
    dtype_check(src)
    with tempfile.TemporaryDirectory() as td:
        t = Path(td)
        env = dict(os.environ)
        env.setdefault('ZIG_GLOBAL_CACHE_DIR', str(t / 'zig-cache'))
        c = t / 'disk.c'
        c.write_text(SHIM + decoder_block(src) + MAIN, encoding='utf-8')
        for target in ('x86_64-windows-gnu', 'x86-windows-gnu'):           # long = 32 bits, as Win16 DWORD
            exe = t / f'disk-{target}.exe'
            r = subprocess.run([zig, 'cc', '-target', target, '-std=c99', '-O1', '-Wall', '-Wextra', '-Wformat=2',
                                '-Werror', '-Wno-unused-function', '-fsanitize=undefined',
                                '-fno-sanitize-recover=all', '-I', str(SRC), str(c), '-o', str(exe)],
                               capture_output=True, text=True, env=env)
            assert r.returncode == 0, r.stdout + r.stderr
            out = {}
            for k in ('full', 'differs', 'nochan', 'v2', 'hostile', 'empty', 'mp', 'mpbad', 'mpv2', 'mphostile',
                      'chan', 'mib'):
                p = subprocess.run([str(exe), k], capture_output=True, text=True)
                assert p.returncode == 0, (k, p.stdout, p.stderr)
                out[k] = p.stdout
            check(out)
            print(f'[{target}] ' + out['full'].splitlines()[0])


def test_usosdbg_disk():
    run(find_zig())


def main() -> int:
    run(find_zig())
    print('USOSDBG-DISK-TEST PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
