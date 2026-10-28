"""usosnvme (tools/nt/usosnvme): the USOS NVMe SCSI miniport for NT 3.1 to
Server 2003 x86. Every committed binary's imports resolve on its NT version
(export-name fixtures, no Microsoft file needed), the PE versions match, and
the source keeps the per-version ScsiPort rules."""
from pathlib import Path
import json, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
import sys
sys.path.insert(0, str(ROOT/"tools"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_nt52_driver_imports import pe  # noqa: E402
from check_nt4_driver_imports import parse  # noqa: E402

DRV = ROOT / 'tools/nt/usosnvme'
SRC = (DRV / 'src/usosnvme.c').read_text(encoding='latin-1')
DATA = ROOT / 'tools/tests/data'


def imports(variant):
    return pe(DRV / f'bin/{variant}/i386/usosnvme.sys')[1]


def pe_version(variant):
    b = (DRV / f'bin/{variant}/i386/usosnvme.sys').read_bytes()
    off = int.from_bytes(b[0x3C:0x40], 'little') + 24
    return (int.from_bytes(b[off + 48:off + 50], 'little'), int.from_bytes(b[off + 50:off + 52], 'little'))


class Imports(unittest.TestCase):
    def check(self, variant, fixture, pairs):
        tables = parse((DATA / fixture).read_text(encoding='utf-8'))
        for kernel, hal in pairs:
            view = {'ntoskrnl.exe': tables[kernel], 'hal.dll': tables[hal], 'scsiport.sys': tables['scsiport.sys']}
            missing = [f'{m}!{n}' for m, n in imports(variant) if n not in view[m.lower()]]
            self.assertEqual(missing, [], f'{variant} on {fixture} {kernel}')

    def test_nt4(self):
        for fx in ('nt4rtm_exports.txt', 'nt4sp6a_exports.txt'):
            self.check('NT4', fx, (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'halmps.dll')))

    def test_nt35x(self):
        for fx in ('nt351_exports.txt', 'nt35_exports.txt'):
            self.check('NT351', fx, (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'halmps.dll')))

    def test_nt31(self):
        self.check('NT31', 'nt31_exports.txt', (('ntoskrnl.exe', 'hal.dll'), ('ntkrnlmp.exe', 'hal.dll')))

    def test_nt6_x86(self):
        # Windows Vista / Server 2008 / 7 x86 and the Win10 x86 WinPE run the
        # NT6 build (src/2KXP + USOSNVME_NT6, docs/nvme-nt6-2026-10-12.md
        # section 16): Server 2008 SP2 x86 kernels, HALs and its SCSIPORT.
        for v in ('2KXP', 'NT6'):
            self.check(v, 'nt60sp2_x86_exports.txt', (('ntoskrnl.exe', 'halmacpi.dll'), ('ntkrnlpa.exe', 'halacpi.dll')))

    def test_no_crt(self):
        # NT 3.1 exports neither memset nor memcpy; no build may import them.
        for v in ('2KXP', 'NT6', 'NT4', 'NT351', 'NT31'):
            names = {n for _, n in imports(v)}
            self.assertFalse(names & {'memset', 'memcpy', 'memmove'}, v)
            self.assertLessEqual({m.lower() for m, _ in imports(v)}, {'ntoskrnl.exe', 'scsiport.sys'}, v)

    def test_pe_versions(self):
        self.assertEqual(pe_version('NT4'), (4, 0))
        self.assertEqual(pe_version('NT351'), (3, 51))
        self.assertEqual(pe_version('NT31'), (3, 10))


