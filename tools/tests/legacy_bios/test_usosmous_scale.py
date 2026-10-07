"""USOSMOUS.DRV pointer speed scaling (src/platform/win3/usosmous_scale.h),
compiled for the host with zig cc: Multiplier/Divisor with the remainder
carried per axis, defaults for missing or bad SYSTEM.INI values, and the
16-bit range the driver relies on."""
from pathlib import Path
import os
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[3]
HEADER = ROOT / 'src/platform/win3/usosmous_scale.h'

HARNESS = r'''
#include <stdio.h>
#include <stdlib.h>
#include "usosmous_scale.h"
/* argv[1] mul, argv[2] div, then dx,dy pairs; prints "x,y" per pair and
 * the settings in use first. */
int main(int argc, char **argv)
{
    SCALE s;
    int i;
    scale_init(&s, atoi(argv[1]), atoi(argv[2]));
    printf("%d/%d\n", s.mul, s.div);
    for (i = 3; i + 1 < argc; i += 2) {
        int dx = atoi(argv[i]), dy = atoi(argv[i + 1]);
        scale_move(&s, &dx, &dy);
        printf("%d,%d\n", dx, dy);
    }
    return 0;
}
'''


class UsosMouseScale(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        work = ROOT / 'zig-out/usosmous-scale-test'
        work.mkdir(parents=True, exist_ok=True)
        (work / 'harness.c').write_text(HARNESS)
        cls.exe = work / 'scale.exe'
        subprocess.run([str(ROOT / 'tools/zig/zig.exe'), 'cc', '-O1', '-Wall', '-Werror', '-Wno-unused-function',
                        '-I', str(HEADER.parent), str(work / 'harness.c'), '-o', str(cls.exe)],
                       check=True, env={**os.environ, 'ZIG_GLOBAL_CACHE_DIR': str(ROOT / 'tools/cache/zig-global')})

    def run_scale(self, mul, div, moves):
        args = [str(self.exe), str(mul), str(div)] + [str(v) for m in moves for v in m]
        out = subprocess.run(args, check=True, capture_output=True, text=True).stdout.split()
        return out[0], [tuple(int(v) for v in line.split(',')) for line in out[1:]]

    def test_defaults_halve_large_movements(self):
        setting, out = self.run_scale(0, 0, [(40, -30), (-100, 64)])
        self.assertEqual(setting, '1/2')
        self.assertEqual(out, [(20, -15), (-50, 32)])

    def test_slow_movements_are_not_lost(self):
        # One count per poll at divisor 2: a pixel every second poll, both directions.
        _, out = self.run_scale(1, 2, [(1, -1)] * 6)
        self.assertEqual(out, [(0, 0), (1, -1)] * 3)
        _, out = self.run_scale(1, 3, [(1, 0)] * 9)
        self.assertEqual(sum(x for x, _ in out), 3)
        # Odd counts: nothing is lost over a run either.
        _, out = self.run_scale(1, 2, [(3, 5)] * 4)
        self.assertEqual((sum(x for x, _ in out), sum(y for _, y in out)), (6, 10))

    def test_direction_change_drops_the_remainder(self):
        _, out = self.run_scale(1, 2, [(1, 0), (-1, 0), (-1, 0)])
        self.assertEqual(out, [(0, 0), (0, 0), (-1, 0)])

    def test_multiplier_and_limits(self):
        self.assertEqual(self.run_scale(3, 2, [(3, -3)]), ('3/2', [(4, -4)]))
        self.assertEqual(self.run_scale(1, 1, [(7, -9)]), ('1/1', [(7, -9)]))
        self.assertEqual(self.run_scale(99, 99, [])[0], '4/16')
        self.assertEqual(self.run_scale(-5, -1, [])[0], '1/2')

    def test_16_bit_range(self):
        # The driver sums up to 32 packets of +-255 per poll; the header clamps
        # so raw * 4 + rest fits a 16-bit int.
        _, out = self.run_scale(4, 1, [(30000, -30000)])
        self.assertEqual(out, [(4096 * 4, -4096 * 4)])
        self.assertLess(4096 * 4 + 15, 32767)

    def test_driver_uses_the_header_and_system_ini(self):
        source = (ROOT / 'src/platform/win3/usosmous.c').read_text(encoding='latin-1')
        self.assertIn('#include "usosmous_scale.h"', source)
        self.assertIn('"usosmous", "Divisor"', source)
        self.assertIn('"usosmous", "Multiplier"', source)
        self.assertIn('scale_move(&scale, &move_x, &move_y)', source)


if __name__ == '__main__':
    unittest.main()
