"""Actual C observer-state semantics, hidden-process contract and NT4 fixture ordering."""
from pathlib import Path
import ctypes
import importlib.util
import os
import subprocess
import tempfile
import unittest

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
HEADER=HERE/'nt4_observer/observer_core.h'
ZIG=Path(os.environ.get('USOS_ZIG',r'C:\Users\ASRock\usos-work\dokumentacja-9x\tools\zig\zig.exe'))
TMP=ROOT/'artifacts/coverage/nt4-observer-host';TMP.mkdir(parents=True,exist_ok=True)
spec=importlib.util.spec_from_file_location('fixture_hook',HERE/'prepare_stick.py');fixture=importlib.util.module_from_spec(spec);spec.loader.exec_module(fixture)
TOKEN='USOS_COVERAGE_FIRST_LOGON_'+'a'*32
SCRIPT=(b'# preserve Storage and LogFile\ncrlf > "$usos/POST.CMD" <<\'EOF\'\n'
        b'echo SP6a completed\n%SystemRoot%\\regedit.exe /s C:\\USOS\\NT4\\DONE.REG\n'
        b'echo done > C:\\USOS\\NT4\\DONE.TXT\nC:\\USOS\\NT4\\USOSOFF.EXE /r\nEOF\n'+
        br'''printf 'answer=%s\r\ncrypto=%s\r\nedition=%s\r\n' "$ANSWER_KIND" "$crypto" "${tse:+tse}" > "$usos/SOURCE.TXT"'''+b'\n')
FINISH=b'nt4_vm_finish() {\n    # SP6a and status verification already finished here\n    sync\n    umount "$c" || status=1\n}\n'


