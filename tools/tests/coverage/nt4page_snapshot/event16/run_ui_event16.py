"""One event-only original NT4 UI callsite trace; never lpText/EDIT/frames."""
from pathlib import Path
import asyncio,hashlib,importlib.util,json,subprocess,time,sys
HERE=Path(__file__).resolve().parent;OUT=HERE/'ui-event16-runtime';WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-setup02-uievent16')
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
r=load('own_base_reader',HERE.parent/'read_candidate02_setup_metadata.py');d=load('own_base_boot',HERE.parent/'diagnose_candidate02_ram.py');rsp=load('own_event_adapter',HERE/'ui_event_rsp16.py')
def public_metadata(value):
 if not isinstance(value,dict) or set(value)-{'caller_enum','caller_module','caller_rva','ACK_authorized','metadata_enum','modules_checked','fs_base_available','resource_enum','resource_id'}:raise ValueError('Metadata output boundary')
 if value.get('ACK_authorized') is not False:raise ValueError('No ACK authorized')
 if 'caller_module' in value and not __import__('re').fullmatch(r'[A-Z0-9_]{1,32}\.(?:DLL|EXE|CPL)',value['caller_module']):raise ValueError('Public module name boundary')
 if 'caller_rva' in value and not __import__('re').fullmatch(r'0x[0-9a-f]{1,8}',value['caller_rva']):raise ValueError('Public RVA boundary')
 for key in ('caller_enum','metadata_enum'):
  if key in value and not __import__('re').fullmatch(r'[A-Z0-9_]{1,80}',value[key]):raise ValueError('Public enum boundary')
 if 'modules_checked' in value and (type(value['modules_checked']) is not int or not 0<=value['modules_checked']<=128):raise ValueError('Module count boundary')
 return value
