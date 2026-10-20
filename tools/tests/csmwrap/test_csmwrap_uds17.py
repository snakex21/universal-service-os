"""Host test: CSMWrap 3.1.2-usos17 patch 0022 (USB disk service stage 2, hot-swap,
docs/usb9x-hotswap-design-2026-10-19.md section 8).

    python -I tools/tests/csmwrap/test_csmwrap_uds17.py [path-to-zig.exe]

1. Series: usos17/patches = usos16/patches byte for byte + 0022; manifest hashes when the
   manifest exists.
2. Source: the pinned archive + the 22 patches; the request check still equals the GPL
   uds_req_check(); usb-uds.h and src/platform/bios/win9x/usosuds.h give the same layout,
   version 2 record included (zig cc, x86), same constants.
3. Wiring: the helper loop calls usos_uds_idle after both channel checks and before MONITOR,
   and skips MWAIT when it returns non-zero; the armed flag is VARFSEG (the loop runs before
   SeaBIOS low memory exists); the pool and the kept controllers depend on
   csm_bootdisk_hash() "only" (int13_boot_disk_only); the watch arms only from the channel 1
   service; xhci_process_events latches CSC; a controller is kept only when registered;
   seabios-config drops MEGASAS and UHCI only; no runtime malloc in the hot-plug path.
4. Pins (usos17 is the release pin since 2026-10-19): xp_csmwrap_esp.sh PINNED, release.go,
   lock.json, run_build_vm.py (20 patches), third-party.json, build_csmwrap_dos_esp.py.
"""
from __future__ import annotations

import hashlib
import json
import re
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import test_csmwrap_uds16 as u16  # noqa: E402

ROOT = u16.ROOT
V16 = u16.V16
V17 = ROOT / 'tools/vendor/csmwrap/3.1.2-usos17'
P22 = V17 / 'patches/0022-usb-disk-hotswap.patch'

LAYOUT2 = u16.LAYOUT.replace('    printf("consts', '''    O(uds_diag, watch_passes); O(uds_diag, ctls); O(uds_diag, pool); O(uds_diag, ctl);
    O(uds_diag, media); S(uds_diag_ctl); O(uds_diag_ctl, busy_arm); S(uds_diag_media);
    O(uds_diag_media, flags); O(uds_diag_media, part_lba); O(uds_diag_media, hash0);
    printf("v2 %u %u %u %u %u %u %u %u\\n", UDS_DIAG_VERSION, UDS_EV_ATTACH, UDS_EV_ARM, UDS_AF_MPS,
           UDS_FS_OTHER, UDS_FS_NTFS, UDS_MF_VBR, UDS_DIAG_CTLS);
    printf("consts''', 1)


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def series() -> None:
    p16 = sorted(p.name for p in (V16 / 'patches').glob('*.patch'))
    p17 = sorted(p.name for p in (V17 / 'patches').glob('*.patch'))
    assert p17 == p16 + [P22.name], p17
    for n in p16:
        assert (V16 / 'patches' / n).read_bytes() == (V17 / 'patches' / n).read_bytes(), n
    assert b'\r\n' not in P22.read_bytes()
    head = P22.read_text(encoding='utf-8').split('\ndiff ')[0]
    for want in ('int13_boot_disk_only = true', 'Own code.', 'SeaBIOS LGPLv3', 'CONFIG_MEGASAS', 'CONFIG_USB_UHCI'):
        assert want in head, want
    man = V17 / 'manifest.json'
    if man.exists():
        m = json.loads(man.read_text(encoding='utf-8'))
        assert m['version'] == '3.1.2-usos17'
        for n in p17:
            assert m['patches'][n] == sha(V17 / 'patches' / n), n
        for n, h in m['files'].items():
            assert sha(V17 / n) == h, n
    print('[series] usos16 + 0022' + (', manifest hashes' if man.exists() else ''))


def patched_tree(td: Path) -> Path:
    old = u16.V16
    u16.V16 = V17          # patched_tree() applies the folder's patches in order
    try:
        return u16.patched_tree(td)
    finally:
        u16.V16 = old


def func(src: str, head: str) -> str:
    i = src.index(head)
    return src[i:src.index('\n}\n', i)]


