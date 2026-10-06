"""Windows 98 Setup phase 1 in a VM (tools/w9x_phase1_qemu.sh, the VM parts
of tools/w9x_csmwrap_target.sh and INSTALL.BAT). Host only: Git sh, a fake
qemu-system-i386 script, temp folders; no VM, no disk.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
LIB = (ROOT / 'tools/w9x_phase1_qemu.sh').as_posix()
TARGET = ROOT / 'tools/w9x_csmwrap_target.sh'


def shell():
    for candidate in ('C:/Program Files/Git/bin/sh.exe', 'C:/Program Files/Git/bin/bash.exe'):
        if os.path.exists(candidate):
            return candidate
    found = shutil.which('sh')
    if not found:
        raise unittest.SkipTest('no POSIX sh available')
    return found


def sh(script, env=None):
    result = subprocess.run([shell(), '-c', script], capture_output=True, text=True,
                            env=dict(os.environ, **(env or {})))
    return result.returncode, result.stdout, result.stderr


class Phase1Vm(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-vm-'))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / 'share').mkdir()
        for name in ('bios-256k.bin', 'vgabios-stdvga.bin'):
            (self.tmp / 'share' / name).write_bytes(b'x')
        (self.tmp / 'flags').mkdir()
        self.qemu = self.tmp / 'qemu-system-i386'
        self.qemu.write_text('#!/bin/sh\nprintf "%s\\n" "$@" > "$W9X_FAKE_ARGS"\nsleep "${W9X_FAKE_SLEEP:-0}"\nexit "${W9X_FAKE_RC:-0}"\n', newline='\n')
        self.qemu.chmod(0o755)
        self.meminfo = self.tmp / 'meminfo'
        self.meminfo.write_text('MemTotal:       16336004 kB\nMemFree: 1 kB\n', newline='\n')

    def env(self, **extra):
        env = {
            'W9X_VM_QEMU': self.qemu.as_posix(), 'W9X_VM_DATADIR': (self.tmp / 'share').as_posix(),
            'W9X_VM_MEMINFO': self.meminfo.as_posix(), 'W9X_VM_FLAGS': (self.tmp / 'flags').as_posix(),
            'W9X_VM_RUN': (self.tmp / 'run').as_posix(), 'W9X_VM_KVM_DEV': (self.tmp / 'nokvm').as_posix(),
            'W9X_FAKE_ARGS': (self.tmp / 'args.txt').as_posix(),
        }
        env.update(extra)
        return env

    def run_lib(self, body, **extra):
        return sh(f'. "{LIB}"\n{body}', self.env(**extra))

    def test_only_98_and_98se_with_qemu_ram_and_no_opt_out(self):
        for tag in ('98SE', '98'):
            rc, out, _ = self.run_lib(f'w9x_vm_available {tag}')
            self.assertEqual(rc, 0, out)
        for tag in ('95', 'ME', 'DOS'):
            self.assertNotEqual(self.run_lib(f'w9x_vm_available {tag}')[0], 0, tag)
        self.assertNotEqual(self.run_lib('w9x_vm_available 98SE', W9X_VM_QEMU=(self.tmp / 'none').as_posix())[0], 0)
        self.meminfo.write_text('MemTotal:       786432 kB\n', newline='\n')
        rc, out, _ = self.run_lib('w9x_vm_available 98SE')
        self.assertNotEqual(rc, 0)
        self.assertIn('RAM', out)
        self.meminfo.write_text('MemTotal:       16336004 kB\n', newline='\n')
        (self.tmp / 'flags/phase1-native.flag').write_bytes(b'')
        self.assertNotEqual(self.run_lib('w9x_vm_available 98SE')[0], 0)
        (self.tmp / 'flags/phase1-native.flag').unlink()
        (self.tmp / 'share/vgabios-stdvga.bin').unlink()
        self.assertNotEqual(self.run_lib('w9x_vm_available 98SE')[0], 0)

    def test_tcg_is_the_default_kvm_needs_flag_and_device(self):
        self.assertEqual(self.run_lib('w9x_vm_accel')[1].strip(), 'tcg')
        (self.tmp / 'flags/phase1-kvm.flag').write_bytes(b'')
        # Flag present, no /dev/kvm: still TCG.
        self.assertEqual(self.run_lib('w9x_vm_accel')[1].strip(), 'tcg')

    def test_qemu_arguments_follow_the_hard_rules(self):
        rc, out, err = self.run_lib('w9x_vm_args /dev/sdb tcg')
        self.assertEqual(rc, 0, err)
        args = out.splitlines()
        joined = ' '.join(args)
        self.assertIn('pc,acpi=off', args)
        self.assertIn('-no-reboot', args)
        self.assertEqual(args[args.index('-nic') + 1], 'none')
        self.assertIn('-nodefaults', args)
        self.assertEqual(args[args.index('-m') + 1], '512')
        self.assertEqual(args[args.index('-accel') + 1], 'tcg,tb-size=128')
        drives = [a for a in args if a.startswith('file=')]
        self.assertEqual(drives, ['file=/dev/sdb,format=raw,if=ide,index=0,media=disk,cache=none,file.locking=off'])
        self.assertNotIn('-no-shutdown', args)
        self.assertNotIn('-netdev', joined)
        self.assertEqual(self.run_lib('w9x_vm_args /dev/sdb kvm')[1].splitlines()[8], 'kvm')

    def test_run_reports_the_guest_restart_qemu_errors_and_timeouts(self):
        if self.run_lib('command -v mkfifo')[0] != 0:
            self.skipTest('no mkfifo in this sh')
        rc, out, err = self.run_lib('w9x_phase1_progress() { echo "P $1 $2"; }\nw9x_phase1_run /dev/fake tcg; echo "rc=$?"')
        self.assertIn('rc=0', out, err)
        self.assertIn('/dev/fake', (self.tmp / 'args.txt').read_text())
        self.assertIn('rc=0 elapsed=', (self.tmp / 'run/command.txt').read_text())
        rc, out, _ = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_RC='1')
        self.assertIn('rc=2', out)
        rc, out, _ = self.run_lib('w9x_phase1_run /dev/fake tcg; echo "rc=$?"', W9X_FAKE_SLEEP='30', W9X_VM_TIMEOUT='1')
        self.assertIn('rc=3', out)

    def test_phase1_tree_check(self):
        c = self.tmp / 'c'
        (c / 'WINDOWS/SYSTEM').mkdir(parents=True)
        self.assertNotEqual(self.run_lib(f'w9x_phase1_tree_ok "{c.as_posix()}"')[0], 0)
        for name in ('WINDOWS/WIN.COM', 'WINDOWS/SYSTEM.INI', 'SETUPLOG.TXT'):
            (c / name).write_bytes(b'x')
        rc, out, _ = self.run_lib(f'w9x_phase1_tree_ok "{c.as_posix()}"')
        self.assertEqual(rc, 0, out)
        (c / 'WINDOWS/WIN.COM').unlink()
        rc, out, _ = self.run_lib(f'w9x_phase1_tree_ok "{c.as_posix()}"')
        self.assertIn('WIN.COM', out)

    def test_patch_drops_the_vm_mouse_line_and_the_second_himem(self):
        # The files of the BIOSTAR/X470 98 SE disk after phase 1 (shortened).
        c = self.tmp / 'c'
        (c / 'WINDOWS').mkdir(parents=True)
        (self.tmp / 'run').mkdir()
        ini = (b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\nebios=*ebios\r\nmouse=*vmouse, msmouse.vxd\r\n'
               b'woafont=dosapp.fon\r\n[mci]\r\nmouse=keep\r\n')
        config = (b'DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\nDEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\n'
                  b'DEVICE=C:\\WINDOWS\\setver.exe\r\nCountry=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')
        (c / 'WINDOWS/SYSTEM.INI').write_bytes(ini)
        (c / 'CONFIG.SYS').write_bytes(config)
        rc, out, err = self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.splitlines(), ['SYSTEM.INI: removed mouse=*vmouse, msmouse.vxd',
                                            'CONFIG.SYS: removed DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2'])
        self.assertEqual((c / 'WINDOWS/SYSTEM.INI').read_bytes(),
                         b'[boot]\r\nmouse.drv=mouse.drv\r\n[386Enh]\r\nebios=*ebios\r\nwoafont=dosapp.fon\r\n[mci]\r\nmouse=keep\r\n')
        self.assertEqual((c / 'CONFIG.SYS').read_bytes(),
                         b'DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2\r\nDEVICE=C:\\WINDOWS\\setver.exe\r\n'
                         b'Country=048,852,C:\\WINDOWS\\COMMAND\\country.sys\r\n')
        # Nothing left to change: no output, files and folder as they are.
        rc, out, err = self.run_lib(f'w9x_phase1_patch_c "{c.as_posix()}"')
        self.assertEqual((rc, out), (0, ''), err)
        self.assertEqual(sorted(p.name for p in c.rglob('*')), ['CONFIG.SYS', 'SYSTEM.INI', 'WINDOWS'])

    def test_fsck_is_read_only_and_its_errors_fail(self):
        bin_dir = self.tmp / 'bin'
        bin_dir.mkdir()
        fake = bin_dir / 'fsck.fat'
        fake.write_text('#!/bin/sh\necho "args: $*"\nexit "${W9X_FAKE_FSCK:-0}"\n', newline='\n')
        fake.chmod(0o755)
        log = (self.tmp / 'fsck.txt').as_posix()
        # A POSIX PATH entry (Git sh on Windows: no drive colon).
        bin_path = bin_dir.as_posix()
        if bin_path[1:2] == ':':
            bin_path = '/' + bin_path[0].lower() + bin_path[2:]
        rc, _, err = sh(f'. "{LIB}"\nPATH="{bin_path}:$PATH"\nw9x_phase1_fsck /dev/loop7 "{log}" "C: test"', self.env())
        self.assertEqual(rc, 0, err)
        text = Path(log).read_text()
        self.assertIn('== fsck.fat -n: C: test', text)
        self.assertIn('args: -n /dev/loop7', text)
        rc, _, _ = sh(f'. "{LIB}"\nPATH="{bin_path}:$PATH"\nw9x_phase1_fsck /dev/loop7 "{log}" again', self.env(W9X_FAKE_FSCK='1'))
        self.assertEqual(rc, 1)
        self.assertIn('== rc=1', Path(log).read_text())

    def test_verify_checks_the_disk_before_and_after_and_flushes(self):
        text = Path(LIB).read_text(encoding='utf-8')
        body = text[text.index('w9x_phase1_verify() {'):]
        first_fsck = body.index('w9x_phase1_fsck "$loop"')
        self.assertLess(body.index('blockdev --flushbufs "$target"'), first_fsck)
        self.assertLess(first_fsck, body.index('mount -t vfat'))
        self.assertLess(body.index('w9x_phase1_patch_c'), body.index('PHASE1.OK'))
        second_fsck = body.index('w9x_phase1_fsck "$loop"', first_fsck + 1)
        self.assertLess(body.index('umount "$W9X_VM_RUN/c"'), second_fsck)
        run = text[text.index('w9x_phase1_run() {'):text.index('w9x_phase1_tree_ok() {')]
        self.assertLess(run.index('blockdev --flushbufs "$target"'), run.index('"$W9X_VM_QEMU" "$@"'))


class TargetVmParts(unittest.TestCase):
    def helpers(self):
        text = TARGET.read_text(encoding='utf-8')
        start = text.index('w9x_display_ids() {')
        return text[start:text.index('\nfor tool in dd od', start)]

    def test_real_display_controllers_go_into_usosvesa_inf(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-pci-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        for name, (vendor, device, klass) in {'0000_00_01.0': ('0x1022', '0x1480', '0x060000'),
                                              '0000_0a_00.0': ('0x1002', '0x67FF', '0x030000'),
                                              '0000_0b_00.0': ('0x10de', '0x1c82', '0x030200')}.items():
            (tmp / name).mkdir()
            for field, value in (('vendor', vendor), ('device', device), ('class', klass)):
                (tmp / name / field).write_text(value + '\n', newline='\n')
        inf = tmp / 'USOSVESA.INF'
        inf.write_bytes(b'[Manufacturer]\r\n%Mfg%=Mfg.VM\r\n\r\n[Mfg.VM]\r\n'
                        b'"vesa (vmdisp9x) 10de:1c82"=VESA, PCI\\VEN_10de&DEV_1c82\r\n'
                        b'%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')
        script = self.helpers() + f'\nids=$(w9x_display_ids "{tmp.as_posix()}")\nprintf "%s\\n" "$ids"\nw9x_add_display_ids "$ids" < "{inf.as_posix()}" > "{(tmp / "out.inf").as_posix()}"\n'
        rc, out, err = sh(script)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.split(), ['1002:67ff', '10de:1c82'])
        self.assertEqual((tmp / 'out.inf').read_bytes(),
                         b'[Manufacturer]\r\n%Mfg%=Mfg.VM\r\n\r\n[Mfg.VM]\r\n'
                         b'"vesa (vmdisp9x) 1002:67ff"=VESA, PCI\\VEN_1002&DEV_67ff\r\n'
                         b'"vesa (vmdisp9x) 10de:1c82"=VESA, PCI\\VEN_10de&DEV_1c82\r\n'
                         b'%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')

    def test_target_writer_sets_u9vm_only_in_vm_mode(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn("VM_PHASE1=${W9X_VM_PHASE1:-0}", text)
        self.assertIn("printf 'SET U9VM=1\\r\\n' >> \"$work/c/USOS9X/U9ENV.BAT\"", text)

    def run_usb_block(self, tag, flag, diag=False):
        """The 98 SE USB stack block of the target writer + the U9ENV.BAT
        lines, with a fake cabinet carver; returns (files in USB, U9ENV.BAT)."""
        text = TARGET.read_text(encoding='utf-8')
        block = text[text.index('# 98 SE: the user'):text.index("if [ \"$VM_PHASE1\" = 1 ]")]
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-usb-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        (tmp / 'usb').mkdir()
        (tmp / 'usb/NUSB33E.EXE').write_bytes(b'MSCF usbport.sys usbhub20.sys')
        (tmp / 'work/c/USOS9X').mkdir(parents=True)
        (tmp / 'esp/win9x').mkdir(parents=True)
        if flag:
            (tmp / 'esp/win9x/xhci98.flag').write_bytes(b'')
        if diag:
            (tmp / 'esp/win9x/diag.flag').write_bytes(b'')
        script = (f'set -eu\nlog() {{ :; }}\nw9x_carve_cab() {{ cp "$1" "$2"; }}\n'
                  f'work="{(tmp / "work").as_posix()}"\nUSB_DIR="{(tmp / "usb").as_posix()}"\n'
                  f'SYSTEM_TAG={tag}\nSETUP_FOLDER=WIN98\nANSWER_KIND=USOS\n'
                  f'XHCI98_FLAG="{(tmp / "esp/win9x/xhci98.flag").as_posix()}"\n'
                  f'DIAG_FLAG="{(tmp / "esp/win9x/diag.flag").as_posix()}"\n' + block)
        rc, _, err = sh(script)
        self.assertEqual(rc, 0, err)
        usb = tmp / 'work/c/USOS9X/USB'
        files = sorted(p.name for p in usb.iterdir()) if usb.exists() else []
        return files, (tmp / 'work/c/USOS9X/U9ENV.BAT').read_bytes()

    def test_xhci98_is_opt_in_through_the_flag_file(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('XHCI98_FLAG=${W9X_XHCI98_FLAG:-$ESP_DIR/win9x/xhci98.flag}', text)
        files, env = self.run_usb_block('98SE', flag=False)
        self.assertEqual(files, [])
        self.assertNotIn(b'U9USB', env)
        self.assertNotIn(b'U9DIAG', env)
        files, env = self.run_usb_block('98SE', flag=True)
        self.assertEqual(files, ['STACK.CAB'])
        self.assertIn(b'SET U9USB=1\r\n', env)
        files, env = self.run_usb_block('98', flag=True)
        self.assertEqual(files, [])
        self.assertNotIn(b'U9USB', env)

    def test_usosdiag_boot_is_opt_in(self):
        text = TARGET.read_text(encoding='utf-8')
        self.assertIn('DIAG_FLAG=${W9X_DIAG_FLAG:-$ESP_DIR/win9x/diag.flag}', text)
        _, env = self.run_usb_block('98SE', flag=False, diag=True)
        self.assertIn(b'SET U9DIAG=1\r\n', env)
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        guard = lines.index('IF NOT "%U9DIAG%"=="1" GOTO DIAGDONE')
        self.assertEqual(lines[guard + 1], r'ECHO @IF EXIST C:\USOS9X\USOSDIAG.COM C:\USOS9X\USOSDIAG.COM BOOT>>C:\AUTOEXEC.BAT')
        self.assertEqual(lines[guard + 2], ':DIAGDONE')
        self.assertEqual(sum('USOSDIAG' in l for l in lines if not l.startswith('REM')), 1)
        import sys
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support
        self.assertIn('USOSDIAG.COM', build_win9x_support.STAGED)
        self.assertIn('USOSDBG.EXE', build_win9x_support.STAGED)
        self.assertNotIn('USOSDIAG.COM', build_win9x_support.FILES)

    def test_install_bat_copies_xhci98_only_with_u9usb(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        guard = lines.index('IF NOT "%U9USB%"=="1" GOTO USBDONE')
        copy = next(i for i, l in enumerate(lines) if 'XHCI98.SYS XHCI98.INF USB\\STACK.CAB' in l)
        self.assertLess(guard, copy)
        self.assertLess(copy, lines.index(':USBDONE'))
        self.assertFalse(any('XHCI98' in l and 'COPY' in l for l in lines[:guard]))

    def test_install_bat_adds_p_i_for_the_vm(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        vm = lines.index('IF "%U9VM%"=="1" SET U9SW=%U9SW% /P I')
        self.assertGreater(vm, lines.index('IF "%U9SYS%"=="95" SET U9SW=/IS'))
        self.assertLess(vm, next(i for i, l in enumerate(lines) if l.startswith('ECHO C:\\%U9SRC%\\SETUP.EXE')))

    def test_install_bat_config_sys_under_csmwrap(self):
        """CREGFIX first (it creates C:\\CONFIG.SYS), one HIMEM line in the VM
        path, the C:\\USOS9X fallback only for the native Setup start."""
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        cregfix = lines.index('ECHO DEVICE=C:\\USOS9X\\CREGFIX.SYS>C:\\CONFIG.SYS')
        himem = lines.index('ECHO DEVICE=C:\\WINDOWS\\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\\CONFIG.SYS')
        skip = lines.index('IF "%U9VM%"=="1" GOTO NOCSM')
        fallback = lines.index('ECHO DEVICE=C:\\USOS9X\\HIMEM.SYS /TESTMEM:OFF /M:2>>C:\\CONFIG.SYS')
        self.assertLess(lines.index('IF NOT EXIST C:\\USOS9X\\CREGFIX.SYS GOTO FAILED'), cregfix)
        self.assertLess(cregfix, himem)
        self.assertLess(himem, skip)
        self.assertLess(skip, fallback)
        self.assertEqual(sum('>C:\\CONFIG.SYS' in l.replace('>>', '') for l in lines), 1)
        self.assertTrue(any('CREGFIX.SYS) DO COPY /Y A:\\%%F C:\\USOS9X' in l for l in lines))

    def test_boot_floppy_config_sys_loads_cregfix_first(self):
        text = TARGET.read_text(encoding='utf-8')
        block = text[text.index(': > "$work/CONFIG.SYS"'):text.index('for name in AUTOEXEC.BAT CONFIG.SYS')]
        self.assertLess(block.index('CREGFIX.SYS'), block.index('HIMEM.SYS'))
        self.assertLess(block.index('HIMEM.SYS'), block.index('FILES=40'))


class PrepareWiring(unittest.TestCase):
    def test_prepare_runs_the_vm_after_the_target_and_stops_on_failure(self):
        text = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        target = text.index('sh /usr/lib/usos/w9x_csmwrap_target.sh')
        run = text.index('w9x_phase1_run "$TARGET_DEVICE"')
        verify = text.index('w9x_phase1_verify "$TARGET_DEVICE"')
        reboot = text.index('reboot -f')
        self.assertLess(target, run)
        self.assertLess(run, verify)
        self.assertLess(verify, reboot)
        self.assertIn("stop 'Windows Setup stage 1 did not finish.", text[verify:reboot])

    def test_the_script_is_in_the_initramfs(self):
        self.assertIn('("tools/w9x_phase1_qemu.sh", "usr/lib/usos/w9x_phase1_qemu.sh")',
                      (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
