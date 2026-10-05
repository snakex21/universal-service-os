"""tools/w2k_gap_trace.py: the usos4 trace record decoding, host-only.

The sample record follows AhciUsosTrace in tools/vendor/ahcint/
1.3.0.0-usos4/src/ahcisatl.c; the key names are checked against that source.

    python tools/tests/test_w2k_gap_trace.py
"""
from pathlib import Path
import re, sys, unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tools'))
import w2k_gap_trace as trace  # noqa: E402

SAMPLE = ('AHCINT 1.3.0.0-usos4 why=stall boot=3 id=43C81022 port=2 verify=1 stage=4\r\n'
          ' rd=D5A wr=F6 wrsec=7B0 err=1 prdbc=0 eng=0 flush=0 lw=6FBA408 rb=F6 rbbad=0\r\n'
          ' isr=0 own=0 tm=1A0 srb=E51 idle=0 bres=0 stalls=1 elba=6FBA408 etfd=D0 ecmd=40000035\r\n'
          'snap p=2 ci=1 sact=0 is=0 serr=0 tfd=D0 cmd=C017 his=0 ghc=80000000 ie=0 op=35 lba=6FBA408 n=80 isr=0 tm=1A0\r\n'
          'hba pi=3F cap=E734FF05 ghc=80000000 his=0\r\n'
          'port p=2 ssts=123 cmd=C017 tfd=50 ci=0 is=0 serr=0 use=1 BIOSTAR S100-120GB\r\n')


class GapTrace(unittest.TestCase):
    def test_explain(self):
        notes = trace.explain(SAMPLE)
        self.assertIn('why: stall = a command was still busy after 2 s and timed out at 3 s', notes)
        self.assertTrue(any(n.startswith('interrupts 0 ') and 'stalls 1' in n and 'bus resets 0' in n for n in notes), notes)
        self.assertIn('STALL port 2: CI 00000001 (still issued) SACT 00000000, completion by poll', notes)
        self.assertTrue(any('ATA 35 LBA 06FBA408 count 128' in n and 'BSY DRDY' in n for n in notes), notes)
        self.assertTrue(any(n.startswith('port 2: SSTS 123 CI 0') for n in notes), notes)
        # usos3 records (8-digit fields, no usos4 header) are only printed.
        self.assertEqual(trace.explain('AHCINT 1.3.0.0-usos3 why=init boot=00000001\r\n'), [])

    def test_fields(self):
        f = trace.fields(SAMPLE.splitlines()[3])
        self.assertEqual((f['ci'], f['tfd'], f['lba'], f['n'], f['isr'], f['tm']), (1, 0xD0, 0x6FBA408, 0x80, 0, 0x1A0))
        self.assertEqual(trace.tfd_text(0x0451), 'status 51 (DRDY ERR) error 04')
        self.assertEqual(trace.is_text(1 << 30 | 1), 'DHRS TFES')

    def test_names_match_driver(self):
        c = (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcisatl.c').read_text()
        names = re.search(r'names\[USOS_SNAP_WORDS\] = \{([^}]*)\}', c).group(1)
        self.assertEqual(re.findall(r'"(\w+)"', names),
                         ['snap', 'p', 'ci', 'sact', 'is', 'serr', 'tfd', 'cmd', 'his', 'ghc', 'ie', 'op', 'lba', 'n', 'isr', 'tm'])
        for key in ('"isr"', '"own"', '"tm"', '"srb"', '"idle"', '"bres"', '"stalls"', '"hba"', '"port"',
                    'AHCINT 1.3.0.0-usos4 why='):
            self.assertIn(key, c)
        for why in ('"stall"', '"slow"', '"idle20s"'):
            self.assertIn(why, c)
        self.assertIn('"busreset"', (ROOT / 'tools/vendor/ahcint/1.3.0.0-usos4/src/ahcimain.c').read_text())


if __name__ == '__main__':
    unittest.main()