def wiring(tree: Path) -> None:
    sb = tree / 'seabios/src'
    rl = (sb / 'romlayout.S').read_text(encoding='utf-8')
    loop = rl[rl.index('.Lhelper_poll_loop:'):rl.index('.Lhelper_do_pause:')]
    i_idle = loop.index('$_cfunc32flat_usos_uds_idle')
    assert loop.index('jne .Lhelper_uds_request') < i_idle < loop.index('\n        monitor\n')
    assert re.search(r'\$_cfunc32flat_usos_uds_idle, %edi\s+calll \*%edi\s+testl %eax, %eax\s+jnz '
                     r'\.Lhelper_do_pause', loop)
    uds = (sb / 'hw/usb-uds.c').read_text(encoding='utf-8')
    assert 'u8 UdsArmed VARFSEG;' in uds and 'struct uds_watch UdsWatch VARLOW;' in uds
    idle = func(uds, 'u32 VISIBLE32FLAT\nusos_uds_idle(void)')
    assert idle.index('if (!UdsArmed)') < idle.index('UdsWatch')            # nothing low before armed
    pool = func(uds, 'usos_uds_pool_setup(void)')
    assert 'csm_bootdisk_hash(&hash, &only) || !only' in pool and 'memalign_high(4096' in pool
    svc = func(uds, 'usos_uds_service(struct uds_channel *ch)')
    assert 'if (!UdsArmed && UdsWatch.pool)\n        uds_arm();' in svc
    assert uds.count('uds_arm();') == 1                                    # only from the channel 1 service
    for f in ('uds_attach(int c', 'uds_watch(void)', 'uds_arm(void)', 'uds_release(int idx'):
        body = func(uds, f)
        assert 'malloc' not in body and 'memalign' not in body, f         # the pool only
    watch = func(uds, 'uds_watch(void)')
    assert 'busy = 1;' in watch and 'if (busy || UdsWatch.due[c][p] == pass)' in watch   # one bring-up, debounce
    assert 'uds_free_entry' in func(uds, 'uds_attach(int c') and '!uds_bios_drive(i)' in func(uds, 'uds_free_entry')
    assert 'd->generation = ++UdsWatch.gen + 1;' in uds
    x = (sb / 'hw/usb-xhci.c').read_text(encoding='utf-8')
    pe = func(x, 'static void xhci_process_events(struct usb_xhci_s *xhci)')
    assert 'xhci->usos_latch |= 1 << port;' in pe and '(portsc & XHCI_PORTSC_CSC) && port < 32' in pe
    cfg = func(x, 'configure_xhci(void *data)')
    assert cfg.index('xhci_usos_register(xhci);') < cfg.index('xhci_check_ports(xhci)')
    assert 'if (count || xhci->usos_idx)' in cfg
    reg = func(x, '\nxhci_usos_register(struct usb_xhci_s *xhci)\n{')
    assert 'if (!usos_uds_pool() || UsosXhciCount >= USOS_X_CTLS)' in reg
    assert 'HCRST' not in x[x.index('USOS patch 0022: runtime bring-up'):]   # never reset the controller
    assert 'usos_uds_pool_setup();' in func(x, 'xhci_setup(void)')
    cfgtxt = (tree / 'seabios-config').read_text(encoding='utf-8')
    off = re.findall(r'# (CONFIG_\w+) is not set', cfgtxt)
    assert {'CONFIG_MEGASAS', 'CONFIG_USB_UHCI'} <= set(off)
    for keep in ('CONFIG_AHCI', 'CONFIG_NVME', 'CONFIG_USB_XHCI', 'CONFIG_USB_EHCI', 'CONFIG_USB_OHCI',
                 'CONFIG_USB_MSC', 'CONFIG_USB_UAS', 'CONFIG_USB_KEYBOARD', 'CONFIG_USB_MOUSE', 'CONFIG_SDCARD'):
        assert keep not in off, keep
    print('[wiring] idle hook, armed flag in the F-segment, pool gate, latch, kept controllers, config')


def source(zig: str) -> None:
    with tempfile.TemporaryDirectory() as tdn:
        td = Path(tdn)
        tree = patched_tree(td)
        sb = tree / 'seabios/src'
        uds_c = (sb / 'hw/usb-uds.c').read_text(encoding='utf-8')
        assert u16.norm_check(uds_c) == u16.norm_check(u16.GPL_C.read_text(encoding='utf-8'))
        shim = td / 'shim'
        shim.mkdir()
        (shim / 'types.h').write_text('#include <stdint.h>\ntypedef uint8_t u8; typedef uint16_t u16; '
                                      'typedef uint32_t u32; typedef uint64_t u64;\n', encoding='utf-8')
        (shim / 'gpl.h').write_text('#include <stdint.h>\ntypedef uint32_t u32;\n#include "usosuds.h"\n',
                                    encoding='utf-8')
        lg = u16.build_run(zig, td, 'lay_lgpl', LAYOUT2, [], [str(shim), str(sb / 'hw')], ['-DHDR="usb-uds.h"'])
        gp = u16.build_run(zig, td, 'lay_gpl', LAYOUT2, [], [str(shim), str(u16.GPL_H.parent)], ['-DHDR="gpl.h"'])
        assert lg == gp, (lg, gp)
        assert 'uds_diag 984' in lg and 'uds_diag.media 856' in lg and 'v2 2 11 17 11 9 6 2 4' in lg, lg
        wiring(tree)
    print('[source] request check identical, version 2 layouts identical')


def pins() -> None:
    h = json.loads((V17 / 'manifest.json').read_text(encoding='utf-8'))['files']['csmwrapx64.efi']
    assert h == '3a36aba19b29ca5cf2fb35567381d48105bacdf11cc3198eccdc678d8c467c3d'
    lock = json.loads((ROOT / 'tools/csmwrap_build/lock.json').read_text(encoding='utf-8'))
    assert lock['usos_version'] == '3.1.2-usos17', lock['usos_version']
    esp = (ROOT / 'tools/xp_csmwrap_esp.sh').read_text(encoding='utf-8')
    assert f'PINNED={h}\n' in esp and 'pinned 3.1.2-usos17 hash' in esp
    rel = (ROOT / 'installer/cmd/usos-efisign/release.go').read_text(encoding='utf-8')
    assert 'csmwrapVendorDir  = "tools/vendor/csmwrap/3.1.2-usos17"' in rel and 'usos16' not in rel
    vm = (ROOT / 'tools/csmwrap_build/run_build_vm.py').read_text(encoding='utf-8')
    assert '3.1.2-usos17/patches' in vm and 'len(patches) != 20' in vm
    tp = json.loads((ROOT / 'tools/release/third-party.json').read_text(encoding='utf-8'))
    blob = json.dumps(tp)
    assert '"version": "3.1.2-usos17"' in blob and 'tools/vendor/csmwrap/3.1.2-usos17' in blob and 'patch 0022' in blob
    dos = (ROOT / 'tools/build_csmwrap_dos_esp.py').read_text(encoding='utf-8')
    assert "3.1.2-usos17/manifest.json" in dos
    print('[pins] xp_csmwrap_esp.sh, release.go, lock.json, run_build_vm.py, third-party.json, DOS ESP')


def main() -> int:
    series()
    source(u16.find_zig())
    pins()
    print('CSMWRAP-UDS17-TEST PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
