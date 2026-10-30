"""usosusb hub support (tools/nt4/usosusb/src/usosusb.c, all builds).

Source checks for the xHCI / hub class pieces, plus the QEMU harness
(tools/tests/usosusb_hub/run_hub_qemu.py: the real driver code booted on
QEMU q35 + qemu-xhci + usb-hub) when USOS_QEMU_HUB=1 and WDK 7.1 + QEMU
are present. QEMU only; the X470 test plan is in docs/usosusb-hubs-2026-10-21.md.
"""
import os
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / 'tools/nt4/usosusb/src/usosusb.c'
HARNESS = ROOT / 'tools/tests/usosusb_hub/run_hub_qemu.py'


class HubSource(unittest.TestCase):
    def setUp(self):
        self.text = SRC.read_text(encoding='latin-1')

    def test_slot_context_topology(self):
        # Route String, root hub port, TT hub slot / port in Address Device
        self.assertIn('ictx(d, 1)[0] = d->route | ((ULONG)d->speed << 20) | (1u << 27);', self.text)
        self.assertIn('ictx(d, 1)[1] = (ULONG)d->rport << 16;', self.text)
        self.assertIn('ictx(d, 1)[2] = d->tthub | ((ULONG)d->ttport << 8);', self.text)
        self.assertIn('d->route = hub->route | ((p > 15 ? 15u : p) << (4 * hub->tier));', self.text)
        # TT: LS / FS device on a high-speed hub, inherited behind a LS / FS hub
        self.assertIn('if (hub->speed == 3 && speed < 3) {', self.text)

    def test_hub_slot_fields(self):
        # Hub = 1, Number of Ports, TTT through a slot-only Configure Endpoint
        self.assertIn('ictx(d, 1)[0] = (ictx(d, 1)[0] & ~(1u << 25)) | (1u << 26);', self.text)
        self.assertIn('((ULONG)d->nports << 24)', self.text)
        self.assertIn('((ULONG)d->httt << 16)', self.text)

    def test_hub_class_requests(self):
        for want in ('d->hss ? 0x2A00 : 0x2900',            # GET_HUB_DESCRIPTOR (USB 3 / USB 2)
                     '12 /* SET_HUB_DEPTH */',
                     'HUB_PORT_POWER', 'HUB_PORT_RESET',
                     'control(h, 0xA3, 0 /* GET_STATUS */',   # GET_PORT_STATUS
                     'control(h, 0x23, 1 /* CLEAR_FEATURE */',
                     '{ 16, 17, 18, 19, 20, 0, 0, 0 }', '{ 16, 0, 0, 19, 20, 29, 25, 26 }'):
            self.assertIn(want, self.text)

    def test_status_change_endpoint_and_poll(self):
        self.assertIn('static void queue_hub(DEV *d)', self.text)
        self.assertIn('} else if (d->ishub && ep == d->hdci) {', self.text)
        self.assertIn('hub_poll_all(&g_hc[i]);', self.text)
        self.assertIn('#define MAXTIER 4', self.text)

    def test_root_ports_unchanged(self):
        # root-port lookups only see devices without a parent hub
        self.assertIn('if (hc->dev[i].used && !hc->dev[i].parent && hc->dev[i].port == p)', self.text)
        self.assertIn('if (hc->dev[k].used && !hc->dev[k].parent && hc->dev[k].port == p) {', self.text)
        self.assertIn('dev_enum(hc, NULL, p, (v >> 10) & 0xF)', self.text)

    def test_root_port_replug(self):
        # X470 2026-10-21: mouse replug -> p16-addr4 (reset before the device
        # was ready, retries on the enabled port without a reset)
        self.assertIn('static void port_enum(HC *hc, ULONG p, int csc)', self.text)
        self.assertIn('port_enum(hc, p, (v & 0x00020000) != 0);', self.text)
        self.assertIn('delay_ms(100);\n    } else if (hc->tried & (1u << p)) {', self.text)
        self.assertIn('if (!(v & PS_PED) || (hc->tried & (1u << p))) {', self.text)
        self.assertIn('if (dev_enum(hc, NULL, p, (v >> 10) & 0xF) || !g_enum_soft)', self.text)
        self.assertEqual(self.text.count('g_enum_soft = 1;'), 5)

    def test_diag_names(self):
        self.assertIn('wfmt(path, 24, hub ? L"%s.%u" : L"p%u", pa);', self.text)
        self.assertIn('L" %s:s%uH%u%s"', self.text)
        self.assertIn('L"/tt%u.%u"', self.text)
        self.assertIn('static WCHAR g_diag[1024];', self.text)

    def test_binaries_carry_hub_build(self):
        for rel, ver in (('bin/i386/usosusb.sys', 'usosusb 1.4-nt4'), ('bin/nt6/i386/usosusb.sys', 'usosusb 1.4-nt6'),
                         ('bin/nt31/i386/usosusb.sys', 'usosusb 1.4-nt31')):
            data = (ROOT / 'tools/nt4/usosusb' / rel).read_bytes()
            self.assertIn(ver.encode('utf-16-le'), data, rel)
            self.assertIn('%s:s%uH%u%s'.encode('utf-16-le'), data, rel)


@unittest.skipUnless(os.environ.get('USOS_QEMU_HUB') == '1', 'set USOS_QEMU_HUB=1 (WDK 7.1 + QEMU, about 2 min per build)')
class HubQemu(unittest.TestCase):
    def run_variant(self, variant):
        r = subprocess.run([sys.executable, str(HARNESS), '--variant', variant], capture_output=True, text=True, timeout=1500)
        self.assertEqual(r.returncode, 0, r.stdout[-3000:] + r.stderr[-2000:])

    def test_nt6(self):
        self.run_variant('nt6')

    def test_nt4(self):
        self.run_variant('nt4')

    def test_nt31(self):
        self.run_variant('nt31')


if __name__ == '__main__':
    unittest.main()
