"""Host test: CSMWrap 3.1.2-usos18 patches 0023 (root HID reconnect, written by Codex on branch
fix/win95-root-hid 6fe7526a) and 0024 (USB keyboard / mouse replug on every boot,
docs/usb9x-hid-replug-2026-10-23.md).

    python -I tools/tests/csmwrap/test_csmwrap_hid18.py

1. Series: usos18/patches = usos17/patches byte for byte + 0023 (the Codex file, SHA-256
   597be290...) + 0024; LF only; manifest hashes.
2. Source: the pinned archive + the 22 patches apply; wiring of 0024 in the patched tree:
   usb_check_event calls usos_hid_tick through call32 only when RootHidCount; usos_hid_tick
   returns while the helper-side watch is armed or before POST ended (HaveRunPost 2); the
   helper idle loop runs the armed watch (uds_watch(1)), the tick the HID-only one
   (uds_watch(0): no uds_attach, no media probe); the ownership guard in xhci_usos_scan
   (DCBAAP, RS); root HID recorded without the pool; any-port match by identity; retries
   bounded by UDS_RETRIES 2 and not for "not ours"; the Evaluate Context port fix; no
   runtime allocation in the re-attach path; the interrupt poll skips a parked pipe and an
   error completion.
3. Pins (usos18 is the release pin of test/x470-98se-qemu since 2026-10-23): xp_csmwrap_esp.sh
   PINNED, release.go, lock.json, run_build_vm.py (22 patches), third-party.json, the DOS ESP
   builder, .gitattributes.
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
V17 = ROOT / 'tools/vendor/csmwrap/3.1.2-usos17'
V18 = ROOT / 'tools/vendor/csmwrap/3.1.2-usos18'
P23 = V18 / 'patches/0023-root-hid-reconnect.patch'
P24 = V18 / 'patches/0024-usb-hid-replug-everywhere.patch'
CODEX_0023 = '597be290ea5fd621d613734f2787fa390c189a1b63002c00794e46033fac6193'


def sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def series() -> None:
    p17 = sorted(p.name for p in (V17 / 'patches').glob('*.patch'))
    p18 = sorted(p.name for p in (V18 / 'patches').glob('*.patch'))
    assert p18 == p17 + [P23.name, P24.name], p18
    for n in p17:
        assert (V17 / 'patches' / n).read_bytes() == (V18 / 'patches' / n).read_bytes(), n
    assert sha(P23) == CODEX_0023, sha(P23)
    for p in (P23, P24):
        assert b'\r\n' not in p.read_bytes(), p
    head = P24.read_text(encoding='utf-8').split('\ndiff ')[0]
    for want in ('patch 0023', 'fix/win95-root-hid', 'BIOS timer interrupt', 'HaveRunPost 2', 'DCBAAP',
                 'retried', 'Own code.', 'SeaBIOS', 'LGPLv3'):
        assert want in head, want
    m = json.loads((V18 / 'manifest.json').read_text(encoding='utf-8'))
    assert m['version'] == '3.1.2-usos18'
    assert sorted(m['patches']) == p18
    for n in p18:
        assert m['patches'][n] == sha(V18 / 'patches' / n), n
    for n, h in m['files'].items():
        assert sha(V18 / n) == h, n
    assert m['upstream_rebuild']['sha256'] == json.loads(
        (V17 / 'manifest.json').read_text(encoding='utf-8'))['upstream_rebuild']['sha256']
    print('[series] usos17 + 0023 (Codex) + 0024, manifest hashes')


def func(src: str, head: str) -> str:
    i = src.index(head)
    j = src.index('\n}\n', i)
    return src[i:j + 3]


def source() -> None:
    old = u16.V16
    u16.V16 = V18
    try:
        with tempfile.TemporaryDirectory() as t:
            tree = u16.patched_tree(Path(t))
            hw = tree / 'seabios/src/hw'
            hid = (hw / 'usb-hid.c').read_text(encoding='utf-8')
            uds = (hw / 'usb-uds.c').read_text(encoding='utf-8')
            xhci = (hw / 'usb-xhci.c').read_text(encoding='utf-8')
    finally:
        u16.V16 = old
    ev = func(hid, 'void\nusb_check_event(void)')
    assert 'if (CONFIG_USB_XHCI && GET_GLOBAL(RootHidCount))\n        call32(usos_hid_tick, 0, 0);' in ev, ev
    tick = func(uds, 'void VISIBLE32FLAT\nusos_hid_tick(void)')
    assert 'if (UdsArmed || HaveRunPost != 2 || !UsosXhciCount)\n        return;' in tick, tick
    assert tick.count('uds_watch(0)') == 1 and 'uds_watch(1)' not in tick and 'uds_attach' not in tick
    idle = func(uds, 'u32 VISIBLE32FLAT\nusos_uds_idle(void)')
    assert 'uds_watch(1)' in idle and 'uds_watch(0)' not in idle
    watch = func(uds, 'static void\nuds_watch(int armed)')
    assert 'u8 why = armed ? uds_attach(c, p, &idx) : UDS_AF_NOTMSC;' in watch
    assert 'if (busy || !armed)\n        return;' in watch      # no media probe from the tick
    assert re.search(r'why != UDS_AF_NOTMSC && why != UDS_AF_POOL\s+&& why != UDS_AF_TABLE '
                     r'&& UdsWatch.tries\[c\]\[p\] < UDS_RETRIES', watch)
    assert '#define UDS_RETRIES 2' in uds
    assert 'UDS_EV_HIDGONE' in watch and 'UDS_EV_HIDBACK' in watch
    att = func(uds, 'static u8\nuds_attach(int c, int port, int *pidx)')
    assert 'if (!usos_uds_pool())\n        return UDS_AF_POOL;' in att
    scan = func(xhci, 'int\nxhci_usos_scan(int c, u32 *ccs, u32 *chg)')
    g = scan.index('dcbaap_low')
    assert g < scan.index('xhci_process_events(xhci)') and 'XHCI_CMD_RS' in scan and 'usos_lost = 1' in scan
    mps = func(xhci, 'int\nxhci_usos_ctl_mps(struct usb_pipe *p, void *in, u16 maxpacket)')
    assert 'port ? port - 1 : 0' in mps and ', pipe->pipe.speed, 0);' not in mps
    rem = func(hid, 'static void\nusb_root_remember(')
    assert 'usos_uds_pool() ||' not in rem and 'xhci_usos_register_hid(pipe)' in rem
    ra = func(hid, 'int\nusb_hid_root_attach(int c, int port)')
    assert 'malloc' not in ra and 'memalign' not in ra
    assert 'e->config_hash != hash' in ra and '(e->ctl == c && e->port == port)' in ra
    assert 'h->ctl = c;' in ra and 'h->port = port;' in ra and 'return rc;' in ra
    poll = func(xhci, 'int VISIBLE32FLAT\nxhci_poll_intr(struct usb_pipe *p, void *data)')
    assert 'if (!pipe->slotid)\n        return -1;' in poll and 'CC_SHORT_PACKET' in poll
    print('[source] 22 patches apply; tick / idle / guard / any-port / retry / mps-port wiring')


def pins() -> None:
    h = json.loads((V18 / 'manifest.json').read_text(encoding='utf-8'))['files']['csmwrapx64.efi']
    assert h == sha(V18 / 'csmwrapx64.efi')
    lock = json.loads((ROOT / 'tools/csmwrap_build/lock.json').read_text(encoding='utf-8'))
    assert lock['usos_version'] == '3.1.2-usos18', lock['usos_version']
    esp = (ROOT / 'tools/xp_csmwrap_esp.sh').read_text(encoding='utf-8')
    assert f'PINNED={h}\n' in esp and 'pinned 3.1.2-usos18 hash' in esp
    rel = (ROOT / 'installer/cmd/usos-efisign/release.go').read_text(encoding='utf-8')
    assert 'csmwrapVendorDir  = "tools/vendor/csmwrap/3.1.2-usos18"' in rel and 'usos17' not in rel
    vm = (ROOT / 'tools/csmwrap_build/run_build_vm.py').read_text(encoding='utf-8')
    assert '3.1.2-usos18/patches' in vm and 'len(patches) != 22' in vm
    blob = json.dumps(json.loads((ROOT / 'tools/release/third-party.json').read_text(encoding='utf-8')))
    assert '"version": "3.1.2-usos18"' in blob and 'tools/vendor/csmwrap/3.1.2-usos18' in blob and 'patch 0024' in blob
    dos = (ROOT / 'tools/build_csmwrap_dos_esp.py').read_text(encoding='utf-8')
    assert "3.1.2-usos18/manifest.json" in dos
    ga = (ROOT / '.gitattributes').read_text(encoding='utf-8')
    assert 'tools/vendor/csmwrap/3.1.2-usos18/** -text' in ga
    print('[pins] xp_csmwrap_esp.sh, release.go, lock.json, run_build_vm.py, third-party.json, DOS ESP, .gitattributes')


def main() -> int:
    series()
    source()
    pins()
    print('CSMWRAP-HID18-PASS')
    return 0


if __name__ == '__main__':
    sys.exit(main())
