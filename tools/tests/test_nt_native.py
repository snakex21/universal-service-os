"""Native NT 3.51 install without the install VM (docs/nt-native-plan.md):
nt3_native_txtsetup in tools/nt4_csmwrap_target.sh and the nt3-native.flag
routing in tools/w9x_csmwrap_prepare.sh. Host only: Git sh, temp folders; no
VM, no disk, no Microsoft file (the TXTSETUP.SIF below is a synthetic
fixture with the section shapes of the NT 3.51 CD).
"""
from pathlib import Path
import shutil
import tempfile
import unittest

from test_w9x_phase1_qemu import sh
from test_nt4_flow import function_text

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'

SIF = (
    '[ScsiClass.Load]\r\ndisk   = scsidisk.sys\r\n'
    '[SCSI.Load]\r\ncpqarray = cpqarray.sys,4\r\naha154x = aha154x.sys,4\r\n'
    'wd33c93 = wd33c93.sys,4,noload\r\namsint = amsint.sys,4\r\n\r\n'
    '[SCSI]\r\naha154x  = "Adaptec 154x"\r\namsint   = "AMD PCI SCSI/NET Adapter"\r\n'
    '[SetupData]\r\nProductType = 0\r\nMajorVersion = 3\r\nMinorVersion = 51\r\n'
    'OsLoadOptions = "/nodebug"\r\nAllowFloppySetup = 1\r\n'
    '[Files]\r\nscsidisk.sys = dx,d7,_3,4,0,0\r\namsint.sys   = dx,d7,_3,4,1\r\n'
)


class NativeTxtsetup(unittest.TestCase):
    def run_fn(self, ports, opts, text):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt-native-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'in.sif').write_bytes(text.encode('ascii'))
        fn = function_text(TARGET, 'nt3_native_txtsetup')
        rc, _, err = sh(f'{fn}\nnt3_native_txtsetup "{ports}" "{opts}" < "{(tmp / "in.sif").as_posix()}" > "{(tmp / "out.sif").as_posix()}"')
        return rc, (tmp / 'out.sif').read_bytes().decode('ascii'), err

    def section(self, text, name):
        out, inside = [], False
        for line in text.split('\r\n'):
            if line.startswith('['):
                inside = line.lower() == name.lower()
                continue
            if inside and line:
                out.append(line)
        return out

    def test_only_the_usos_miniports_load(self):
        rc, out, err = self.run_fn('ahcint', '/nodebug /NUMPROC=2 /MAXMEM=1024', SIF)
        self.assertEqual(rc, 0, err)
        self.assertEqual(self.section(out, '[SCSI.Load]'), ['ahcint = ahcint.sys,4'])
        self.assertIn('ahcint = "USOS AHCI (SATA)"', self.section(out, '[SCSI]'))
        self.assertIn('amsint   = "AMD PCI SCSI/NET Adapter"', self.section(out, '[SCSI]'))
        files = self.section(out, '[Files]')
        self.assertIn('ahcint.sys = dx,d7,_3,4,1', files)
        self.assertIn('amsint.sys   = dx,d7,_3,4,1', files)
        self.assertEqual(self.section(out, '[ScsiClass.Load]'), ['disk   = scsidisk.sys'])
        self.assertNotIn('\r\r', out)
        self.assertTrue(out.endswith('\r\n'))

    def test_load_options_replace_the_cd_ones(self):
        _, out, _ = self.run_fn('ahcint', '/nodebug /NUMPROC=2 /MAXMEM=1024', SIF)
        setup = self.section(out, '[SetupData]')
        self.assertEqual([l for l in setup if l.lower().startswith('osloadoptions')], ['OsLoadOptions = "/nodebug /NUMPROC=2 /MAXMEM=1024"'])
        self.assertIn('MinorVersion = 51', setup)

    def test_nvme_target_adds_usosnvme(self):
        _, out, _ = self.run_fn('ahcint usosnvme', '/nodebug', SIF)
        self.assertEqual(self.section(out, '[SCSI.Load]'), ['ahcint = ahcint.sys,4', 'usosnvme = usosnvme.sys,4'])
        self.assertIn('usosnvme = "USOS NVMe"', self.section(out, '[SCSI]'))
        self.assertIn('usosnvme.sys = dx,d7,_3,4,1', self.section(out, '[Files]'))

    def test_without_the_amsint_row_nothing_is_written(self):
        rc, out, _ = self.run_fn('ahcint', '/nodebug', SIF.replace('amsint.sys   = dx,d7,_3,4,1\r\n', ''))
        self.assertNotEqual(rc, 0)
        self.assertEqual(out, '')