async def main():
 if OUT.exists() or WORK.exists() or WORK.resolve()!=WORK:raise ValueError('Fresh exact own folders required')
 OUT.mkdir();WORK.mkdir();manifest_path=HERE/'original-ui-event-breakpoint-manifest-v5.json';manifest=json.loads(manifest_path.read_text(encoding='utf-8'));entries=manifest['api_entries'];client=rsp.Rsp(x['address'] for x in entries);qmp=d.boot.Qmp();qs=None;gs=None;proc=None;waiter=None;event_task=None;deadline=None;started=time.monotonic()
 result={'scope':'diagnostic_only, original Setup in preserved-target overlay; comparative pc/PS2/noNIC fixture, no desktop/LAN/HID/MSC assessment','owned_image':str(WORK/'target.qcow2'),'state':'PREFLIGHT','completed':False,'events':[],'operator_results':[],'ui_actions':0,'candidate_metadata_only_no_ACK':True,'private_frame_read':False,'text_pointer_read':False,'edit_read':False,'bulk_register_read':False,'ram_export':False,'manifest_sha256':hashlib.sha256(manifest_path.read_bytes()).hexdigest(),'adapter_sha256':hashlib.sha256((HERE/'ui_event_rsp16.py').read_bytes()).hexdigest()}
 def save(name,value):
  tmp=OUT/(name+'.tmp');tmp.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8');tmp.replace(OUT/name)
 try:
  old=json.loads((HERE/'ui-event15-runtime/result.json').read_text(encoding='utf-8'))
  if not old['completed'] or old['qemu_returncode']!=0:raise ValueError('Previous writer boundary')
  fs=r.Fat(r.MappedRead(r.TARGET));pins=[]
  try:
   for module in manifest['modules']:
    blob,unused=r.debug.file_data(fs,'WINNT/SYSTEM32/'+module['module'],8*1024**2);match=hashlib.sha256(blob).hexdigest()==module['sha256'];pins.append({'module':module['module'],'original_hash_matches':match})
  finally:fs.f.close()
  result['stopped_original_module_pins']=pins
  if not all(x['original_hash_matches'] for x in pins):raise ValueError('Original module pin mismatch')
  try:result['guard']=d.boot.fixture.check_resources(WORK,512)
  except Exception as error:result.update(state='NORMAL_GUARD_REJECTED',error_class=type(error).__name__,vm_launched=False);return
  subprocess.run([str(r.QIMG),'create','-f','qcow2','-F','qcow2','-b',str(r.TARGET),str(WORK/'target.qcow2')],check=True,capture_output=True)
  qs=await asyncio.start_server(qmp.accept,'127.0.0.1',0);gs=await asyncio.start_server(client.accept,'127.0.0.1',0);qp=qs.sockets[0].getsockname()[1];gp=gs.sockets[0].getsockname()[1]
  argv=[str(d.QEMU),'-name','nt4-setup02-uievent16','-nodefaults','-machine','pc','-accel','tcg,tb-size=128','-cpu','pentium3','-smp','1','-m','512','-rtc','base=localtime','-vga','std','-display','none','-nic','none','-no-reboot','-drive',f'file={WORK/"target.qcow2"},format=qcow2,if=ide,index=0,media=disk,cache=writeback','-boot','order=c','-serial','none','-monitor','none','-chardev',f'socket,id=gdb0,host=127.0.0.1,port={gp},server=off','-gdb','chardev:gdb0','-S','-qmp',f'tcp:127.0.0.1:{qp},server=off']
  result['argv']=argv;save('launch.json',result);proc=await asyncio.create_subprocess_exec(*argv,stdout=asyncio.subprocess.DEVNULL,stderr=asyncio.subprocess.PIPE,creationflags=subprocess.CREATE_NO_WINDOW);waiter=asyncio.create_task(proc.wait());result['vm_launched']=True;await qmp.command('qmp_capabilities');await asyncio.wait_for(client.ready.wait(),10);await asyncio.wait_for(client.features(),10)
  for entry in entries:await client.breakpoint(entry['address'])
  result['fs_base_available']='fs_base' in client.regs
  result['state']='AWAITING_UI_EVENT';print('NT4_UIEVENT16_STARTED_EVENT_ONLY_NO_PROGRESS_READS',flush=True);deadline=asyncio.create_task(asyncio.sleep(150));policy=rsp.WordPolicy(entries,manifest['modules']);event_task=asyncio.create_task(client.resume())
  while True:
   done,unused=await asyncio.wait((waiter,event_task,deadline),return_when=asyncio.FIRST_COMPLETED)
   if waiter in done:result['state']='VM_EXITED';break
   if deadline in done:result['state']='FIXED_EVENT_ENDPOINT';break
   await event_task;address,event=await policy.event(client);result['events'].append(event)
   if event['api_enum']=='MessageBoxW':
    deadline.cancel();result['state']='PAUSED_MESSAGEBOX_ENDPOINT';result['operator_results'].append(public_metadata(policy.relocated_candidate()));save('paused.json',result);print('NT4_UIEVENT16_PAUSED_MESSAGEBOX_ENDPOINT',flush=True)
    while True:
     command=(await asyncio.to_thread(sys.stdin.readline)).strip()
     if command in ('FINISH',''):result['state']='OPERATOR_FINISHED';break
     if command=='LOW16':value=policy.relocated_candidate()
     elif command=='MODULES':
      try:
       extension=load('own_public_module_reader',HERE/'ui_event_modules.py');value=await extension.inspect(client,policy._paused_context,manifest)
      except Exception as error:value={'metadata_enum':'METADATA_READER_UNAVAILABLE_OR_REJECTED','ACK_authorized':False}
     else:print('OPERATOR_COMMAND_REJECTED',flush=True);continue
     value=public_metadata(value);result['operator_results'].append(value);save('operator-'+str(len(result['operator_results']))+'.json',value);print(json.dumps(value,sort_keys=True),flush=True)
    break
   if len(result['events'])>=128:result['state']='EVENT_COUNT_BOUND';break
   await client.breakpoint(address,False);await asyncio.wait_for(client.resume(step=True),10);await client.breakpoint(address);event_task=asyncio.create_task(client.resume())
 except Exception as error:result.update(state='ADAPTER_OR_PREFLIGHT_ERROR',error_class=type(error).__name__)
 finally:
  if deadline:deadline.cancel()
  if event_task and not event_task.done():event_task.cancel()
  if waiter and not waiter.done():
   try:await qmp.command('quit')
   except Exception:proc.terminate()
   try:await asyncio.wait_for(waiter,20)
   except asyncio.TimeoutError:proc.kill();await waiter
  if client.writer:client.writer.close()
  for server in (qs,gs):
   if server:server.close();await server.wait_closed()
  result.update(completed=True,elapsed_seconds=round(time.monotonic()-started,3),qemu_returncode=proc.returncode if proc else None,qemu_stderr_present=bool(await proc.stderr.read()) if proc else False)
  save('result.json',result);print('NT4_UIEVENT16_COMPLETE '+result['state'],flush=True)
if __name__=='__main__':asyncio.run(main())