class Source(unittest.TestCase):
    def test_scsiport_rules(self):
        for want in ('init.HwInitializationDataSize = FIELD_OFFSET(HW_INITIALIZATION_DATA, HwAdapterControl);',
                     'init.HwInitializationDataSize = 0x40;', 'init.AdapterInterfaceType = Isa;',
                     'ConfigInfo->AdapterInterfaceType = Eisa;', 'ConfigInfo->BusInterruptLevel = 0;',
                     'NvmeWr(Ext, NVME_REG_INTMS, 0xFFFFFFFF);', 'c.Cdw11 = 1;                         /* physically contiguous, IEN = 0 */',
                     'if (lbads != 9 || ms != 0) {', 'only 512-byte sectors are supported',
                     'SPDX-License-Identifier: GPL-3.0-or-later'):
            self.assertIn(want, SRC)
        # the class code the driver and the setup integration match
        self.assertIn('Cfg->BaseClass == 0x01 && Cfg->SubClass == 0x08 && Cfg->ProgIf == 0x02', SRC)
        self.assertIn('PCI\CC_010802', (DRV / 'usosnvme.inf').read_text(encoding='latin-1'))

    def test_nt6_no_interrupt(self):
        # NT6 build: no HwInterrupt (ScsiPort connects nothing; the X470
        # Win10 x86 WinPE gave the stornvme.inf MSI-X resource and the 2KXP
        # build's start failed, Problem 10 / 0xC000000D), no forced
        # LevelSensitive, MSI / MSI-X masked at the function. 2KXP, NT4,
        # NT3 and 9x keep the stub HwInterrupt.
        self.assertIn('#ifdef USOSNVME_NT6\n    init.HwInterrupt = NULL;', SRC)
        self.assertIn('#else\n    init.HwInterrupt = NvmeInterrupt;\n#endif', SRC)
        self.assertIn('#ifndef USOSNVME_NT6\n    ConfigInfo->InterruptMode = LevelSensitive;\n#endif', SRC)
        mask = SRC[SRC.index('static VOID NvmeMaskMessages('):SRC.index('static BOOLEAN NvmeIsNvme(')]
        for want in ('cfg[ptr] == 0x11 && !(ctl & 0x4000)', 'ctl |= 0x4000;', 'cfg[ptr] == 0x05 && (ctl & 0x0001)', 'guard < 48'):
            self.assertIn(want, mask)
        self.assertIn('#ifdef USOSNVME_NT6\n    NvmeMaskMessages(ext, bus, slot);\n#endif', SRC)
        build = (DRV / 'build.cmd').read_text(encoding='latin-1')
        self.assertIn('if /i "%VARIANT%"=="nt6"   set "DIR=2KXP" & set "OUT=NT6" & set "DEFS=-DUSOSNVME_NT6"', build)
        sign = (ROOT / 'tools/build_usosnvme_nt6_signed.py').read_text(encoding='utf-8')
        self.assertIn("'tools/nt/usosnvme/bin/NT6/i386/usosnvme.sys'", sign)
        self.assertNotIn('bin/2KXP', sign)
        self.assertNotEqual((DRV / 'bin/NT6/i386/usosnvme.sys').read_bytes(), (DRV / 'bin/2KXP/i386/usosnvme.sys').read_bytes())


