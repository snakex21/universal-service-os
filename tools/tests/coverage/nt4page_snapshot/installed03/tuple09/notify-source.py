"""Exact future operator/completion notifications only; no progress reads."""
from pathlib import Path
import importlib.util,json,sys
HERE=Path(__file__).resolve().parent
s=importlib.util.spec_from_file_location('tuple09_future_notify',HERE/'candidate03_notify.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
OUT=HERE.parents[1]/'artifacts/coverage/vm/nt4-installed08-usbmsc-hid-net09'
def main():
 mode=sys.argv[1];OUT.mkdir(parents=True,exist_ok=True)
 if mode=='endpoint':paths=[OUT/'endpoint.png',OUT/'completed.json']
 elif mode=='completed':paths=[OUT/'completed.json']
 else:
  n=int(mode)
  if not 1<=n<=128:raise ValueError('Explicit bounded operator step')
  paths=[OUT/('operator-%02d.png'%n),OUT/'completed.json']
 print(json.dumps({'completed':str(m.wait_created(paths,'tuple09_'+mode))}),flush=True)
if __name__=='__main__':main()
