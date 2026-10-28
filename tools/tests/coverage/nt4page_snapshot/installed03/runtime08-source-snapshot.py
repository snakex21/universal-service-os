"""Retained installed NT4, q35/igb/AHCI; one guarded native BIOS cold boot."""
from pathlib import Path
import asyncio,hashlib,importlib.util,json,os,re,subprocess,time
HERE=Path(__file__).resolve().parent
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
OWN=Path(r'C:\Users\ASRock\usos-work\nt4-net')
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed07-canonical-irq08')
OUT=OWN/'artifacts/coverage/vm/nt4-installed07-canonical-irq08'
QEMU=Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-system-x86_64.exe')
def load(name,path):
 s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def token_boundary(line,token):
 return len(line)<=128 and line.strip(b'\r\n')==token.encode('ascii')
async def main():
 boot=load('own_matrix_native_boot',MATRIX/'tools/tests/coverage/boot_menu.py');boot.aux.require_operator_channel(True)
 prep=json.loads((HERE/'candidate08-irq-preparation.json').read_text(encoding='utf-8'))
 if not prep.get('system_unchanged') or not prep.get('all_other_virtual_disk_bytes_identical') or not prep.get('full_raw_overlay_compare') or prep['overlay']!=str(WORK/'target.qcow2'):raise ValueError('Prepared overlay proof required')
 if (OUT/'command.json').exists() or (OUT/'result.json').exists():raise ValueError('No repeated launch')
 source=MATRIX/'artifacts/coverage/vm/nt4-sp6a-desktop-net-ps2-candidate03'
 meta=json.loads((WORK/'prepared-fixture.json').read_text(encoding='utf-8'));token=meta['observer_token']
 if not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token):raise ValueError('Exact existing own token')
 with Path(prep['base']).open('rb') as f:
  if hashlib.file_digest(f,'sha256').hexdigest()!=prep['base_sha256']:raise ValueError('Immutable base changed')
 OUT.mkdir(parents=True,exist_ok=True)
 trace=load('own_irq08_passive',OWN/'tools/tests/coverage/nt4page_snapshot/installed03/irq08_trace.py');policy=load('own_irq08_policy',OWN/'tools/tests/coverage/nt4page_snapshot/installed03/network08_policy.py')
 policy.collector().validate(meta,WORK,Path(r'G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt4-hid13-netdns-utc-ipfix'),MATRIX/'artifacts/coverage/nt4-installed08-network-excerpt',Path(r'G:\USOS-Kolekcja'),MATRIX,preflight=True)
 if (OUT/'guard-attempted.json').exists():raise ValueError('One normal resource guard only')
 (OUT/'guard-attempted.json').write_text('{"attempted":true}\n',encoding='utf-8')
 subprocess.run([str(QEMU.with_name('qemu-img.exe')),'create','-q','-f','qcow2',str(WORK/'blank-stick.qcow2'),'10G'],check=True)
 resources=boot.fixture.check_resources(WORK,2048) # exactly one normal guard; no retry
 tracefile=OUT/'trace-events.txt';tracefile.write_text('\n'.join(trace.EVENTS)+'\n',encoding='ascii')
 qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
 cap=boot.nt4_capture.Capture(OUT/'network.pcap');port=await cap.start()
 command=[str(QEMU),'-name','nt4-installed07-canonical-irq08','-machine','q35','-accel','tcg,thread=multi','-cpu','EPYC-Rome','-smp','2','-m','2048','-display','none','-serial','stdio','-monitor','none','-trace','events='+str(tracefile),'-qmp',f'tcp:127.0.0.1:{server.sockets[0].getsockname()[1]},server=off',
 '-device','qemu-xhci,id=xhci','-netdev','user,id=usabilitynet,hostname=usos-test','-device','igb,netdev=usabilitynet,mac=52:54:00:55:53:01',
 '-drive',f'if=none,id=stick,format=qcow2,file={(WORK/"blank-stick.qcow2").as_posix()}','-device','usb-storage,id=coverage-install-stick,bus=xhci.0,drive=stick,removable=on,serial=USOS-COVERAGE-STICK,bootindex=1',
 '-drive',f'if=none,id=target,format=qcow2,file={(WORK/"target.qcow2").as_posix()}','-device','ich9-ahci,id=coverageahci','-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0',*boot.nt4_capture.arguments(port)]
 (OUT/'command.json').write_text(json.dumps(command,indent=2)+'\n',encoding='utf-8')
 meta.update(preserved_base=prep['base'],base_sha256=prep['base_sha256'],result={'result':'PASS'})
 (WORK/'fixture.json').write_text(json.dumps(meta,indent=2)+'\n',encoding='utf-8')
 process=None;pump=None;tracepump=None;failure=None;shutdown=None;started=time.monotonic();filtered=trace.Filter();trace_error=None;selected=None;stderr_bytes=0
 tracehandle=(OUT/'irq-events.jsonl').open('x',encoding='ascii',newline='\n')
 def trace_event(line):
  encoded=filtered.event(line,time.monotonic_ns())
  if encoded:tracehandle.write(encoded);tracehandle.flush()
 (OUT/'instrumentation.json').write_text(json.dumps({'runtime_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),'policy_sha256':hashlib.sha256(Path(policy.__file__).read_bytes()).hexdigest(),'trace_policy_sha256':hashlib.sha256(Path(trace.__file__).read_bytes()).hexdigest(),'driver_sha256':policy.DRIVER,'driver_bytes':policy.DRIVER_BYTES,'active_mmio_reads':False,'pci_reads':1},indent=2)+'\n',encoding='utf-8')
 serial=(OUT/'serial.log').open('xb');errors=(OUT/'stderr.log').open('xb')
 try:
  env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK))
  process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE,env=env)
  async def consume_errors():
   nonlocal trace_error,stderr_bytes
   pending=b'';discarding=False
   while data:=await process.stderr.read(65536):
    for chunk in data.splitlines(keepends=True):
     if discarding:
      if chunk.endswith(b'\n'):discarding=False
      continue
     pending+=chunk
     if len(pending)>2049:
      filtered.dropped+=1;pending=b'';discarding=not chunk.endswith(b'\n');continue
     if not chunk.endswith(b'\n'):continue
     raw=pending.rstrip(b'\r\n');pending=b''
     try:line=raw.decode('ascii')
     except UnicodeDecodeError:filtered.dropped+=1;continue
     if line.split(' ',1)[0] in trace.EVENTS:trace_event(line)
     elif stderr_bytes+len(raw)+1<=4096:
      errors.write(raw+b'\n');errors.flush();stderr_bytes+=len(raw)+1
   if pending or discarding:trace_error='INCOMPLETE_STDERR_LINE'
  tracepump=asyncio.create_task(consume_errors())
  print('NT4_IRQ08_STARTED; one fixed 150s endpoint, no progress polling',flush=True)
  async def consume():
   pending=b''
   while data:=await process.stdout.read(65536):
    serial.write(data);serial.flush();pending+=data
    while b'\n' in pending:
     line,pending=pending.split(b'\n',1)
     if token_boundary(line,token) and not cap.first_logon_observed:
      cap.mark_first_logon();trace_event('OWN_ACTUAL_FIRST_LOGON_BOUNDARY');(OUT/'first-logon.json').write_text('{"actual_first_logon_token":true}\n',encoding='utf-8');print('NT4_ACTUAL_FIRST_LOGON_TOKEN',flush=True)
    if len(pending)>4096:pending=b''
  pump=asyncio.create_task(consume())
  await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
  try:await asyncio.wait_for(process.wait(),150)
  except asyncio.TimeoutError:
   try:
    selected=filtered.select(await qmp.command('query-pci'))
    (OUT/'pci-irq-boundary.json').write_text(json.dumps({'selected':selected,'monotonic_ns':time.monotonic_ns(),'scope':'one bounded query-pci, no MMIO read'},indent=2)+'\n',encoding='utf-8')
   except Exception as e:
    trace_error='PCI_BOUNDARY_'+type(e).__name__
    (OUT/'pci-irq-boundary.json').write_text(json.dumps({'error':trace_error})+'\n',encoding='utf-8')
   await boot.capture(qmp,OUT/'endpoint.png');print('NT4_IRQ08_ENDPOINT_COMPLETE',flush=True)
   await boot.operator_steps(qmp,OUT,False,False,'mouse');await boot.capture(qmp,OUT/'final.png')
 except Exception as error:failure=type(error).__name__+': '+str(error)
 finally:
  if process and process.returncode is None:
   cap.begin_controlled_shutdown()
   try:await asyncio.wait_for(qmp.command('quit'),3)
   except Exception:pass
   try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
   except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
  if pump:await pump
  if tracepump:await tracepump
  serial.close();errors.close();tracehandle.close()
  records=[json.loads(line) for line in (OUT/'irq-events.jsonl').read_text(encoding='ascii').splitlines()]
  trace_assessment=trace.assess(records,selected['irq'] if selected else None,filtered.dropped,trace_error)
  trace_assessment['before_pci_pic_events_drained']=filtered.before_pci_dropped
  (OUT/'irq-assessment.json').write_text(json.dumps(trace_assessment,indent=2)+'\n',encoding='utf-8')
  capture=await cap.finish(controlled_shutdown=bool(process and process.returncode==0 and shutdown=='QMP quit'))
  server.close();await server.wait_closed()
  if qmp.writer:
   qmp.writer.close()
   try:await qmp.writer.wait_closed()
   except OSError:pass
  result={'scope':'Installed08 new own canonical IRQ SYS only versus completed LAN07; native BIOS q35/igb/AHCI, PS2 allowed; passive trace, separate LAN collector. Not fresh installation or HID/MSC qualification.',
    'resources':resources,'elapsed':round(time.monotonic()-started,3),'qemu_returncode':process.returncode if process else None,'shutdown':shutdown,'error':failure,'base_sha256':prep['base_sha256'],'network_capture':capture,'first_logon_observed':cap.first_logon_observed,'retained_target':str(WORK/'target.qcow2'),'irq_assessment':trace_assessment,'lan_pass':False,'hid_pass':False,'msc_pass':False}
  (OUT/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
  (OUT/'completed.json').write_text('{"stopped":true,"retained":true}\n',encoding='utf-8');print('NT4_IRQ08_COMPLETED',flush=True)
if __name__=='__main__':asyncio.run(main())
