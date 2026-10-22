"""One guarded installed NT4 MSC test, explicit UI/device actions and COM1 ends."""
from pathlib import Path
import asyncio,importlib.util,json,os,re,sys,time

HERE=Path(__file__).resolve().parent
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
h=load('nt4_msc_contract',HERE/'nt4_msc_fixture.py')
hid=load('nt4_msc_console',HERE/'boot_nt4_hid.py')

def parse_action(line):
 if len(line.rstrip('\r\n').encode('utf-8'))>450:raise ValueError('Encoded JSON must be <=450 bytes')
 a=json.loads(line)
 if not isinstance(a,dict) or set(a)-{'finish','usb','keys','settle','expect_msc'}:raise ValueError('Unknown action')
 if a.get('finish'):
  if a!={'finish':True}:raise ValueError('Finish must be separate')
  return a
 keys=a.get('keys',[]);settle=a.get('settle',2)
 if not isinstance(keys,list) or len(keys)>64 or any(not isinstance(v,str) or not re.fullmatch('[a-z0-9_-]+',v) for v in keys):raise ValueError('Invalid bounded keys')
 if type(settle) not in (int,float) or not 0<=settle<=60:raise ValueError('Explicit settle0..60 required')
 if 'usb' in a and a['usb'] not in ('insert','remove'):raise ValueError('Only owned hot MSC action allowed')
 if 'expect_msc' in a:
  if a['expect_msc'] not in ('STARTUP','HOT','REPLUG') or 'usb' in a or not keys:raise ValueError('One explicit native observer action required')
 return a

def descriptor():
 return dict(driver='usb-storage',id='usability-hot',bus='xhci.0',port='2',drive='usabilityhot',removable=True,serial='USOS-USB-HOT-TEST')

def publish_json(path,value):
 pending=path.with_name(path.name+'.pending')
 with pending.open('x',encoding='utf-8') as f:json.dump(value,f,indent=2);f.write('\n')
 try:os.link(pending,path)
 finally:pending.unlink()

class Completions:
 """Never accept a past/unsolicited token as an action's completion."""
 def __init__(self):self.active=None;self.used=set();self.results={}
 def arm(self,stage):
  if self.active or stage in self.used:raise ValueError('Stage is one-shot and explicitly armed')
  self.used.add(stage);future=asyncio.get_running_loop().create_future();self.active=(stage,future);return future
 def line(self,line):
  match=re.fullmatch(rb'USOS_MSC4_DONE=(STARTUP|HOT|REPLUG):([03])\r?',line)
  if not match:return
  stage=match[1].decode('ascii');status=int(match[2])
  if not self.active or self.active[0]!=stage:raise RuntimeError('Unarmed/duplicate MSC completion refused')
  future=self.active[1];self.active=None;self.results[stage]=status;future.set_result(status)

