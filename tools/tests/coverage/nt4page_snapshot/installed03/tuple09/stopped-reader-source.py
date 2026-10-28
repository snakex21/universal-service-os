"""Selected stopped09 tuple facts and own MSC fixture contents only."""
from pathlib import Path
import hashlib,importlib.util,json
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('tuple09_stopped_inputs',HERE/'prepare_candidate09_tuple.py');p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
OUT=p.ROOT/'artifacts/coverage/vm'/p.WORK.name;DEST=HERE/'candidate09-tuple-stopped-readback.json'
def main():
 result=json.loads((OUT/'result.json').read_text(encoding='utf-8'))
 if result['error'] or result['qemu_returncode']!=0 or result['shutdown']!='QMP quit' or not (OUT/'completed.json').is_file():raise ValueError('Completed writer boundary required')
 if result['native_observer_completions']!={'STARTUP':0,'HOT':0,'REPLUG':0} or not result['first_logon_observed']:raise ValueError('Three actual fresh MSC completions and actual NET token required')
 if DEST.exists():raise FileExistsError('Preserve first stopped evidence')
 raw=p.WORK/'stopped.raw';target=p.WORK/'target.qcow2';pin=p.sha(target);report={}
 try:
  p.run('convert','-f','qcow2','-O','raw',target,raw);_,_,_,report=p.inspect(raw,4,True)
  fs=p.msc.Fat(raw)
  try:
   log,_=p.h.file_data(fs,'USOS/NT4/MSC4LOG.TXT',16384);status,_=p.h.file_data(fs,'USOS/COVERAGE/OBSERVER.STATUS',128)
   if status!=b'NT4_OBSERVER_STATUS=TESTNET_DONE\r\n':raise ValueError('Actual completed NET helper status required')
   if not all(c in (10,13) or 32<=c<127 for c in log) or log.count(b'MSC4_PASS')!=3 or log.count(b'ROUNDTRIP_WRITE_FLUSH_CLOSE_PASS')!=1 or log.count(b'ROUNDTRIP_READBACK_PASS')!=2:raise ValueError('Fresh own three-stage MSC log required')
   (HERE/'candidate09-own-MSC4LOG.TXT').write_bytes(log)
   report.update(observer_status='TESTNET_DONE',own_msc_log_sha256=hashlib.sha256(log).hexdigest(),own_msc_log_bytes=len(log),fresh_msc_pass_count=3,roundtrip_write_flush_close_pass_count=1,roundtrip_readback_pass_count=2)
  finally:fs.f.close()
 finally:
  if raw.exists():p.remove(raw)
 report['own_usb']={}
 for kind in ('boot','hot'):
  disk=p.WORK/('usb-test-'+kind+'.qcow2');raw=p.WORK/('stopped-'+kind+'.raw')
  try:p.run('convert','-f','qcow2','-O','raw',disk,raw);report['own_usb'][kind]=dict(sha256=p.sha(disk),**p.msc.inspect_media(raw,kind,kind=='hot'))
  finally:
   if raw.exists():p.remove(raw)
 if p.sha(p.BASE)!=p.BASE_SHA or p.sha(target)!=pin:raise ValueError('Readonly/base boundary changed')
 report.update(closed_target_sha256=pin,base08_sha256=p.BASE_SHA,base08_unchanged=True,qemu_returncode=0,native_observer_completions=result['native_observer_completions'],actual_first_logon_token=result['first_logon_observed'],raw_scratch_removed=True,ms_bytes_exported=False)
 DEST.write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n');print(json.dumps(report,indent=2),flush=True)
if __name__=='__main__':main()
