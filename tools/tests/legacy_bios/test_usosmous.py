"""USB mouse for Windows 9x under CSMWrap: the INT 15h C207h callback of the
real USOSKEY.COM (shared block version 4) in Unicorn, the USOSMOUS.DRV NE
exports and imports, the Windows Me path (v2: USOSKEY.DRV installs the
bridge copy and calls USOSMOUS.DRV's USOSATTACH; the mouse driver imports
KERNEL only; v3: USOSKEY.DRV's WH_CBT hook pauses the mouse through
USOSPAUSE while a DOS box exists) and its wiring into the 95 / 98 / 98 SE /
Me install (INSTALL.BAT, payload; Me: mouse.drv= at the first sign-in)."""
from pathlib import Path
import re
import struct
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_win3_usb_keyboard import build_tsr, build_mouse_driver, elf_symbols, write_tsr_header, ne_imported_modules

SEG = 0x2000
# Shared block offsets (usoskey.S, version 4).
MHEAD, MTAIL, MALIVE, MCB, MDROPPED, MIGNORED, MPACKETS, MLAST, MRING = 396, 397, 398, 400, 402, 404, 408, 412, 420


class UsosMouse(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/win3-usb-mouse-test'
        work.mkdir(parents=True, exist_ok=True)
        com = build_tsr(work, work)
        cls.code = com.read_bytes()
        cls.sym = elf_symbols(work / 'usoskey.elf')
        write_tsr_header(com, work / 'usoskey.elf', work)
        cls.drv = build_mouse_driver(work, work).read_bytes()

    def machine(self):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        u.mem_write(SEG * 16 + 0x100, self.code)
        for reg in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES):
            u.reg_write(reg, SEG)
        u.reg_write(UC_X86_REG_SS, 0x3000)
        u.hook_add(UC_HOOK_INTR, lambda uc, n, d: self.fail(f'unexpected INT {n:02x}'))
        return u

    def shared(self, u, off, size=1):
        return bytes(u.mem_read(SEG * 16 + self.sym['shared'] + off, size))

    def set_shared(self, u, off, data):
        u.mem_write(SEG * 16 + self.sym['shared'] + off, data)

    def callback(self, u, status, x, y, z=0):
        """Far call as SeaBIOS's invoke_mouse_handler: push status, X, Y, Z
        (words), lcall, the caller pops 8 bytes."""
        sp = 0xff00
        frame = struct.pack('<HHHHHH', 0x7000, 0x0000, z, y, x, status)  # ret IP, ret CS, Z, Y, X, status
        u.mem_write(0x30000 + sp, frame)
        u.reg_write(UC_X86_REG_SP, sp)
        u.reg_write(UC_X86_REG_BP, 0x1234)
        u.reg_write(UC_X86_REG_AX, 0xaaaa)
        u.reg_write(UC_X86_REG_BX, 0xbbbb)
        u.reg_write(UC_X86_REG_SI, 0x5151)
        u.reg_write(UC_X86_REG_CS, SEG)
        mcb = struct.unpack('<H', self.shared(u, MCB, 2))[0]
        self.assertEqual(mcb, self.sym['mcb'])
        u.emu_start(SEG * 16 + mcb, 0x7000, count=200)
        self.assertEqual((u.reg_read(UC_X86_REG_CS), u.reg_read(UC_X86_REG_IP)), (0, 0x7000))
        self.assertEqual(u.reg_read(UC_X86_REG_SP), sp + 4)        # retf only: the BIOS pops its 4 words
        self.assertEqual([u.reg_read(r) for r in (UC_X86_REG_BP, UC_X86_REG_AX, UC_X86_REG_BX, UC_X86_REG_SI)],
                         [0x1234, 0xaaaa, 0xbbbb, 0x5151])

    def test_block_version_and_layout(self):
        u = self.machine()
        self.assertEqual(self.shared(u, 0, 6), b'USKY\x04\x00')
        self.assertEqual(self.sym['mring'] - self.sym['shared'], MRING)
        self.assertEqual(self.sym['in9'] - self.sym['shared'], MRING + 128)
        self.assertLess(self.sym['mcb'], self.sym['resident_end'])

    def test_packets_go_to_the_ring_only_while_the_driver_polls(self):
        u = self.machine()
        self.callback(u, 0x09, 0x05, 0xfe)          # no consumer: counted, not stored
        self.assertEqual(self.shared(u, MHEAD, 2), b'\x00\x00')
        self.assertEqual(struct.unpack('<H', self.shared(u, MIGNORED, 2))[0], 1)
        self.set_shared(u, MALIVE, b'\x12')
        self.callback(u, 0x19, 0xfb, 0x03)          # left button, X -5, Y +3
        self.assertEqual(self.shared(u, MHEAD, 2), b'\x01\x00')
        self.assertEqual(self.shared(u, MRING, 3), b'\x19\xfb\x03')
        self.assertEqual(self.shared(u, MLAST, 3), b'\x19\xfb\x03')
        self.assertEqual(struct.unpack('<I', self.shared(u, MPACKETS, 4))[0], 2)

    def test_full_ring_drops(self):
        u = self.machine()
        self.set_shared(u, MALIVE, b'\x12')
        for i in range(31):
            self.callback(u, 0x08, i, 0)
        self.assertEqual(self.shared(u, MHEAD, 1), bytes([31]))
        self.callback(u, 0x08, 0x40, 0)             # 32 slots, one stays free
        self.assertEqual(self.shared(u, MHEAD, 1), bytes([31]))
        self.assertEqual(struct.unpack('<H', self.shared(u, MDROPPED, 2))[0], 1)
        self.set_shared(u, MTAIL, bytes([5]))       # the driver took 5
        self.callback(u, 0x0a, 0x41, 0x42)
        self.assertEqual(self.shared(u, MHEAD, 1), b'\x00')
        self.assertEqual(self.shared(u, MRING + 31 * 4, 3), b'\x0a\x41\x42')

    def test_wheel_byte_from_the_z_word(self):
        # CSMWrap patch 0016: after the IntelliMouse knock SeaBIOS passes the
        # wheel byte (up negative) in the Z word; the ring keeps its low byte.
        u = self.machine()
        self.set_shared(u, MALIVE, b'\x12')
        self.callback(u, 0x08, 0, 0, 0xfffe)       # two notches up
        self.callback(u, 0x08, 0, 0)               # a BIOS without the wheel: Z = 0
        self.assertEqual(self.shared(u, MRING, 4), b'\x08\x00\x00\xfe')
        self.assertEqual(self.shared(u, MRING + 4, 4), b'\x08\x00\x00\x00')
        self.assertEqual(self.shared(u, MLAST, 4), b'\x08\x00\x00\x00')

    def test_mouse_driver_exports(self):
        d = self.drv
        ne = struct.unpack_from('<H', d, 0x3c)[0]
        self.assertEqual(d[ne:ne + 2], b'NE')
        names, i = {}, ne + struct.unpack_from('<H', d, ne + 0x26)[0]
        while d[i]:
            n = d[i]
            names[d[i + 1:i + 1 + n].decode()] = struct.unpack_from('<H', d, i + 1 + n)[0]
            i += n + 3
        # Module name MOUSE (USER imports the mouse driver by it), DDK
        # ordinals; USOSATTACH and USOSPAUSE (Me, called by USOSKEY.DRV by
        # name) after them, USOSWHEELINFO (USOSDBG.EXE, read only) last.
        self.assertEqual(names, {'MOUSE': 0, 'INQUIRE': 1, 'ENABLE': 2, 'DISABLE': 3, 'MOUSEGETINTVECT': 4, 'WEP': 5,
                                 'USOSATTACH': 6, 'USOSPAUSE': 7, 'USOSWHEELINFO': 8})

    def test_mouse_driver_imports_kernel_only(self):
        # KERNEL loads mouse.drv right after keyboard.drv, before DISPLAY, GDI
        # and USER (Me BOOTLOG.TXT); v1 imported USER and Me did not start.
        # v3 keeps it so: the DOS-box guard's USER part is in USOSKEY.DRV.
        self.assertEqual(ne_imported_modules(self.drv), ['KERNEL'])
        build = (ROOT / 'tools/build_win3_usb_keyboard.py').read_text(encoding='utf-8')
        self.assertIn("if ne_imported_modules(data) != ['KERNEL']:", build)   # the build refuses anything else

    def test_mouse_driver_segments_as_before(self):
        # Two segments as in the driver that worked on 98 SE: code fixed
        # preload (0D60h), DGROUP fixed preload data (0C61h); module flags.
        d = self.drv
        ne = struct.unpack_from('<H', d, 0x3c)[0]
        self.assertEqual(struct.unpack_from('<H', d, ne + 0x1c)[0], 2)
        seg = ne + struct.unpack_from('<H', d, ne + 0x22)[0]
        flags = [struct.unpack_from('<H', d, seg + 8 * i + 4)[0] for i in range(2)]
        self.assertEqual(flags, [0x0D60, 0x0C61])
        self.assertEqual(struct.unpack_from('<H', d, ne + 0x0c)[0], 0x8301)

    def test_install_wiring(self):
        install = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1')
        auto = [l for l in install.splitlines() if 'AUTOEXEC.BAT' in l and l.startswith('ECHO @')]
        copy_line = next(i for i, l in enumerate(auto) if 'USOSMOUS.DRV COPY' in l or 'USOSMOUS.DRV IF EXIST' in l)
        fix_line = next(i for i, l in enumerate(auto) if 'U9FIX.COM /CSM' in l)
        self.assertLess(copy_line, fix_line, 'the driver must be in SYSTEM before U9FIX names it')
        self.assertIn('IF "%U9SYS%"=="98SE" GOTO MOUSEOK', install)
        # 98 (first edition), 95 and Me get the mouse driver too.
        self.assertIn('IF "%U9SYS%"=="98" GOTO MOUSEOK', install)
        self.assertIn('IF "%U9SYS%"=="95" GOTO MOUSEOK', install)
        self.assertIn('IF "%U9SYS%"=="ME" GOTO MOUSEOK', install)
        # Me: both drivers in SYSTEM before Setup (no AUTOEXEC.BAT copy runs).
        me = install[install.index('IF NOT "%U9SYS%"=="ME" GOTO CSMREG'):install.index(':CSMREG')]
        self.assertIn('COPY /Y C:\\USOS9X\\USOSKEY.DRV C:\\WINDOWS\\SYSTEM', me)
        self.assertIn('COPY /Y C:\\USOS9X\\USOSMOUS.DRV C:\\WINDOWS\\SYSTEM', me)
        # 95 / 98 / 98 SE: unchanged, no first-sign-in INF.
        nine_x = install[install.index(':CSMREG\n'):install.index(':AUTODONE')]
        self.assertNotIn('USOSMOUS.INF', nine_x)
        sys.path.insert(0, str(ROOT / 'tools'))
        import build_win9x_support
        self.assertIn('USOSMOUS.DRV', build_win9x_support.FILES)
        self.assertIn('"USOSMOUS.DRV"', (ROOT / 'src/platform/bios/dos_native_iso.zig').read_text())
        self.assertIn('win9x/USOSMOUS.DRV', (ROOT / 'installer/cmd/usos-payload-pack/main.go').read_text())


