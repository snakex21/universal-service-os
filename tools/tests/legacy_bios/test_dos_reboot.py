"""Execute the real DOS COM helper without restarting the host."""
from pathlib import Path
import struct
import sys
import unittest
from unicorn import Uc, UC_ARCH_X86, UC_MODE_16, UC_HOOK_CODE, UC_HOOK_INTR
from unicorn.x86_const import *

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
from build_dos_reboot import build


class DosRestart(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.code = build(ROOT, ROOT / 'zig-out/dos-reboot-test').read_bytes()

    def run_helper(self, command=b'', pending=(), fail_after=None):
        u = Uc(UC_ARCH_X86, UC_MODE_16)
        u.mem_map(0, 0x100000)
        base = 0x20000
        u.mem_write(base + 0x100, self.code)
        u.mem_write(base + 0x80, bytes([len(command)]) + command + b'\r')
        for reg in (UC_X86_REG_CS, UC_X86_REG_DS, UC_X86_REG_ES, UC_X86_REG_SS):
            u.reg_write(reg, base >> 4)
        u.reg_write(UC_X86_REG_SP, 0xfffe)
        u.reg_write(UC_X86_REG_EFLAGS, 0x202)
        queue = list(pending)
        events = []
        stored = 0

        def interrupt(uc, number, data):
            nonlocal stored
            ax = uc.reg_read(UC_X86_REG_AX)
            ah = ax >> 8
            if number == 0x16:
                if ah == 1:
                    flags = uc.reg_read(UC_X86_REG_EFLAGS)
                    uc.reg_write(UC_X86_REG_EFLAGS, (flags & ~0x40) | (0 if queue else 0x40))
                elif ah == 0:
                    self.assertTrue(queue)
                    uc.reg_write(UC_X86_REG_AX, queue.pop(0))
                elif ah == 5:
                    failed = fail_after is not None and stored >= fail_after
                    if not failed:
                        queue.append(uc.reg_read(UC_X86_REG_CX))
                        stored += 1
                    uc.reg_write(UC_X86_REG_AX, int(failed))
                else:
                    self.fail(f'Unexpected keyboard service {ah:x}')
            elif number == 0x21:
                if ah == 0x0d:
                    events.append('flush')
                elif ah == 9:
                    events.append('help')
                elif ah == 0x4c:
                    events.append(('exit', ax & 255))
                    uc.emu_stop()
                else:
                    self.fail(f'Unexpected DOS service {ah:x}')
            else:
                self.fail(f'Unexpected interrupt {number:x}')

        def firmware(uc, address, size, data):
            if address == 0xffff0:
                self.assertEqual(events, ['flush'])
                self.assertEqual(struct.unpack('<H', uc.mem_read(0x472, 2))[0], 0x1234)
                events.append('restart')
                uc.emu_stop()

        u.hook_add(UC_HOOK_INTR, interrupt)
        u.hook_add(UC_HOOK_CODE, firmware)
        u.emu_start(base + 0x100, 0x100000, count=10000)
        return queue, events

    def test_prefill_discards_old_enter_and_never_submits(self):
        for option in (b' /P', b' /p'):
            queue, events = self.run_helper(option, pending=(0x1c0d, 0x1c0d))
            self.assertEqual(bytes(key & 255 for key in queue), b'REBOOT')
            self.assertNotIn(13, [key & 255 for key in queue])
            self.assertEqual(events, [('exit', 0)])

    def test_restart_flushes_dos_before_entering_bios_post(self):
        for command in (b'', b'   '):
            self.assertEqual(self.run_helper(command)[1], ['flush', 'restart'])

    def test_unknown_arguments_cannot_restart(self):
        for command in (b' /?', b' /X', b' anything', b' /Pextra'):
            self.assertEqual(self.run_helper(command)[1], ['help', ('exit', 1)])

    def test_keyboard_failure_removes_partial_command(self):
        queue, events = self.run_helper(b' /P', fail_after=3)
        self.assertEqual(queue, [])
        self.assertEqual(events, ['help', ('exit', 1)])


if __name__ == '__main__':
    unittest.main()
