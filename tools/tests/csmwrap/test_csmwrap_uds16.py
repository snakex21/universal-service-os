"""Host test: CSMWrap 3.1.2-usos16 patch 0021 (USB disk service on channel 1 of the helper core,
docs/usb9x-hotswap-design-2026-10-19.md stage 1).

    python -I tools/tests/csmwrap/test_csmwrap_uds16.py [path-to-zig.exe]

1. Series: usos16/patches = usos15/patches byte for byte + 0021; manifest hashes of every file.
2. Source: the pinned source archive + the 21 patches (GNU patch); the LGPL request check in
   seabios/src/hw/usb-uds.c is the same code as uds_req_check() in
   src/platform/bios/win9x/usosuds_slot.c (GPL, same authors); usb-uds.h and usosuds.h give the
   same layout (zig cc, both built for x86, sizes and offsets compared); the request check of the
   SeaBIOS copy built on the host gives the same verdicts as the GPL one on a set of requests.
3. Wiring: the mailbox is 64-byte aligned with channel 1 at +48..+63 and offsets 0-47 as before;
   the helper loop tests doorbell != done after request_pending (before and after MONITOR) and
   calls usos_uds_service with EAX = mailbox + 48; usb-msc.c only calls the UDS hooks outside
   MODESEGMENT; POST sends no UDS traffic (INQUIRY / READ CAPACITY / GET_DESCRIPTOR only in
   uds_probe, reached from the channel 1 service).
4. Pins: when usos16 is the release pin, xp_csmwrap_esp.sh PINNED, release.go, lock.json and
   run_build_vm.py agree with the manifest.
"""
from __future__ import annotations

import hashlib
import json
import lzma
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
V15 = ROOT / 'tools/vendor/csmwrap/3.1.2-usos15'
V16 = ROOT / 'tools/vendor/csmwrap/3.1.2-usos16'
ARCHIVE = ROOT / 'tools/vendor/csmwrap/3.1.2-src/csmwrap-3.1.2-src.tar.xz'
P21 = V16 / 'patches/0021-usb-disk-service.patch'
GPL_H = ROOT / 'src/platform/bios/win9x/usosuds.h'
GPL_C = ROOT / 'src/platform/bios/win9x/usosuds_slot.c'


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def find_zig() -> str:
    if len(sys.argv) > 1:
        return sys.argv[1]
    for cand in (ROOT / 'tools/zig/zig.exe', Path.home() / 'Desktop/Universal_Service_OS/tools/zig/zig.exe'):
        if cand.exists():
            return str(cand)
    z = shutil.which('zig')
    if z:
        return z
    raise SystemExit('zig not found (pass its path)')


def find_patch() -> str:
    for cand in (shutil.which('patch'), r'C:\Program Files\Git\usr\bin\patch.exe'):
        if cand and Path(cand).exists():
            return cand
    raise SystemExit('GNU patch not found')


def series() -> None:
    p15 = sorted(p.name for p in (V15 / 'patches').glob('*.patch'))
    p16 = sorted(p.name for p in (V16 / 'patches').glob('*.patch'))
    assert p16 == p15 + [P21.name], p16
    for n in p15:
        assert sha(V15 / 'patches' / n) == sha(V16 / 'patches' / n), n
    m = json.loads((V16 / 'manifest.json').read_text(encoding='utf-8'))
    assert m['version'] == '3.1.2-usos16'
    assert set(m['patches']) == set(p16)
    for n, h in m['patches'].items():
        assert sha(V16 / 'patches' / n) == h, n
    for n, h in m['files'].items():
        assert sha(V16 / n) == h, n
    assert m['source_archive']['sha256'] == sha(ARCHIVE)
    text = P21.read_text(encoding='utf-8')
    assert 'Own code' in text and 'LGPLv3' in text
    assert '\r' not in text


