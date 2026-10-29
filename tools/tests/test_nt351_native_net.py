"""Native NT 3.51 LAN (no install VM): USOSNET351N build, local-source
OEMNADLB patch and the target-script wiring (docs/nt351-native-net-2026-10-28.md).

Host checks only; runtime (QEMU / X470) is recorded in the doc, not here.
"""
from pathlib import Path
import hashlib
import json
import os
import shutil
import struct
import subprocess
import tempfile
import unittest
import zlib

import capstone
import pefile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'tools/nt/usosnet/bin/i386/usosnet351n.sys'
QUALIFIED = ROOT / 'tools/nt/usosnet/bin/i386/usosnet351.sys'
CONTRACT = json.loads((Path(__file__).parent / 'fixtures/nt351-ndis-contract.json').read_text())
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
LIBRARY = ROOT / 'tools/nt351_network_setup.sh'
HOST_TOOL = ROOT / 'zig-out/bin/usos-win3x-display.exe'


def bash():
    for candidate in (shutil.which('bash'), 'C:/Program Files/Git/bin/bash.exe', 'C:/msys64/usr/bin/bash.exe'):
        if candidate and Path(candidate).is_file():
            return candidate
    return None


def one_file_cab(name, data):
    """Minimal MSCF 1.3 cabinet: one MSZIP folder, one CFDATA block."""
    deflate = zlib.compressobj(9, zlib.DEFLATED, -15)
    block = b'CK' + deflate.compress(data) + deflate.flush()
    files_off = 36 + 8
    entry = struct.pack('<IIHHHH', len(data), 0, 0, 0x1eba, 0x5f20, 0x20) + name.encode() + b'\0'
    data_off = files_off + len(entry)
    total = data_off + 8 + len(block)
    header = b'MSCF' + struct.pack('<IIIIIBBHHHHH', 0, total, 0, files_off, 0, 3, 1, 1, 1, 0, 0, 0)
    folder = struct.pack('<IHH', data_off, 1, 1)
    cdata = struct.pack('<IHH', 0, len(block), len(data)) + block
    return header + folder + entry + cdata


