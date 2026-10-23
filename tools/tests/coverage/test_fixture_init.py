from pathlib import Path
import importlib.util
import unittest

spec=importlib.util.spec_from_file_location('fixture_init',Path(__file__).with_name('fixture_init.py'))
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
GOOD={'result':'PASS','exit_code':0,'timed_out':False}
MARKER='USOS-FIXTURE-COMPLETE-'+'a'*32

class Completion(unittest.TestCase):
    def test_echoed_success_and_kernel_panic_cannot_pass(self):
        text='~ # echo LOWRAM-RESULT=PASS\n~ # echo '+MARKER+'\nKernel panic - not syncing: Attempted to kill init!\n'
        self.assertFalse(module.completion(GOOD,text,MARKER))

    def test_echo_without_panic_cannot_pass(self):
        self.assertFalse(module.completion(GOOD,'~ # echo '+MARKER+'\n',MARKER))

    def test_clean_exact_completion_line(self):
        self.assertTrue(module.completion(GOOD,'readback completed\r\n'+MARKER+'\r\nLOWRAM-RESULT=PASS\r\n',MARKER))

    def test_later_panic_rejects_an_executed_marker(self):
        self.assertFalse(module.completion(GOOD,MARKER+'\nKernel panic\n',MARKER))

    def test_failed_or_timed_out_child_cannot_pass(self):
        for update in ({'result':'FAIL'},{'exit_code':1},{'timed_out':True}):
            self.assertFalse(module.completion(dict(GOOD,**update),MARKER+'\n',MARKER))

    def test_old_metadata_is_rejected_before_boot(self):
        with self.assertRaises(ValueError):module.require_verified({'result':GOOD})
        with self.assertRaises(ValueError):module.require_verified({'result':GOOD,'fixture_verification':{'transport':'initrd-script','complete':False}})
        module.require_verified({'result':GOOD,'fixture_verification':{'transport':'initrd-script','complete':True}})

    def test_firmware_fallback_is_a_terminal_failure(self):
        with self.assertRaisesRegex(RuntimeError,'before USOS'):
            module.reject_firmware_shell('\x1b[01;01HUEFI Interactive Shell v2.2\r\n')
        module.reject_firmware_shell('BdsDxe: loading EFI USOS boot application')

if __name__=='__main__':unittest.main()
