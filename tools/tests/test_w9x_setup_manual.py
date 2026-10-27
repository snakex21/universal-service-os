"""Windows 95/98/Me manual Setup (answer-profile option win9x_setup=manual,
src/flow/answer/msbatch.zig): the rendered MSBATCH.INF carries
`;USOS-SETUP=manual`, and tools/w9x_csmwrap_prepare.sh then never runs
Setup's phase 1 in the VM (nobody could answer the pages there)."""
from pathlib import Path
import shutil
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from test_w9x_phase1_qemu import sh

ROOT = Path(__file__).resolve().parents[2]
PREPARE = ROOT / 'tools/w9x_csmwrap_prepare.sh'
MARK = '# A manual-Setup profile (;USOS-SETUP=manual'


class ManualSetup(unittest.TestCase):
    def block(self):
        text = PREPARE.read_text(encoding='utf-8')
        a = text.index(MARK)
        return text[a:text.index('\n        fi\n', a) + len('\n        fi\n')]

    def test_after_the_vm_decision_and_before_its_log(self):
        text = PREPARE.read_text(encoding='utf-8')
        mark = text.index(MARK)
        self.assertLess(text.index('if vm_reason=$(w9x_vm_available "$tag"); then vm_phase1=yes; fi'), mark)
        self.assertLess(text.index("vm_reason='Windows 95 without a product key"), mark)
        self.assertLess(mark, text.index('w9x_csmwrap_log "PHASE1 vm=$vm_phase1 ($vm_reason)"'))

    def test_manual_answer_keeps_phase1_native(self):
        tmp = Path(tempfile.mkdtemp(prefix='usos-w9x-manual-'))
        self.addCleanup(shutil.rmtree, tmp, ignore_errors=True)
        inf = tmp / 'MSBATCH.INF'
        for text, vm, want in (
                (b'; MSBATCH.INF rendered by USOS\r\n; Manual Setup\r\n;USOS-SETUP=manual\r\n[Version]\r\n', 'yes', 'no'),
                (b'; MSBATCH.INF rendered by USOS\r\n[Version]\r\n[Setup]\r\nExpress=1\r\n', 'yes', 'yes'),
                (b';USOS-SETUP=manual\r\n', 'no', 'no'),
                (b'[Setup]\r\nComment=";USOS-SETUP=manual"\r\n', 'yes', 'yes')):
            with self.subTest(text=text, vm=vm):
                inf.write_bytes(text)
                script = (f'vm_phase1={vm}\nvm_reason=available\nW9X_VM_KEY=12345\nanswer_inf="{inf.as_posix()}"\n'
                          + self.block() + 'printf "%s|%s|%s\\n" "$vm_phase1" "$W9X_VM_KEY" "$vm_reason"\n')
                rc, out, err = sh(script)
                self.assertEqual(rc, 0, err)
                phase1, key, reason = out.strip().split('|')
                self.assertEqual(phase1, want)
                if vm == 'yes' and want == 'no':
                    self.assertEqual(key, '')
                    self.assertIn('manual Setup', reason)
                else:
                    self.assertEqual(reason, 'available')


if __name__ == '__main__':
    unittest.main()
