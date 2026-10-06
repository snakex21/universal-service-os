"""Run the real U9FIX.COM (Windows 9x SYSTEM.INI memory settings) in Unicorn
against a small emulated DOS file API."""
from pathlib import Path
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_INTR, UC_HOOK_INSN
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_win9x_support import build_u9fix

INI = 'C:\\WINDOWS\\SYSTEM.INI'
TEMP = 'C:\\WINDOWS\\SYSTEM.U9$'


class U9Fix(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        out = ROOT / 'zig-out/win9x-support-test'
        out.mkdir(parents=True, exist_ok=True)
        cls.code = build_u9fix(out, out).read_bytes()

    def run_fix(self, files, command=' ' + INI, fail_write=False, pci=None):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        base = 0x20000
        u.mem_write(base + 0x100, self.code)
        tail = command.encode('ascii')
        u.mem_write(base + 0x80, bytes([len(tail)]) + tail + b'\r')
        for reg in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS):
            u.reg_write(reg, base >> 4)
        u.reg_write(UC_X86_REG_SP, 0xfffe)
        handles, state = {}, {'exit': None, 'writes': 0}

        def string(offset):
            data = bytes(u.mem_read(base + offset, 128))
            return data[:data.index(0)].decode('ascii').upper()

        def carry(value):
            flags = u.reg_read(UC_X86_REG_EFLAGS)
            u.reg_write(UC_X86_REG_EFLAGS, (flags | 1) if value else (flags & ~1))

        def interrupt(uc, number, data):
            ax = uc.reg_read(UC_X86_REG_AX)
            ah, dx = ax >> 8, uc.reg_read(UC_X86_REG_DX)
            bx, cx = uc.reg_read(UC_X86_REG_BX), uc.reg_read(UC_X86_REG_CX)
            self.assertEqual(number, 0x21)
            if ah == 0x3d:
                name = string(dx)
                if name not in files:
                    carry(True); uc.reg_write(UC_X86_REG_AX, 2); return
                h = 5 + len(handles)
                handles[h] = [name, 0]
                uc.reg_write(UC_X86_REG_AX, h); carry(False)
            elif ah == 0x3c:
                name = string(dx)
                files[name] = b''
                h = 5 + len(handles)
                handles[h] = [name, 0]
                uc.reg_write(UC_X86_REG_AX, h); carry(False)
            elif ah == 0x3f:
                name, pos = handles[bx]
                chunk = files[name][pos:pos + cx]
                handles[bx][1] += len(chunk)
                u.mem_write(base + dx, chunk)
                uc.reg_write(UC_X86_REG_AX, len(chunk)); carry(False)
            elif ah == 0x40:
                state['writes'] += 1
                if fail_write:
                    carry(True); uc.reg_write(UC_X86_REG_AX, 5); return
                name = handles[bx][0]
                files[name] += bytes(u.mem_read(base + dx, cx))
                uc.reg_write(UC_X86_REG_AX, cx); carry(False)
            elif ah == 0x3e:
                handles.pop(bx); carry(False)
            elif ah == 0x41:
                files.pop(string(dx), None); carry(False)
            elif ah == 0x56:
                new = string(uc.reg_read(UC_X86_REG_DI))
                files[new] = files.pop(string(dx)); carry(False)
            elif ah == 0x43:
                self.assertEqual(ax, 0x4300)
                if string(dx) in files:
                    uc.reg_write(UC_X86_REG_CX, 0x20); carry(False)
                else:
                    uc.reg_write(UC_X86_REG_AX, 2); carry(True)
            elif ah == 0x09:
                pass
            elif ah == 0x4c:
                state['exit'] = ax & 255
                uc.emu_stop()
            else:
                self.fail(f'unexpected DOS call {ah:02x}')

        u.hook_add(UC_HOOK_INTR, interrupt)
        # PCI configuration mechanism #1: {(bus, device): (vendor, device id, class<<8)}
        pci = pci or {}
        address = [0]

        def port_in(uc, port, size, data):
            if port != 0xcfc:
                return 0xffffffff
            a = address[0]
            bus, dev, fn, reg = (a >> 16) & 255, (a >> 11) & 31, (a >> 8) & 7, a & 0xfc
            entry = pci.get((bus, dev)) if fn == 0 else None
            if entry is None:
                return 0xffffffff
            return (entry[1] << 16 | entry[0]) if reg == 0 else (entry[2] << 8 | 1) if reg == 8 else 0

        def port_out(uc, port, size, value, data):
            if port == 0xcf8:
                address[0] = value

        u.hook_add(UC_HOOK_INSN, port_in, None, 1, 0, UC_X86_INS_IN)
        u.hook_add(UC_HOOK_INSN, port_out, None, 1, 0, UC_X86_INS_OUT)
        u.emu_start(base + 0x100, base + 0x10000, count=5_000_000)
        return state

    def test_adds_both_keys_after_their_headers(self):
        files = {INI: b'[boot]\r\nshell=Explorer.exe\r\n[386Enh]\r\nwoafont=dosapp.fon\r\n[vcache]\r\n'}
        st = self.run_fix(files)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[INI], b'[boot]\r\nshell=Explorer.exe\r\n[386Enh]\r\nMaxPhysPage=40000\r\n'
                         b'woafont=dosapp.fon\r\n[vcache]\r\nMaxFileCache=262144\r\n')
        self.assertNotIn(TEMP, files)

    def test_missing_section_is_appended_and_last_line_terminated(self):
        files = {INI: b'[386enh]\r\nmaxphyspage = 20000\r\n[boot]\r\nshell=Explorer.exe'}
        st = self.run_fix(files)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[INI], b'[386enh]\r\nmaxphyspage = 20000\r\n[boot]\r\nshell=Explorer.exe\r\n'
                         b'[vcache]\r\nMaxFileCache=262144\r\n')

    def test_present_values_leave_the_file_untouched(self):
        text = b'[386Enh]\r\nMaxPhysPage=30000\r\n[vcache]\r\nMaxFileCache=65536\r\n'
        files = {INI: text}
        st = self.run_fix(files)
        self.assertEqual((st['exit'], st['writes'], files), (0, 0, {INI: text}))

    def test_lookalike_key_does_not_count(self):
        files = {INI: b'[386Enh]\r\nMaxPhysPageX=1\r\n;MaxFileCache=1\r\n[vcache]\r\nMaxFileCache=1\r\n'}
        self.run_fix(files)
        self.assertEqual(files[INI], b'[386Enh]\r\nMaxPhysPage=40000\r\nMaxPhysPageX=1\r\n;MaxFileCache=1\r\n[vcache]\r\nMaxFileCache=1\r\n')

    def test_header_on_the_last_line_without_newline(self):
        files = {INI: b'[vcache]\r\nMaxFileCache=1\r\n[386Enh]'}
        self.run_fix(files)
        self.assertEqual(files[INI], b'[vcache]\r\nMaxFileCache=1\r\n[386Enh]\r\nMaxPhysPage=40000\r\n')

    def test_missing_file_and_failed_write_keep_everything(self):
        files = {}
        self.assertEqual(self.run_fix(files)['exit'], 1)
        self.assertEqual(files, {})
        text = b'[boot]\r\n'
        files = {INI: text}
        self.assertEqual(self.run_fix(files, fail_write=True)['exit'], 1)
        self.assertEqual(files, {INI: text})
        self.assertEqual(self.run_fix({}, command='')['exit'], 1)

    def test_vga_mode_adds_one_hardware_id_line_per_display_controller(self):
        inf = 'C:\\WIN98\\USOSVESA.INF'
        text = b'[Manufacturer]\r\n%Mfg%=Mfg.VM\r\n\r\n[Mfg.VM]\r\n%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n'
        files = {inf: text}
        pci = {(0, 1): (0x8086, 0x7000, 0x060100), (0, 2): (0x1234, 0x1111, 0x030000), (3, 0): (0x1002, 0x67ff, 0x030000)}
        st = self.run_fix(files, command=' /VGA ' + inf, pci=pci)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[inf], b'[Manufacturer]\r\n%Mfg%=Mfg.VM\r\n\r\n[Mfg.VM]\r\n'
                         b'"vesa (vmdisp9x) 1002:67ff"=VESA, PCI\\VEN_1002&DEV_67ff\r\n'
                         b'"vesa (vmdisp9x) 1234:1111"=VESA, PCI\\VEN_1234&DEV_1111\r\n'
                         b'%VESAPCI.DeviceDesc%=VESA, PCI\\CC_0300\r\n')
        # A second run finds both lines and leaves the file alone.
        again = dict(files)
        st = self.run_fix(again, command=' /vga ' + inf, pci=pci)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))
        # No display controller: nothing to do.
        st = self.run_fix({inf: text}, command=' /VGA ' + inf, pci={(0, 1): (0x8086, 0x7000, 0x060100)})
        self.assertEqual((st['exit'], st['writes']), (0, 0))

    def test_csm_mode_adds_the_usb_keyboard_driver_only(self):
        text = (b'[boot]\r\nshell=Explorer.exe\r\ndrivers=mmsystem.dll\r\nmouse.drv=mouse.drv\r\n'
                b'[boot.description]\r\nmouse.drv=Standard mouse\r\n[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        files = {INI: text}
        st = self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[INI], b'[boot]\r\nshell=Explorer.exe\r\ndrivers=mmsystem.dll usoskey.drv\r\nmouse.drv=mouse.drv\r\n'
                         b'[boot.description]\r\nmouse.drv=Standard mouse\r\n[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        again = dict(files)
        st = self.run_fix(again, command=' /csm ' + INI)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))
        # No drivers= in [boot]: the line is added; mouse.drv stays as it is.
        files = {INI: b'[boot]\r\nshell=Explorer.exe\r\n[boot.description]\r\nmouse.drv=Standard mouse\r\n'}
        self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(files[INI], b'[boot]\r\ndrivers=usoskey.drv\r\nshell=Explorer.exe\r\n'
                         b'[boot.description]\r\nmouse.drv=Standard mouse\r\n[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=262144\r\n')

    def test_csm_mode_drops_the_vmouse_line_of_386enh(self):
        # Setup's line from the BIOSTAR/X470 98 SE install (VPICD_Phys_EOI).
        text = (b'[boot]\r\ndrivers=mmsystem.dll usoskey.drv\r\n[386Enh]\r\nebios=*ebios\r\n'
                b'mouse=*vmouse, msmouse.vxd\r\nwoafont=dosapp.fon\r\nMOUSE = *VMOUSE\r\nMaxPhysPage=40000\r\n'
                b'[mouse]\r\nmouse=*vmouse\r\n[vcache]\r\nMaxFileCache=1\r\n')
        files = {INI: text}
        st = self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(st['exit'], 0)
        # "MOUSE = *VMOUSE" has blanks before '=': Setup never writes that; kept.
        # Lines outside [386Enh] stay.
        self.assertEqual(files[INI], b'[boot]\r\ndrivers=mmsystem.dll usoskey.drv\r\n[386Enh]\r\nebios=*ebios\r\n'
                         b'woafont=dosapp.fon\r\nMOUSE = *VMOUSE\r\nMaxPhysPage=40000\r\n'
                         b'[mouse]\r\nmouse=*vmouse\r\n[vcache]\r\nMaxFileCache=1\r\n')
        again = dict(files)
        st = self.run_fix(again, command=' /CSM ' + INI)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))
        # Two vmouse lines, another mouse= value kept, last line without CR LF.
        files = {INI: b'[386Enh]\r\nmouse=*vmouse\r\nmouse=serial.vxd\r\nMaxPhysPage=40000\r\nMouse=*VMouse, msmouse.vxd'}
        self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(files[INI], b'[386Enh]\r\nmouse=serial.vxd\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=262144\r\n')
        # Without /CSM the line stays.
        files = {INI: text}
        self.run_fix(files)
        self.assertIn(b'mouse=*vmouse, msmouse.vxd\r\n', files[INI])

    def test_csm_mode_names_the_usb_mouse_driver_when_it_is_in_system(self):
        drv = 'C:\\WINDOWS\\SYSTEM\\USOSMOUS.DRV'
        text = (b'[boot]\r\nshell=Explorer.exe\r\ndrivers=mmsystem.dll usoskey.drv\r\nmouse.drv=mouse.drv\r\n'
                b'[boot.description]\r\nmouse.drv=Standard mouse\r\n[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        files = {INI: text, drv: b'MZ'}
        st = self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(st['exit'], 0)
        # Setup's mouse.drv line is replaced in place; [boot.description] stays.
        self.assertEqual(files[INI], b'[boot]\r\nshell=Explorer.exe\r\ndrivers=mmsystem.dll usoskey.drv\r\nmouse.drv=usosmous.drv\r\n'
                         b'[boot.description]\r\nmouse.drv=Standard mouse\r\n[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        again = dict(files)
        st = self.run_fix(again, command=' /CSM ' + INI)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))
        # No mouse.drv and no drivers= line: both go right after [boot].
        files = {INI: b'[boot]\r\nshell=Explorer.exe\r\n[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n', drv: b'MZ'}
        self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(files[INI], b'[boot]\r\nmouse.drv=usosmous.drv\r\ndrivers=usoskey.drv\r\nshell=Explorer.exe\r\n'
                         b'[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        # A look-alike value on the last line without CR LF.
        files = {INI: b'[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n[boot]\r\ndrivers=usoskey.drv\r\n'
                      b'Mouse.drv=usosmous.drv2', drv: b'MZ'}
        self.run_fix(files, command=' /CSM ' + INI)
        self.assertEqual(files[INI], b'[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n[boot]\r\n'
                         b'drivers=usoskey.drv\r\nmouse.drv=usosmous.drv\r\n')
        # The driver is not in SYSTEM (95, Me, before the AUTOEXEC copy): untouched.
        files = {INI: text}
        self.run_fix(files, command=' /CSM ' + INI)
        self.assertIn(b'mouse.drv=mouse.drv\r\n', files[INI])
        # Without /CSM the mouse driver line stays.
        files = {INI: text, drv: b'MZ'}
        self.run_fix(files)
        self.assertEqual(files[INI], text)

    def test_95_mode_inserts_the_480_mib_cap_when_missing(self):
        files = {INI: b'[386Enh]\r\nwoafont=dosapp.fon\r\n[vcache]\r\nMaxFileCache=1\r\n'}
        st = self.run_fix(files, command=' /95 ' + INI)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[INI], b'[386Enh]\r\nMaxPhysPage=1E000\r\nwoafont=dosapp.fon\r\n[vcache]\r\nMaxFileCache=1\r\n')
        self.assertNotIn(TEMP, files)
        # A second run finds 1E000 and does not write.
        again = dict(files)
        st = self.run_fix(again, command=' /95 ' + INI)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))

    def test_95_mode_replaces_usos_own_40000(self):
        files = {INI: b'[386Enh]\r\nebios=*ebios\r\nmaxphyspage = 40000\r\nwoafont=dosapp.fon\r\n'
                      b'[vcache]\r\nMaxFileCache=1\r\n'}
        st = self.run_fix(files, command=' /95 ' + INI)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[INI], b'[386Enh]\r\nebios=*ebios\r\nMaxPhysPage=1E000\r\nwoafont=dosapp.fon\r\n'
                         b'[vcache]\r\nMaxFileCache=1\r\n')
        again = dict(files)
        st = self.run_fix(again, command=' /95 ' + INI)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))
        # The last line without CR LF.
        files = {INI: b'[vcache]\r\nMaxFileCache=1\r\n[386Enh]\r\nMaxPhysPage=40000'}
        self.run_fix(files, command=' /95 ' + INI)
        self.assertEqual(files[INI], b'[vcache]\r\nMaxFileCache=1\r\n[386Enh]\r\nMaxPhysPage=1E000\r\n')

    def test_95_mode_keeps_a_user_value(self):
        for value in (b'20000', b'400000', b'40000 ;x'):
            text = b'[386Enh]\r\nMaxPhysPage=' + value + b'\r\n[vcache]\r\nMaxFileCache=1\r\n'
            files = {INI: text}
            st = self.run_fix(files, command=' /95 ' + INI)
            self.assertEqual((st['exit'], st['writes'], files), (0, 0, {INI: text}))
        # Outside [386Enh] a 40000 line is not the memory setting.
        text = b'[386Enh]\r\nMaxPhysPage=20000\r\n[other]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n'
        files = {INI: text}
        st = self.run_fix(files, command=' /95 ' + INI)
        self.assertEqual((st['exit'], st['writes'], files), (0, 0, {INI: text}))

    def test_95_and_csm_together(self):
        text = (b'[boot]\r\nshell=Explorer.exe\r\ndrivers=mmsystem.dll\r\n[386Enh]\r\n'
                b'mouse=*vmouse, msmouse.vxd\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        expected = (b'[boot]\r\nshell=Explorer.exe\r\ndrivers=mmsystem.dll usoskey.drv\r\n[386Enh]\r\n'
                    b'MaxPhysPage=1E000\r\n[vcache]\r\nMaxFileCache=1\r\n')
        files = {INI: text}
        st = self.run_fix(files, command=' /95 /CSM ' + INI)
        self.assertEqual(st['exit'], 0)
        self.assertEqual(files[INI], expected)
        again = dict(files)
        st = self.run_fix(again, command='  /95\t/csm  ' + INI)
        self.assertEqual((st['exit'], st['writes'], again), (0, 0, files))
        # No [386Enh] at all: the section comes with the 1E000 line.
        files = {INI: b'[boot]\r\ndrivers=usoskey.drv\r\n'}
        self.run_fix(files, command=' /95 /CSM ' + INI)
        self.assertEqual(files[INI], b'[boot]\r\ndrivers=usoskey.drv\r\n[386Enh]\r\nMaxPhysPage=1E000\r\n'
                         b'[vcache]\r\nMaxFileCache=262144\r\n')
        # An option without a file name fails.
        self.assertEqual(self.run_fix({INI: text}, command=' /95')['exit'], 1)
        self.assertEqual(self.run_fix({INI: text}, command=' /95 /CSM ')['exit'], 1)

    def test_without_95_the_40000_line_stays(self):
        text = b'[386Enh]\r\nMaxPhysPage=40000\r\n[vcache]\r\nMaxFileCache=1\r\n'
        for command in (' ' + INI, ' /CSM ' + INI):
            files = {INI: text}
            st = self.run_fix(files, command=command)
            self.assertEqual((st['exit'], st['writes'], files), (0, 0, {INI: text}))


if __name__ == '__main__':
    unittest.main()
