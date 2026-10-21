"""SPDX-License-Identifier: GPL-3.0-or-later
PE contract checks and unsupported-host negative smoke test.
These do not claim Vista UI or installer acceptance.
"""
from pathlib import Path
import argparse,json,os,subprocess,unittest
import pefile

OUT=None
ROOT=Path(__file__).resolve().parents[3]
TOOLS=ROOT/'tools'
class ComponentTest(unittest.TestCase):
    def test_memory_renderer_clipping_and_origins(self):
        folder=OUT/'render-tests';folder.mkdir(exist_ok=True)
        from PIL import Image
        Image.new('RGB',(8,4),(12,34,56)).save(folder/'decode.jpg',quality=100,subsampling=0)
        Image.new('RGBA',(8,4),(12,34,56,255)).save(folder/'decode.png')
        Image.new('RGBA',(8,4),(12,34,56,128)).save(folder/'decode-alpha.png')
        (folder/'decode-bad.dat').write_bytes(b'not an image')
        env=dict(os.environ,TEMP=str(folder),TMP=str(folder),ZIG_GLOBAL_CACHE_DIR=str(folder/'zig-global'),ZIG_LOCAL_CACHE_DIR=str(folder/'zig-local'))
        harness=folder/'render.exe'
        command=[str(TOOLS/'zig/zig.exe'),'cc','-target','x86_64-windows.win10-gnu','-Os','-nostdlib','-fno-stack-protector','-fno-builtin','-Wno-missing-declarations','-I'+str(TOOLS/'zig/lib/libc/include/any-windows-any'),str(ROOT/'tools/tests/watermark_render_harness.c'),str(ROOT/'tools/nt6/usoswm/runtime.c'),'-Wl,--entry,entry','-lkernel32','-luser32','-lgdi32','-ladvapi32','-lole32','-o',str(harness)]
        subprocess.run(command,env=env,capture_output=True,check=True,timeout=120)
        subprocess.run([str(harness)],env=env,check=True,timeout=15)
    def test_pe_architecture_and_os_contract(self):
        for name in ('usoswm.exe','usoswm-desktop.dll','usoswm-register.exe'):
            p=pefile.PE(str(OUT/name))
            self.assertEqual(p.FILE_HEADER.Machine,0x8664)
            self.assertEqual(p.OPTIONAL_HEADER.Magic,0x20b)
            self.assertLessEqual((p.OPTIONAL_HEADER.MajorSubsystemVersion,p.OPTIONAL_HEADER.MinorSubsystemVersion),(6,0))
    def test_no_crt_kernel_driver_or_boot_dependencies(self):
        allowed={b'kernel32.dll',b'user32.dll',b'gdi32.dll',b'advapi32.dll',b'ole32.dll',b'shell32.dll'}
        forbidden={b'WriteProcessMemory',b'CreateRemoteThread',b'NtSetSystemInformation',b'RegSetValueExW',b'RegCreateKeyExW',b'CreateServiceW'}
        for name in ('usoswm.exe','usoswm-desktop.dll','usoswm-register.exe'):
            p=pefile.PE(str(OUT/name))
            for imp in p.DIRECTORY_ENTRY_IMPORT:
                self.assertIn(imp.dll.lower(),allowed)
                self.assertFalse({i.name for i in imp.imports}&forbidden)
    def test_hook_export_and_single_launcher(self):
        p=pefile.PE(str(OUT/'usoswm-desktop.dll'))
        self.assertIn(b'WmHook',{s.name for s in p.DIRECTORY_ENTRY_EXPORT.symbols})
        p=pefile.PE(str(OUT/'usoswm.exe'))
        functions={i.name for d in p.DIRECTORY_ENTRY_IMPORT for i in d.imports}
        self.assertIn(b'SetWindowsHookExW',functions)
        self.assertIn(b'SetWinEventHook',functions)
        self.assertNotIn(b'CreateToolhelp32Snapshot',functions)
        self.assertNotIn(b'SetTimer',functions)
        self.assertIn(b'SetProcessShutdownParameters',functions)
        self.assertIn(b'SystemParametersInfoW',functions)
        self.assertIn(b'GetFileAttributesW',functions)
        # Diagnostic screen capture only behind the explicit flag file.
        self.assertIn('capture.flag'.encode('utf-16-le'),(OUT/'usoswm.exe').read_bytes())
        source=(ROOT/'tools/nt6/usoswm/launcher.c').read_text(encoding='utf-8')
        self.assertIn('if(!capture_enabled())return;',source)
        p=pefile.PE(str(OUT/'usoswm-desktop.dll'))
        self.assertIn(b'WmPaintCover',{s.name for s in p.DIRECTORY_ENTRY_EXPORT.symbols})
    def test_host_outside_vista_refuses_activation(self):
        result=subprocess.run([str(OUT/'usoswm.exe')],timeout=15)
        self.assertEqual(result.returncode,0)
        logs=list((OUT/'logs').glob('*.log'))
        self.assertTrue(logs)
        self.assertTrue(any('Not started: OS/testsigning/default desktop/opt-out guard' in p.read_text() for p in logs))
    def test_registration_on_unsupported_host_is_rejected(self):
        result=subprocess.run([str(OUT/'usoswm-register.exe')],timeout=15)
        self.assertEqual(result.returncode,50) # ERROR_NOT_SUPPORTED, before Windows integration

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--out',type=Path,required=True);p.add_argument('--tool-root',type=Path,default=TOOLS);a=p.parse_args();OUT=a.out.resolve();TOOLS=a.tool_root.resolve()
    unittest.main(argv=['test_component'],verbosity=2)
