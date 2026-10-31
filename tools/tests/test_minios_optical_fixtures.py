# SPDX-License-Identifier: GPL-3.0-or-later
"""Own optical-media layout expectations; no Microsoft or archive payload."""
import importlib.util
from pathlib import Path
import struct
import unittest

REPO=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('optical_fixtures',REPO/'tools/minios/optical_fixtures.py')
m=importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)


def valid_tag(b,lba,ident):
    return (struct.unpack_from('<H',b)[0]==ident and struct.unpack_from('<I',b,12)[0]==lba
            and b[4]==sum(b[:4]+b[5:16])&255
            and struct.unpack_from('<H',b,8)[0]==m.crc16(b[16:16+struct.unpack_from('<H',b,10)[0]]))


class OpticalFixtureTests(unittest.TestCase):
    def test_iso_endian_lengths_and_multi_extent_layout(self):
        for joliet,multi in ((False,False),(True,False),(False,True),(True,True)):
            image=m.iso9660(joliet,multi)
            self.assertEqual(len(image),320*m.BLOCK)
            self.assertEqual(struct.unpack_from('<I',image,16*m.BLOCK+80)[0],320)
            self.assertEqual(struct.unpack_from('>I',image,16*m.BLOCK+84)[0],320)
            self.assertEqual(image[(18 if joliet else 17)*m.BLOCK:][:7],b'\xffCD001\x01')
            if multi:self.assertIn(b'LONG.TXT;1',image)

    def test_udf_revisions_have_valid_primary_and_backup_anchor(self):
        for revision in (0x102,0x201,0x250,0x260):
            image=m.udf(revision,metadata=revision>=0x250)
            self.assertTrue(valid_tag(image[256*m.BLOCK:257*m.BLOCK],256,2))
            self.assertTrue(valid_tag(image[319*m.BLOCK:320*m.BLOCK],319,2))
            self.assertEqual(struct.unpack_from('<H',image,258*m.BLOCK+240)[0],revision)

    def test_extended_embedded_and_continued_entries_are_distinct_and_checksum_valid(self):
        for options in (dict(extended=True),dict(embedded=True),dict(extended=True,embedded=True),
                        dict(continuation=True,payload=b'x'*m.BLOCK+m.PAYLOAD)):
            image=m.udf(0x201,**options)
            fe=image[37*m.BLOCK:38*m.BLOCK]
            self.assertTrue(valid_tag(fe,5,266 if options.get('extended') else 261))
            if options.get('embedded'):
                self.assertEqual(struct.unpack_from('<H',fe,34)[0]&7,3)
                self.assertIn(m.PAYLOAD,fe)
            if options.get('continuation'):
                aed=image[44*m.BLOCK:45*m.BLOCK]
                self.assertTrue(valid_tag(aed,12,258))
                self.assertEqual(struct.unpack_from('<I',aed,20)[0],32)

    def test_loop_mutations_keep_valid_crc_instead_of_failing_early_checksum(self):
        image=m.udf(0x201,allocation_loop=True)
        aed=image[44*m.BLOCK:45*m.BLOCK]
        self.assertTrue(valid_tag(aed,12,258))
        self.assertEqual(struct.unpack_from('<I',aed,28)[0],12)
        changed=m.udf_patch(m.udf(),37,184,struct.pack('<H',99))
        self.assertTrue(valid_tag(changed[37*m.BLOCK:38*m.BLOCK],5,261))
        bad=m.udf_patch(m.udf(),37,184,struct.pack('<H',99),repair=False)
        self.assertFalse(valid_tag(bad[37*m.BLOCK:38*m.BLOCK],5,261))

    def test_sparse_multi_extent_plan_exceeds_u32_without_allocating_image(self):
        plan=m.iso9660_sparse_plan()
        self.assertGreater(plan['file_bytes'],2**32)
        self.assertGreater(plan['logical_bytes'],plan['file_bytes'])
        self.assertLess(sum(len(chunk) for _,chunk in plan['chunks']),1024**2)
        self.assertEqual(plan['split']%m.BLOCK,0)
        sample=m.sparse_sample(plan,plan['split']-16)
        self.assertEqual(sample[:16],b'FIRST-EXTENT-END')
        self.assertEqual(sample[16:],b'SECOND-EXTENT-BE')
        self.assertEqual(m.sparse_sample(plan,2**32,32),bytes(32))
        with self.assertRaises(ValueError):m.iso9660_sparse_plan(2**32)
        with self.assertRaises(ValueError):m.sparse_sample(plan,plan['file_bytes'],1)

    def test_metadata_map_and_input_combinations_validate(self):
        with self.assertRaises(ValueError):m.udf(0x201,metadata=True)
        with self.assertRaises(ValueError):m.udf(embedded=True,continuation=True)
        with self.assertRaises(ValueError):m.udf(embedded=True,payload=bytes(m.BLOCK))
        with self.assertRaises(ValueError):m.udf_patch(m.udf(),999,16,b'own')


if __name__=='__main__':unittest.main()
