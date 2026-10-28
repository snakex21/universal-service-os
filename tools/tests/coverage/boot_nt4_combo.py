"""Same frozen313952 HID+MSC runtime; explicit actions, no progress queries."""
from pathlib import Path
import asyncio,importlib.util,json,os,sys,time
HERE=Path(__file__).resolve().parent
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
h=load('nt4_combo_contract',HERE/'nt4_combo_fixture.py')
msc=load('nt4_combo_serial',HERE/'boot_nt4_msc.py')
def parse_action(line):
 if len(line.rstrip('\r\n').encode('utf-8'))>450:raise ValueError('Encoded JSON must be <=450 bytes')
 a=json.loads(line)
 if not isinstance(a,dict) or set(a)-{'finish','hid','pointer','keys','settle','usb','expect_msc'}:raise ValueError('Unknown action')
 msc.hid.parse_action(json.dumps({k:v for k,v in a.items() if k not in ('usb','expect_msc')}))
 msc.parse_action(json.dumps({k:v for k,v in a.items() if k not in ('hid','pointer')}))
 if ('hid' in a and 'usb' in a) or ('expect_msc' in a and ('hid' in a or 'pointer' in a)):raise ValueError('Separate device and observer actions required')
 return a
def descriptor(device):
 d=msc.hid.descriptor(device);d['port']='3' if device=='keyboard' else '4';return d
async def operator(qmp,boot,completions):
 print('AWAITING_NT4_COMBO_OPERATOR <=450 encoded JSON bytes',flush=True);n=0;hot=False;present=dict(keyboard=True,mouse=True)
 while line:=await asyncio.to_thread(sys.stdin.readline):
  a=parse_action(line)
  if a.get('finish'):return
  future=completions.arm(a['expect_msc']) if 'expect_msc' in a else None
  if a.get('hid'):
   d=a['hid'];device=d['device'];insert=d['state']=='insert'
   if present[device]==insert:raise ValueError('Owned HID state mismatch')
   if insert:await qmp.command('device_add',descriptor(device))
   else:await qmp.delete_device(descriptor(device)['id'])
   present[device]=insert
  if a.get('usb'):
   if (a['usb']=='insert')==hot:raise ValueError('Owned hot MSC state mismatch')
   if hot:await qmp.delete_device('usability-hot')
   else:await qmp.command('device_add',msc.descriptor())
   hot=not hot
  for key in a.get('keys',[]):await qmp.key(key)
  if a.get('pointer'):
   p=a['pointer'];await qmp.command('input-send-event',dict(events=[dict(type='rel',data=dict(axis=axis,value=p.get('d'+axis,0))) for axis in ('x','y')]))
   if p.get('click'):
    for down in (True,False):
     await qmp.command('input-send-event',dict(events=[dict(type='btn',data=dict(down=down,button=p['click']))]));await asyncio.sleep(.1)
  if future is not None:
   status=await asyncio.wait_for(future,45);msc.publish_json(h.RUNTIME/('msc-'+a['expect_msc'].lower()+'-done.json'),dict(stage=a['expect_msc'],status=status,explicit_native_action=True))
  await asyncio.sleep(a.get('settle',2));n+=1;image='operator-%02d.png'%n;await boot.capture(qmp,h.RUNTIME/image)
  with (h.RUNTIME/'operator-actions.jsonl').open('a',encoding='utf-8') as f:f.write(json.dumps(dict(image=image,hid=a.get('hid'),pointer=a.get('pointer'),usb=a.get('usb'),expect_msc=a.get('expect_msc'),keys_count=len(a.get('keys',[])),settle=a.get('settle',2)))+'\n')
  print('STEP_COMPLETE '+image,flush=True)
 raise EOFError('Operator closed before explicit finish')
