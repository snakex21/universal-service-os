"""Synthetic USBmon packets, no VM/files/private inputs."""
from pathlib import Path
import importlib.util,struct,unittest
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('packets',ROOT/'tools/tests/coverage/usb_input_packets.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
def capture(payloads,*,event='C',status=0,endpoint=0x81,link=220):
    data=bytearray(struct.pack('<IHHIIII',0xa1b2c3d4,2,4,0,0,65535,link))
    for payload in payloads:
        usb=bytearray(64);usb[8]=ord(event);usb[9]=1;usb[10]=endpoint
        struct.pack_into('<iII',usb,28,status,len(payload),64+len(payload))
        packet=usb+payload;data+=struct.pack('<IIII',0,0,len(packet),len(packet))+packet
    return bytes(data)
def keyboard(usage=0):return bytes((0,0,usage,0,0,0,0,0))
class Packets(unittest.TestCase):
    def test_press_deduplication_and_release(self):
        reports=m.completed_interrupt_reports(capture([keyboard(4),keyboard(4),keyboard(),keyboard(4)]))
        self.assertEqual(m.key_presses(reports),[4,4])
    def test_only_completed_successful_in_reports(self):
        for args in ({'event':'S'},{'status':-19},{'endpoint':1}):
            self.assertEqual(m.completed_interrupt_reports(capture([keyboard(4)],**args)),[])
    def test_signed_mouse_and_click_release(self):
        reports=m.completed_interrupt_reports(capture([bytes((1,252,8)),bytes((0,0,0))]))
        self.assertEqual(m.mouse_facts(reports),dict(completed_reports=2,movement_reports=1,left_down=1,left_up=1))
    def test_public_token(self):
        values=[ord(c)-ord('A')+4 for c in 'USBKEY']
        reports=[value for key in values for value in (keyboard(key),keyboard())]
        self.assertTrue(m.public_token_seen(reports,'USBKEY'))
        self.assertFalse(m.public_token_seen(reports,'USBOTHER'))
        with self.assertRaises(ValueError):m.public_token_seen(reports,'not-a-public-challenge')
    def test_empty_and_rollover_do_not_pass(self):
        self.assertFalse(m.public_token_seen([],'USBKEY'))
        with self.assertRaises(ValueError):m.key_presses([keyboard(1)])
    def test_truncation_and_wrong_link_fail(self):
        valid=capture([keyboard(4)])
        for data in (valid[:10],valid[:-1],capture([keyboard(4)],link=1)):
            with self.assertRaises(ValueError):m.completed_interrupt_reports(data)
if __name__=='__main__':unittest.main()