def patched_tree(td: Path) -> Path:
    with lzma.open(ARCHIVE) as xz, tarfile.open(fileobj=xz) as t:
        t.extractall(td, filter='data')
    tree = td / 'csmwrap-3.1.2'
    patch = find_patch()
    for p in sorted((V16 / 'patches').glob('*.patch')):
        r = subprocess.run([patch, '-p1', '-s', '--no-backup-if-mismatch', '-i', str(p)], cwd=tree,
                           capture_output=True, text=True)
        assert r.returncode == 0, (p.name, r.stdout, r.stderr)
    return tree


def norm_check(code: str) -> str:
    """the body of uds_req_check, comments / whitespace / UL suffixes / types removed"""
    m = re.search(r'uds_req_check\(const struct uds_req \*r, (?:uds_)?u32 \*why\)\s*\{(.*?)\n\}', code, re.S)
    assert m, 'uds_req_check not found'
    body = re.sub(r'/\*.*?\*/', '', m.group(1), flags=re.S)
    body = re.sub(r'//[^\n]*', '', body)
    body = re.sub(r'\b(0x[0-9A-Fa-f]+|\d+)UL\b', r'\1', body)
    body = body.replace('uds_u32', 'u32')
    return re.sub(r'\s+', '', body)


LAYOUT = r'''
#include <stdio.h>
#include <stddef.h>
#include HDR
#define O(s, f) printf(#s "." #f " %u\n", (unsigned)offsetof(struct s, f))
#define S(s) printf(#s " %u\n", (unsigned)sizeof(struct s))
int main(void)
{
    S(uds_channel); O(uds_channel, doorbell); O(uds_channel, done);
    S(uds_req); O(uds_req, seq); O(uds_req, op); O(uds_req, dir); O(uds_req, data_phys);
    O(uds_req, data_len); O(uds_req, cdb_len); O(uds_req, cdb); O(uds_req, status);
    O(uds_req, generation); O(uds_req, residue); O(uds_req, csw_status); O(uds_req, sense_len);
    O(uds_req, sense);
    S(uds_dev_info); O(uds_dev_info, generation); O(uds_dev_info, block_size);
    O(uds_dev_info, last_lba_lo); O(uds_dev_info, vendor); O(uds_dev_info, product);
    S(uds_diag_dev); O(uds_diag_dev, slotid); O(uds_diag_dev, last_asc); O(uds_diag_dev, generation);
    O(uds_diag_dev, requests); O(uds_diag_dev, kib_in); O(uds_diag_dev, kib_out);
    S(uds_diag_disk); O(uds_diag_disk, sectors_lo); S(uds_diag_event); O(uds_diag_event, event);
    S(uds_diag); O(uds_diag, version); O(uds_diag, services); O(uds_diag, channel); O(uds_diag, events);
    O(uds_diag, dev); O(uds_diag, disk); O(uds_diag, ev);
    printf("consts %u %u %u %lu %lu %u %u %u %u %u %u\n", UDS_VERSION, UDS_MAX_DEVS, UDS_MAX_LUN,
           (unsigned long)UDS_MAX_DATA, (unsigned long)UDS_CH1_MAGIC, UDS_S_OWNED, UDS_S_HWFAIL,
           UDS_EV_STALL, UDS_DIAG_EVENTS, UDS_DIAG_DISKS, UDS_WHY_ADDR);
    return 0;
}
'''

