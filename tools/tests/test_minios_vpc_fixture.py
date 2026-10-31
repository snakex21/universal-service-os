# SPDX-License-Identifier: GPL-3.0-or-later
"""Own VHD proof expectations and completed-log parsing; no images created."""
import hashlib
import io
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'minios'))
import vpc_fixture as c


class VpcFixtureTests(unittest.TestCase):
    def test_streamed_expected_sha_matches_independent_small_byte_string(self):
        marker=bytes(index%251 for index in range(512))
        with patch.object(c,'SIZE',4096):
            expected=marker+bytes(4096-512-c.PATTERN_BYTES)+b'\x5a'*c.PATTERN_BYTES
            self.assertEqual(c.expected_digest(marker),hashlib.sha256(expected).hexdigest())
            with self.assertRaises(ValueError):c.expected_digest(marker[:-1])

    def test_logical_reader_covers_exact_size_in_bounded_chunks(self):
        class Reader:
            size=130000
            def __init__(self):self.file=io.BytesIO(b'v'*self.size);self.position=0;self.maximum=0
            def seek(self,at):self.file.seek(at);self.position=at
            def read(self,count):
                self.maximum=max(self.maximum,count);value=self.file.read(count);self.position+=len(value);return value
        reader=Reader()
        with patch.object(c,'SIZE',reader.size):
            self.assertEqual(c.full_logical_digest(reader),hashlib.sha256(b'v'*reader.size).hexdigest())
        self.assertLessEqual(reader.maximum,65536)
        with self.assertRaises(ValueError):c.full_logical_digest(reader)

    def test_json_requires_closed_success_and_clean_header(self):
        path=Path('never-opened.log')
        good='HEAD '+'a'*40+'\nWORKTREE_DIRTY 0\nCOMMAND []\n{\n"virtual-size":33554432\n}\nEXIT 0\n'
        with patch.object(Path,'read_text',return_value=good):
            self.assertEqual(c.closed_command_json(path),{'virtual-size':33554432})
        for bad in (good.replace('EXIT 0','EXIT 1'),good.replace('WORKTREE_DIRTY 0','WORKTREE_DIRTY 1'),good.replace('EXIT 0\n','')):
            with patch.object(Path,'read_text',return_value=bad),self.assertRaises(ValueError):c.closed_command_json(path)


if __name__=='__main__':unittest.main()
