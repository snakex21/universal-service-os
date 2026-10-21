"""One bounded native diagnostic boot; retains overlay, waits on own e9 init event."""
from pathlib import Path
import argparse,asyncio,hashlib,importlib.util,json,os,re,shutil,subprocess,time
ROOT=Path(__file__).resolve().parents[3]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
COLLECTION=Path(r'G:\USOS-Kolekcja')
WORK=COLLECTION/'_vm/r18d-nt351-debug-e9'
PARENT=COLLECTION/'_vm/r18c-nt351-cold-i8042-on'
OUT=ROOT/'artifacts/coverage/vm/r18d-nt351-debug-e9'
QEMU=Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-system-x86_64.exe')

def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

async def main(case):
 global WORK,PARENT,OUT
 if case=='r18e':
  WORK=COLLECTION/'_vm/r18e-nt351-stubfix-e9';PARENT=COLLECTION/'_vm/r18d-nt351-debug-e9';OUT=ROOT/'artifacts/coverage/vm/r18e-nt351-stubfix-e9'
 tag=WORK.name
 boot=load('owned_matrix_boot',MATRIX/'tools/tests/coverage/boot_menu.py')
 proof_path=ROOT/('artifacts/nt351-network/r18e-stubfix-preparation.json' if case=='r18e' else 'artifacts/nt351-network/r18d-debug-preparation.json')
 proof=json.loads(proof_path.read_text(encoding='utf-8'))
 if case=='r18e':boot.aux.require_operator_channel(True)
 meta=json.loads((WORK/'fixture.json').read_text(encoding='utf-8'))
 if meta.get('private_profile') is not False or meta.get('folder')!='Windows NT 3.51' or meta.get('debug_port')!=233:raise ValueError('Explicit keyless prepared diagnostic required')
 if proof.get('raw_overlay_qemu_compare_pass') is not True:raise ValueError('No verified stopped overlay')
 if case=='r18d' and proof.get('hive_only_one_dword_changed') is not True:raise ValueError('No verified single-DWORD preparation')
 if case=='r18e' and (proof.get('system_hive_unchanged') is not True or proof.get('only_own_sys_replaced') is not True):raise ValueError('Only own SYS replacement allowed')
 if OUT.exists() or (WORK/'vars.fd').exists() or (WORK/'stick.qcow2').exists():raise FileExistsError('Fresh run required')
 resources=boot.fixture.check_resources(WORK,2048)
 OUT.mkdir(parents=True);shutil.copyfile(PARENT/'vars.fd',WORK/'vars.fd')
 subprocess.run([str(QEMU.with_name('qemu-img.exe')),'create','-q','-f','qcow2',str(WORK/'stick.qcow2'),'10G'],check=True)
 init_done=asyncio.Event();debug_connected=asyncio.Event();debug_tasks=[];debug_writers=[];debug_lines=[];debug_bytes=0;debug_error=None
 debug_log=(OUT/'debugcon.log').open('wb')
 async def debug_client(reader,writer):
  nonlocal debug_bytes,debug_error
  debug_writers.append(writer);debug_tasks.append(asyncio.current_task());debug_connected.set()
  try:
   while raw:=await reader.readline():
    if len(raw)>1024:raise ValueError('Debug line bound exceeded')
    if debug_bytes+len(raw)<=65536:
     debug_log.write(raw);debug_log.flush();debug_bytes+=len(raw)
     text=raw.decode('ascii',errors='strict').rstrip('\r\n');debug_lines.append(text)
     if re.fullmatch(r'USOSNET (?:init failed|started) stage [0-9A-F]{8} status [0-9A-F]{8}',text):init_done.set()
    else:debug_error='Debug byte cap reached; subsequent bytes drained'
  except Exception as error:debug_error=type(error).__name__+': '+str(error)
  finally:writer.close()
 debug_server=await asyncio.start_server(debug_client,'127.0.0.1',0,limit=2048)
 qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
 cap=boot.nt351_capture.Capture(OUT/'network.pcap');process=None;pump=None;failure=None;trigger=None;started=time.monotonic();shutdown=None
 with (OUT/'serial.log').open('wb') as serial,(OUT/'stderr.log').open('wb') as errors:
  try:
   port=await cap.start();cap.mark_prepared_target()
   prior_tag='r18d-nt351-debug-e9' if case=='r18e' else 'r18c-nt351-cold-i8042-on'
   cmd=json.loads((ROOT/'artifacts/coverage/vm'/prior_tag/'command.json').read_text(encoding='utf-8'))
   if case=='r18e':
    pairs=list(zip(cmd[1::2],cmd[2::2]))
    pairs=[(opt,val) for opt,val in pairs if not (opt=='-chardev' and val.startswith('socket,id=nt351debug,')) and not (opt=='-device' and val.startswith('isa-debugcon,id=nt351debugcon,'))]
    cmd=[cmd[0],*(part for pair in pairs for part in pair)]
   if cmd[0]!=str(QEMU) or cmd[cmd.index('-machine')+1]!='q35,i8042=on' or cmd[cmd.index('-cpu')+1]!='EPYC-Rome':raise ValueError('Unexpected matched ON command')
   for i,v in enumerate(cmd):
    if PARENT.as_posix()+'/' in v:cmd[i]=v.replace(PARENT.as_posix()+'/',WORK.as_posix()+'/')
    if v.startswith('socket,id=nt351mirror,'):cmd[i]=f'socket,id=nt351mirror,host=127.0.0.1,port={port},server=off'
   cmd[cmd.index('-qmp')+1]=f'tcp:127.0.0.1:{server.sockets[0].getsockname()[1]},server=off'
   cmd+=['-chardev',f'socket,id=nt351debug,host=127.0.0.1,port={debug_server.sockets[0].getsockname()[1]},server=off','-device','isa-debugcon,id=nt351debugcon,chardev=nt351debug,iobase=0xe9']
   (OUT/'command.json').write_text(json.dumps(cmd,indent=2)+'\n',encoding='utf-8')
   env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
   process=await asyncio.create_subprocess_exec(*cmd,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env)
   print('DIAGNOSTIC_BOOT_STARTED '+tag,flush=True)
   async def consume():
    while data:=await process.stdout.read(65536):serial.write(data);serial.flush()
   pump=asyncio.create_task(consume())
   await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
   waiters=[asyncio.create_task(init_done.wait()),asyncio.create_task(process.wait())]
   done,pending=await asyncio.wait(waiters,timeout=300,return_when=asyncio.FIRST_COMPLETED)
   if init_done.is_set():
    trigger='own USOSNET Initialize terminal event';await asyncio.sleep(30)
   elif process.returncode is not None:trigger='process exited'
   else:trigger='single300second endpoint; no init terminal event'
   for task in pending:task.cancel()
   await asyncio.gather(*waiters,return_exceptions=True)
   if process.returncode is None:
    await boot.capture(qmp,OUT/'endpoint.png')
    if case=='r18e' and any(line.startswith('USOSNET started stage ') for line in debug_lines):
     print('ENDPOINT_COMPLETE '+tag,flush=True)
     await boot.operator_steps(qmp,OUT,False,True,'mouse')
  except Exception as error:failure=type(error).__name__+': '+str(error)
  finally:
   if process and process.returncode is None:
    cap.begin_controlled_shutdown()
    try:await asyncio.wait_for(qmp.command('quit'),3)
    except Exception:pass
    try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit after diagnostic endpoint'
    except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
   if pump:await pump
   capture=await cap.finish(controlled_shutdown=bool(process and process.returncode==0 and shutdown=='QMP quit after diagnostic endpoint')) if cap.server else None
   server.close();await server.wait_closed()
   if qmp.writer:
    qmp.writer.close()
    try:await qmp.writer.wait_closed()
    except (ConnectionResetError,OSError):pass
   debug_server.close()
   for writer in debug_writers:writer.close()
   if debug_tasks:await asyncio.wait_for(asyncio.gather(*debug_tasks,return_exceptions=True),5)
   await asyncio.wait_for(debug_server.wait_closed(),5);debug_log.close()
 result=dict(result='ASSESS_DIAGNOSTIC' if failure is None else 'RUNNER_ERROR',error=failure,elapsed=round(time.monotonic()-started,2),trigger=trigger,
  qemu_returncode=process.returncode if process else None,shutdown=shutdown,resources=resources,retained_overlay=str(WORK/'target.qcow2'),
  debug_port=233,debug_bytes=debug_bytes,debug_error=debug_error,debug_lines=debug_lines,network_capture=capture,
  installed_runtime_pass=False,usb_path_pass=False,scope='Own init diagnostics only; no test of DHCP/ICMP/DNS or HID')
 (OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
 (OUT/'completed.json').write_text(json.dumps({'stopped':True,'retained_overlay':True})+'\n',encoding='utf-8')
 print('CASE_COMPLETE '+tag,flush=True)
 return 0 if failure is None else 1
if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--case',choices=('r18d','r18e'),required=True)
 raise SystemExit(asyncio.run(main(parser.parse_args().case)))