VERDICTS = r'''
#include <stdio.h>
#include <string.h>
#include HDR
u32 uds_req_check(const struct uds_req *r, u32 *why);
int main(void)
{
    unsigned i, n = 0;
    struct uds_req r;
    u32 why;
    for (i = 0; i < 40000; i++) {
        unsigned x = i * 2654435761u;
        memset(&r, 0, sizeof(r));
        r.magic = (i % 97) ? 0x52534455 : 0x52534454;
        r.version = (i % 89) ? 1 : 2;
        r.size = (i % 83) ? sizeof(r) : 64;
        r.op = x % 7; r.dev = (x >> 3) % 10; r.lun = (x >> 7) % 18; r.dir = (x >> 11) % 4;
        r.cdb_len = (x >> 13) % 18;
        r.data_len = (x & 0x40000) ? 0 : ((x >> 5) % 3 == 0 ? 65536 : (x >> 9) % 70000);
        r.data_phys = (x & 0x80000) ? ((x >> 2) & 0xFFFFF) : (x * 7u);
        uds_req_check(&r, &why);
        n = n * 31 + why;
    }
    printf("%u\n", n);
    return 0;
}
'''


def build_run(zig: str, td: Path, name: str, src: str, files: list[str], incs: list[str], defs: list[str]) -> str:
    c = td / f'{name}.c'
    c.write_text(src, encoding='utf-8')
    exe = td / f'{name}.exe'
    env = dict(os.environ)
    env.setdefault('ZIG_GLOBAL_CACHE_DIR', str(td / 'zig-cache'))
    cmd = [zig, 'cc', '-target', 'x86-windows-gnu', '-std=gnu11', '-O1', '-Wall', '-Werror',
           '-fsanitize=undefined', '-fno-sanitize-recover=all', *defs, *[f'-I{i}' for i in incs], str(c), *files,
           '-o', str(exe)]
    r = subprocess.run(cmd, capture_output=True, text=True, env=env)
    assert r.returncode == 0, r.stdout + r.stderr
    r = subprocess.run([str(exe)], capture_output=True, text=True)
    assert r.returncode == 0, r.stdout + r.stderr
    return r.stdout


def source(zig: str) -> None:
    with tempfile.TemporaryDirectory() as tdn:
        td = Path(tdn)
        tree = patched_tree(td)
        sb = tree / 'seabios/src'
        uds_c = (sb / 'hw/usb-uds.c').read_text(encoding='utf-8')
        assert norm_check(uds_c) == norm_check(GPL_C.read_text(encoding='utf-8')), 'request checks differ'
        # layouts: the LGPL header (with a tiny types.h) and the GPL one
        shim = td / 'shim'
        shim.mkdir()
        (shim / 'types.h').write_text('#include <stdint.h>\ntypedef uint8_t u8; typedef uint16_t u16; '
                                      'typedef uint32_t u32; typedef uint64_t u64;\n', encoding='utf-8')
        (shim / 'gpl.h').write_text('#include <stdint.h>\ntypedef uint32_t u32;\n#include "usosuds.h"\n',
                                    encoding='utf-8')
        lg = build_run(zig, td, 'lay_lgpl', LAYOUT, [], [str(shim), str(sb / 'hw')], ['-DHDR="usb-uds.h"'])
        gp = build_run(zig, td, 'lay_gpl', LAYOUT, [], [str(shim), str(GPL_H.parent)], ['-DHDR="gpl.h"'])
        assert lg == gp, (lg, gp)
        assert 'uds_diag 768' in lg and 'uds_req 80' in lg
        # the SeaBIOS copy of the check, built alone, against the GPL one
        body = re.search(r'static u32\nuds_req_check\(.*?\n\}\n', uds_c, re.S).group(0).replace('static u32', 'u32', 1)
        (td / 'lchk.c').write_text('#include "usb-uds.h"\n' + body, encoding='utf-8')
        v1 = build_run(zig, td, 'v_lgpl', VERDICTS, [str(td / 'lchk.c')], [str(shim), str(sb / 'hw')],
                       ['-DHDR="usb-uds.h"'])
        v2 = build_run(zig, td, 'v_gpl', VERDICTS, [str(GPL_C)], [str(shim), str(GPL_H.parent)], ['-DHDR="gpl.h"'])
        assert v1 == v2, (v1, v2)
        wiring(tree)
    print('[source] request check identical, layouts identical, verdicts identical')