async def operator(qmp,boot,completions):
 print('AWAITING_NT4_MSC_OPERATOR <=450 encoded JSON bytes',flush=True);n=0;attached=False
 while line:=await asyncio.to_thread(sys.stdin.readline):
  a=parse_action(line)
  if a.get('finish'):return
  future=completions.arm(a['expect_msc']) if 'expect_msc' in a else None
  if a.get('usb'):
   if (a['usb']=='insert')==attached:raise ValueError('Owned hot stick state mismatch')
   if attached:await qmp.delete_device('usability-hot')
   else:await qmp.command('device_add',descriptor())
   attached=not attached
  for key in a.get('keys',[]):await qmp.key(key)
  if future is not None:
   status=await asyncio.wait_for(future,45)
   publish_json(h.RUNTIME/('msc-'+a['expect_msc'].lower()+'-done.json'),dict(stage=a['expect_msc'],status=status,explicit_native_action=True))
  await asyncio.sleep(a.get('settle',2));n+=1
  image='operator-%02d.png'%n;await boot.capture(qmp,h.RUNTIME/image)
  with (h.RUNTIME/'operator-actions.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(dict(image=image,usb=a.get('usb'),expect_msc=a.get('expect_msc'),keys_count=len(a.get('keys',[])),settle=a.get('settle',2)))+'\n')
  print('STEP_COMPLETE '+image,flush=True)
 raise EOFError('Operator closed before explicit finish')

async def consume(process,serial,completions):
 buffer=b'';total=0
 while data:=await process.stdout.read(4096):
  total+=len(data)
  if total>4*1024**2:raise ValueError('Bounded own serial capture exceeded')
  serial.write(data);serial.flush();buffer+=data
  while b'\n' in buffer:
   line,buffer=buffer.split(b'\n',1)
   if len(line)<=256:completions.line(line)
  if len(buffer)>256:raise ValueError('Bounded own serial line exceeded')

async def main():
 if not hid.live_console():raise ValueError('Live Windows PTY required before QEMU')
 prep=h.h.read(h.OUT/'preparation.json')
 if not all(prep.get(k) for k in ('all_other_original_contents_unchanged','system_binary_unchanged','independent_full_inventory_readback','base_unchanged')) or prep['target_sha256']!=h.h.sha(h.WORK/'target.qcow2') or h.h.sha(h.BASE)!=h.BASE_SHA:raise ValueError('Exact fresh prepared pins required')
 if prep['usb_sha256']!=h.MSC or prep['helper_sha256']!=h.HELPER_SHA or prep['new_own_files']!=list(h.NEW):raise ValueError('Own package differs')
 for kind in ('boot','hot'):
  if h.h.sha(h.WORK/('usb-test-'+kind+'.qcow2'))!=prep['test_media'][kind]['sha256']:raise ValueError('Own initial media differs')
 if h.RUNTIME.exists():raise FileExistsError('Never relaunch existing MSC case')
 boot=load('nt4_msc_native_boot',h.h.MATRIX/'tools/tests/coverage/boot_menu.py')
 if h.h.sha(h.h.MATRIX/'tools/tests/coverage/usability_aux.py')!=prep['shared_aux_sha256']:raise ValueError('Pinned named-backend fixture changed')
 resources=boot.fixture.check_resources(h.WORK,2048) # one normal8GiB reserve; no retry
 h.RUNTIME.mkdir(parents=True);qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
 qemu=h.h.QIMG.with_name('qemu-system-x86_64.exe')
 command=[str(qemu),'-name',h.WORK.name,'-machine','q35','-accel','tcg,thread=multi','-cpu','EPYC-Rome','-smp','2','-m','2048','-display','none','-serial','stdio','-monitor','none','-qmp',f'tcp:127.0.0.1:{server.sockets[0].getsockname()[1]},server=off',
  '-device','qemu-xhci,id=xhci',*boot.aux.network_arguments('igb'),
  '-drive',f'if=none,id=target,format=qcow2,file={(h.WORK/"target.qcow2").as_posix()}',
  '-device','ich9-ahci,id=coverageahci','-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0',
  *boot.aux.usb_block_arguments('boot',h.WORK/'usb-test-boot.qcow2'),*boot.aux.usb_block_arguments('hot',h.WORK/'usb-test-hot.qcow2'),
  '-device','usb-storage,id=usability-boot,bus=xhci.0,port=1,drive=usabilityboot,removable=true,serial=USOS-USB-BOOT-TEST']
 publish_json(h.RUNTIME/'command.json',command)
 publish_json(h.RUNTIME/'preflight.json',dict(resources=resources,preparation_sha256=h.h.sha(h.OUT/'preparation.json'),source_pins={str(p):h.h.sha(p) for p in (Path(__file__),HERE/'nt4_msc_fixture.py',HERE/'nt4_hid_fixture.py',h.h.MATRIX/'tools/tests/coverage/boot_menu.py',h.h.MATRIX/'tools/tests/coverage/usability_aux.py')}))
 process=None;pump=None;failure=None;shutdown=None;started=time.monotonic();completions=Completions()
 try:
  env=dict(os.environ,TEMP=str(h.WORK),TMP=str(h.WORK),APPDATA=str(h.WORK),LOCALAPPDATA=str(h.WORK))
  with (h.RUNTIME/'serial.log').open('xb') as serial,(h.RUNTIME/'stderr.log').open('xb') as errors:
   process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env)
   print('NT4_MSC_STARTED; one planned150s endpoint, no progress polling',flush=True)
   pump=asyncio.create_task(consume(process,serial,completions));await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
   try:await asyncio.wait_for(process.wait(),150)
   except asyncio.TimeoutError:
    await boot.capture(qmp,h.RUNTIME/'endpoint.png');print('NT4_MSC_ENDPOINT_COMPLETE',flush=True);await operator(qmp,boot,completions)
 except Exception as e:
  failure=type(e).__name__+': '+str(e)
  if process and process.returncode is None and qmp.writer:
   try:await boot.capture(qmp,h.RUNTIME/'action-failure.png')
   except Exception:pass
 finally:
  if process and process.returncode is None:
   try:await asyncio.wait_for(qmp.command('quit'),3)
   except Exception:pass
   try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
   except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
  if pump:
   try:await pump
   except Exception as e:failure=failure or type(e).__name__+': '+str(e)
  server.close();await server.wait_closed()
  if qmp.writer:qmp.writer.close()
  publish_json(h.RUNTIME/'result.json',dict(scope='Installed NT4 MSC-only; BIOS q35/AHCI cold firmware differs from fresh OVMF/CSM',resources=resources,
   elapsed=round(time.monotonic()-started,3),qemu_returncode=process.returncode if process else None,shutdown=shutdown,error=failure,
   i8042_hardware_present=True,i8042prt_start=1,usb_sha256=h.MSC,helper_sha256=h.HELPER_SHA,base_sha256=h.BASE_SHA,
   native_observer_completions=completions.results,lan_pass=False,hid_pass=False,msc_pass=False))
  publish_json(h.RUNTIME/'completed.json',dict(stopped=True,retained=True));print('NT4_MSC_COMPLETED',flush=True)
if __name__=='__main__':asyncio.run(main())