class NativeWiring(unittest.TestCase):
    def test_target_refuses_other_versions_before_the_disk(self):
        text = TARGET.read_text(encoding='utf-8')
        gate = text.index('if [ "$NATIVE" = 1 ]; then\n    { [ "$nt3:$minor" = yes:51 ]')
        self.assertLess(gate, text.index('dd if=/dev/zero of="$TARGET_DEVICE"'))
        self.assertIn('No disk was changed', text[gate:gate + 300])
        # The miniports go next to SETUPLDR (~BT) and into the local source.
        block = text[text.index('nt3_native_txtsetup "$ports"'):]
        self.assertIn('for dir in "$bt_dir" "$ls_src"; do', block[:1200])
        # Native NT 3.51 has LAN since docs/nt351-native-net-2026-10-28.md;
        # native NT 3.5 still skips it.
        self.assertIn("log 'NT35 LAN skipped: native install", text)
        self.assertIn('if [ "$NATIVE" = 1 ] && [ "$major:$minor" != 3:51 ]; then', text)
        self.assertIn('if [ "$major:$minor" = 3:50 ] && [ "$NATIVE" != 1 ]; then', text)

    def test_native_nt3_lan_stage_needs_no_lan_library(self):
        # X470 2026-10-28 (B261028-165856): the native path never sourced
        # the LAN libraries, so "usos_nt351_stage: not found" stopped the
        # prep. Since docs/nt351-native-net-2026-10-28.md native NT 3.51
        # sources nt351_network_setup.sh (its stage functions exist), native
        # NT 3.5 still sources nothing. Run the staging block as it is.
        nl = chr(10)
        text = TARGET.read_text(encoding='utf-8')
        start = text.index('[ "$minor" != 51 ] || usos_nt351_stage')
        end = text.index('if [ "$NATIVE" != 1 ]; then' + nl + '[ "$minor" != 50 ] || usos_nt35_stage', start)
        block = text[start:text.index(nl + 'fi' + nl, end) + 4]
        self.assertIn('usos_nt35_client_request', block)
        stub = nl.join(['fail() { echo "FAIL $1"; exit 9; }', 'work=/x; product=0; ANSWER_KIND=PROFILE', ''])
        names = ('usos_nt351_stage', 'usos_nt351_client_request', 'usos_nt35_stage', 'usos_nt35_client_request')
        calls = ''.join(n + '() { echo ' + n + '; }' + nl for n in names)
        nt351 = ''.join(n + '() { echo ' + n + '; }' + nl for n in names[:2])
        # Native 3.5: no library, nothing called.
        rc, out, err = sh(stub + 'NATIVE=1; minor=50' + nl + block + 'echo ok' + nl)
        self.assertEqual((rc, out.strip()), (0, 'ok'), err)
        # Native 3.51: the sourced 3.51 functions only.
        rc, out, err = sh(stub + nt351 + 'NATIVE=1; minor=51' + nl + block)
        self.assertEqual((rc, out.split()), (0, list(names[:2])), err)
        # The install VM path still calls the sourced stage functions.
        for minor, want in (('51', list(names[:2])), ('50', list(names[2:]))):
            rc, out, err = sh(stub + calls + 'NATIVE=0; minor=' + minor + nl + block)
            self.assertEqual((rc, out.split()), (0, want), err)

    def test_target_nt35_needs_no_key_page(self):
        text = TARGET.read_text(encoding='utf-8')
        block = text[text.index('if [ "$NATIVE" = 1 ] && [ "$minor" = 50 ]; then'):]
        block = block[:block.index(chr(10) + 'fi' + chr(10))]
        # "unable to verify C:" never comes: the stand-in where 3.5 looks (~BT).
        self.assertIn('cp "$drv/USOSACHK.EXE" "$bt_dir/AUTOCHK.EXE"', block)
        # GUI Setup's processor check: the patched INITIAL.IN_ or a stop.
        self.assertIn('--nt35-initial "$initial" "$work/INITIAL.NEW"', block)
        self.assertIn("fail 'cannot patch the NT 3.5 INITIAL.INF processor check'", block)
        self.assertIn('NT_NATIVE_LOAD_OPTIONS=${NT35_NATIVE_LOAD_OPTIONS:-/NUMPROC=2 /MAXMEM=128}', text)
        # The page recorder is staged for every native start.
        self.assertIn('cp "$drv/USOSANS3.EXE" "$usos/USOSANS3.EXE"', text)

    def test_usosnt3_setup_starts_the_recorder(self):
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
        setup = src[src.index('static void setup(void)'):]
        setup = setup[:setup.index(chr(10) + '}' + chr(10))]
        self.assertIn('DIR "USOSANS3.EXE"', setup)
        self.assertIn('DETACHED_PROCESS', setup)
        micro = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('usr/lib/usos/nt3/USOSANS3.EXE', micro)


    def test_native_marker_early_usb_and_boot_ini_finish(self):
        # X470 2026-10-28 (native NT 3.51, B261028-191138): the first start had
        # only PS/2 (usosusb came with the service's post(), active only after
        # one more restart) and BOOT.INI kept Setup's timeout=30 + the "C:\"
        # entry of the saved syslinux boot sector.
        text = TARGET.read_text(encoding='utf-8')
        nt3 = text[text.index('usos="$work/c/USOS/NT3"' + chr(10) + 'mkdir -p "$usos"'):text.index('usos="$work/c/USOS/NT4"')]
        self.assertIn('''printf 'boot_options=%s\\r\\n' "$NT_NATIVE_LOAD_OPTIONS" > "$usos/NATIVE.TXT"''', nt3)
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
        setup = src[src.index('static void setup(void)'):]
        setup = setup[:setup.index(chr(10) + '}' + chr(10))]
        self.assertIn('if (native_install())\n        usb_early();', setup)
        early = src[src.index('static void usb_early(void)'):]
        early = early[:early.index(chr(10) + '}' + chr(10))]
        for piece in ('"\\\\drivers\\\\usosusb.sys"', 'set_dword("usosusb", NULL, "Start", 1);',
                      'set_sz("usosusb", "Group", REG_SZ, "Keyboard Port");',
                      'set_dword("Kbdclass", "Parameters", "ConnectMultiplePorts", 1);',
                      'set_dword("Mouclass", "Parameters", "ConnectMultiplePorts", 1);'):
            self.assertIn(piece, early)
        service = src[src.index('static void WINAPI service_main('):]
        service = service[:service.index(chr(10) + '}' + chr(10))]
        self.assertIn('if (native_install()) {\n        pagefile_cap();\n        boot_ini_finish();', service)
        finish = src[src.index('static void boot_ini_finish(void)' + chr(10) + '{'):]
        finish = finish[:finish.index(chr(10) + '}' + chr(10))]
        for piece in ('"timeout=5"', '" [USOS /SOS]\\" /SOS"', '" [VGA mode]\\" /basevideo /sos"',
                      '"C:\\\\BOOTSECT.DOS"', '"C:\\\\LDLINUX.SYS"', '"C:\\\\WINNT.SIF"'):
            self.assertIn(piece, finish)

    def test_native_pagefile_cap(self):
        # X470 2026-10-28 (native NT 3.51): GUI Setup's VIRTUAL.INF sized the
        # pagefile RAM + 12 MiB capped at the free space: 1816 MiB of the
        # 2000 MiB FAT16 C:. It writes PagingFiles late in GUI Setup, so the
        # first-start service (not /setup) sets a fixed 64-128 MiB file.
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
        cap = src[src.index('static void pagefile_cap(void)' + chr(10) + '{'):]
        cap = cap[:cap.index(chr(10) + '}' + chr(10))]
        for piece in ('Session Manager\\\\Memory Management"', '":\\\\pagefile.sys 64 128"',
                      'REG_MULTI_SZ', '(DWORD)n + 2', 'value[n + 1] = 0;'):
            self.assertIn(piece, cap)
        setup = src[src.index('static void setup(void)'):]
        setup = setup[:setup.index(chr(10) + '}' + chr(10))]
        self.assertNotIn('pagefile_cap', setup)
        manual = src[src.index('if (lstrcmpA(opt, "finish") == 0)'):]
        manual = manual[:manual.index('ExitProcess(0);')]
        self.assertIn('pagefile_cap();', manual)


