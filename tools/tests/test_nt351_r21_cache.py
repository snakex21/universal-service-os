import gzip,importlib.util,stat,unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('r21_builder',ROOT/'tools/tests/build_nt351_r21_cache.py')
builder=importlib.util.module_from_spec(spec);spec.loader.exec_module(builder)

class CacheLayers(unittest.TestCase):
    def test_later_payload_overrides_without_losing_unrelated_script(self):
        c=builder.cpio_module()
        before={'payload':c.Entry('payload',stat.S_IFREG|0o644,b'old'),'kept.sh':c.Entry('kept.sh',stat.S_IFREG|0o755,b'late NT4 hunk')}
        after={'payload':c.Entry('payload',stat.S_IFREG|0o644,b'new')}
        packed=gzip.compress(c.newc(before),mtime=0)+b'\0'*4+gzip.compress(c.newc(after),mtime=0)
        entries,layers=builder.effective_newc(gzip.decompress(packed))
        self.assertEqual(layers,2)
        self.assertEqual(entries['payload'].data,b'new')
        self.assertEqual(entries['kept.sh'].data,b'late NT4 hunk')
        self.assertEqual(entries['kept.sh'].mode,stat.S_IFREG|0o755)

    def test_truncated_payload_or_missing_layer_trailer_rejected(self):
        c=builder.cpio_module();data=c.newc({'x':c.Entry('x',stat.S_IFREG|0o644,b'payload')})
        for candidate in (data[:115],data[:116+8],data[:-112]):
            with self.subTest(length=len(candidate)),self.assertRaises(ValueError):builder.effective_newc(candidate)

if __name__=='__main__':unittest.main()
