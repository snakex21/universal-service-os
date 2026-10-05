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
        self.assertEqual(drives, ['file=/dev/sdb,format=raw,if=ide,index=0,media=disk,cache=writeback,file.locking=off'])
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

    def test_install_bat_adds_p_i_for_the_vm(self):
        lines = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='ascii').splitlines()
        vm = lines.index('IF "%U9VM%"=="1" SET U9SW=%U9SW% /P I')
        self.assertGreater(vm, lines.index('IF "%U9SYS%"=="95" SET U9SW=/IS'))
        self.assertLess(vm, next(i for i, l in enumerate(lines) if l.startswith('ECHO C:\\%U9SRC%\\SETUP.EXE')))


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