class NativeBinary(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.pe = pefile.PE(str(NATIVE))
        cls.imports = {i.name.decode() for m in cls.pe.DIRECTORY_ENTRY_IMPORT for i in m.imports}
        cls.dlls = {m.dll.lower() for m in cls.pe.DIRECTORY_ENTRY_IMPORT}

    def test_qualified_vm_binary_unchanged(self):
        self.assertEqual(hashlib.sha256(QUALIFIED.read_bytes()).hexdigest(),
                         'f579ef120d296eb5d19c9092f3bd87d7d97866ea2798479d5129a61b758f55cf')

    def test_only_original_ndis351_exports_with_the_miniport_timer(self):
        self.assertEqual(self.dlls, {b'ndis.sys'})
        self.assertTrue(self.imports <= set(CONTRACT['exports']), self.imports - set(CONTRACT['exports']))
        self.assertTrue({'NdisMInitializeTimer', 'NdisSetTimer', 'NdisMCancelTimer'} <= self.imports)
        self.assertNotIn('NdisMSetPeriodicTimer', self.imports)
        self.assertNotIn('NdisMSetAttributesEx', self.imports)

    def test_pe_310_and_cf8_port_access(self):
        opt = self.pe.OPTIONAL_HEADER
        self.assertEqual((opt.MajorSubsystemVersion, opt.MinorSubsystemVersion), (3, 10))
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        code = [i for s in self.pe.sections if s.Characteristics & 0x20000000
                for i in md.disasm(s.get_data(), opt.ImageBase + s.VirtualAddress)]
        text = [(i.mnemonic, i.op_str) for i in code]
        self.assertIn(('out', 'dx, eax'), text)
        self.assertIn(('in', 'eax, dx'), text)
        self.assertIn(('mov', 'edx, 0xcf8'), text)
        self.assertIn(('add', 'edx, 0xcfc'), text)
        self.assertIn(('cli', ''), text)
        self.assertIn(('popfd', ''), text)


class SourceContract(unittest.TestCase):
    def test_driver_source(self):
        source = (ROOT / 'tools/nt/usosnet/src/usosnet.c').read_text()
        header = (ROOT / 'tools/nt/usosnet/src/usosnet.h').read_text()
        self.assertIn('#define USOSNET_DRVTIMER (!USOSNET_NDIS3 || USOSNET_NT351)', header)
        self.assertIn('#define NdisReadPciSlotInformation(h, s, o, b, l) UsPciRead(', header)
        # the real NDIS function stays reachable through the parenthesized name
        self.assertIn('(NdisReadPciSlotInformation)(H, Slot, Off, Buf, Len)', source)
        self.assertIn('if (!Cf8Find(A)) { st = NDIS_STATUS_ADAPTER_NOT_FOUND; goto fail; }', source)
        self.assertIn('if (A->Cf8 && !A->PollMode) {', source)
        self.assertIn('if (A->TimerInit) return FALSE;      /* NT 3.51: TimerFn does it every 20 ms */', source)

    def test_native_registry_diagnostics(self):
        # X470 2026-10-29: NDISLoop failed (SCM 7000, %%31) without a trace;
        # the native build writes Usosnet* values under NDISLoop1 Parameters
        pe = pefile.PE(str(NATIVE))
        self.assertIn('NdisWriteConfiguration',
                      {i.name.decode() for m in pe.DIRECTORY_ENTRY_IMPORT for i in m.imports})
        source = (ROOT / 'tools/nt/usosnet/src/usosnet.c').read_text(encoding='latin-1')
        self.assertIn('#if !USOSNET_NDIS3 || USOSNET_NT351\nstatic void CfgPut(', source)
        # X470 2026-10-29 STOP 0x1E in wcslen(NULL): NDIS.SYS 3.51
        # NdisWriteConfiguration reads the service name at handle + 5Ch, i.e.
        # it takes the WrapperConfigurationContext, not the 8-byte
        # NdisOpenConfiguration handle; HexInteger is NOT_SUPPORTED there.
        self.assertIn('#if USOSNET_NT351\n#define USOSNET_DIAG_HANDLE(Cfg, Wcc) (Wcc)\n'
                      '#define USOSNET_DIAG_TYPE NdisParameterInteger\n', source)
        self.assertEqual(source.count('WriteDiag(A, USOSNET_DIAG_HANDLE(cfg, WrapperConfigurationContext))'), 2)
        self.assertNotIn('WriteDiag(A, cfg)', source)
        # NdisWriteConfiguration gets ParameterType 0 (and dword [ebp-10h], 0)
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        imp = {i.address for m in pe.DIRECTORY_ENTRY_IMPORT for i in m.imports
               if i.name == b'NdisWriteConfiguration'}
        base = pe.OPTIONAL_HEADER.ImageBase
        calls = 0
        for s in pe.sections:
            if not s.Characteristics & 0x20000000:
                continue
            code = list(md.disasm(s.get_data(), base + s.VirtualAddress))
            for k, i in enumerate(code):
                if i.mnemonic == 'call' and any(hex(a) in i.op_str for a in imp):
                    calls += 1
                    before = [(j.mnemonic, j.op_str) for j in code[max(0, k - 10):k]]
                    self.assertTrue(any(m == 'and' and o.endswith(', 0') for m, o in before) or
                                    any(m == 'mov' and o.endswith('], 0') for m, o in before), before)
        self.assertEqual(calls, 1)

    def test_native_bus_master_after_reset(self):
        # firmware-programmed queues must not DMA before the chip reset
        source = (ROOT / 'tools/nt/usosnet/src/usosnet.c').read_text(encoding='latin-1')
        early = source.index('cfg32 = ((cfg32 & 0xFFFF) | 0x0002) & ~0x0004UL;')
        reset = source.index('st = A->Chip->Ops->Reset(A);\n    if (st != NDIS_STATUS_SUCCESS) goto fail;\n#if USOSNET_NT351')
        late = source.index('cfg32 = (cfg32 & 0xFFFF & ~0x0400UL) | 0x0006;')
        self.assertLess(early, reset)
        self.assertLess(reset, late)

    def test_usosnt3_setup_watch_account_notice(self):
        source = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='latin-1')
        setup = source[source.index('static void setup(void)'):]
        setup = setup[:setup.index('\n}\n')]
        # notice first, BOOT.INI finish, then the endless PagingFiles watch
        self.assertLess(setup.index('logon_notice(1);'), setup.index('boot_ini_finish();'))
        self.assertLess(setup.index('boot_ini_finish();'), setup.index('setup_watch();'))
        watch = source[source.index('static void setup_watch(void)'):source.index('static void setup(void)')]
        self.assertIn('"RegNotifyChangeKeyValue"', watch)
        self.assertIn('REG_NOTIFY_CHANGE_LAST_SET', watch)
        # account only after GUI Setup's own PagingFiles write (SAM final)
        self.assertIn('if (pagefile_cap() && !first && !account_done) {', watch)
        self.assertIn('"RegFlushKey"', source)
        self.assertIn(r'":\\pagefile.sys 64 128"', source)
        start = source.index('static void WINAPI service_main')
        service = source[start:source.index('/* ----', start)]
        self.assertEqual(service.count('logon_notice(0);'), 2)
        self.assertIn('"LegalNoticeCaption"', source)
        self.assertIn('ACCOUNT.SET', source)

    def test_usosnt3_bus_type(self):
        source = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text()
        self.assertIn('bus_type = net351_hal_pci() ? 5 : 1;', source)
        self.assertIn('"HARDWARE\\\\DESCRIPTION\\\\System\\\\MultifunctionAdapter"', source)
        self.assertIn('(bus_type == 1 && !net351_dword(params,"BusNumber",0))', source)

    def test_target_wiring(self):
        text = TARGET.read_text()
        self.assertNotIn("NT351 LAN skipped: native install", text)
        self.assertIn('[ "$NATIVE" != 1 ] || _u351_variant=native', text)
        patch = text.index('usos_nt351_source_patch "$ls_src" "$work"')
        copy = text.index('cp "$work/WINNT.SIF" "$bt_dir/WINNT.SIF"')
        self.assertLess(patch, copy)
        self.assertIn('mv "$work/WINNT.NONET" "$work/WINNT.SIF"', text)
        stage = text.index('[ "$minor" != 51 ] || usos_nt351_stage "$work/c"')
        guard = text.index('if [ "$NATIVE" != 1 ]; then\n[ "$minor" != 50 ] || usos_nt35_stage')
        self.assertLess(stage, guard)
        build = (ROOT / 'tools/build_micro_linux.py').read_text()
        self.assertIn("'usr/lib/usos/nt3/USOSNET351N.SYS'", build)


