"""Keep initial evidence and publish each completed PNG without overwrite."""
from pathlib import Path
import importlib.util
import os
import tempfile
import unittest
from unittest.mock import patch
from PIL import Image

ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('capture_menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


class Qmp:
    def __init__(self,color):self.color=color;self.calls=[]
    async def command(self,name,args):
        self.calls.append((name,args))
        Image.new('RGB',(8,8),self.color).save(args['filename'],format='PPM')


class CaptureTests(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        base=ROOT/'artifacts/coverage/capture-publication-tests';base.mkdir(parents=True,exist_ok=True)
        self.tmp=tempfile.TemporaryDirectory(dir=base);self.addCleanup(self.tmp.cleanup)
        self.out=Path(self.tmp.name)

    async def test_publication_event_can_only_observe_complete_png(self):
        destination=self.out/'endpoint.png';observed=[];link=os.link
        def publish(src,dst):
            with Image.open(src) as frame:
                frame.load();self.assertEqual(frame.getpixel((0,0)),(10,20,30))
            link(src,dst)
            with Image.open(dst) as frame:frame.load();observed.append(frame.size)
        with patch.object(menu.os,'link',side_effect=publish):
            await menu.capture(Qmp((10,20,30)),destination)
        self.assertEqual(observed,[(8,8)])
        self.assertEqual([p.name for p in self.out.iterdir()],['endpoint.png'])

    async def test_initial_and_final_frames_remain_distinct(self):
        endpoint=self.out/'endpoint.png';final=self.out/'final.png'
        await menu.capture(Qmp((10,20,30)),endpoint);before=endpoint.read_bytes()
        await menu.capture(Qmp((40,50,60)),final)
        self.assertEqual(endpoint.read_bytes(),before)
        self.assertNotEqual(final.read_bytes(),before)
        source=(ROOT/'tools/tests/coverage/boot_menu.py').read_text(encoding='utf-8')
        self.assertIn("await operator_steps(qmp,args.out,usb_test,not args.ps2_input,getattr(args,'usb_pointer','tablet'))\n                    await capture(qmp,args.out/'final.png')",source)
        self.assertNotIn("frame.save(args.out/'endpoint.png')",source)

    async def test_existing_frame_is_rejected_before_qmp(self):
        for name in ('endpoint.png','endpoint.png.pending','endpoint.ppm'):
            with self.subTest(name=name):
                existing=self.out/name;existing.write_bytes(b'previous proof')
                qmp=Qmp((10,20,30))
                with self.assertRaises(FileExistsError):await menu.capture(qmp,self.out/'endpoint.png')
                self.assertEqual(qmp.calls,[]);self.assertEqual(existing.read_bytes(),b'previous proof')
                existing.unlink()

    async def test_destination_race_does_not_overwrite_and_cleans_own_scratch(self):
        destination=self.out/'endpoint.png';link=os.link
        def race(src,dst):
            Path(dst).write_bytes(b'competing proof')
            link(src,dst)
        with patch.object(menu.os,'link',side_effect=race):
            with self.assertRaises(FileExistsError):await menu.capture(Qmp((10,20,30)),destination)
        self.assertEqual(destination.read_bytes(),b'competing proof')
        self.assertEqual([p.name for p in self.out.iterdir()],['endpoint.png'])


if __name__=='__main__':unittest.main()
