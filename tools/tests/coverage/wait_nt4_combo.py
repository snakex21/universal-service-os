"""One exact future combined action/endpoint/COM completion, no progress polling."""
from pathlib import Path
import importlib.util,json,sys
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('nt4_combo_notify',HERE/'wait_nt4_hid.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
OUT=HERE.parents[2]/'artifacts/coverage/vm/nt4-installed03-usb-combo01'
def main():
 mode=sys.argv[1]
 if mode=='endpoint':wanted=[OUT/'endpoint.png',OUT/'completed.json']
 elif mode=='completed':wanted=[OUT/'completed.json']
 elif mode in ('startup','hot','replug'):wanted=[OUT/('msc-'+mode+'-done.json'),OUT/'completed.json']
 else:
  n=int(mode)
  if not 1<=n<=128:raise ValueError('Step1..128 required')
  wanted=[OUT/('operator-%02d.png'%n),OUT/'completed.json']
 print(json.dumps(dict(completed=str(m.wait_created(wanted,mode)))),flush=True)
if __name__=='__main__':main()