def wiring(tree: Path) -> None:
    sb = tree / 'seabios/src'
    stacks = (sb / 'stacks.c').read_text(encoding='utf-8')
    assert 'bios_proxy VARFSEG __aligned(64)' in stacks
    for off, name in ((48, 'uds_magic'), (52, 'uds_req_phys'), (56, 'uds_doorbell'), (60, 'uds_done')):
        assert re.search(rf'{name};\s+/\* offset {off}:', stacks), name
    assert 'u32 reset_fn_hi;            /* offset 44' in stacks
    rl = (sb / 'romlayout.S').read_text(encoding='utf-8')
    loop = rl[rl.index('.Lhelper_poll_loop:'):rl.index('.Lhelper_do_pause:')]
    assert loop.count('movl 56(%ebp), %eax\n        cmpl 60(%ebp), %eax\n        jne .Lhelper_uds_request') == 2
    assert loop.index('cmpl $0, 8(%ebp)') < loop.index('movl 56(%ebp)')       # channel 0 first
    assert loop.index('\n        monitor\n') < loop.rindex('movl 56(%ebp)') < loop.index('\n        mwait\n')
    tail = rl[rl.index('.Lhelper_uds_request:'):]
    assert 'leal 48(%ebp), %eax' in tail and '$_cfunc32flat_usos_uds_service' in tail
    msc = (sb / 'hw/usb-msc.c').read_text(encoding='utf-8')
    assert 'MODESEGMENT ? -1 : usos_uds_reserve(inpipe)' in msc
    assert 'if (!MODESEGMENT && uds >= 0)\n        usos_uds_commit(' in msc
    uds = (sb / 'hw/usb-uds.c').read_text(encoding='utf-8')
    commit = uds[uds.index('usos_uds_commit(int idx'):uds.index('\n}\n', uds.index('usos_uds_commit(int idx'))]
    for banned in ('uds_bot', 'uds_cmd_in', 'usb_send_default_control', 'uds_probe'):
        assert banned not in commit, banned          # POST: no extra USB traffic
    assert 'VISIBLE32FLAT\nusos_uds_service(struct uds_channel *ch)' in uds
    assert 'memcpy(&r, (void*)rp, sizeof(r));' in uds    # the request is read once
    mk = (tree / 'seabios/Makefile').read_text(encoding='utf-8')
    assert 'hw/usb-uds.c' in mk.split('SRC32FLAT=')[1].split('SRC32SEG')[0]
    assert 'hw/usb-uds.c' not in mk.split('SRCBOTH=')[1].split('SRC16=')[0]
    print('[wiring] mailbox, helper loop, hooks, no POST traffic')


def pins() -> None:
    m = json.loads((V16 / 'manifest.json').read_text(encoding='utf-8'))
    h = m['files']['csmwrapx64.efi']
    esp = (ROOT / 'tools/xp_csmwrap_esp.sh').read_text(encoding='utf-8')
    lock = json.loads((ROOT / 'tools/csmwrap_build/lock.json').read_text(encoding='utf-8'))
    if lock['usos_version'] != '3.1.2-usos16':
        print('[pins] usos16 is not the release pin (skipped)')
        return
    assert f'PINNED={h}' in esp
    rel = (ROOT / 'installer/cmd/usos-efisign/release.go').read_text(encoding='utf-8')
    assert 'csmwrapVendorDir  = "tools/vendor/csmwrap/3.1.2-usos16"' in rel
    vm = (ROOT / 'tools/csmwrap_build/run_build_vm.py').read_text(encoding='utf-8')
    assert "3.1.2-usos16/patches" in vm and 'len(patches) != 19' in vm
    print('[pins] xp_csmwrap_esp.sh, release.go, lock.json, run_build_vm.py')


def main() -> int:
    series()
    print('[series] usos15 + 0021, manifest hashes')
    source(find_zig())
    pins()
    print('CSMWRAP-UDS16-TEST PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
