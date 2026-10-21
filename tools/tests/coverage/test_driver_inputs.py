"""A hashed user NIC fixture must stay within the owned DATA input tree."""
from pathlib import Path
import hashlib,importlib.util,tempfile,unittest,zipfile

s=importlib.util.spec_from_file_location('driver_inputs',Path(__file__).with_name('driver_inputs.py'))
d=importlib.util.module_from_spec(s);s.loader.exec_module(d)
OUT=Path(__file__).resolve().parents[3]/'artifacts/coverage/driver-input-tests'


class DriverInputs(unittest.TestCase):
    def setUp(self):
        OUT.mkdir(parents=True,exist_ok=True)
        self.folder=tempfile.TemporaryDirectory(dir=OUT)
        self.addCleanup(self.folder.cleanup)
        self.root=Path(self.folder.name)

    def archive(self,items):
        path=self.root/'driver.zip'
        with zipfile.ZipFile(path,'w') as z:
            for name,data in items:z.writestr(name,data)
        return path,hashlib.sha256(path.read_bytes()).hexdigest()

    def test_exact_bytes_in_a_new_owned_directory(self):
        path,digest=self.archive([('Other/nic/driver.inf',b'[Version]\nClass=Net\n'),('Other/nic/driver.sys',b'own inert bytes')])
        bundle=d.load(path,digest,allowed=self.root)
        target=self.root/'fixture/drivers';d.stage(bundle,target,self.root)
        self.assertEqual((target/'Other/nic/driver.sys').read_bytes(),b'own inert bytes')
        self.assertEqual(d.metadata(bundle)['sha256'],digest)
        with self.assertRaises(ValueError):d.stage(bundle,target,self.root)

    def test_rejects_traversal_windows_aliases_links_and_collisions(self):
        link=zipfile.ZipInfo('Other/nic/link.inf');link.create_system=3;link.external_attr=0o120777<<16
        for items in ([('../escape.inf',b'x')],[('Other/nic/../../escape.inf',b'x')],
                      [('Other/nic/CON.inf',b'x')],[(link,b'outside')],
                      [('Other/nic/A.inf',b'x'),('Other/nic/a.inf',b'y')]):
            with self.subTest(items=items):
                path,digest=self.archive(items)
                with self.assertRaises(ValueError):d.load(path,digest,allowed=self.root)

    def test_hash_and_private_input_root_are_mandatory(self):
        path,digest=self.archive([('Other/nic/driver.inf',b'own fixture')])
        with self.assertRaises(ValueError):d.load(path,'0'*64,allowed=self.root)
        with self.assertRaises(ValueError):d.load(path,digest,allowed=self.root/'other')


if __name__=='__main__':unittest.main()
