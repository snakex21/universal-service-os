"""One guarded installed NT4 HID-only boot; fixed endpoint and explicit actions."""
from pathlib import Path
import asyncio,ctypes,importlib.util,json,os,re,sys,time

HERE=Path(__file__).resolve().parent
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
h=load('nt4_hid_contract',HERE/'nt4_hid_fixture.py')
def live_console():
 if not sys.stdin.isatty():return False
 k=ctypes.WinDLL('kernel32',use_last_error=True);k.GetStdHandle.argtypes=[ctypes.c_uint32];k.GetStdHandle.restype=ctypes.c_void_p
 k.GetConsoleMode.argtypes=[ctypes.c_void_p,ctypes.POINTER(ctypes.c_uint32)];mode=ctypes.c_uint32()
 return bool(k.GetConsoleMode(k.GetStdHandle(0xfffffff6),ctypes.byref(mode)))
def parse_action(line):
 if len(line.rstrip('\r\n').encode('utf-8'))>450:raise ValueError('Encoded JSON must be <=450 bytes')
 a=json.loads(line)
 if not isinstance(a,dict) or set(a)-{'finish','hid','pointer','keys','settle'}:raise ValueError('Unknown action')
 if a.get('finish'):
  if a!={'finish':True}:raise ValueError('Finish must be separate')
  return a
 keys=a.get('keys',[]);settle=a.get('settle',2)
 if not isinstance(keys,list) or len(keys)>64 or any(not isinstance(v,str) or not re.fullmatch('[a-z0-9_-]+',v) for v in keys):raise ValueError('Invalid bounded keys')
 if type(settle) not in (int,float) or not 0<=settle<=60:raise ValueError('Explicit settle0..60 required')
 if 'hid' in a:
  d=a['hid']
  if not isinstance(d,dict) or set(d)!={'device','state'} or d['device'] not in ('keyboard','mouse') or d['state'] not in ('remove','insert'):raise ValueError('Exact owned HID action required')
 if 'pointer' in a:
  p=a['pointer']
  if not isinstance(p,dict) or set(p)-{'dx','dy','click'}:raise ValueError('Bounded pointer action required')
  if any(type(p.get(axis,0))!=int or not -2048<=p.get(axis,0)<=2048 for axis in ('dx','dy')) or p.get('click') not in (None,'left','right','middle'):raise ValueError('Invalid pointer action')
 return a
def descriptor(device):
 return dict(driver='usb-kbd' if device=='keyboard' else 'usb-mouse',id='coveragekbd' if device=='keyboard' else 'coveragepointer',bus='xhci.0',port='1' if device=='keyboard' else '2')
