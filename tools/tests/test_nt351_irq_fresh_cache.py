import importlib.util,stat,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('irq_cache',Path(__file__).with_name('build_nt351_irq_fresh_cache.py'))
b=importlib.util.module_from_spec(spec);spec.loader.exec_module(b)

class EffectiveTree(unittest.TestCase):
    def setUp(self):
        self.layers,self.c=b.modules()
        self.old={n:self.c.Entry(n,stat.S_IFREG|0o644,v) for n,v in (('sys',b'old'),('kept',b'unchanged'))}
        self.delta={'sys':self.c.Entry('sys',stat.S_IFREG|0o644,b'new')}
    def test_exact_replacement_preserves_other_entry(self):
        self.assertEqual(b.compare(self.old,{**self.old,**self.delta},self.delta),['sys'])
    def test_unrelated_payload_or_mode_change_rejected(self):
        for mode,data in ((stat.S_IFREG|0o600,b'unchanged'),(stat.S_IFREG|0o644,b'changed')):
            with self.subTest(mode=mode,data=data),self.assertRaises(ValueError):
                b.compare(self.old,{**self.old,**self.delta,'kept':self.c.Entry('kept',mode,data)},self.delta)
    def test_added_missing_or_ineffective_override_rejected(self):
        for after in ({**self.old,**self.delta,'extra':self.old['kept']},{'sys':self.delta['sys']},self.old):
            with self.subTest(names=list(after)),self.assertRaises(ValueError):b.compare(self.old,after,self.delta)

if __name__=='__main__':unittest.main()