class Recorder(unittest.TestCase):
    def test_imports_exist_on_nt3_and_pe_version(self):
        # kernel32 / user32 calls checked against the NT 3.51 CD's DLLs
        # (2026-10-28); all of them are NT 3.1 APIs.
        import struct
        import sys
        sys.path.insert(0, str(ROOT / 'tools'))
        from build_windows_usos_res import build_nt3_answer
        from check_nt52_driver_imports import pe
        allowed = {
            # GetModuleFileNameA / GetCommandLineA / CreateProcessA /
            # CreateMutexA / GetLastError: also in the NT 3.51 and NT 4.0
            # kernel32 (checked 2026-10-28).
            'kernel32.dll': {'CloseHandle', 'CreateFileA', 'ExitProcess', 'FlushFileBuffers', 'GetTickCount',
                             'SetFilePointer', 'Sleep', 'WriteFile', 'lstrcmpA', 'lstrcmpiA', 'lstrlenA',
                             'GetModuleFileNameA', 'GetCommandLineA', 'CreateProcessA', 'CreateMutexA', 'GetLastError'},
            'user32.dll': {'EnumChildWindows', 'EnumWindows', 'GetClassNameA', 'GetDlgCtrlID', 'GetWindowTextA',
                           'GetWindowTextLengthA', 'IsWindowEnabled', 'IsWindowVisible', 'wsprintfA'},
        }
        exe = build_nt3_answer(ROOT, ROOT / 'zig-out/windows-usos-res/ans3-test')
        data = exe.read_bytes()
        opt = struct.unpack_from('<I', data, 0x3c)[0] + 24
        self.assertEqual(struct.unpack_from('<HH', data, opt + 48), (3, 10))
        _, imports = pe(exe)
        self.assertEqual([f'{m}!{n}' for m, n in imports if n not in allowed.get(m.lower(), set())], [])
        src = (ROOT / 'tools/nt3/usosans3/usosans3.c').read_text(encoding='utf-8')
        # Edit controls: only the length, never the text (passwords).
        self.assertIn('textlen=%d', src)
        self.assertIn('mode=record', src)

    def test_prepare_flags_per_family_and_skip_the_vm(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('NT351|NT351S|NT35|NT35S) nt_native_flag=nt3-native.flag ;;', text)
        self.assertIn('NT4|NT4S|NT4T) nt_native_flag=nt4-native.flag ;;', text)
        self.assertIn('[ -z "$nt_native_flag" ] || [ ! -e "/mnt/esp/EFI/USOS/win9x/$nt_native_flag" ] || nt_native=yes', text)
        self.assertEqual(text.count('nt_native=yes'), 1)
        # NT 3.1 and POSReady have no native flag.
        self.assertNotIn('NT31|NT31S) nt_native_flag', text)
        self.assertIn('NT_NATIVE="$([ "$nt_native" = yes ] && echo 1 || echo 0)"', text)
        native = text.index('if [ -n "$nt4" ] && [ "$nt_native" = yes ]; then\n        # Native')
        vm = text.index('nt4_vm_install "$TARGET_DEVICE"')
        self.assertLess(native, vm)
        self.assertIn('xp_csmwrap_esp.sh', text[native:vm])
        # The VM gate is not consulted for a native start.
        gate = text.index('elif [ -n "$nt4" ] && [ "$nt_native" = yes ]; then')
        self.assertLess(gate, text.index('elif [ -n "$nt4" ]; then\n        . /usr/lib/usos/w9x_phase1_qemu.sh'))


# The section shapes of the NT 4.0 CDs (WS PL, Enterprise Server EN, TSE EN):
# [SourceDisksFiles] twice, [SetupData] twice, the Enterprise CD's
# OsLoadOptionsVar. Synthetic, no Microsoft text beyond section/key names.
SIF4 = (
    '[SourceDisksFiles]\r\namsint.sys   = 1,,,,,,_3,4,1\r\natapi.sys    = 1,,,,,,_3,4,0,0\r\n'
    'ntkrnlmp.exe = 1,,,,,,_1,2,3\r\nntoskrnl.exe = 1,,,,,,,2,3\r\n\r\n'
    '[SourceDisksFiles]\r\nperfc015.dat = 1,,,,,,,2,0,0\r\n\r\n'
    '[SetupData]\r\nMajorVersion = 4\r\nMinorVersion = 0\r\nOsLoadOptions = "/nodebug /maxmem=256"\r\n'
    'OsLoadOptionsVAR = "/maxmem=256"\r\nProductType = 1\r\n\r\n'
    '[SCSI.Load]\r\ncpqarray = cpqarray.sys,4\r\natapi = atapi.sys,4\r\namsint = amsint.sys,4\r\n\r\n;\r\n; Extenders\r\n;\r\n'
    '[Extenders.Load]\r\npcmcia = pcmcia.sys,4\r\n'
    '[SetupData]\r\nFreeDiskSpace = 125872\r\n'
    '[Computer]\r\nmps_up      = "MPS Uniprocessor PC",files.none\r\nmps_mp      = "MPS Multiprocessor PC",files.none\r\n'
    '[SCSI]\r\namsint   = "AMD PCI SCSI Controller/Ethernet Adapter"\r\n'
)


def run_fn_file(fn_name, args, text):
    tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-native-'))
    try:
        (tmp / 'in.sif').write_bytes(text.encode('ascii'))
        fn = function_text(TARGET, fn_name)
        rc, out, err = sh(f'{fn}\n{fn_name} {args} < "{(tmp / "in.sif").as_posix()}" > "{(tmp / "out.sif").as_posix()}"')
        return rc, (tmp / 'out.sif').read_bytes().decode('ascii'), err
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def all_sections(text, name):
    out, inside = [], False
    for line in text.split('\r\n'):
        if line.startswith('['):
            inside = line.lower() == name.lower()
            if inside:
                out.append([])
            continue
        if inside and line:
            out[-1].append(line)
    return out


class Nt4NativeTxtsetup(unittest.TestCase):
    OPTS = '"ahcint" "/nodebug /NUMPROC=2 /MAXMEM=1024" "/NUMPROC=2 /MAXMEM=1024"'

    def test_sourcedisksfiles_row_once_and_scsi_load(self):
        rc, out, err = run_fn_file('nt3_native_txtsetup', self.OPTS, SIF4)
        self.assertEqual(rc, 0, err)
        files = all_sections(out, '[SourceDisksFiles]')
        self.assertEqual(len(files), 2)
        self.assertIn('ahcint.sys = 1,,,,,,_3,4,1', files[0])
        self.assertNotIn('ahcint.sys = 1,,,,,,_3,4,1', files[1])
        self.assertEqual(all_sections(out, '[SCSI.Load]'), [['ahcint = ahcint.sys,4', ';', '; Extenders', ';']])
        self.assertEqual(all_sections(out, '[Extenders.Load]'), [['pcmcia = pcmcia.sys,4']])
        self.assertIn('ahcint = "USOS AHCI (SATA)"', all_sections(out, '[SCSI]')[0])

    def test_both_setupdata_get_the_options_and_the_var(self):
        _, out, _ = run_fn_file('nt3_native_txtsetup', self.OPTS, SIF4)
        setups = all_sections(out, '[SetupData]')
        self.assertEqual(len(setups), 2)
        for setup in setups:
            opts = [l for l in setup if l.lower().startswith('osloadoptions')]
            self.assertEqual(opts, ['OsLoadOptions = "/nodebug /NUMPROC=2 /MAXMEM=1024"', 'OsLoadOptionsVar = "/NUMPROC=2 /MAXMEM=1024"'])
        self.assertNotIn('maxmem=256', out)
        self.assertIn('FreeDiskSpace = 125872', out)

    def test_nt3_call_without_var_keeps_a_var_row(self):
        # The NT 3.5x call passes no third argument: OsLoadOptionsVar rows stay.
        rc, out, err = run_fn_file('nt3_native_txtsetup', '"ahcint" "/nodebug"', SIF4)
        self.assertEqual(rc, 0, err)
        self.assertIn('OsLoadOptionsVAR = "/maxmem=256"', out)
        self.assertNotIn('OsLoadOptionsVar = ', out)

    def test_computer_desc(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-ct-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'in.sif').write_bytes(SIF4.encode('ascii'))
        fn = function_text(TARGET, 'nt4_computer_desc')
        rc, out, err = sh(f'{fn}\nnt4_computer_desc mps_mp < "{(tmp / "in.sif").as_posix()}"')
        self.assertEqual((rc, out), (0, 'MPS Multiprocessor PC\n'), err)

    def test_native_answer_computer_type(self):
        desc = '"MPS Multiprocessor PC"'
        _, out, _ = run_fn_file('nt4_native_answer', desc, '[Unattended]\r\nOemPreinstall = Yes\r\n[UserData]\r\nFullName = "x"\r\n')
        self.assertEqual(out, '[Unattended]\r\nComputerType = "MPS Multiprocessor PC", Retail\r\nOemPreinstall = Yes\r\n[UserData]\r\nFullName = "x"\r\n')
        # An answer with its own ComputerType keeps it.
        _, out, _ = run_fn_file('nt4_native_answer', desc, '[Unattended]\r\nComputerType = "Standard PC", Retail\r\n')
        self.assertEqual(out.count('ComputerType'), 1)
        self.assertIn('"Standard PC"', out)
        # No [Unattended] section: one is added.
        _, out, _ = run_fn_file('nt4_native_answer', desc, '[UserData]\r\nFullName = "x"\r\n')
        self.assertTrue(out.endswith('\r\n[Unattended]\r\nComputerType = "MPS Multiprocessor PC", Retail\r\n'))


FAKE_FB_UI = '''#!/bin/sh
[ "$1" = --nt4-kernel ] || exit 2
echo "[NT4_KERNEL] $2: CPUID leaf limit 3 -> 7Fh" >&2
[ "$FAKE_RC" = 0 ] || exit "$FAKE_RC"
{ cat "$2"; echo patched; } > "$3"
'''


class Nt4NativeKernels(unittest.TestCase):
    """nt4_native_kernels with a stand-in usos-fb-ui (no Microsoft file)."""

    def run_kernels(self, files, tool_rc=0):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt4-kern-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'i386').mkdir()
        for name in files:
            (tmp / 'i386' / name).write_bytes(b'kernel ' + name.encode())
        tool = tmp / 'fbui.sh'
        tool.write_text(FAKE_FB_UI, encoding='ascii', newline='\n')
        fn = function_text(TARGET, 'nt4_native_kernels')
        script = ('log() { printf "[NT4_CSMWRAP] %s\\n" "$*"; }\nfail() { printf "STOP: %s\\n" "$1"; exit 1; }\n' + fn + '\n'
                  f'work="{(tmp / "work").as_posix()}"; i386="{(tmp / "i386").as_posix()}"; mkdir -p "$work"\n'
                  f'FAKE_RC={tool_rc} USOS_FB_UI="{tool.as_posix()}" nt4_native_kernels\n')
        rc, out, err = sh(script)
        return rc, out + err, tmp

    def test_plain_and_compressed_kernels(self):
        rc, out, tmp = self.run_kernels(['NTOSKRNL.EX_', 'NTKRNLMP.EXE'])
        self.assertEqual(rc, 0, out)
        self.assertEqual((tmp / 'work/kernel/NTOSKRNL.EXE').read_bytes(), b'kernel NTOSKRNL.EX_patched\n')
        self.assertEqual((tmp / 'work/kernel/NTKRNLMP.EXE').read_bytes(), b'kernel NTKRNLMP.EXEpatched\n')
        self.assertIn('[NT4_CSMWRAP] [NT4_KERNEL]', out)

    def test_no_match_or_missing_kernel_stops(self):
        rc, out, _ = self.run_kernels(['NTOSKRNL.EXE', 'NTKRNLMP.EXE'], tool_rc=1)
        self.assertNotEqual(rc, 0)
        self.assertIn('cannot raise the CPUID leaf limit of NTOSKRNL', out)
        self.assertIn('No disk was changed', out)
        rc, out, _ = self.run_kernels(['NTOSKRNL.EXE'])
        self.assertNotEqual(rc, 0)
        self.assertIn('the ISO has no I386\\NTKRNLMP.EXE', out)