async def operator(qmp,boot):
 print('AWAITING_NT4_HID_OPERATOR <=450 encoded JSON bytes',flush=True);n=0
 while line:=await asyncio.to_thread(sys.stdin.readline):
  a=parse_action(line)
  if a.get('finish'):return
  if a.get('hid'):
   d=descriptor(a['hid']['device'])
   if a['hid']['state']=='remove':await qmp.delete_device(d['id'])
   else:await qmp.command('device_add',d)
  for key in a.get('keys',[]):await qmp.key(key)
  if a.get('pointer'):
   p=a['pointer'];await qmp.command('input-send-event',dict(events=[dict(type='rel',data=dict(axis=axis,value=p.get('d'+axis,0))) for axis in ('x','y')]))
   if p.get('click'):
    for down in (True,False):
     await qmp.command('input-send-event',dict(events=[dict(type='btn',data=dict(down=down,button=p['click']))]));await asyncio.sleep(.1)
  await asyncio.sleep(a.get('settle',2));n+=1
  image='operator-%02d.png'%n;await boot.capture(qmp,h.RUNTIME/image)
  with (h.RUNTIME/'operator-actions.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(dict(image=image,hid=a.get('hid'),pointer=a.get('pointer'),keys_count=len(a.get('keys',[]))))+'\n')
  print('STEP_COMPLETE '+image,flush=True)
 raise EOFError('Operator closed before explicit finish')
async def main():
 if not live_console():raise ValueError('Live Windows PTY required before QEMU')
 prep=h.read(h.OUT/'preparation.json')
 if not prep.get('only_i8042prt_start_changed') or not prep.get('independent_readback') or prep.get('target_sha256')!=h.sha(h.WORK/'target.qcow2') or h.sha(h.BASE)!=h.BASE_SHA:raise ValueError('Exact fresh prepared pins required')
 if h.RUNTIME.exists():raise FileExistsError('Never relaunch an existing case')
 boot=load('nt4_hid_native_boot',h.MATRIX/'tools/tests/coverage/boot_menu.py')
 resources=boot.fixture.check_resources(h.WORK,2048) # one guard, including8GiB reserve; no retry
 h.RUNTIME.mkdir(parents=True);qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
 qemu=h.QIMG.with_name('qemu-system-x86_64.exe')
 command=[str(qemu),'-name',h.WORK.name,'-machine','q35','-accel','tcg,thread=multi','-cpu','EPYC-Rome','-smp','2','-m','2048','-display','none','-serial','stdio','-monitor','none','-qmp',f'tcp:127.0.0.1:{server.sockets[0].getsockname()[1]},server=off',
  '-device','qemu-xhci,id=xhci','-device','usb-kbd,id=coveragekbd,bus=xhci.0,port=1','-device','usb-mouse,id=coveragepointer,bus=xhci.0,port=2',
  '-netdev','user,id=usabilitynet,hostname=usos-test','-device','igb,netdev=usabilitynet,mac=52:54:00:55:53:01',
  '-drive',f'if=none,id=target,format=qcow2,file={(h.WORK/"target.qcow2").as_posix()}',
  '-device','ich9-ahci,id=coverageahci','-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0']
 (h.RUNTIME/'command.json').write_text(json.dumps(command,indent=2)+'\n',encoding='utf-8')
 (h.RUNTIME/'preflight.json').write_text(json.dumps(dict(resources=resources,preparation_sha256=h.sha(h.OUT/'preparation.json'),source_pins={str(p):h.sha(p) for p in (Path(__file__),HERE/'nt4_hid_fixture.py',h.MATRIX/'tools/tests/coverage/boot_menu.py')}),indent=2)+'\n',encoding='utf-8')
 process=None;pump=None;failure=None;shutdown=None;started=time.monotonic()
 try:
  env=dict(os.environ,TEMP=str(h.WORK),TMP=str(h.WORK),APPDATA=str(h.WORK),LOCALAPPDATA=str(h.WORK))
  with (h.RUNTIME/'serial.log').open('xb') as serial,(h.RUNTIME/'stderr.log').open('xb') as errors:
   process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env)
   print('NT4_HID_STARTED; one planned150s endpoint, no progress polling',flush=True)
   async def consume():
    while data:=await process.stdout.read(65536):serial.write(data);serial.flush()
   pump=asyncio.create_task(consume());await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
   try:await asyncio.wait_for(process.wait(),150)
   except asyncio.TimeoutError:
    await boot.capture(qmp,h.RUNTIME/'endpoint.png');print('NT4_HID_ENDPOINT_COMPLETE',flush=True);await operator(qmp,boot)
 except Exception as e:failure=type(e).__name__+': '+str(e)
 finally:
  if process and process.returncode is None:
   try:await asyncio.wait_for(qmp.command('quit'),3)
   except Exception:pass
   try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
   except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
  if pump:await pump
  server.close();await server.wait_closed()
  if qmp.writer:qmp.writer.close()
  result=dict(scope='Installed NT4 HID-only, BIOS q35/AHCI; different cold firmware from fresh OVMF/CSM flow',resources=resources,
   elapsed=round(time.monotonic()-started,3),qemu_returncode=process.returncode if process else None,shutdown=shutdown,error=failure,
   i8042_hardware_present=True,i8042prt_start=4,usb_sha256=h.USB,base_sha256=h.BASE_SHA,lan_pass=False,msc_pass=False,hid_pass=False)
  (h.RUNTIME/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
  (h.RUNTIME/'completed.json').write_text('{"stopped":true,"retained":true}\n',encoding='utf-8');print('NT4_HID_COMPLETED',flush=True)
if __name__=='__main__':asyncio.run(main())
