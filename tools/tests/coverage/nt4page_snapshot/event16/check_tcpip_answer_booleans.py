"""Immutable stopped fixture: exact TCP/IP section only; export flags, never values."""
from pathlib import Path
import importlib.util,json,ipaddress
HERE=Path(__file__).resolve().parent;s=importlib.util.spec_from_file_location('own_stopped_base',HERE.parent/'read_candidate02_setup_metadata.py');r=importlib.util.module_from_spec(s);s.loader.exec_module(r)
NAMES=('IPAddress','Subnet','Gateway','DNSServer','WINSPrimary','WINSSecondary','DNSName','ScopeID','DHCP')
def fields(data):
 text=data.decode('utf-16') if data.startswith((b'\xff\xfe',b'\xfe\xff')) else data.decode('cp1250');section='';out={};dupes=[]
 for line in text.splitlines():
  line=line.strip()
  if not line or line.startswith((';','#')):continue
  if line.startswith('[') and line.endswith(']'):section=line[1:-1].casefold();continue
  if section!='usos.tcpip' or '=' not in line:continue
  key,value=line.split('=',1);key=key.strip().casefold()
  if key not in {n.casefold() for n in NAMES}:continue
  if key in out:dupes.append(key)
  out[key]=value.strip().strip('"')
 return out,dupes
def valid(value):
 try:ipaddress.IPv4Address(value);return True
 except ipaddress.AddressValueError:return False
def main():
 fs=r.Fat(r.MappedRead(r.TARGET));records=[];values=[]
 try:
  for path in ('WINNT.SIF','$WIN_NT$.~BT/WINNT.SIF','WINNT/SYSTEM32/$WINNT$.INF'):
   blob,unused=r.debug.file_data(fs,path,1024**2);fields_,dupes=fields(blob);values.append(fields_);rows=[]
   for name in NAMES:
    value=fields_.get(name.casefold(),'');rows.append({'name':name,'present':name.casefold() in fields_,'nonempty':bool(value),'valid_ipv4_syntax':valid(value) if value and name not in ('DNSName','ScopeID','DHCP') else None,'is_expected_staging_ipv4':value=='192.0.2.1' if name=='IPAddress' else value=='255.255.255.0' if name=='Subnet' else None})
   records.append({'path':path,'section_present':bool(fields_),'duplicates_present':bool(dupes),'dhcp_yes':fields_.get('dhcp','').casefold()=='yes','dhcp_no':fields_.get('dhcp','').casefold()=='no','fields':rows})
 finally:fs.f.close()
 result={'scope':'Stopped immutable base TCP/IP answer flags only; no user/key/network values','records':records,'all_three_tcpip_sections_identical':all(x==values[0] for x in values)}
 (HERE/'base-tcpip-answer-booleans.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n');print(json.dumps(result,indent=2))
if __name__=='__main__':main()