async def main():
 if not msc.hid.live_console():raise ValueError('Live Windows PTY required before QEMU')
 prep=h.read(h.OUT/'preparation.json')
 if not all(prep.get(k) for k in ('only_system_dword_changed','hive_binary_compare','independent_full_inventory_readback','sys_helper_marker_log_unchanged','media_initial_pins_identical_to_msc04','msc04_parent_unchanged','original03_parent_unchanged')) or prep['target_sha256']!=h.sha(h.WORK/'target.qcow2') or h.sha(h.BASE)!=h.BASE_SHA or h.sha(h.msc.BASE)!=h.msc.BASE_SHA:raise ValueError('Exact fresh prepared pins required')
 if prep['usb_sha256']!=h.USB or prep['helper_sha256']!=h.HELPER_SHA or prep['new_target_files'] or prep['topology']!=dict(boot=1,hot=2,keyboard=3,mouse=4):raise ValueError('Combined fixture changed')
 for kind in ('boot','hot'):
  if h.sha(h.WORK/('usb-test-'+kind+'.qcow2'))!=prep['test_media'][kind]['sha256']:raise ValueError('Own media changed')
 if h.RUNTIME.exists():raise FileExistsError('Never relaunch existing combined case')
 boot=load('nt4_combo_native_boot',h.MATRIX/'tools/tests/coverage/boot_menu.py')
 if h.sha(h.MATRIX/'tools/tests/coverage/usability_aux.py')!=prep['shared_aux_sha256']:raise ValueError('Pinned named backend changed')
 resources=boot.fixture.check_resources(h.WORK,2048) # one normal8GiB reserve, no retry
 h.RUNTIME.mkdir(parents=True);qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
 command=[str(h.QIMG.with_name('qemu-system-x86_64.exe')),'-name',h.WORK.name,'-machine','q35','-accel','tcg,thread=multi','-cpu','EPYC-Rome','-smp','2','-m','2048','-display','none','-serial','stdio','-monitor','none','-qmp',f'tcp:127.0.0.1:{server.sockets[0].getsockname()[1]},server=off',
  '-device','qemu-xhci,id=xhci','-device','usb-kbd,id=coveragekbd,bus=xhci.0,port=3','-device','usb-mouse,id=coveragepointer,bus=xhci.0,port=4',*boot.aux.network_arguments('igb'),
  '-drive',f'if=none,id=target,format=qcow2,file={(h.WORK/"target.qcow2").as_posix()}',
  '-device','ich9-ahci,id=coverageahci','-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0',
  *boot.aux.usb_block_arguments('boot',h.WORK/'usb-test-boot.qcow2'),*boot.aux.usb_block_arguments('hot',h.WORK/'usb-test-hot.qcow2'),
  '-device','usb-storage,id=usability-boot,bus=xhci.0,port=1,drive=usabilityboot,removable=true,serial=USOS-USB-BOOT-TEST']
 msc.publish_json(h.RUNTIME/'command.json',command);msc.publish_json(h.RUNTIME/'preflight.json',dict(resources=resources,preparation_sha256=h.sha(h.OUT/'preparation.json'),source_pins={str(p):h.sha(p) for p in (Path(__file__),HERE/'nt4_combo_fixture.py',HERE/'boot_nt4_msc.py',HERE/'boot_nt4_hid.py',HERE/'nt4_msc_fixture.py',HERE/'nt4_hid_fixture.py',h.MATRIX/'tools/tests/coverage/boot_menu.py',h.MATRIX/'tools/tests/coverage/usability_aux.py')}))
 process=None;pump=None;failure=None;shutdown=None;started=time.monotonic();completions=msc.Completions()
 try:
  env=dict(os.environ,TEMP=str(h.WORK),TMP=str(h.WORK),APPDATA=str(h.WORK),LOCALAPPDATA=str(h.WORK))
  with (h.RUNTIME/'serial.log').open('xb') as serial,(h.RUNTIME/'stderr.log').open('xb') as errors:
   process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env);print('NT4_COMBO_STARTED; one planned150s endpoint, no progress polling',flush=True)
   pump=asyncio.create_task(msc.consume(process,serial,completions));await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
   try:await asyncio.wait_for(process.wait(),150)
   except asyncio.TimeoutError:
    await boot.capture(qmp,h.RUNTIME/'endpoint.png');print('NT4_COMBO_ENDPOINT_COMPLETE',flush=True);await operator(qmp,boot,completions)
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
  msc.publish_json(h.RUNTIME/'result.json',dict(scope='Installed NT4 same frozen313952 HID+MSC; BIOS q35/AHCI, PS2 hardware present/driverStart4',resources=resources,elapsed=round(time.monotonic()-started,3),qemu_returncode=process.returncode if process else None,shutdown=shutdown,error=failure,i8042_hardware_present=True,i8042prt_start=4,usb_sha256=h.USB,helper_sha256=h.HELPER_SHA,msc04_parent_sha256=h.BASE_SHA,topology=prep['topology'],native_observer_completions=completions.results,lan_pass=False,hid_pass=False,msc_pass=False,combined_pass=False))
  msc.publish_json(h.RUNTIME/'completed.json',dict(stopped=True,retained=True));print('NT4_COMBO_COMPLETED',flush=True)
if __name__=='__main__':asyncio.run(main())
