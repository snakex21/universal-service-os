"""Bounded label normalization policy; synthetic files, no VM or Windows bytes."""
from pathlib import Path
import os,shutil,subprocess,tempfile,unittest
ROOT=Path(__file__).resolve().parents[2]

class Label95(unittest.TestCase):
    def setUp(self):
        parent=(ROOT/'zig-out/w95-label-tests').resolve();parent.mkdir(parents=True,exist_ok=True)
        self.folder=Path(tempfile.mkdtemp(dir=parent)).resolve();assert self.folder.is_relative_to(parent)
        self.addCleanup(shutil.rmtree,self.folder)
        self.run=self.folder/'run';self.run.mkdir();self.bin=self.folder/'bin';self.bin.mkdir()
        self.disk=self.folder/'synthetic-partition';boot=bytearray(512);boot[54:62]=b'FAT16   '
        boot[17:19]=b'\0\x02';boot[22:24]=b'\0\x01'
        self.disk.write_bytes(boot);self.calls=self.folder/'writes'
        (self.bin/'fatlabel').write_text('''#!/bin/sh
[ "${FAKE_LABEL_FAIL:-0}" = 0 ] || exit 2
if [ "$#" = 1 ]; then printf '%s\\n' "${FAKE_ROOT_LABEL:-WINDOWS95}"; exit 0; fi
printf 'write:%s\\n' "$2" >> "$FAKE_LABEL_CALLS"
printf '%-11s' "$2" | dd of="$1" bs=1 seek=43 conv=notrunc 2>/dev/null || exit 2
if [ "${FAKE_EXTRA_BYTE:-0}" = 1 ]; then printf X | dd of="$1" bs=1 seek=90 conv=notrunc 2>/dev/null; fi
''',newline='\n')
        (self.bin/'fsck.fat').write_text('#!/bin/sh\necho synthetic-structural-error\nexit "${FAKE_FSCK_RC:-1}"\n',newline='\n')
        self.shell=r'C:\Program Files\Git\bin\sh.exe'
    def invoke(self,body=None,**extra):
        posix=self.bin.as_posix();posix='/'+posix[0].lower()+posix[2:] if posix[1:2]==':' else posix
        script=f'. "{(ROOT/"tools/w9x_phase1_qemu.sh").as_posix()}"\nPATH="{posix}:$PATH"\nsync() {{ :; }}\n'
        script+=body or 'w9x_phase1_label95 "$PARTITION" "$LABEL_LOG"; echo rc=$?'
        env=dict(os.environ,W9X_VM_KEY='synthetic95scope',W9X_VM_RUN=self.run.as_posix(),
            PARTITION=self.disk.as_posix(),LABEL_LOG=(self.folder/'label.log').as_posix(),
            FAKE_LABEL_CALLS=self.calls.as_posix(),TEMP=str(self.folder),TMP=str(self.folder))
        env.update(extra)
        return subprocess.run([self.shell,'-c',script],env=env,capture_output=True,text=True)
    def test_known_pair_changes_only_eleven_boot_bytes(self):
        before=self.disk.read_bytes();result=self.invoke();self.assertIn('rc=0',result.stdout,result.stderr)
        expected=bytearray(before);expected[43:54]=b'WINDOWS95  '
        self.assertEqual(self.disk.read_bytes(),expected);self.assertEqual(self.calls.read_text().splitlines(),['write:WINDOWS95'])
    def test_non_windows95_is_unchanged(self):
        before=self.disk.read_bytes();r=self.invoke(W9X_VM_KEY='')
        self.assertIn('rc=0',r.stdout);self.assertEqual(self.disk.read_bytes(),before);self.assertFalse(self.calls.exists())
    def test_fat32_is_unchanged(self):
        data=bytearray(self.disk.read_bytes());data[54:62]=b'FAT32   ';self.disk.write_bytes(data)
        r=self.invoke();self.assertIn('rc=0',r.stdout);self.assertEqual(self.disk.read_bytes(),data);self.assertFalse(self.calls.exists())
    def test_fat32_bpb_fields_block_a_misleading_type_string(self):
        for offset in (17,22):
            data=bytearray(512);data[54:62]=b'FAT16   ';data[17:19]=b'\0\x02';data[22:24]=b'\0\x01'
            data[offset:offset+2]=b'\0\0';self.disk.write_bytes(data)
            r=self.invoke();self.assertIn('rc=0',r.stdout);self.assertEqual(self.disk.read_bytes(),data);self.assertFalse(self.calls.exists())
    def test_other_root_label_is_unchanged(self):
        before=self.disk.read_bytes();r=self.invoke(FAKE_ROOT_LABEL='OTHER')
        self.assertIn('rc=0',r.stdout);self.assertEqual(self.disk.read_bytes(),before);self.assertFalse(self.calls.exists())
    def test_nonblank_boot_label_is_unchanged(self):
        for label in (b'WINDOWS95  ',b'OTHER      ',b'\n'*11):
            data=bytearray(512);data[54:62]=b'FAT16   ';data[17:19]=b'\0\x02';data[22:24]=b'\0\x01'
            data[43:54]=label;self.disk.write_bytes(data)
            r=self.invoke();self.assertIn('rc=0',r.stdout);self.assertEqual(self.disk.read_bytes(),data);self.assertFalse(self.calls.exists())
    def test_short_sector_fails(self):
        self.disk.write_bytes(b'x'*10);r=self.invoke();self.assertIn('rc=1',r.stdout);self.assertFalse(self.calls.exists())
    def test_tool_failure_fails_without_write(self):
        before=self.disk.read_bytes();r=self.invoke(FAKE_LABEL_FAIL='1')
        self.assertIn('rc=1',r.stdout);self.assertEqual(self.disk.read_bytes(),before);self.assertFalse(self.calls.exists())
    def test_unexpected_boot_write_fails_readback(self):
        r=self.invoke(FAKE_EXTRA_BYTE='1');self.assertIn('rc=1',r.stdout)
        self.assertIn('readback failed',(self.folder/'label.log').read_text())
    def test_structural_fsck_error_still_blocks_mount_and_handoff(self):
        body='''
blockdev() { :; }
losetup() { if [ "$1" = -f ]; then echo "$PARTITION"; fi; return 0; }
mount() { echo FORBIDDEN_MOUNT; return 1; }
w9x_phase1_verify /dev/fake "$W9X_VM_RUN/logs"; echo rc=$?
'''
        r=self.invoke(body)
        self.assertIn('rc=1',r.stdout,r.stderr);self.assertIn('fsck.fat found errors',r.stdout)
        self.assertNotIn('FORBIDDEN_MOUNT',r.stdout);self.assertFalse((self.run/'c/USOS9X/PHASE1.OK').exists())
        self.assertIn('synthetic-structural-error',(self.run/'logs/fsck.txt').read_text())

if __name__=='__main__':unittest.main()
