"""Recover only hash-bound completed R17 transport; never boot or read active VM."""
from pathlib import Path
import base64,hashlib,importlib.util,io,json,re,tarfile
ROOT=Path(__file__).resolve().parents[2];MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
SERIAL=Path(r'G:\USOS-Kolekcja\_vm\r17-nt351-wks-diag\read-logs-mtools\1024-qemu64-evidence\serial.log')
SERIAL_SHA='64104d524077568695a340d0a98218888fadcf212f93d9a27ba5e48cae7c0597'
PAYLOAD_SHA='5e6ba4f5932be7a6473669d89da903f8a8b6de013098cbbc3c3be6b7196c3252'
PATCHES={910:('suffix','ho COVER'),1092:('suffix','AGE_EVID'),1316:('suffix','ENCE_END'),1574:('line','cd /'),1576:('prefix','ec'),1774:('suffix','ho LOWRA'),1972:('suffix','M-RESULT'),2204:('suffix','=PASS'),2206:('line','po'),2414:('suffix','weroff -'),2588:('suffix','f')}
ALLOWED={'runs.txt',*(f'run-{run}/{leaf}' for run in (1,2) for leaf in ('command.txt','qemu.log','serial.log','seabios.log','monitor.log','screen.ppm'))}
def strip_observed(line,kind,part):
 if kind=='line':
  if line!=part:raise ValueError('Changed standalone historical echo')
  return ''
 if len(line)!=76+len(part):raise ValueError('Changed historical echo length')
 if kind=='suffix' and line.endswith(part):value=line[:-len(part)]
 elif kind=='prefix' and line.startswith(part):value=line[len(part):]
 else:raise ValueError('Changed historical echo content')
 if not re.fullmatch('[A-Za-z0-9+/]{76}',value):raise ValueError('Historical complete base64 line changed')
 return value
def recover(raw):
 if hashlib.sha256(raw).hexdigest()!=SERIAL_SHA:raise ValueError('Only exact completed historical R17 serial accepted')
 lines=raw.decode('utf-8',errors='strict').splitlines();begins=[i for i,l in enumerate(lines) if l=='COVERAGE_EVIDENCE_BEGIN'];ends=[i for i,l in enumerate(lines) if l=='COVERAGE_EVIDENCE_END']
 if begins!=[719] or ends!=[2747]:raise ValueError('Historical boundary changed')
 values=[];seen=[];echoes=[]
 for no in range(begins[0]+2,ends[0]+1):
  line=lines[no-1]
  if no in PATCHES:line=strip_observed(line,*PATCHES[no]);seen.append(no)
  if not line:continue
  if line in ('/tmp/export/nt4 # base64 /tmp/evidence.tgz','/tmp/export/nt4 # echo COVERAGE_EVIDENCE_END'):echoes.append((no,line));continue
  if not re.fullmatch('[A-Za-z0-9+/=]{1,76}',line):raise ValueError('Unknown historical payload line')
  values.append(line)
 if seen!=list(PATCHES) or [v[0] for v in echoes]!=[722,2746]:raise ValueError('Historical command echo order changed')
 encoded=''.join(values);payload=base64.b64decode(encoded,validate=True)
 if base64.b64encode(payload).decode()!=encoded or hashlib.sha256(payload).hexdigest()!=PAYLOAD_SHA:raise ValueError('Canonical complete historical archive differs')
 return payload
def main():
 out=ROOT/'artifacts/coverage/r17-historical-recovery'
 if out.exists():raise FileExistsError('Fresh owned recovery output required')
 completed=json.loads((MATRIX/'artifacts/coverage/vm/r17-nt351-wks-diag/cleanup.json').read_text());assert completed.get('removed')
 payload=recover(SERIAL.read_bytes());policy_path=MATRIX/'tools/tests/coverage/evidence_archive.py';spec=importlib.util.spec_from_file_location('r17_archive_policy',policy_path);policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy);plain=policy.single_gzip(payload,32*1024**2);records={}
 with tarfile.open(fileobj=io.BytesIO(plain),mode='r:') as archive:
  for member in archive:
   name=member.name.removeprefix('./')
   if not member.isfile() or name not in ALLOWED or name in records or not 0<=member.size<=8*1024**2:raise ValueError('Unexpected historical archive member')
   data=archive.extractfile(member).read(8*1024**2+1)
   if len(data)!=member.size:raise ValueError('Historical file bound mismatch')
   if name.endswith('.ppm'):
    from PIL import Image
    with Image.open(io.BytesIO(data)) as frame:
     if frame.width*frame.height>2000000:raise ValueError('Historical screen pixel bound')
     saved=io.BytesIO();frame.save(saved,format='PNG');data=saved.getvalue();name=name[:-4]+'.png'
   else:
    if b'\0' in data:raise ValueError('Nontext historical log')
    data=data.decode('utf-8',errors='strict').replace('\r\n','\n').encode('utf-8')
   records[name]=data
  policy.tar_end(plain,archive.offset)
 if len(records)!=len(ALLOWED):raise ValueError('Incomplete historical archive')
 out.mkdir(parents=True)
 for name,data in records.items():
  target=out/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data)
 report={'scope':'Completed failed R17 only; not runtime PASS','source_serial':str(SERIAL),'serial_sha256':SERIAL_SHA,'payload_sha256':PAYLOAD_SHA,'payload_bytes':len(payload),'gzip_crc_single_stream_tar_end_verified':True,'exact_observed_fragments':[{"line":line,"kind":v[0],"text":v[1]} for line,v in PATCHES.items()],'archive_policy_sha256':hashlib.sha256(policy_path.read_bytes()).hexdigest(),'historical_failure_evidence_error_retained':'ValueError: Unexpected evidence transport line','new_vm_started':False,'files':sorted(records)}
 (out/'recovery.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8');print(json.dumps(report,indent=2))
if __name__=='__main__':main()