class Flow(unittest.TestCase):
    """Wiring: only an NVMe target loads usosnvme (XP / 2003 bundle NVME/ set,
    NT 4.0 DRIVERS.REG); 4Kn targets stop before any write."""

    def test_xp_bundle(self):
        sys.path.insert(0, str(ROOT / 'tools'))
        import xp_driver_overlay as o
        base = '[SourceDisksFiles.x86]\r\na.sys = 1\r\n[HardwareIdsDatabase]\r\n[SCSI.Load]\r\n[SCSI]\r\n[FileFlags]\r\n'
        t = o.nvme_txtsetup(base)
        for want in ('usosnvme.sys = 1,,,,,,4_,4,0,0,,1,4', 'PCI\\CC_010802 = "usosnvme"',
                     'usosnvme = usosnvme.sys,4', 'usosnvme.sys = 16'):
            self.assertIn(want, t)
        rows = {(p, n): v for p, n, _, v in o.nvme_registry_rows()}
        self.assertEqual(rows[('Control\\CriticalDeviceDatabase\\pci#cc_010802', 'Service')], 'usosnvme')
        self.assertEqual(rows[('Services\\usosnvme\\Parameters\\PnpInterface', '5')], 1)
        self.assertEqual(rows[('Services\\usosnvme', 'Start')], 0)

    def test_scripts(self):
        stage = (ROOT / 'tools/xp_driver_stage.sh').read_text(encoding='utf-8')
        self.assertIn('/dev/nvme*)', stage)
        self.assertIn('sha256sum -c nvme.sha256', stage)
        legacy = (ROOT / 'tools/legacy_xp_staging.sh').read_text(encoding='utf-8')
        self.assertIn('queue/logical_block_size', legacy)
        nt4 = (ROOT / 'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('case "$TARGET_DEVICE" in /dev/nvme*)', nt4)
        self.assertIn('Services\\usosnvme]', nt4)
        self.assertIn('if exist C:\\USOS\\NT4\\USOSNVME.SYS copy', nt4)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        self.assertIn('("tools/nt/usosnvme/bin/NT4/i386/usosnvme.sys", "usr/lib/usos/nt4/USOSNVME.SYS")', build)