class CStateMachine(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(dir=TMP);cls.directory=Path(cls.temp.name);cls.addClassCleanup(cls.temp.cleanup)
        source=cls.directory/'model.c';dll=cls.directory/'model.dll';temporary=cls.directory/'tmp';temporary.mkdir()
        source.write_text('#include "'+HEADER.as_posix()+'"\n'+r'''
        typedef struct {unsigned fail,n,event[32];int state,armed;} T;
        static int event(T*t,unsigned n){t->event[t->n++]=n;return !(t->fail&(1u<<n));}
        static int arm(void*c){T*t=c;return event(t,1)&&t->armed;} static int stage(void*c){return event(c,2);}
        static int once(void*c){return event(c,3);} static int run(void*c){return event(c,4);}
        static int del(void*c){T*t=c;int ok=event(t,5);if(ok)t->armed=0;return ok;} static int ready(void*c){T*t=c;return event(t,7)&&(t->state==OBS_READY||t->state==OBS_TESTNET_DONE);}
        static int hidden(void*c,int n){T*t=c;int ok=event(t,n?8:6);if(ok&&!n)t->event[t->n++]=90;return ok;}
        static void status(void*c,int n){T*t=c;t->state=n;t->event[t->n++]=100u+(unsigned)n;}
        __declspec(dllexport) int model(unsigned fail,int net,unsigned*out,int*state){
          T t={0};unsigned i;int result;OBS_OPS p={&t,arm,stage,once,run,del,hidden,ready,status};t.fail=fail;t.state=*state;t.armed=1;
          result=net?obs_testnet(&p):obs_first(&p);for(i=0;i<t.n;i++)out[i]=t.event[i];*state=t.state;return result;
        }
        __declspec(dllexport) int model_pair(unsigned fail,int after_net,unsigned*out,int*state){
          T t={0};unsigned i;int result;OBS_OPS p={&t,arm,stage,once,run,del,hidden,ready,status};t.fail=fail;t.armed=1;
          obs_first(&p);if(after_net)obs_testnet(&p);result=obs_first(&p);
          for(i=0;i<t.n;i++)out[i]=t.event[i];*state=t.state;return result;
        }''',encoding='utf-8')
        result=subprocess.run([str(ZIG),'cc','-shared','-O2','-Wall','-Wextra','-Werror',str(source),'-o',str(dll)],capture_output=True,
            env=dict(os.environ,TEMP=str(temporary),TMP=str(temporary),ZIG_GLOBAL_CACHE_DIR=str(cls.directory/'cache-global'),ZIG_LOCAL_CACHE_DIR=str(cls.directory/'cache-local')))
        if result.returncode:raise RuntimeError(result.stderr.decode(errors='replace'))
        cls.library=ctypes.CDLL(str(dll));cls.function=cls.library.model
        cls.function.argtypes=[ctypes.c_uint,ctypes.c_int,ctypes.POINTER(ctypes.c_uint),ctypes.POINTER(ctypes.c_int)];cls.function.restype=ctypes.c_int
        cls.pair=cls.library.model_pair;cls.pair.argtypes=cls.function.argtypes;cls.pair.restype=ctypes.c_int
        def unload():
            free=ctypes.windll.kernel32.FreeLibrary;free.argtypes=[ctypes.c_void_p];free.restype=ctypes.c_int;free(cls.library._handle)
        cls.addClassCleanup(unload)
    def model(self,fail=0,net=0,initial=0):
        events=(ctypes.c_uint*32)();status=ctypes.c_int(initial);result=self.function(fail,net,events,ctypes.byref(status))
        return result,status.value,[n for n in events if n]
    def test_no_arm_means_no_staging_cleanup_child_or_token(self):
        self.assertEqual(self.model(1<<1),(1,0,[1]))
    def test_duplicate_unarmed_invocation_preserves_ready_and_error_status(self):
        for previous in (5,6,8,9):
            self.assertEqual(self.model(1<<1,initial=previous),(1,previous,[1]))
    def test_two_actual_sequential_c_invocations_preserve_ready_done_and_failure(self):
        for fail,network,expected in ((0,0,6),(0,1,9),(1<<6,0,5)):
            events=(ctypes.c_uint*32)();status=ctypes.c_int()
            self.assertEqual(self.pair(fail,network,events,ctypes.byref(status)),1)
            emitted=[v for v in events if v]
            self.assertEqual(status.value,expected)
            self.assertEqual(emitted[-1],1)  # Second invocation checks ARM only.
            for effect in (3,4,5,6):self.assertEqual(emitted.count(effect),1)
            self.assertEqual(emitted.count(90),0 if fail else 1)
    def test_staging_failure_never_removes_hook_arm_or_emits_token(self):
        self.assertEqual(self.model(1<<2),(2,2,[1,2,102]))
    def test_both_hooks_are_attempted_and_any_failure_blocks_arm_removal_and_token(self):
        for bit in (3,4):self.assertEqual(self.model(1<<bit),(3,3,[1,2,3,4,103]))
    def test_arm_removal_and_child_failure_are_explicit_and_emit_no_token(self):
        self.assertEqual(self.model(1<<5),(4,4,[1,2,3,4,5,104]))
        self.assertEqual(self.model(1<<6),(5,5,[1,2,3,4,5,6,105]))
    def test_success_removes_both_hooks_and_arm_before_hidden_firstlo_and_token(self):
        self.assertEqual(self.model(),(6,6,[1,2,3,4,5,6,90,106]))
    def test_testnet_is_explicit_waited_and_has_no_first_logon_token(self):
        self.assertEqual(self.model(net=1,initial=6),(9,9,[7,2,8,109]))
        self.assertEqual(self.model(1<<7,1),(7,7,[7,107]))
        self.assertEqual(self.model(1<<8,1,initial=6),(8,8,[7,2,8,108]))


class FixtureOrdering(unittest.TestCase):
    def test_only_cached_own_scripts_are_modified_and_arm_is_not_in_post(self):
        entries=fixture.nt4_observer_entries(SCRIPT,FINISH,TOKEN,b'MZ own synthetic NT4OBS')
        result={name:data for name,mode,data in entries};target=result['usr/lib/usos/nt4_csmwrap_target.sh'];finish=result['usr/lib/usos/nt4_qemu_install.sh']
        self.assertIn(b'# preserve Storage and LogFile',target)
        self.assertLess(target.index(b'echo SP6a completed'),target.index(b'Coverage\\OBS.REG'))
        self.assertLess(target.index(b'NT4\\DONE.REG'),target.index(b'Coverage\\OBS.REG'))
        self.assertNotIn(b'ARMED.TXT',target)
        self.assertIn(b'[ "$status" = 0 ] && [ "$sub" = NT4 ]',finish)
        self.assertLess(finish.index(b'ARMED.TXT'),finish.index(b'    sync\n    umount'))
        obs=result['usr/lib/usos/coverage-nt4/OBS.REG'].decode('ascii')
        self.assertIn('\\RunOnce]',obs);self.assertIn('\\Run]',obs);self.assertEqual(obs.count('NT4OBS.EXE /firstlogon'),2)
        first=result['usr/lib/usos/coverage-nt4/FIRSTLO.CMD'].decode('ascii')
        self.assertLess(first.index('if errorlevel 1 exit 1'),first.index('echo '+TOKEN));self.assertNotIn('copy /y',first.lower());self.assertNotIn('%~d0',first)
        test=result['usr/lib/usos/coverage-nt4/TESTNET.CMD'].decode('ascii')
        self.assertIn('/release >nul',test);self.assertIn('/renew >nul',test);self.assertIn('/nodisk',test);self.assertNotIn(TOKEN,test)
        stage=fixture.NT4_OBSERVER_STAGE.encode('ascii').replace(b'LOGGER_SHA',fixture.NT4_NETWORK_LOGGER_SHA256.encode('ascii'))
        restored=target.replace(br'%SystemRoot%\regedit.exe /s C:\USOS\Coverage\OBS.REG'+b'\n',b'').replace(stage,b'')
        self.assertEqual(restored,SCRIPT)
        self.assertEqual(finish.replace(fixture.NT4_OBSERVER_ARM.encode('ascii'),b''),FINISH)
        for bad in (b'',SCRIPT+SCRIPT):
            with self.assertRaises(ValueError):fixture.nt4_observer_entries(bad,FINISH,TOKEN,b'x')
    def test_native_gui_uses_hidden_detached_process_wait_and_exact_cleanup_targets(self):
        source=(HERE/'nt4_observer/observer.c').read_text(encoding='utf-8')
        self.assertIn('si.wShowWindow=SW_HIDE',source);self.assertIn('FALSE,DETACHED_PROCESS',source)
        self.assertIn('WaitForSingleObject(pi.hProcess,INFINITE)',source);self.assertIn('GetExitCodeProcess',source)
        self.assertIn('RegDeleteValueA(key,"USOSCoverage")',source)
        self.assertIn('CurrentVersion\\\\RunOnce',source);self.assertIn('CurrentVersion\\\\Run',source)
        self.assertIn('DeleteFileA(path)',source);self.assertIn('local(path,"ARMED.TXT")',source)
        self.assertNotIn('CreateFileA("C:',source)


if __name__=='__main__':unittest.main()
