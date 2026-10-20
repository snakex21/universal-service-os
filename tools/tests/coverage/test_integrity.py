"""Regression tests: full-file digests differ from Apple's XAR TOC digest."""
from pathlib import Path
from unittest import mock
import hashlib
import importlib.util
import io
import struct
import tempfile
import unittest
import zlib

HERE = Path(__file__).resolve().parent


def module(name):
    spec = importlib.util.spec_from_file_location('coverage_test_'+name,HERE/(name+'.py'))
    result = importlib.util.module_from_spec(spec); spec.loader.exec_module(result)
    return result


apple = module('apple_integrity')
download = module('download_apple')
cab = module('unpack_bytes')


def sample():
    toc = zlib.compress(b'<xar><toc><file>synthetic test only</file></toc></xar>')
    data = struct.pack('>4sHHQQI',b'xar!',28,1,len(toc),56,1)+toc+b'synthetic payload'*71
    digest = hashlib.sha1(toc).hexdigest()
    chunks = [data[:101],data[101:]]
    manifest = struct.pack('<4sIBBBxQQQ',b'CNKL',36,1,1,2,2,36,108)
    manifest += b''.join(struct.pack('<I32s',len(part),hashlib.sha256(part).digest()) for part in chunks)
    manifest += hashlib.sha256(manifest).digest()
    return data,digest,manifest


class Integrity(unittest.TestCase):
    def test_catalogue_toc_is_not_whole_package(self):
        data,digest,manifest = sample()
        self.assertNotEqual(hashlib.sha1(data).hexdigest(),digest)
        self.assertEqual(apple.verify_xar_toc(io.BytesIO(data),digest)['sha1'],digest)
        self.assertEqual(sum(n for n,h in apple.chunk_manifest(manifest,len(data))),len(data))

    def test_changed_toc_is_rejected(self):
        data,digest,manifest = sample()
        changed = bytearray(data); changed[35] ^= 1
        with self.assertRaisesRegex(ValueError,'TOC SHA-1 differs'):
            apple.verify_xar_toc(io.BytesIO(changed),digest)

    def test_changed_manifest_is_rejected(self):
        data,digest,manifest = sample()
        changed = bytearray(manifest); changed[60] ^= 1
        with self.assertRaisesRegex(ValueError,'footer checksum'):
            apple.chunk_manifest(changed,len(data))

    def test_catalogue_size_must_match_chunks(self):
        data,digest,manifest = sample()
        with self.assertRaisesRegex(ValueError,'Manifest size'):
            apple.chunk_manifest(manifest,len(data)+1)

    def transfer(self, corrupt=False):
        data,digest,manifest = sample()
        location = Path.cwd()/'artifacts/coverage/tests'
        location.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as folder:
            root = Path(folder)
            row = dict(relative='macOS/Test/InstallAssistant.pkg',bytes=len(data),
                published_hash=digest,url='https://swcdn.apple.com/test/InstallAssistant.pkg',
                integrity_url='https://swcdn.apple.com/test/InstallAssistant.pkg.integrityDataV1')
            class Response(io.BytesIO): status = 200
            responses = [Response(manifest),Response(data[:-1]+b'!' if corrupt else data)]
            with mock.patch.object(download.downloader,'COLLECTION',root), \
                 mock.patch.object(download.downloader,'MIN_FREE',0), \
                 mock.patch.object(download.urllib.request,'urlopen',side_effect=responses):
                target = root/row['relative']
                if corrupt:
                    with self.assertRaisesRegex(ValueError,'chunk SHA-256 differs'):
                        download.download_package(row)
                    self.assertFalse(target.exists())
                else:
                    result = download.download_package(row)
                    self.assertEqual(target.read_bytes(),data)
                    self.assertEqual(result['sha256'],hashlib.sha256(data).hexdigest())
                    self.assertFalse(result['integrity_signature'])
                self.assertFalse(target.with_name(target.name+'.part').exists())

    def test_download_accepts_matching_toc_and_all_chunks(self): self.transfer()
    def test_download_discards_a_corrupt_chunk(self): self.transfer(corrupt=True)

    def test_cab_uses_seekable_input_and_removes_it(self):
        location = Path.cwd()/'artifacts/coverage/tests'
        location.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=location) as folder:
            root = Path(folder)
            def seven(command,**kwargs):
                self.assertNotIn('-si',command)
                self.assertEqual(Path(command[3]).read_bytes(),b'MSCFsynthetic')
                return mock.Mock(returncode=0,stdout=b'MZsynthetic',stderr=b'')
            with mock.patch.object(cab.subprocess,'run',side_effect=seven):
                self.assertEqual(cab.unpack(b'MSCFsynthetic',scratch=root),b'MZsynthetic')
            self.assertEqual(list(root.iterdir()),[])


if __name__ == '__main__': unittest.main()