class Nt4NativeWiring(unittest.TestCase):
    def test_target_order_and_pieces(self):
        text = TARGET.read_text(encoding='utf-8')
        first_write = text.index('dd if=/dev/zero of="$TARGET_DEVICE"')
        self.assertLess(text.index('[ "$nt3:$major" = :4 ]'), first_write)
        # The kernels are patched and the hook options byte set before the disk is touched.
        self.assertLess(text.index('        nt4_native_kernels\n'), first_write)
        self.assertLess(text.index('printf \'\\001\' | dd of="$work/hook.bin" bs=1 seek=509'), first_write)
        self.assertIn('[ -z "$nt3$nt4_native_mbr" ] || mbr_code=$LIB/nt3-e820-mbr-440.bin', text)
        self.assertIn('[ -z "$nt3$nt4_native_mbr" ] || mbr_hook=$LIB/nt3-e820-hook-512.bin', text)
        self.assertIn('[ -n "$nt3" ] || [ "$NATIVE" != 1 ] || nt4_native_mbr=yes', text)
        # Kernels and miniports in ~BT and the local source, the CD twin removed.
        block = text[text.index('elif [ "$NATIVE" = 1 ]; then\n    # Native NT 4.0'):]
        block = block[:block.index('\nfi\n')]
        self.assertIn('nt3_native_txtsetup "$ports" "/nodebug $NT_NATIVE_LOAD_OPTIONS" "$NT_NATIVE_LOAD_OPTIONS"', block)
        self.assertIn('for dir in "$bt_dir" "$ls_src"; do', block)
        self.assertIn('rm -f "$dir/$base.EX_" "$dir/$base.EXE"', block)
        self.assertIn('cp "$work/kernel/$base.EXE" "$dir/$base.EXE"', block)
        # Recorder from CMDLINES.TXT (NT 4.0 has no DetachedProgram).
        self.assertIn('USOSANS3.EXE /detach', text)
        self.assertIn('cp "$ans3" "$usos/USOSANS3.EXE"', text)
        self.assertIn('nt4_native_answer "$nt4_mps_desc"', text)

    def test_prepare_service_pack_optional_only_native(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('[ -n "$sp_exe" ] || [ "$nt_native" = yes ] || stop "Windows NT 4.0 Terminal Server needs', text)
        self.assertIn('[ -n "$sp_exe" ] || [ "$nt_native" = yes ] || stop \'Windows NT 4.0 needs Service Pack 6a', text)
        self.assertLess(text.index('nt_native=no'), text.index('if [ "$tag" = NT4T ]; then'))

    def test_mbr_options_byte(self):
        src = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        self.assertIn('.equ HOOK_OPTIONS,    509', src)
        check = src.index('    test byte ptr es:[HOOK_OPTIONS], OPT_KEEP_PCI_BIOS\n    jnz boot_partition\n    mov ax, 0xB101\n')
        self.assertLess(src.index('    mov word ptr [0x15 * 4 + 2], es\n'), check)
        ps1 = (ROOT / 'tools/build_xp_geometry_fix_mbr.ps1').read_text(encoding='utf-8')
        # The hook code stays below the options byte.
        self.assertIn('max is 500', ps1)

    def test_nt35_native_ram_cap(self):
        # Native NT 3.5 only: hook byte 508 = 8 (128 MiB), set before the
        # first disk write; NT 3.51 / 4.0 / the VM path leave it 0.
        src = (ROOT / 'src/platform/bios/nt3/nt3_e820_mbr.S').read_text(encoding='utf-8')
        self.assertIn('.equ HOOK_RAM_CAP,    508', src)
        self.assertIn('    movzx eax, byte ptr cs:[HOOK_RAM_CAP]\n    shl eax, 24\n', src)
        self.assertIn('    mov ah, byte ptr cs:[HOOK_RAM_CAP]\n    sub ah, 1\n', src)
        text = TARGET.read_text(encoding='utf-8')
        cond = 'if [ "$NATIVE" = 1 ] && [ "$nt3:$minor" = yes:50 ] && [ -n "$mbr_hook" ]; then'
        self.assertEqual(text.count('seek=508'), 1)
        block = text[text.index(cond):]
        block = block[:block.index(chr(10) + 'fi' + chr(10))]
        self.assertIn("printf '\\010' | dd of=\"$work/hook35.bin\" bs=1 seek=508 count=1", block)
        self.assertIn('mbr_hook=$work/hook35.bin', block)
        self.assertLess(text.index(cond), text.index('dd if=/dev/zero of="$TARGET_DEVICE"'))

    def test_kernel_tool_entry_points(self):
        fb = (ROOT / 'src/platform/linux/fb_ui_main.zig').read_text(encoding='utf-8')
        self.assertIn('"--nt4-kernel"', fb)
        self.assertIn('usos.win3x.nt4_kernel.run', fb)
        root = (ROOT / 'src/compat/win3x/root.zig').read_text(encoding='utf-8')
        self.assertIn('pub const nt4_kernel = @import("nt4_kernel.zig");', root)
        src = (ROOT / 'src/compat/win3x/nt4_kernel.zig').read_text(encoding='utf-8')
        # mov eax,0 ; cpuid ; mov ecx,fs:[38h] ; pop [ecx+34h] ; pop [ecx+30h] ; cmp eax,
        self.assertIn('0xB8, 0, 0, 0, 0, 0x0F, 0xA2, 0x64, 0x8B, 0x0D, 0x38, 0, 0, 0, 0x8F, 0x41, 0x34, 0x8F, 0x41, 0x30, 0x83, 0xF8', src)
        self.assertIn('pub const new_limit: u8 = 0x7F;', src)


if __name__ == '__main__':
    unittest.main()