class MeBridge(unittest.TestCase):
    """Windows Me: no USOSKEY.COM. KERNEL loads mouse.drv before USER and
    USER asks it (Init = Mouse) before the installable drivers (Micron
    BOOTLOG.TXT 2026-10-18). v1 installed the bridge copy from Inquire and
    added a WH_CBT hook (USER import): Me no longer started. v2: Inquire and
    Enable change nothing on Me; USOSKEY.DRV installs the copy at DRV_LOAD
    and calls USOSATTACH, which registers the BIOS mouse."""

    @classmethod
    def setUpClass(cls):
        cls.mouse = (ROOT / 'src/platform/win3/usosmous.c').read_text(encoding='utf-8')
        cls.key = (ROOT / 'src/platform/win3/usoskey.c').read_text(encoding='utf-8')
        cls.resident = (ROOT / 'src/platform/win3/usos_resident.h').read_text(encoding='utf-8')
        cls.lnk = (ROOT / 'src/platform/win3/usosmous.lnk').read_text(encoding='utf-8')
        work = ROOT / 'zig-out/win3-usb-mouse-test'
        work.mkdir(parents=True, exist_ok=True)
        com = build_tsr(work, work)
        cls.code = com.read_bytes()
        cls.sym = elf_symbols(work / 'usoskey.elf')
        cls.header = write_tsr_header(com, work / 'usoskey.elf', work).read_text()

    @staticmethod
    def body(text, name):
        m = re.search(r'\b%s\s*\([^;{]*\)\s*\{' % name, text)
        assert m, name
        depth, i = 0, m.end() - 1
        for j in range(i, len(text)):
            depth += {'{': 1, '}': -1}.get(text[j], 0)
            if depth == 0:
                return text[i:j + 1]
        raise AssertionError(name)

    @staticmethod
    def code_only(text):
        return re.sub(r'/\*.*?\*/', '', text, flags=re.S)

    def test_mouse_driver_never_installs_the_bridge_or_hooks(self):
        code = self.code_only(self.mouse)
        for word in ('install_resident', 'usos_resident.h', 'usoskey_tsr.h', 'GlobalDosAlloc', 'SetWindowsHookEx',
                     'CallNextHookEx', 'GetClassName', 'WritePrivateProfileString', '0201h', 'int 21h'):
            self.assertNotIn(word, code)

    def test_inquire_on_me_without_bridge_is_static(self):
        inquire = self.body(self.mouse, 'Inquire')
        self.assertIn('exists = probed ? present : (BYTE)is_me();', inquire)
        self.assertLess(inquire.index('switched_off()'), inquire.index('probe()'))
        probe = self.body(self.mouse, 'probe')
        self.assertIn('if (!query_bridge()) return;', probe)
        self.assertLess(probe.index('query_bridge()'), probe.index('bios15'))
        self.assertIn('>= 8', self.body(self.mouse, 'is_me'))        # DOS 8.00 = Me

    def test_enable_keeps_the_procedure_and_attach_starts(self):
        enable = self.body(self.mouse, 'Enable')
        self.assertIn('if (probed ? !present : !is_me()) return;', enable)   # 95/98 without bridge: as before
        self.assertLess(enable.index('event_proc = (DWORD)proc;'), enable.index('start();'))
        start = self.body(self.mouse, 'start')
        self.assertIn('!event_proc || !shared || !present', start)
        self.assertLess(start.index('bios_on()'), start.index('create_timer(20'))
        self.assertIn('bios_off(MS_FAILED)', start)
        attach = self.body(self.mouse, 'UsosAttach')
        self.assertIn('switched_off() || !event_proc || timer', attach)
        self.assertLess(attach.index('probe()'), attach.index('start()'))
        self.assertIn('export USOSATTACH.6 resident', self.lnk)

    def test_nomouse_switch(self):
        sw = self.body(self.mouse, 'switched_off')
        self.assertIn(r'"C:\\USOS9X\\NOMOUSE.TXT"', sw)
        self.assertIn('OF_EXIST', sw)
        for name in ('Inquire', 'Enable', 'UsosAttach'):
            self.assertIn('switched_off()', self.body(self.mouse, name))

    def test_wheel(self):
        # 98 / 98 SE / Me USER: mouse_event AX=0800h with the delta in DX
        # (WM_MOUSEWHEEL), Inquire msExists 4Bh = SM_MOUSEWHEELPRESENT.
        self.assertIn('#define SF_WHEEL      0x0800', self.mouse)
        self.assertIn('#define MS_EXISTS_WHEEL 0x4B', self.mouse)
        knock = self.body(self.mouse, 'knock')
        self.assertIn('rates[3] = { 0x0600, 0x0500, 0x0400 };', knock)    # 200, 100, 80, in order
        self.assertIn('for (i = 0; i < 3; i++)', knock)
        self.assertLess(knock.index('bios15(0xC202, rates[i], 0)'), knock.index('bios15(0xC204, 0, 0)'))
        self.assertIn('winfo.knock_id == 3', knock)
        self.assertLess(knock.index('wheel = 0;'), knock.index('if (!want) return;'))  # cleared before any return
        self.assertLess(knock.index('if (!want) return;'), knock.index('bios15('))
        wanted = self.body(self.mouse, 'wheel_wanted')
        self.assertIn('LOBYTE(dos) >= 10', wanted)                       # DOS 7.10+: 98 and later
        self.assertIn('"usosmous", "Wheel", 1', wanted)
        on = self.body(self.mouse, 'bios_on')
        self.assertLess(on.index('bios15(0xC205'), on.index('knock()'))  # C205h resets the device ID
        self.assertLess(on.index('knock()'), on.index('bios15(0xC207'))
        poll = self.body(self.mouse, 'poll_body')
        self.assertIn('wheel_sum += (signed char)p[3];', poll)
        self.assertLess(poll.index('call_event(SF_MOVEMENT'), poll.index('call_wheel(wheel_sum)'))
        # v4 (CSMWrap usos15 patch 0020): the Z word counts also when the
        # knock was not answered with ID 3, but only where the wheel is wanted.
        self.assertIn('if (wheel_sum && (wheel || wheel_pref == 2)) call_wheel(wheel_sum);', poll)
        # v4: a knock answered with an ID other than 3 is sent once more, at most.
        self.assertIn('for (tries = 0; tries < 2 && !wheel; tries++)', knock)
        self.assertLess(knock.index('for (tries = 0;'), knock.index('winfo.knocks++;'))
        self.assertLess(knock.index('wheel = winfo.knock_id == 3;'), knock.rindex('winfo.wheel = wheel;'))
        wheel = self.body(self.mouse, 'call_wheel')
        self.assertIn('mov ax, SF_WHEEL', wheel)
        self.assertIn('mov dx, delta', wheel)
        self.assertIn('-sum * WHEEL_DELTA', wheel)                        # IntelliMouse up negative, USER up positive
        inquire = self.body(self.mouse, 'Inquire')
        self.assertIn('(probed ? wheel : wheel_wanted())', inquire)      # Me without bridge: no BIOS call
        self.assertNotIn('knock', inquire)

    def test_wheel_diagnostics(self):
        # USOSWHEELINFO (ordinal 8, USOSDBG.EXE): a far pointer to the
        # driver's own record; no BIOS call, nothing changed but winfo.wheel.
        self.assertIn('export USOSWHEELINFO.8 resident', self.lnk)
        info = self.body(self.mouse, 'UsosWheelInfo')
        self.assertIn('__loadds', self.mouse[self.mouse.index('UsosWheelInfo') - 60:self.mouse.index('UsosWheelInfo')])
        self.assertNotIn('bios15', info)
        self.assertIn('return (DWORD)(WHEELINFO FAR *)&winfo;', info)
        self.assertIn('static WHEELINFO winfo = { 2, 0, 0, 0xFF };', self.mouse)
        wheel = self.body(self.mouse, 'call_wheel')
        self.assertIn('winfo.wheel_calls++;', wheel)
        self.assertIn('winfo.last_sum = sum;', wheel)

    def test_timer_path_stays_interrupt_safe(self):
        poll = self.body(self.mouse, 'poll_body') + self.body(self.mouse, 'call_wheel')
        for call in ('Get', 'Open', 'bios15', 'Alloc', 'probe', 'start(', 'create_timer', 'knock', 'wheel_wanted'):
            self.assertNotIn(call, poll)

    def test_usoskey_installs_then_attaches_the_mouse_on_me_only(self):
        init = self.body(self.key, 'init')
        self.assertIn('if (shared->pad == RESIDENT_FROM_WINDOWS) attach_mouse();', init)
        self.assertLess(init.index('find_bridge()'), init.index('attach_mouse()'))
        attach = self.body(self.key, 'attach_mouse')
        self.assertIn('mouse_export("USOSATTACH")', attach)    # by name: other mouse drivers have none
        self.assertNotIn('attach_mouse', self.body(self.key, 'poll_body'))
        fb = self.body(self.key, 'find_bridge')
        self.assertLess(fb.index('query_bridge()'), fb.index('install_resident()'))

    def test_me_dos_box_guard_in_usoskey(self):
        # v3: the hook counts WinOldAp "tty" windows; the first pauses the
        # mouse, the last one gone resumes it.
        cbt = self.body(self.key, 'cbt_proc')
        self.assertIn('code == HCBT_CREATEWND || code == HCBT_DESTROYWND', cbt)
        self.assertIn('mouse_guard &&', cbt)
        self.assertIn('if (dos_boxes++ == 0) mouse_pause(1);', cbt)
        self.assertIn('else if (dos_boxes && --dos_boxes == 0) {', cbt)
        self.assertIn('mouse_pause(0);', cbt)
        self.assertIn('dos_focus = is_dos_box((HWND)wp);', cbt)     # keyboard routing as before
        self.assertIn("(name[0] | 0x20) == 't'", self.body(self.key, 'is_dos_box'))
        self.assertIn('mouse_export("USOSPAUSE")', self.body(self.key, 'mouse_pause'))
        export = self.body(self.key, 'mouse_export')
        self.assertIn('GetModuleHandle("MOUSE")', export)             # looked up at every use
        self.assertIn('GetProcAddress(mouse, name)', export)

    def test_me_guard_pauses_before_attach_and_until_the_hook(self):
        attach = self.body(self.key, 'attach_mouse')
        self.assertIn('mouse_export("USOSATTACH")', attach)          # by name: other mouse drivers have none
        # The guard is armed through USOSPAUSE, except when USOSVMD.VXD is
        # deployed (then the VxD owns the DOS-box mouse; see test_usosvmd.py).
        self.assertIn('mouse_export("USOSPAUSE") != 0', attach)
        self.assertIn('!usosvmd_on()', attach)
        self.assertLess(attach.index('mouse_pause(1)'), attach.index('attach)();'))
        start = self.body(self.key, 'start')
        self.assertIn('(win9x && vkd_entry) || mouse_guard', start)
        self.assertIn('mouse_pause(cbt_hook ? 0 : 2);', start)      # no hook: paused for good
        self.assertLess(start.index('SetWindowsHookEx'), start.index('mouse_pause('))
        # DRV_DISABLE keeps the guard's hook and count; DRV_FREE pauses first.
        stop = self.body(self.key, 'stop')
        self.assertIn('if (!mouse_guard) unhook();', stop)
        self.assertNotIn('dos_boxes', stop)
        release = self.body(self.key, 'release')
        self.assertLess(release.index('mouse_pause(2)'), release.index('unhook()'))
        self.assertIn('case DRV_FREE:    release(); return 1L;', self.key)
        self.assertIn('unhook();', self.body(self.key, 'WEP'))
        self.assertNotIn('mouse_pause', self.body(self.key, 'poll_body'))

    def test_me_pause_export_in_the_mouse_driver(self):
        self.assertIn('export USOSPAUSE.7 resident', self.lnk)
        pause = self.body(self.mouse, 'UsosPause')
        self.assertIn("paused = how == 2 ? MS_NO_GUARD : MS_PAUSED;", pause)
        self.assertIn('if (shared->mstate == MS_ENABLED) bios_off(paused);', pause)
        self.assertIn('paused = 0;', pause)
        self.assertIn('shared->mstate != MS_PAUSED && shared->mstate != MS_NO_GUARD', pause)
        self.assertLess(pause.index('paused = 0;'), pause.index('bios_on()'))
        self.assertIn('!shared || !timer || !event_proc', pause)
        # bios_off: C200h off, then C207h 0:0.
        off = self.body(self.mouse, 'bios_off')
        self.assertLess(off.index('bios15(0xC200, 0x0000, 0)'), off.index('bios15(0xC207, 0, 0)'))
        # start() while paused: timer only, the BIOS mouse stays off.
        start = self.body(self.mouse, 'start')
        self.assertIn('if (paused) shared->mstate = paused;', start)
        self.assertIn('else if (!bios_on()) return;', start)
        self.assertIn('#define MS_PAUSED     5', self.mouse)
        self.assertIn('#define MS_NO_GUARD   6', self.mouse)
        self.assertNotIn('UsosPause', self.body(self.mouse, 'poll_body'))
        dbg = (ROOT / 'src/platform/bios/win9x/usosdbg.c').read_text(encoding='utf-8')
        self.assertIn('"paused (DOS box open)",', dbg)
        self.assertIn('"paused (no DOS-box guard)" };', dbg)
        self.assertIn('s->mstate < 7 ? states[s->mstate]', dbg)

    def me_install(self):
        install = (ROOT / 'src/platform/bios/dos_startup.cmd').read_text(encoding='latin-1')
        return install[install.index('IF NOT "%U9SYS%"=="ME" GOTO CSMREG'):install.index(':CSMREG\n')]

    @staticmethod
    def echo_output(block, target):
        """What the block's ECHO lines append to (or create as) target,
        as COMMAND.COM writes it: %% becomes %, %U9SRC% expands."""
        out = []
        for line in block.splitlines():
            m = re.match(r'ECHO (.*?)(>>?)(\S+)$', line)
            if m and m.group(3).replace('%U9SRC%', 'WIN9X') == target:
                if m.group(2) == '>':
                    out = []
                out.append(m.group(1).replace('%%', '%'))
        return out

    def test_me_install_sets_mouse_drv_at_the_first_sign_in(self):
        me = self.me_install()
        self.assertIn('IF NOT EXIST C:\\USOS9X\\USOSMOUS.DRV GOTO MEKEY', me)
        self.assertLess(me.index('COPY /Y C:\\USOS9X\\USOSMOUS.DRV C:\\WINDOWS\\SYSTEM'), me.index(':MEKEY'))
        inf = self.echo_output(me, 'C:\\USOS9X\\USOSMOUS.INF')
        self.assertEqual(inf, ['[Version]', 'Signature="$CHICAGO$"', '[DefaultInstall]', 'UpdateInis=USOS.MeMouse.Ini',
                               '[USOS.MeMouse.Ini]', 'system.ini,boot,"mouse.drv=*","mouse.drv=usosmous.drv"',
                               'system.ini,386Enh,"mouse=*",'])
        batch = self.echo_output(me, 'C:\\WIN9X\\MSBATCH.INF')
        self.assertEqual(batch[0], 'system.ini,boot,drivers,,usoskey.drv')        # still in [USOS.Csm]
        self.assertEqual(batch[1:], [
            '[USOS.CsmReg]',
            'HKLM,%USOSRO%,USOSMouse,,"%USOSMC%"',
            '[Strings]',
            'USOSRO="Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce"',
            'USOSMC="rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 C:\\USOS9X\\USOSMOUS.INF"'])
        # [Install] AddReg names USOS.CsmReg, [USOS.Csm] is the last section.
        msbatch = (ROOT / 'src/flow/answer/msbatch.zig').read_text(encoding='utf-8')
        self.assertIn('AddReg=USOS.RunOnce,USOS.CsmReg', msbatch)
        self.assertIn('std.mem.endsWith(u8, me, "[USOS.Csm]', msbatch)
        # The user's own answer file: nothing appended.
        self.assertLess(me.index('IF "%U9ANS%"=="USER" GOTO AUTODONE'), me.index('>>C:\\%U9SRC%\\MSBATCH.INF'))
        # Every line fits COMMAND.COM's batch line (127 characters, expanded).
        for line in me.splitlines():
            self.assertLessEqual(len(line.replace('%U9SRC%', 'WIN9X').replace('%%', '%')), 127, line)

    def test_no_system_ini_rewriting(self):
        for src in (self.key, self.mouse):
            self.assertNotIn('WritePrivateProfileString', self.code_only(src))
            self.assertNotIn('keep_mouse_ini', src)

    def test_the_windows_copy_marks_itself_in_an_unused_tsr_byte(self):
        shared = self.sym['shared']
        self.assertIn('#define TSR_SHARED 0x%04X' % shared, self.header)
        self.assertEqual(self.code[shared - 0x100:shared - 0x100 + 4], b'USKY')
        self.assertEqual(self.code[shared - 0x100 + 9], 0)  # the TSR leaves it 0
        self.assertEqual(self.sym['alive'] - shared, 8)
        self.assertIn('p[TSR_SHARED + 9] = RESIDENT_FROM_WINDOWS;', self.resident)
        self.assertIn('if (tsr_mem) return;', self.body(self.resident, 'install_resident'))


if __name__ == '__main__':
    unittest.main()