class Nt3Flow(unittest.TestCase):
    """NT 3.1 / 3.5 / 3.51 (docs/nvme-nt-2026-10-11.md section 9): the NT31 /
    NT351 builds staged as USOS/NT3/USOSNVME.SYS only for an NVMe target,
    registered by USOSNT3.EXE (3.5x) or INITIAL.INF [UsosNt31Post] (3.1)."""

    def test_target_script(self):
        nt4 = (ROOT / 'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('[ -z "$nt31" ] || nvme_sys=USOSNVME31.SYS', nt4)
        self.assertIn('cp "$drv/$nvme_sys" "$usos/USOSNVME.SYS"', nt4)
        self.assertIn('    [ -n "$nvme" ] || return 0', nt4)
        self.assertEqual(nt4.count('nt3_nvme_stage\n'), 2)
        self.assertLess(nt4.index('fail "missing: $drv/$nvme_sys'), nt4.index('of="$TARGET_DEVICE"'))
        self.assertIn(r'if exist C:\USOS\NT3\USOSNVME.SYS copy', nt4)

    def test_nt31_initial_inf(self):
        inst = (ROOT / 'tools/nt4_qemu_install.sh').read_text(encoding='utf-8')
        self.assertIn('if (nvme == "nvme") svc("usosnvme", 1, 0, 1, "SCSI miniport")', inst)
        self.assertIn('::/USOS/NT3/USOSNVME.SYS', inst)

    def test_usosnt3(self):
        src = (ROOT / 'tools/nt3/usosnt3/src/usosnt3.c').read_text(encoding='utf-8')
        self.assertIn('DIR "USOSNVME.SYS"', src)
        self.assertIn('set_dword("usosnvme", NULL, "Start", 0);', src)
        from build_windows_usos_res import build_nt3
        self.assertIn(b'USOSNVME.SYS', build_nt3(ROOT).read_bytes())


class Nt6Flow(unittest.TestCase):
    """Windows 7 / Vista / Server 2008 x86 through CSMWrap (x86 PE10 donor):
    the NVMe gate in micro-Linux, target_bus in the target record and the
    WinPE nvme step (docs/nvme-nt6-2026-10-12.md)."""
    CMD = (ROOT / 'tools/windows_x86_csmwrap.cmd').read_text(encoding='utf-8')

    def step(self):
        return self.CMD[self.CMD.index('\n:nvme\n'):]

    def test_gate(self):
        prep = (ROOT / 'tools/vista_csmwrap_prepare.sh').read_text(encoding='utf-8')
        gate = prep[prep.index('usos_xp_choose_disk\n'):]
        self.assertLess(gate.index('case "$TARGET_DEVICE" in /dev/nvme*)'), gate.index('usos_xp_confirm '))
        self.assertIn('[ "$nvme_lbs" = 512 ] || stop', gate)
        self.assertIn('vista_nvme64_enabled "$profile" /mnt/esp/EFI/USOS/windows-native/vista-support.cpio ||', gate)
        # X470 2026-10-13: Microsoft's stornvme under CSMWrap failed every
        # size / layout IOCTL (433) on the Micron, so 8.1 / 10 x86 (stornvme
        # in Setup itself) stop on NVMe (docs/nvme-nt6-2026-10-12.md
        # section 12). Windows 7 / Vista / Server 2008 x86 run usosnvme in
        # the PE image and the installed system (USOS_PE_NVME); X470 PASS
        # 2026-10-14 for 7 SP1 x86 and Vista SP2 x86 (B261014-195920), so no
        # nvme-experimental.txt any more (section 17).
        nv = gate[gate.index('case "$TARGET_DEVICE" in /dev/nvme*)'):gate.index('usos_xp_confirm ')]
        self.assertIn('case "$profile" in\n'
                      '                win-nt6-x86-uefi-csmwrap)\n', nv)
        nt6 = nv[nv.index('win-nt6-x86-uefi-csmwrap)'):nv.index('win-x86-uefi-csmwrap)')]
        self.assertIn('                    pe_nvme=usosnvme ;;\n', nt6)
        self.assertNotIn('stop', nt6)
        self.assertNotIn('nvme-experimental.txt', nt6)
        # 8.1 / 10 x86: default on since the X470 PASS 2026-10-22 (section
        # 18); only the opt-out file remains.
        self.assertNotIn('Unattended/nvme-experimental.txt', prep)
        self.assertIn('Unattended/nvme-off.txt', prep)
        self.assertNotIn('nvme-off.txt', nt6)
        self.assertNotIn('32-bit Windows 7/Vista/2008', prep)
        self.assertLess(prep.index("pe_nvme=''"), prep.index('        usos_xp_choose_disk\n'))
        self.assertIn('X86_SELF=$x86_self USOS_PE_NVME=$pe_nvme', prep)
        self.assertIn("                win-x86-uefi-csmwrap)\n", nv)
        # Other win-x86 folders (e.g. Windows 8) keep the translated stop.
        self.assertIn('*) stop "32-bit $NT5_NAME on NVMe is not supported yet on this path. No disk was changed." ;;', nv)
        self.assertNotIn("'win-nt6-x86-uefi-csmwrap:Windows 7'", prep)
        # Both stops come before the 512-byte check (dormant until reopened).
        self.assertLess(nv.index("32-bit $NT5_NAME on NVMe"), nv.index('[ "$nvme_lbs" = 512 ] || stop'))
        # Translated: the stop text is a {0} template of a boot.lx key.
        en = json.loads((ROOT / 'installer/internal/i18n/locales/en.json').read_text(encoding='utf-8'))
        tmpl = en['boot.lx.nvme_x86_csmwrap_not_supported']
        self.assertEqual(tmpl, '32-bit {0} on NVMe is not supported yet on this path. No disk was changed.')
        self.assertIn(tmpl.replace('{0}', '$NT5_NAME'), nv)
        for loc in (ROOT / 'installer/internal/i18n/locales').glob('*.json'):
            self.assertIn('{0}', json.loads(loc.read_text(encoding='utf-8'))['boot.lx.nvme_x86_csmwrap_not_supported'], loc.name)
        self.assertIn(tmpl, (ROOT / 'src/i18n/linux_strings.zig').read_text(encoding='utf-8'))
        # The OOBE gate (signed usosnvme staging) is not folder-specific:
        # any NT 6.0.6002 x86 install, Vista SP2 as Server 2008 SP2.
        oobe = (ROOT / 'tools/windows_vista_oobe_gate.c').read_text(encoding='utf-8')
        self.assertNotIn('Server 2008', oobe[oobe.index('void entry(void)'):].split('#ifdef USOS_GATE_NATIVE_DEPLOY')[0])
        target = (ROOT / 'tools/vista_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertIn('/dev/nvme*) target_bus=nvme', target)
        self.assertIn(r'target_bus=%s\r\n', target)
        # The PE image: the stornvme service's file becomes usosnvme (NVMe
        # target + USOS_PE_NVME only), read back after the update.
        self.assertIn('if [ "$target_bus" = nvme ] && [ "${USOS_PE_NVME:-}" = usosnvme ]; then', target)
        self.assertIn('''printf 'add "%s" "/Windows/System32/drivers/stornvme.sys"\\n' "$work/inject/usosnvme-nt6.sys" >> "$commands"''', target)
        self.assertLess(target.index('/Windows/System32/drivers/stornvme.sys'), target.index('wimlib-imagex update "$work/staging/sources/boot.wim"'))
        self.assertIn('''cmp -s "$work/inject/usosnvme-nt6.sys" "$work/check/stornvme.sys" || fail''', target)

    def test_other_flows_stop(self):
        nt4 = (ROOT / 'tools/nt4_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertNotIn('no NVMe driver for Windows NT 3.x', nt4)
        self.assertLess(nt4.index('[ "$nvme_lbs" = 512 ] || fail'), nt4.index('of="$TARGET_DEVICE"'))
        pos = (ROOT / 'tools/posready_csmwrap_target.sh').read_text(encoding='utf-8')
        self.assertLess(pos.index('no NVMe driver for POSReady 2009'), pos.index('of="$TARGET_DEVICE"'))

    def test_step(self):
        lines = self.CMD.splitlines()
        self.assertLess(lines.index('call :nt60_usb'), lines.index('call :nvme'))
        s = self.step()
        self.assertLess(s.index('find "target_bus=nvme"'), s.index('copy /y'))
        self.assertIn('if not "%USOS_NT%"=="6.0" if not "%USOS_NT%"=="6.1"', s)
        self.assertIn(r'copy /y "%~dp0usosnvme-nt6.sys" "%USOS_T%\Windows\System32\drivers\usosnvme.sys"', s)
        for want in ('/v Start /t REG_DWORD /d 0 ', '/v Group /t REG_SZ /d "SCSI miniport"',
                     r'Services\usosnvme"', r'\Parameters\PnpInterface" /v 5 /t REG_DWORD /d 1',
                     r'CriticalDeviceDatabase\pci#cc_010802"', '/v Service /t REG_SZ /d usosnvme',
                     '{4D36E97B-E325-11CE-BFC1-08002BE10318}', '*kb2990941*x86*.msu', '*kb3087873*x86*.msu'):
            self.assertIn(want, s)
        self.assertNotRegex(s, r'exit /b [1-9]')

    def test_setup_hwcompat(self):
        # Setup 6.0 / 6.1 checks the NVMe controller against hwcompat.txt; a
        # PE-injected driver would have to be migrated (0x80070032), so Setup
        # runs from a sources copy that lists PCI\CC_010802.
        before = self.CMD[:self.CMD.index('usos-x86-csmwrap.exe" before')]
        self.assertIn('if defined USOS_NVME_TARGET call :nvme_setup', before)
        self.assertNotIn('USOS_NVME_DRIVERS', self.CMD)
        sub = self.CMD[self.CMD.index('\n:nvme_setup\n'):self.CMD.index('\n:nvme\n')]
        self.assertIn('usos-x86-csmwrap.exe" setupver "%USOS_SETUP%"', sub)
        self.assertIn('if not "%USOS_SETUPVER%"=="60" if not "%USOS_SETUPVER%"=="61"', sub)
        # boot.wim is copied too: Vista Setup needs it next to setup.exe.
        self.assertIn('/xf install.wim install.esd install.swm /njh', sub)
        self.assertIn(r'>>"%USOS_SRC%\sources\hwcompat.txt" echo PCI\CC_010802', sub)
        # SUBST drive: Vista Setup started from X: looks for a DVD.
        self.assertIn('(subst %%L: "%USOS_SRC%" >nul 2>&1 && set "USOS_SUBST=%%L:")', sub)
        self.assertIn(r'set "USOS_SETUP=%USOS_SUBST%\sources\setup.exe"', sub)
        # Setup 6.1 stays on X: (WinSetup.dll AV from the SUBST drive).
        self.assertIn('if "%USOS_SETUPVER%"=="61" goto nvme_setup_ready', sub)
        # dump_stornvme bugchecked while Setup worked on the NVMe disk.
        self.assertIn('usos-x86-csmwrap.exe" nodump', sub)
        self.assertIn('for %%S in ("%USOS_SETUP%") do pushd "%%~dpS"', self.CMD)
        src = (ROOT / 'tools/windows_x86_csmwrap.c').read_text(encoding='utf-8')
        self.assertIn('L"setupver"', src)
        # MSU path: the stornvme CriticalDeviceDatabase entry is checked.
        self.assertIn('CriticalDeviceDatabase pci#cc_010802 -^> stornvme added', self.step())

    def test_usosnvme_only(self):
        # User decision 2026-10-14: usosnvme in the PE and the installed
        # system, no Microsoft stornvme MSUs on this path.
        self.assertNotIn('call :nvme_msu', self.CMD)
        s = self.step()
        self.assertIn('if "%USOS_NT%"=="6.1" call :nvme_dism', s)
        # DISM runs before the SYSTEM hive is loaded for the service / CDD.
        self.assertLess(s.index('call :nvme_dism'), s.index('reg load HKLM\\USOS_SYS'))
        dism = self.CMD[self.CMD.index('\n:nvme_dism\n'):]
        dism = dism[:dism.index('exit /b 0')]
        self.assertIn('/Add-Driver /Driver:"%USOS_T%\\USOS\\nvme\\usosnvme.inf" /ForceUnsigned', dism)
        # PE: first NVMe step; nodump before anything touches the disk.
        before = self.CMD[:self.CMD.index('usos-x86-csmwrap.exe" before')]
        self.assertLess(before.index('call :nvme_pe_driver'), before.index('call :nvme_lowmem'))
        pe = self.CMD[self.CMD.index('\n:nvme_pe_driver\n'):self.CMD.index('\n:nvme_lowmem\n')]
        self.assertIn('usos-x86-csmwrap.exe" nodump', pe)
        self.assertIn('%SystemRoot%\\System32\\drivers\\stornvme.sys', pe)
        self.assertIn('%~dp0usosnvme-nt6.sys', pe)
        # Disk not found: the System event log entries of the storage stack.
        report = self.CMD[self.CMD.index('\n:disk_report\n'):]
        report = report[:report.index('exit /b 0')]
        self.assertIn("qe System /q:\"*[System[Provider[@Name='stornvme' or @Name='storport' or @Name='disk'", report)
        self.assertIn('/f:text /c:50', report)

    def test_lowmem(self):
        # NVMe target: the WinPE runs without RAM above 4 GiB (truncatememory in
        # the staging BCD, one WinPE restart) before the disk is touched.
        before = self.CMD[:self.CMD.index('usos-x86-csmwrap.exe" before')]
        self.assertLess(before.index('call :nvme_lowmem'), before.index('call :nvme_setup'))
        self.assertIn('if defined USOS_NVME_TARGET if "%USOS_LOWMEM%"=="10" exit /b 0', before)
        sub = self.CMD[self.CMD.index('\n:nvme_lowmem\n'):self.CMD.index('\n:nvme_setup\n')]
        self.assertIn('usos-x86-csmwrap.exe" lowmem', sub)
        # Disk not found in lowmem (exit 4): disk report before nodump too.
        self.assertLess(sub.index('if "%USOS_LOWMEM%"=="4" call :disk_report'), sub.index('wpeutil reboot'))
        self.assertIn('lowmem: WinPE RAM top before any disk access (MiB)=', (ROOT / 'tools/windows_x86_csmwrap.c').read_text(encoding='utf-8'))
        self.assertLess(sub.index('if not "%USOS_LOWMEM%"=="10" exit /b 0'), sub.index('wpeutil reboot'))
        src = (ROOT / 'tools/windows_x86_csmwrap.c').read_text(encoding='utf-8')
        main = src[src.index('void entry(void)'):]
        self.assertLess(main.index('ExitProcess(low_memory())'), main.index('L"before") == 0 && (arg_count'))
        for want in ('System Resources\\\\Physical Memory', 'L".Translated"', 'Elements\\\\15000007',
                     '{9dea862c-5cdd-4e70-acc1-f32b344d4795}\\\\Elements\\\\23000003', 'want = 0x100000000ULL',
                     'top <= 0x100000000ULL'):
            self.assertIn(want, src)

    def test_lowmem_stops_on_missing_disk(self):
        # lowmem exit 4 (no prepared disk in the WinPE): disk report, then stop
        # before the Setup copy and "before" (X470 2026-10-14).
        before = self.CMD[:self.CMD.index('usos-x86-csmwrap.exe" before')]
        stop = 'if defined USOS_NVME_TARGET if "%USOS_LOWMEM%"=="4" exit /b 1'
        self.assertIn(stop, before)
        self.assertLess(before.index('call :nvme_lowmem'), before.index(stop))
        self.assertLess(before.index(stop), before.index('call :nvme_setup'))

    def test_prepare_time_truncatememory(self):
        # micro-Linux writes truncatememory into the staging BCD for an NVMe
        # target of the 32-bit WinPE (usos-fb-ui --bcd-truncatememory,
        # src/platform/linux/bcd_lowmem.zig) on a copy, before it is copied.
        target = (ROOT / 'tools/vista_csmwrap_target.sh').read_text(encoding='utf-8')
        edit = 'usos-fb-ui --bcd-truncatememory "$work/bcd"'
        self.assertIn(edit, target)
        self.assertLess(target.index('cp "$bcd" "$work/bcd"'), target.index(edit))
        self.assertLess(target.index(edit), target.index('cp "$work/bcd" "$work/staging/boot/bcd" && cmp -s "$work/bcd" "$work/staging/boot/bcd"'))
        block = target[target.index('cp "$bcd" "$work/bcd"'):target.index(edit)]
        self.assertIn('case "$TARGET_DEVICE" in /dev/nvme*)', block)
        self.assertIn('if [ "$X86_SELF" = 1 ]; then', block)
        main = (ROOT / 'src/platform/linux/fb_ui_main.zig').read_text(encoding='utf-8')
        self.assertIn('"--bcd-truncatememory"', main)
        self.assertIn('bcd.run(args.next() orelse return 2, bcd.truncatememory);', main)
        self.assertIn('bcd.run(args.next() orelse return 2, bcd.testsigning);', main)
        zig = (ROOT / 'src/platform/linux/bcd_lowmem.zig').read_text(encoding='utf-8')
        for want in ('pub const limit: u64 = 0x100000000;', 'element_name = "15000007"', 'return error.Dirty;',
                     '"{9dea862c-5cdd-4e70-acc1-f32b344d4795}"', 'default_element = "23000003"'):
            self.assertIn(want, zig)
        self.assertIn('_ = @import("bcd_lowmem.zig");', (ROOT / 'src/platform/linux/fb_ui_tests.zig').read_text(encoding='utf-8'))

    def test_disk_report_interrupts(self):
        report = self.CMD[self.CMD.index('\n:disk_report\n'):]
        report = report[:report.index('exit /b 0')]
        self.assertIn('call :nvme_pe_id', report)
        self.assertIn(r'reg query "HKLM\SYSTEM\CurrentControlSet\Enum\%USOS_NVME_ID%\Device Parameters\Interrupt Management" /s', report)
        self.assertIn(r'reg query "HKLM\HARDWARE\RESOURCEMAP\PnP Manager" /s', report)
        pid = self.CMD[self.CMD.index('\n:nvme_pe_id\n'):]
        self.assertIn(r'reg query "HKLM\SYSTEM\CurrentControlSet\Services\stornvme\Enum" /v 0', pid[:pid.index('exit /b 0')])

    def test_pe_msi_fallback(self):
        # Controller start failed in the WinPE: MSI off for that device
        # instance (RAM WinPE only) and one device restart.
        pe = self.CMD[self.CMD.index('\n:nvme_pe_driver\n'):self.CMD.index('\n:nvme_pe_id\n')]
        problem = 'pnputil.exe" /enum-devices /problem | find /i "%USOS_NVME_ID%" >nul || goto nvme_pe_driver_done'
        msi = r'\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" /v MSISupported /t REG_DWORD /d 0 /f'
        self.assertIn(problem, pe)
        self.assertLess(pe.index(problem), pe.index(msi))
        self.assertLess(pe.index(msi), pe.index('/restart-device "%USOS_NVME_ID%"'))

    def test_packed(self):
        build = (ROOT / 'tools/build_windows_native_support.py').read_text(encoding='utf-8')
        self.assertIn("writer.add_file('usosnvme-nt6.sys', signed / 'usosnvme.sys')", build)
        for name in ('usosnvme.inf', 'usosnvme.cat', 'usosnvme.cer'):
            self.assertIn(repr(name), build)

    def test_signed_package(self):
        # Vista / 2008 specialize installs the NULL driver unless the package
        # is in the driver store: per-build signature, key deleted right
        # after signing, certificate trusted by the gate, pnputil before
        # windeploy (docs/nvme-nt6-2026-10-12.md section 9).
        sign = (ROOT / 'tools/build_usosnvme_nt6_signed.py').read_text(encoding='utf-8')
        for want in ('-KeyExportPolicy NonExportable', '-HashAlgorithm SHA1', '-DeleteKey', '} finally {',
                     'signing certificate still in CurrentUser', 'OSAttr:2:6.0,2:6.1',
                     '<hash>usosnvme.inf=usosnvme.inf', '<hash>usosnvme.sys=usosnvme.sys', '/fd sha1'):
            self.assertIn(want, sign)
        self.assertLess(sign.index('& $signtool sign'), sign.index('-DeleteKey'))
        import importlib.util
        spec = importlib.util.spec_from_file_location('usosnvme_signed', ROOT / 'tools/build_usosnvme_nt6_signed.py')
        mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        inf = mod.nt6_inf(ROOT)
        self.assertIn(b'DriverVer=01/01/2001,1.0.0.0\r\nCatalogFile=usosnvme.cat\r\n', inf)
        s = self.step()
        self.assertNotIn('Windows\\inf\\usosnvme.inf', s)
        self.assertIn('for %%F in (usosnvme.inf usosnvme.cat usosnvme.cer) do if exist "%~dp0%%F" '
                      'copy /y "%~dp0%%F" "%USOS_T%\\USOS\\nvme\\%%F"', s)
        gate = (ROOT / 'tools/windows_vista_oobe_gate.c').read_text(encoding='utf-8')
        body = gate[gate.index('static BOOL nvme_stage(void)'):]
        for want in ('CERT_SYSTEM_STORE_LOCAL_MACHINE', 'L"Root",L"TrustedPublisher"', 'CertAddEncodedCertificateToStore',
                     'pnputil.exe', '-a \\"', 'CREATE_NO_WINDOW'):
            self.assertIn(want, body)
        entry = gate[gate.index('void entry(void)'):]
        native = entry[entry.index('#ifdef USOS_GATE_NATIVE_DEPLOY'):entry.index('#else')]
        self.assertLess(native.index('nvme_stage();'), native.index('windeploy.exe'))
        build = (ROOT / 'tools/build_windows_native_support.py').read_text(encoding='utf-8')
        self.assertIn("'-lcrypt32', '-o', str(helpers / 'usos-vista-oobe-x86.exe')", build)


if __name__ == '__main__':
    unittest.main()
