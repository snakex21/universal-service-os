"""One explicit new installed07 qualification, strict original collector gates."""
from pathlib import Path
import asyncio,hashlib,importlib.util,json,types
ROOT=Path(r'C:\Users\ASRock\usos-work\nt4-net');MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
WORK=Path(r'G:\USOS-Kolekcja\_vm\nt4-installed08-usbmsc-hid-net09');SOURCE=ROOT/'artifacts/coverage/vm/nt4-installed08-usbmsc-hid-net09'
def policy():
 path=ROOT/'tools/tests/coverage/nt4page_snapshot/installed03/network08_policy.py';s=importlib.util.spec_from_file_location('own_explicit08_pins',path);p=importlib.util.module_from_spec(s);s.loader.exec_module(p);return p.collector()
def main(preflight=False):
 c=policy();args=types.SimpleNamespace(fixture=WORK,assets=Path(r'G:\USOS-Kolekcja\_assets\B261020-200536-968CCBE8-nt4-hid13-netdns-utc-ipfix'),out=MATRIX/'artifacts/coverage/nt4-installed09-network-excerpt',qemu=Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-system-x86_64.exe'),first_logon_observed=False,network_capture=None)
 metadata=json.loads((WORK/('prepared-fixture.json' if preflight else 'fixture.json')).read_text(encoding='utf-8'))
 c.validate(metadata,WORK,args.assets,args.out,Path(r'G:\USOS-Kolekcja'),MATRIX,preflight=True)
 if preflight:
  print('09_TUPLE_STRICT_POLICY_PREFLIGHT_PASS; exact new SYS89b/21248, two inherited EXE pins, unchanged paths/grammar/token/status/DORA gates');return
 result=json.loads((SOURCE/'result.json').read_text(encoding='utf-8'))
 if result['qemu_returncode']!=0 or result['shutdown']!='QMP quit' or result['error'] or not (SOURCE/'completed.json').is_file():raise ValueError('Completed writer boundary')
 if result['first_logon_observed'] is not True:raise ValueError('Exact actual logon token missing')
 args.first_logon_observed=True;args.network_capture=result['network_capture'];asyncio.run(c.main(args))
if __name__=='__main__':main('--preflight' in __import__('sys').argv)
