"""Portable logger paths must remain usable by the Win16 log companion."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]


class ArgumentTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc=shutil.which('gcc') or r'C:\msys64\mingw64\bin\gcc.exe'
        if not Path(cc).is_file():raise unittest.SkipTest('host compiler unavailable')
        cls.tmp=tempfile.TemporaryDirectory(prefix='dbg-args-',dir=ROOT/'artifacts')
        work=Path(cls.tmp.name);source=(ROOT/'src/platform/bios/win9x/usosdbg.c').read_text()
        fn=re.search(r'^static void parse_args\(void\)\n\{.*?^\}',source,re.M|re.S).group()
        shim=r'''
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#define FAR
#define MAKELP(a,b) tail
#define lstrcpy strcpy
typedef unsigned short WORD;
static char *tail,log_path[128];
static WORD e_cmdseg=1,e_cmdoff;
static int log_mode,log_pci,disk_only;
static unsigned long net_pa;
static unsigned long hexval(const char *s) { return strtoul(s,0,16); }
'''
        c=work/'args.c';cls.exe=work/'args.exe'
        c.write_text(shim+fn+r'''
int main(int argc,char **argv) { (void)argc;tail=argv[1];parse_args();
 printf("mode=%d pci=%d disk=%d net=%lX\npath=%s\n",log_mode,log_pci,disk_only,net_pa,log_path);return 0; }
''')
        subprocess.run([cc,str(c),'-o',str(cls.exe)],check=True,capture_output=True)
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def run_case(self,tail):
        return subprocess.run([str(self.exe),tail],check=True,capture_output=True,text=True).stdout
    def test_quoted_path_and_following_flags(self):
        out=self.run_case(r'/L "C:\Moved Application\LOGS\USOSDBG.TMP" /D /F /N A1230000')
        self.assertIn('mode=1 pci=1 disk=1 net=A1230000',out)
        self.assertIn('path=C:\\Moved Application\\LOGS\\USOSDBG.TMP\n',out)
    def test_existing_unquoted_path(self):
        self.assertIn('path=C:\\USOS9X\\LOGS\\USOSDBG.TMP\n',self.run_case(r'/L C:\USOS9X\LOGS\USOSDBG.TMP'))
    def test_bad_log_path_remains_silent_and_is_not_truncated(self):
        for tail in ('/L "unterminated path','/L '+('x'*200)):
            with self.subTest(tail_length=len(tail)):
                out=self.run_case(tail)
                self.assertIn('mode=1',out);self.assertTrue(out.endswith('path=\n'))


if __name__=='__main__':unittest.main()
