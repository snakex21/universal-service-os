"""Real Windows completion notifications on own tiny fixtures; no QEMU."""
from pathlib import Path
import asyncio,json,os,shutil,tempfile,unittest,uuid
ROOT=Path(__file__).resolve().parents[2]
SCRIPT=ROOT/'tools/tests/coverage/wait_nt351_marker.ps1'
PWSH=os.environ.get('USOS_PWSH') or shutil.which('pwsh')
PARENT=ROOT/'artifacts/nt351-marker-host';PARENT.mkdir(parents=True,exist_ok=True)
COLLECTION=Path(r'G:\USOS-Kolekcja')

class Marker(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        if not PWSH:raise RuntimeError('Set USOS_PWSH to existing PowerShell7')
        self.temp=tempfile.TemporaryDirectory(dir=PARENT);self.root=Path(self.temp.name)
        self.tag='nt351-marker-host-'+uuid.uuid4().hex[:12];self.processes=[]
        self.work=COLLECTION/'_vm'/self.tag;self.work.mkdir()
        self.output=self.root/'artifacts/coverage/vm'/self.tag;self.output.mkdir(parents=True)
        self.token='USOS_NET_DONE_'+uuid.uuid4().hex
        self.metadata=dict(folder='Windows NT 3.51',private_profile=False);self.write_metadata()
    async def asyncTearDown(self):
        for process in self.processes:
            if process.returncode is None:process.kill();await process.wait()
        assert self.work.resolve().is_relative_to(COLLECTION.resolve()/'_vm')
        (self.work/'fixture.json').unlink();self.work.rmdir()
        assert self.root.resolve().is_relative_to(PARENT.resolve());self.temp.cleanup()
    def write_metadata(self):
        (self.work/'fixture.json').write_text(json.dumps(self.metadata),encoding='utf-8')
    async def launch(self):
        env=dict(os.environ,TEMP=str(self.root),TMP=str(self.root),
            PSModuleAnalysisCachePath=str(self.root/'module-analysis.cache'),
            POWERSHELL_TELEMETRY_OPTOUT='1',POWERSHELL_UPDATECHECK='Off')
        process=await asyncio.create_subprocess_exec(str(PWSH),'-NoProfile','-NonInteractive','-File',str(SCRIPT),
            '-Root',str(self.root),'-Tag',self.tag,'-Token',self.token,
            stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env)
        self.processes.append(process);return process
    async def test_real_notification_split_token_no_progress_output(self):
        process=await self.launch()
        self.assertEqual((await asyncio.wait_for(process.stdout.readline(),10)).strip(),b'COMPLETION_LISTENER_ARMED')
        (self.output/'serial.log').write_bytes(b'x'*65517+b'\n'+self.token.encode()+b'\r\n')
        out,err=await asyncio.wait_for(process.communicate(),10)
        self.assertEqual(process.returncode,0,err.decode(errors='replace'))
        self.assertEqual(out.strip(),('SERIAL_COMPLETION '+self.token).encode())
    async def test_cleanup_before_marker_is_terminal_failure(self):
        process=await self.launch()
        self.assertEqual((await asyncio.wait_for(process.stdout.readline(),10)).strip(),b'COMPLETION_LISTENER_ARMED')
        (self.output/'serial.log').write_text('prefix'+self.token+'\n'+self.token+'suffix\n',encoding='utf-8')
        (self.output/'cleanup.json').write_text('{}',encoding='utf-8')
        out,err=await asyncio.wait_for(process.communicate(),10)
        self.assertNotEqual(process.returncode,0);self.assertNotIn(b'SERIAL_COMPLETION',out)
        self.assertIn(b'cleanup occurred',err)
    async def test_ambiguous_private_profile_rejected_before_read(self):
        for value in (None,0,'false',True):
            self.metadata['private_profile']=value;self.write_metadata();process=await self.launch()
            out,err=await asyncio.wait_for(process.communicate(),10)
            self.assertNotEqual(process.returncode,0);self.assertNotIn(b'ARMED',out)
            self.assertIn(b'explicitly keyless',err)

if __name__=='__main__':unittest.main()
