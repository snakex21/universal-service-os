"""Native NT 3.1 install without the install VM (docs/nt-native-plan.md
section 8): nt31_native_txtsetup / nt31_native_initial / the routing in
tools/nt4_csmwrap_target.sh and tools/w9x_csmwrap_prepare.sh, usosnt3
/finish31. Host only: Git sh, temp folders; no VM, no disk. The fixtures
are synthetic (section shapes of the NT 3.1 CD); the real-CD checks run
only when a local, extracted copy of the user's CD is named by
USOS_NT31_CD (an I386 folder, never in git).
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

from test_w9x_phase1_qemu import sh
from test_nt4_flow import function_text

ROOT = Path(__file__).resolve().parents[2]
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'
QEMU = ROOT / 'tools/nt4_qemu_install.sh'
CD = Path(os.environ['USOS_NT31_CD']) if os.environ.get('USOS_NT31_CD') else None

TXT = (
    '[SourceDisks]\r\n\r\nd2 = "CD",\\disk2,\\i386,TopLevelSource\r\n'
    '[debug]\r\nDebugBoot = 0\r\n'
    '[SCSI.ISA.Load]\r\nd0,ncr53c9x\r\nd0,aha154x\r\n\r\n'
    '[SCSI.EISA.Load]\r\nd0,ncr53c9x\r\n#d0,dce376nt\r\nd0,tmv1\r\n\r\n'
    '[SCSI.MCA.Load]\r\nd0,spock\r\n\r\n'
    '[WinntFiles]\r\nd2,DEFAULT,3\r\nd2,SYSTEM,3\r\nd2,SCSIPORT.SYS,4\r\n'
    '[SCSI.ISA]\r\naha154x  = "Adaptec 154x",files.aha154x,aha154x,1\r\n'
)

INITIAL = (
    '[LoadSetupLibrary]\r\n    LoadLibrary "x" $(!STF_CWDDIR)setupdll.dll !LIBHANDLE\r\n    exit\r\n'
    '[Shell Commands]\r\n    StartWait\r\n    install   LoadSetupLibrary\r\n    set-subst CR = "\\r"\r\n'
    '    read-syms ProcessorVar\r\n    detect    ProcessorVar\r\n'
    '    ifstr(i) $(STF_PROCESSOR) == $(ProcessorID_I386)\r\n'
    '[UsosNt31Post]\r\n'
    '    shell "registry.inf" CreateKey $(UsosSvc) {{Scsidisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),0}}\r\n'
    '    ifstr(i) $($R0) == STATUS_SUCCESSFUL\r\n        CloseRegKey $($R1)\r\n    endif\r\n'
    '    CloseRegKey $(UsosSvc)\r\n'
)
USOSDISK_OFF = ('    shell "registry.inf" CreateKey $(UsosSvc) {{usosdisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),4}}\r\n'
                '    ifstr(i) $($R0) == STATUS_SUCCESSFUL\r\n        CloseRegKey $($R1)\r\n    endif\r\n')


def run(fn_names, call, text, extra=''):
    tmp = Path(tempfile.mkdtemp(prefix='usos-nt31-native-'))
    try:
        (tmp / 'in').write_bytes(text)
        fns = '\n'.join(function_text(TARGET, n) for n in fn_names)
        rc, out, err = sh(f'{extra}\n{fns}\n{call} < "{(tmp / "in").as_posix()}" > "{(tmp / "out").as_posix()}"')
        return rc, (tmp / 'out').read_bytes(), err
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def section(text, name):
    out, inside = [], False
    for line in text.split('\r\n'):
        if line.startswith('['):
            inside = line.lower() == name.lower()
            continue
        if inside and line:
            out.append(line)
    return out


class Nt31NativeTxtsetup(unittest.TestCase):
    def test_scsi_load_empty_and_drivers_in_winntfiles(self):
        rc, out, err = run(['nt31_native_txtsetup'], 'nt31_native_txtsetup ""', TXT.encode())
        self.assertEqual(rc, 0, err)
        text = out.decode()
        for sec in ('[SCSI.ISA.Load]', '[SCSI.MCA.Load]'):
            self.assertEqual(section(text, sec), [], sec)
        self.assertEqual(section(text, '[SCSI.EISA.Load]'), ['#d0,dce376nt'])
        self.assertEqual(section(text, '[WinntFiles]')[:5], ['d2,AHCINT.SYS,4', 'd2,USOSRST.SYS,4', 'd2,USOSUSB.SYS,4', 'd2,USOSDISK.SYS,4', 'd2,DEFAULT,3'])
        self.assertNotIn('USOSNVME', text)
        # Everything else unchanged, CR LF kept.
        self.assertIn('[SCSI.ISA]\r\naha154x  = "Adaptec 154x",files.aha154x,aha154x,1\r\n', text)
        self.assertIn('DebugBoot = 0\r\n', text)

    def test_nvme_and_missing_sections(self):
        rc, out, _ = run(['nt31_native_txtsetup'], 'nt31_native_txtsetup nvme', TXT.encode())
        self.assertEqual(rc, 0)
        self.assertIn('d2,USOSNVME.SYS,4', section(out.decode(), '[WinntFiles]'))
        rc, _, _ = run(['nt31_native_txtsetup'], 'nt31_native_txtsetup ""', TXT.replace('[WinntFiles]', '[Other]').encode())
        self.assertNotEqual(rc, 0)
        rc, _, _ = run(['nt31_native_txtsetup'], 'nt31_native_txtsetup ""', TXT.replace('[SCSI.MCA.Load]', '[X]').encode())
        self.assertNotEqual(rc, 0)


class Nt31NativeInitial(unittest.TestCase):
    def test_cpu_line_and_answerer(self):
        rc, out, err = run(['nt31_native_initial'], 'nt31_native_initial', INITIAL.encode())
        self.assertEqual(rc, 0, err)
        text = out.decode()
        self.assertIn('    install   LoadSetupLibrary\r\n    StartDetachedProcess STATUS "" "" "C:\\USOS\\NT3\\USOSANS31.EXE"\r\n', text)
        self.assertIn('    detect    ProcessorVar\r\n    set STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT31-CPU\r\n    ifstr(i)', text)
        self.assertEqual(len(text), len(INITIAL) + len('    StartDetachedProcess STATUS "" "" "C:\\USOS\\NT3\\USOSANS31.EXE"\r\n')
                         + len('    set STF_PROCESSOR = $(ProcessorID_I586) ;USOS-NT31-CPU\r\n') + len(USOSDISK_OFF))
        # usosdisk (first-boot disk class driver, nt31_hive.zig) off right
        # after [UsosNt31Post] turns Scsidisk on.
        self.assertIn('{{Start,0,$(!REG_VT_DWORD),0}}\r\n    ifstr(i) $($R0) == STATUS_SUCCESSFUL\r\n        CloseRegKey $($R1)\r\n'
                      '    endif\r\n' + USOSDISK_OFF + '    CloseRegKey $(UsosSvc)\r\n', text)
        rc, _, _ = run(['nt31_native_initial'], 'nt31_native_initial', INITIAL.replace('detect    ProcessorVar', 'x').encode())
        self.assertNotEqual(rc, 0)
        rc, _, _ = run(['nt31_native_initial'], 'nt31_native_initial', INITIAL.replace('{{Scsidisk,', '{{Other,').encode())
        self.assertNotEqual(rc, 0)

    @unittest.skipUnless(CD and (CD / 'INITIAL.IN_').is_file(), 'USOS_NT31_CD not set (local copy of the user CD)')
    def test_real_cd_inf_chain(self):
        tool = ROOT / 'zig-out/bin/usos-win3x-display.exe'
        self.assertTrue(tool.is_file(), 'zig build win3x-display-tool first')
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt31-cd-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for name in ('INITIAL.IN_', 'HARDWARE.IN_'):
            subprocess.run([str(tool), 'szdd-get', str(CD / name), str(tmp / (name + '.txt'))], check=True)
        lib = f'. "{QEMU.as_posix()}"'
        rc, out, err = run(['nt31_native_initial'], f'{{ {{ {lib}; nt31_initial_inf "USOS" "" "USOS-NT31" "" nvme; }} | nt31_native_initial; }}',
                           (tmp / 'INITIAL.IN_.txt').read_bytes())
        self.assertEqual(rc, 0, err)
        text = out.decode('latin1')
        self.assertIn('[UsosNt31Post]', text)
        self.assertEqual(text.count(';USOS-NT31-CPU'), 1)
        self.assertEqual(text.count('USOSANS31.EXE'), 1)
        self.assertEqual(text.count('{{usosdisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),4}}'), 1)
        (tmp / 'body').write_bytes(out)
        subprocess.run([str(tool), 'szdd-put', str(CD / 'INITIAL.IN_'), str(tmp / 'body'), str(tmp / 'INITIAL.IN_')], check=True)
        subprocess.run([str(tool), 'szdd-get', str(tmp / 'INITIAL.IN_'), str(tmp / 'back')], check=True)
        self.assertEqual((tmp / 'back').read_bytes(), out)
        rc, _, err = run([], f'{{ {lib}; nt31_hardware_inf; }}', (tmp / 'HARDWARE.IN_.txt').read_bytes())
        self.assertEqual(rc, 0, err)

    @unittest.skipUnless(CD and (CD / 'TXTSETUP.INF').is_file(), 'USOS_NT31_CD not set (local copy of the user CD)')
    def test_real_cd_txtsetup(self):
        rc, out, err = run(['nt31_native_txtsetup'], 'nt31_native_txtsetup ""', (CD / 'TXTSETUP.INF').read_bytes())
        self.assertEqual(rc, 0, err)
        text = out.decode('latin1')
        for sec in ('[SCSI.ISA.Load]', '[SCSI.MCA.Load]'):
            self.assertEqual(section(text, sec), [])
        self.assertEqual(section(text, '[SCSI.EISA.Load]'), ['#d0,dce376nt'])


class Nt31NativeRouting(unittest.TestCase):
    def test_target_gate_options_mbr_and_order(self):
        text = TARGET.read_text(encoding='utf-8')
        gate = text.index('if [ "$NATIVE" = 1 ]; then\n    { [ "$nt3:$minor" = yes:51 ]')
        self.assertIn('[ "$nt3:$minor" = yes:10 ]', text[gate:gate + 300])
        self.assertIn('NT_NATIVE_LOAD_OPTIONS=${NT31_NATIVE_LOAD_OPTIONS:-/NODEBUG /MAXMEM=64}', text[gate:gate + 1000])
        self.assertIn("        yes:10) ram_cap=4 ram_oct='\\004' ;;", text)
        disk = text.index('dd if=/dev/zero of="$TARGET_DEVICE"')
        self.assertLess(text.index("[ \"$NATIVE:$nt31\" != 1:yes ] || [ -z \"$mbr_hook\" ] || mbr_keys="), disk)
        self.assertLess(text.index('[ -z "$mbr_keys" ] || opt=$((opt | 4))'), disk)
        self.assertIn('[ -z "$mbr_keys" ] || dd if="$mbr_keys" of="$TARGET_DEVICE" bs=512 seek=5 count=1', text)
        # nt31_native after nt31_usos (NAMES.TXT, POST.CMD exist then).
        self.assertIn('nt31_usos\n[ "$NATIVE" != 1 ] || nt31_native\n', text)
        native = function_text(TARGET, 'nt31_native')
        for piece in ('--nt31-hive', 'INITIAL.IN_', 'HARDWARE.IN_', 'NTLANMAN.IN_', 'OEMNADLB.IN_', 'USOSANS31.EXE',
                      'NATIVE31.INI', 'NATIVE.TXT', '/finish31'):
            self.assertIn(piece, native)
        # First GUI-mode boot disk class driver: the CD's SCSIDISK under the
        # usosdisk service name, before the hive template is patched.
        self.assertLess(native.index('cp "$ls_dir/$disk_src" "$ls_dir/USOSDISK.${disk_src##*.}"'), native.index('--nt31-hive'))

    def test_post_cmd_gets_finish31_before_done(self):
        post = '@echo off\r\nC:\\USOS\\NT3\\USOSNT3.EXE /polish\r\necho done > C:\\USOS\\NT3\\DONE.TXT\r\n'
        native = function_text(TARGET, 'nt31_native')
        awk = native[native.index("awk -v BINMODE=3 '{ sub(/\\r$/, \"\") } /^echo done"):]
        awk = awk[:awk.index('"$usos/POST.CMD" >')]
        rc, out, err = run([], awk, post.encode())
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.decode(), '@echo off\r\nC:\\USOS\\NT3\\USOSNT3.EXE /polish\r\nC:\\USOS\\NT3\\USOSNT3.EXE /finish31\r\n'
                         'echo done > C:\\USOS\\NT3\\DONE.TXT\r\n')

    def test_prepare_flag_covers_nt31(self):
        text = PREPARE.read_text(encoding='utf-8')
        self.assertIn('NT351|NT351S|NT35|NT35S|NT31|NT31S) nt_native_flag=nt3-native.flag ;;', text)

    def test_usosnt3_finish31(self):
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
        block = src[src.index('if (lstrcmpA(opt, "finish31") == 0) {'):]
        block = block[:block.index('ExitProcess(0);')]
        for piece in ('native_install()', 'boot_ini_finish();', 'ROOTLIST.TXT', 'C:\\\\TXTSETUP.INF'):
            self.assertIn(piece, block)
        # Before the generic /finish refusal and /polish do not swallow it.
        self.assertLess(src.index('"finish31"'), src.index('if (lstrcmpA(opt, "polish") == 0)'))

    def test_hive_tool_entry_points(self):
        fb = (ROOT / 'src/platform/linux/fb_ui_main.zig').read_text(encoding='utf-8')
        for arg in ('--nt31-hive', '--szdd-get', '--szdd-put'):
            self.assertIn(f'std.mem.eql(u8, arg, "{arg}")', fb)
        self.assertIn('pub const nt31_hive = @import("nt31_hive.zig");', (ROOT / 'src/compat/win3x/root.zig').read_text(encoding='utf-8'))
        ml = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('usr/lib/usos/nt3/USOSANS31.EXE', ml)
        self.assertIn('usr/lib/usos/nt3-e820-keys-512.bin', ml)


if __name__ == '__main__':
    unittest.main()