@unittest.skipUnless(bash() and HOST_TOOL.is_file(), 'bash or zig-out/bin/usos-win3x-display.exe missing')
class SourcePatch(unittest.TestCase):
    def run_patch(self, directory, cab_name='OEMNADLB.IN_'):
        wrapper = directory / 'fbui.sh'
        wrapper.write_text('#!/bin/sh\ncmd=$1; shift\nexec "%s" "${cmd#--}" "$@"\n' % HOST_TOOL.as_posix(), newline='\n')
        script = (f'. "{LIBRARY.as_posix()}"; _u351_enabled=on; USOS_FB_UI="{wrapper.as_posix()}"; '
                  f'usos_nt351_source_patch "{directory.as_posix()}/ls" "{directory.as_posix()}/work"')
        return subprocess.run([bash(), '-c', script], capture_output=True, text=True, timeout=60)

    def test_unknown_inf_is_refused_and_untouched(self):
        parent = ROOT / 'artifacts/nt351-native-net/host-tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            d = Path(temp)
            (d / 'ls').mkdir()
            (d / 'work').mkdir()
            cab = one_file_cab('oemnadlb.inf', b'[x]\r\nadapteroptions = +\r\nskipoptions = +\r\n')
            (d / 'ls/OEMNADLB.IN_').write_bytes(cab)
            run = self.run_patch(d)
            self.assertNotEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertEqual((d / 'ls/OEMNADLB.IN_').read_bytes(), cab)

    def test_missing_cabinet_is_refused(self):
        parent = ROOT / 'artifacts/nt351-native-net/host-tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            d = Path(temp)
            (d / 'ls').mkdir()
            (d / 'work').mkdir()
            self.assertNotEqual(self.run_patch(d).returncode, 0)

    @unittest.skipUnless(os.environ.get('USOS_NT351_OEMNADLB'), 'USOS_NT351_OEMNADLB (the CD\'s OEMNADLB.IN_) not set')
    def test_original_cd_cabinet_gets_the_pinned_patch(self):
        original = Path(os.environ['USOS_NT351_OEMNADLB']).read_bytes()
        parent = ROOT / 'artifacts/nt351-native-net/host-tests'
        parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=parent) as temp:
            d = Path(temp)
            (d / 'ls').mkdir()
            (d / 'work').mkdir()
            (d / 'ls/OEMNADLB.IN_').write_bytes(original)
            run = self.run_patch(d)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('-> df77ec120ac57faa3bc5b8ba554d254a1c00be55bf56fdc930519c7b0aa16d33', run.stdout)
            got = subprocess.run([str(HOST_TOOL), 'nt3-cab-get', str(d / 'ls/OEMNADLB.IN_'), str(d / 'back.inf')],
                                 capture_output=True, timeout=30)
            self.assertEqual(got.returncode, 0)
            self.assertEqual(hashlib.sha256((d / 'back.inf').read_bytes()).hexdigest(),
                             'df77ec120ac57faa3bc5b8ba554d254a1c00be55bf56fdc930519c7b0aa16d33')
            self.assertEqual(list((d / 'work').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
