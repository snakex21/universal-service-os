"""Real native receiver against a synthetic RFB peer; no QEMU or Windows media."""
from pathlib import Path
import os
import socket
import struct
import subprocess
import unittest
import queue
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / 'artifacts/win95-events'

def exact(peer, count):
    result = b''
    while len(result) < count:
        block = peer.recv(count-len(result))
        if not block:
            raise EOFError('Native client closed unexpectedly')
        result += block
    return result

class RfbEvents(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        OUT.mkdir(parents=True, exist_ok=True)
        cls.exe = OUT / 'win95-rfb-events.exe'
        subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-std=c11','-O2',
            '-Wall','-Wextra','-Werror',str(ROOT/'tools/win95_rfb_events.c'),
            '-o',str(cls.exe),'-lws2_32'],check=True,capture_output=True)
        value=14695981039346656037
        for byte in bytes((0x33,0x22,0x11))*(480*24):
            value=((value^byte)*1099511628211)&((1<<64)-1)
        profile=OUT/'synthetic-profile.h'
        button=14695981039346656037
        for byte in bytes((0x33,0x22,0x11))*(32*10):
            button=((button^byte)*1099511628211)&((1<<64)-1)
        profile.write_text('#define WIN95_UI_READY_BUTTON_HASH UINT64_C(0x'+format(button,'016x')+')\n'
            'static const Page pages[] = {{"coa", UINT64_C(0x'+format(value,'016x')+'), 0, 0, 0, 0, 0}};\n')
        cls.synthetic=OUT/'win95-rfb-synthetic.exe'
        subprocess.run([r'C:\msys64\mingw64\bin\gcc.exe','-std=c11','-O2',
            '-Wall','-Wextra','-Werror','-DWIN95_UI_PROFILE_TEST_HEADER="'+profile.as_posix()+'"',
            '-DWIN95_UI_STABLE_MS=150','-DWIN95_UI_UNSUPPORTED_MS=300',
            str(ROOT/'tools/win95_rfb_events.c'),'-o',str(cls.synthetic),'-lws2_32'],check=True,capture_output=True)

    def setUp(self):
        with socket.socket() as temporary:
            temporary.bind(('127.0.0.1',0))
            port = temporary.getsockname()[1]
        executable=self.synthetic if (self._testMethodName=='test_recognized_role_and_private_field_updates'
            or self._testMethodName.startswith('test_gate_')) else self.exe
        self.process = subprocess.Popen([str(executable),'--tcp-test',str(port)],
            stdout=subprocess.PIPE,stderr=subprocess.PIPE,
            env=dict(os.environ,TEMP=str(OUT),TMP=str(OUT)))
        self.assertEqual(self.process.stdout.readline(), b'ready\r\n')
        self.peer = socket.create_connection(('127.0.0.1',port),timeout=3)
        self.addCleanup(self.cleanup)

    def cleanup(self):
        self.peer.close()
        if self.process.returncode is None:
            self.process.terminate()
        self.process.communicate(timeout=5)

    def hello(self, width=640, height=480):
        self.peer.sendall(b'RFB 003.008\n')
        self.assertEqual(exact(self.peer,12),b'RFB 003.008\n')
        self.peer.sendall(b'\x01\x01')
        self.assertEqual(exact(self.peer,1),b'\x01')
        self.peer.sendall(b'\0\0\0\0')
        self.assertEqual(exact(self.peer,1),b'\x01')
        self.peer.sendall(struct.pack('>HH',width,height)+b'\0'*16+struct.pack('>I',4)+b'test')
        if not width or not height or max(width,height)>2048:
            return
        pf=exact(self.peer,20)
        self.assertEqual(pf[4:17],bytes([32,24,0,1,0,255,0,255,0,255,16,8,0]))
        self.assertEqual(exact(self.peer,12),b'\x02\0\0\x02'+struct.pack('>ii',0,-223))
        self.assertEqual(exact(self.peer,10),struct.pack('>BBHHHH',3,0,0,0,width,height))

    def update(self,x=0,y=0,width=1,height=1,encoding=0,data=b'\x11\x22\x33\0'):
        self.peer.sendall(b'\0\0\0\x01'+struct.pack('>HHHHi',x,y,width,height,encoding)+data)

    def finish(self, code=0):
        try:
            self.peer.shutdown(socket.SHUT_RDWR)
        except (ConnectionResetError, ConnectionAbortedError):
            # A rejected frame can close the native peer before shutdown.
            # Still verify its actual exit code and all output below.
            pass
        self.peer.close()
        output,errors=self.process.communicate(timeout=5)
        self.assertEqual(self.process.returncode,code,errors)
        self.assertEqual(output,b'', 'Unknown/private pixels must never leave the receiver')

    def test_incremental_wait_rearms_only_after_reply(self):
        self.hello()
        # An actual blocking receive times out: no periodic request is emitted.
        self.peer.settimeout(.2)
        with self.assertRaises(socket.timeout): self.peer.recv(1)
        self.peer.settimeout(3)
        self.update()
        self.assertEqual(exact(self.peer,10),struct.pack('>BBHHHH',3,1,0,0,640,480))
        self.finish()

    def test_recognized_role_and_private_field_updates(self):
        self.hello()
        self.update(width=640,height=480,data=bytes((0x11,0x22,0x33,0))*(640*480))
        self.assertEqual(self.process.stdout.readline(),b'page coa\r\n')
        self.assertEqual(exact(self.peer,10),struct.pack('>BBHHHH',3,1,0,0,640,480))
        self.update(x=120,y=200,data=bytes((99,98,97,0)))
        self.assertEqual(exact(self.peer,10),struct.pack('>BBHHHH',3,1,0,0,640,480))
        self.finish() # no duplicate role and no field pixels on stdout

    def gate_frame(self):
        self.update(width=640,height=480,data=bytes((0x11,0x22,0x33,0))*(640*480))
        self.assertEqual(exact(self.peer,10),struct.pack('>BBHHHH',3,1,0,0,640,480))

    def role_reader(self):
        result=queue.Queue()
        thread=threading.Thread(target=lambda:result.put(self.process.stdout.readline()),daemon=True)
        thread.start()
        return result,thread

    def test_gate_disabled_next_cancels_pending_input(self):
        self.hello();self.gate_frame()
        self.update(x=425,y=395,width=32,height=10,data=b'\0'*32*10*4)
        exact(self.peer,10)
        result,reader=self.role_reader()
        with self.assertRaises(queue.Empty):result.get(timeout=.3)
        self.update(x=425,y=395,width=32,height=10,data=bytes((0x11,0x22,0x33,0))*32*10)
        exact(self.peer,10)
        with self.assertRaises(queue.Empty):result.get(timeout=.05)
        self.assertEqual(result.get(timeout=3),b'page coa\r\n');reader.join()
        # Publishing after the one deadline must not send another RFB request.
        self.peer.settimeout(.2)
        with self.assertRaises(socket.timeout):self.peer.recv(1)
        self.peer.settimeout(3);self.finish()

    def test_gate_changed_heading_cancels_pending_role(self):
        self.hello();self.gate_frame()
        self.update(x=104,y=90,data=b'\x03\x02\x01\0');exact(self.peer,10)
        data=bytearray(bytes((0x33,0x22,0x11))*480*24);data[:3]=bytes((1,2,3))
        heading=14695981039346656037
        for byte in data:heading=((heading^byte)*1099511628211)&((1<<64)-1)
        self.assertEqual(self.process.stdout.readline(),f'unsupported {heading:016x}\r\n'.encode())
        self.finish(4)

    def test_gate_unknown_disabled_page_keeps_blocking(self):
        self.hello()
        frame=bytearray(bytes((0x11,0x22,0x33,0))*(640*480))
        frame[(90*640+104)*4:(90*640+104)*4+4]=b'\x03\x02\x01\0'
        for y in range(395,405):frame[(y*640+425)*4:(y*640+457)*4]=b'\0'*32*4
        self.update(width=640,height=480,data=frame);exact(self.peer,10)
        self.peer.settimeout(.4)
        with self.assertRaises(socket.timeout):self.peer.recv(1)
        self.peer.settimeout(3);self.finish()

    def test_gate_private_field_paints_do_not_postpone_public_readiness(self):
        self.hello();self.gate_frame()
        result,reader=self.role_reader();errors=[]
        def field_paints():
            try:
                for shade in range(12):
                    time.sleep(.05)  # Scripted private-edit/caret paint events.
                    self.update(x=120,y=200,data=bytes((shade,shade,shade,0)))
                    exact(self.peer,10)
            except Exception as error:errors.append(error)
        producer=threading.Thread(target=field_paints,daemon=True);producer.start()
        self.assertEqual(result.get(timeout=.5),b'page coa\r\n')
        reader.join();producer.join(timeout=3)
        self.assertFalse(producer.is_alive());self.assertEqual(errors,[])
        self.finish()

    def test_resize_changes_subscription_bounds(self):
        self.hello()
        self.update(width=720,height=400,encoding=-223,data=b'')
        self.assertEqual(exact(self.peer,10),struct.pack('>BBHHHH',3,1,0,0,720,400))
        self.finish()

    def test_rectangle_overflow_rejected(self):
        self.hello()
        self.update(x=639,width=2)
        self.finish(2)

    def test_unsupported_encoding_rejected(self):
        self.hello()
        self.update(encoding=5,data=b'')
        self.finish(2)

    def test_oversized_initial_frame_rejected(self):
        self.hello(width=65535)
        self.finish(2)

    def test_zero_resize_rejected(self):
        self.hello()
        self.update(width=0,height=480,encoding=-223,data=b'')
        self.finish(2)

    def test_truncated_pixel_data_rejected(self):
        self.hello()
        self.update(data=b'\x11\x22')
        self.finish(2)

    def test_bad_rfb_version_rejected(self):
        self.peer.sendall(b'RFB 003.003\n')
        self.finish(2)

if __name__ == '__main__': unittest.main()
