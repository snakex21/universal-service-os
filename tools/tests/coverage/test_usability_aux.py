"""The auxiliary USB inputs must be FAT16 MBR volumes with readable markers."""
from pathlib import Path
import importlib.util
import struct
import unittest
import io
from types import SimpleNamespace

spec=importlib.util.spec_from_file_location('aux',Path(__file__).with_name('usability_aux.py'))
aux=importlib.util.module_from_spec(spec);spec.loader.exec_module(aux)


class AuxiliaryTests(unittest.TestCase):
    def test_disk_mode_uses_the_actual_non_erasing_first_row(self):
        root=Path(__file__).resolve().parents[3]
        source=(root/'tools/xp_disk_reset_ui.sh').read_text()
        self.assertLess(source.index('item=Keep existing partitions'),source.index('item=Format entire disk'))
        self.assertEqual(aux.framebuffer_menu_keys('[COVERAGE_MENU] /run/xp-disk-mode.txt'),('ret',))
        self.assertEqual(aux.framebuffer_menu_keys('[COVERAGE_MENU] /run/xp-confirm-menu.state'),('up','ret'))
        with self.assertRaises(ValueError):aux.framebuffer_menu_keys('[COVERAGE_MENU] /run/new-menu.txt')
    def test_hid_requests_are_limited_to_owned_devices(self):
        self.assertEqual(aux.hid_descriptor('keyboard','mouse')['id'],'coveragekbd')
        self.assertEqual(aux.hid_descriptor('mouse','mouse')['driver'],'usb-mouse')
        self.assertEqual(aux.hid_descriptor('mouse','tablet')['driver'],'usb-tablet')
        with self.assertRaises(ValueError):aux.hid_descriptor('host-controller','mouse')
        with self.assertRaises(ValueError):aux.hid_descriptor('mouse','unknown')
    def test_closed_or_noninteractive_input_is_rejected_before_vm_creation(self):
        with self.assertRaises(ValueError):aux.require_operator_channel(True,io.StringIO())
        with self.assertRaises(ValueError):aux.require_operator_channel(True,SimpleNamespace(closed=True,isatty=lambda:True))
        aux.require_operator_channel(True,SimpleNamespace(closed=False,isatty=lambda:True))
        aux.require_operator_channel(False,io.StringIO())
    def test_82576_is_in_the_actual_driver_and_inf(self):
        root=Path(__file__).resolve().parents[3]
        self.assertIn('0x10C9',(root/'tools/nt/usosnet/src/usosnet.c').read_text())
        self.assertIn('DEV_10C9',(root/'tools/nt/usosnet/inf/usosnet.inf').read_text())
        self.assertIn('igb,netdev=',','.join(aux.network_arguments('igb')))
        self.assertEqual(aux.network_arguments('none'),['-nic','none'])
        with self.assertRaises(ValueError):aux.network_arguments('e1000')

    def test_fat16_geometry_and_file_chain(self):
        for kind,name in [('boot',b'START   TXT'),('hot',b'HOTPLUG TXT')]:
            with self.subTest(kind=kind):
                image=aux.fat16_prefix(kind)
                self.assertEqual(image[510:512],b'\x55\xaa')
                self.assertEqual(image[450],6)
                lba,sectors=struct.unpack_from('<II',image,454);start=lba*512
                bps,cluster,reserved,fats,root_entries,small,media,fatsecs=struct.unpack_from('<HBHBHHBH',image,start+11)
                self.assertEqual((bps,small,media),(512,0,0xf8))
                total=struct.unpack_from('<I',image,start+32)[0]
                self.assertEqual(total,sectors)
                rootsecs=(root_entries*32+bps-1)//bps
                clusters=(total-reserved-fats*fatsecs-rootsecs)//cluster
                self.assertTrue(4085<=clusters<65525,'Must be FAT16, not FAT12/FAT32')
                self.assertGreaterEqual(fatsecs*bps//2,clusters+2)
                first=image[start+reserved*bps:start+(reserved+fatsecs)*bps]
                second=image[start+(reserved+fatsecs)*bps:start+(reserved+2*fatsecs)*bps]
                self.assertEqual(first,second)
                root=start+(reserved+fats*fatsecs)*bps
                self.assertEqual(image[root:root+11],name)
                cluster_no,size=struct.unpack_from('<HI',image,root+26)
                self.assertGreaterEqual(struct.unpack_from('<H',first,cluster_no*2)[0],0xfff8)
                data=start+(reserved+fats*fatsecs+rootsecs+(cluster_no-2)*cluster)*bps
                self.assertEqual(image[data:data+size],('USOS disposable USB '+kind+' read test\r\n').encode())


if __name__=='__main__':unittest.main()
