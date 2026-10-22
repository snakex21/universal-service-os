"""One guarded tuple09 runtime; reuse frozen combo operator and MSC observer."""
from pathlib import Path
import asyncio,hashlib,importlib.util,json,os,re,time
HERE=Path(__file__).resolve().parent;OWN=HERE.parents[1];MATRIX=OWN.parent/'macierz-windows';OTHER=OWN.parent/'nt4-usb-hid'
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed08-usbmsc-hid-net09');OUT=OWN/'artifacts/coverage/vm'/WORK.name
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
combo=load('nt4_tuple_existing_operator',OTHER/'tools/tests/coverage/boot_nt4_combo.py');msc=combo.msc
class TokenMux:
 """One serial consumer, exact actual NET token plus armed MSC completions."""
 def __init__(self,completions,token,callback):self.completions=completions;self.token=token.encode('ascii');self.callback=callback;self.seen=False
 def line(self,line):
  self.completions.line(line)
  if len(line)<=128 and line.strip(b'\r\n')==self.token and not self.seen:self.seen=True;self.callback()
async def main():
 if not msc.hid.live_console():raise ValueError('Live PTY required before resource guard')
 fixture=load('tuple09_prepared',HERE/'prepare_candidate09_tuple.py');prep=json.loads((HERE/'candidate09-tuple-preparation.json').read_text(encoding='utf-8'))
 if not all(prep.get(k) for k in ('prepared','hive_binary_compare','all_unrelated_virtual_disk_bytes_identical','independent_full_inventory_readback','base_unchanged','raw_scratch_removed')):raise ValueError('Full prepared proof required')
 if prep['target_sha256']!=fixture.sha(WORK/'target.qcow2') or fixture.sha(fixture.BASE)!=fixture.BASE_SHA:raise ValueError('Exact prepared target/immutable08 required')
 if (OUT/'guard-attempted.json').exists() or (OUT/'command.json').exists():raise ValueError('Single guard/launch only')
 meta=json.loads((WORK/'prepared-fixture.json').read_text(encoding='utf-8'));token=meta['observer_token']
 if not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token):raise ValueError('Exact own NET token')
 policy=load('tuple09_network_pins',OWN/'tools/tests/coverage/nt4page_snapshot/installed03/network08_policy.py');c=policy.collector()
 c.validate(meta,WORK,Path(r'G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt4-hid13-netdns-utc-ipfix'),MATRIX/'artifacts/coverage/nt4-installed09-network-excerpt',Path(r'G:\USOS-Kolekcja'),MATRIX,preflight=True)
 for kind in ('boot','hot'):
  if fixture.sha(WORK/('usb-test-'+kind+'.qcow2'))!=prep['test_media'][kind]['sha256']:raise ValueError('Fresh exact named media required')
 boot=load('tuple09_native_boot',MATRIX/'tools/tests/coverage/boot_menu.py')
 if fixture.sha(MATRIX/'tools/tests/coverage/usability_aux.py')!=prep['shared_aux_sha256']:raise ValueError('Named backend source changed')
 OUT.mkdir(parents=True,exist_ok=True);msc.publish_json(OUT/'guard-attempted.json',{'attempted':True})
 resources=boot.fixture.check_resources(WORK,2048) # one normal8GiB reserve, no retries
 qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0);cap=boot.nt4_capture.Capture(OUT/'network.pcap');port=await cap.start()
 command=[str(fixture.h.QIMG.with_name('qemu-system-x86_64.exe')),'-name',WORK.name,'-machine','q35','-accel','tcg,thread=multi','-cpu','EPYC-Rome','-smp','2','-m','2048','-display','none','-serial','stdio','-monitor','none','-qmp',f'tcp:127.0.0.1:{server.sockets[0].getsockname()[1]},server=off',
  '-device','qemu-xhci,id=xhci','-device','usb-kbd,id=coveragekbd,bus=xhci.0,port=3','-device','usb-mouse,id=coveragepointer,bus=xhci.0,port=4',*boot.aux.network_arguments('igb'),
  '-drive',f'if=none,id=target,format=qcow2,file={(WORK/"target.qcow2").as_posix()}',
  '-device','ich9-ahci,id=coverageahci','-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0',
  *boot.aux.usb_block_arguments('boot',WORK/'usb-test-boot.qcow2'),*boot.aux.usb_block_arguments('hot',WORK/'usb-test-hot.qcow2'),
  '-device','usb-storage,id=usability-boot,bus=xhci.0,port=1,drive=usabilityboot,removable=true,serial=USOS-USB-BOOT-TEST',*boot.nt4_capture.arguments(port)]
 msc.publish_json(OUT/'command.json',command);sources=[Path(__file__),Path(fixture.__file__),Path(combo.__file__),Path(msc.__file__),Path(msc.hid.__file__),Path(combo.h.__file__),Path(combo.h.msc.__file__),Path(combo.h.msc.h.__file__),Path(policy.__file__),MATRIX/'tools/tests/coverage/boot_menu.py',MATRIX/'tools/tests/coverage/usability_aux.py',MATRIX/'tools/tests/coverage/nt4_capture.py']
 msc.publish_json(OUT/'preflight.json',dict(resources=resources,preparation_sha256=fixture.sha(HERE/'candidate09-tuple-preparation.json'),source_pins={str(p):fixture.sha(p) for p in sources},usb_sha256=fixture.USB,msc_helper_sha256=fixture.HELPER_SHA,network_sha256=policy.DRIVER,network_bytes=policy.DRIVER_BYTES,topology=prep['topology']))
 meta.update(result={'result':'PASS'},preserved_base=str(fixture.BASE),base_sha256=fixture.BASE_SHA);(WORK/'fixture.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8',newline='\n')
 combo.h.RUNTIME=OUT # RAM-only context for the unchanged completed operator
 process=None;pump=None;failure=None;shutdown=None;started=time.monotonic();completions=msc.Completions()
 serial=(OUT/'serial.log').open('xb');errors=(OUT/'stderr.log').open('xb')
 def first_logon():
  cap.mark_first_logon();msc.publish_json(OUT/'first-logon.json',{'actual_first_logon_token':True});print('NT4_TUPLE09_ACTUAL_FIRST_LOGON',flush=True)
 mux=TokenMux(completions,token,first_logon)
 try:
  env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK))
  process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env);print('NT4_TUPLE09_STARTED; one fixed150s endpoint, no progress polling',flush=True)
  pump=asyncio.create_task(msc.consume(process,serial,mux));await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
  try:await asyncio.wait_for(process.wait(),150)
  except asyncio.TimeoutError:
   await boot.capture(qmp,OUT/'endpoint.png');print('NT4_TUPLE09_ENDPOINT_COMPLETE',flush=True);await combo.operator(qmp,boot,completions)
 except Exception as e:failure=type(e).__name__+': '+str(e)
 finally:
  if process and process.returncode is None:
   cap.begin_controlled_shutdown()
   try:await asyncio.wait_for(qmp.command('quit'),3)
   except Exception:pass
   try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
   except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
  if pump:
   try:await pump
   except Exception as e:failure=failure or type(e).__name__+': '+str(e)
  serial.close();errors.close();capture=await cap.finish(controlled_shutdown=bool(process and process.returncode==0 and shutdown=='QMP quit'))
  server.close();await server.wait_closed()
  if qmp.writer:
   qmp.writer.close()
   try:await qmp.writer.wait_closed()
   except OSError:pass
  msc.publish_json(OUT/'result.json',dict(scope='One frozen USB313952 isolated HID+MSC plus NET89b/Start2 installed coexistence; no fresh AUTO/X470 or full IRQroute qualification',resources=resources,elapsed=round(time.monotonic()-started,3),qemu_returncode=process.returncode if process else None,shutdown=shutdown,error=failure,base_sha256=fixture.BASE_SHA,retained_target=str(WORK/'target.qcow2'),first_logon_observed=cap.first_logon_observed,network_capture=capture,native_observer_completions=completions.results,usb_sha256=fixture.USB,msc_helper_sha256=fixture.HELPER_SHA,network_sha256=policy.DRIVER,i8042prt_start=4,ndisloop_start=2,topology=prep['topology'],lan_pass=False,hid_pass=False,msc_pass=False,combined_pass=False))
  msc.publish_json(OUT/'completed.json',dict(stopped=True,retained=True));print('NT4_TUPLE09_COMPLETED',flush=True)
if __name__=='__main__':asyncio.run(main())
