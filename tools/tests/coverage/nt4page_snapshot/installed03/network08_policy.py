"""Installed08: one exact new own driver, with every installed07 gate retained."""
from pathlib import Path
import importlib.util
DRIVER='89b7337c294ca0c56415cdc4e7023615a628ae8158a5a7ab80dcf6f35ca02233'
DRIVER_BYTES=21248
def collector():
 path=Path(__file__).with_name('network07_policy.py')
 s=importlib.util.spec_from_file_location('own_nt4_network08_inherited07',path);p=importlib.util.module_from_spec(s);s.loader.exec_module(p)
 c=p.collector()
 if c.DRIVER_SHA256!='4f2eb16b71753baab740302025b9e8ba02c38a676670b13626c757bdb3700f8d' or c.DRIVER_BYTES!=21376:raise ValueError('Unexpected inherited07 driver contract')
 c.DRIVER_SHA256=DRIVER;c.DRIVER_BYTES=DRIVER_BYTES
 original_commands=c.commands
 def commands():
  text=original_commands()
  old='if [ "$(wc -c </tmp/raw/driver)" -eq 21376 ]; then'
  if text.count(old)!=1:raise ValueError('Exact inherited guest driver-size guard required')
  return text.replace(old,'if [ "$(wc -c </tmp/raw/driver)" -eq 21248 ]; then')
 c.commands=commands
 original=c.validate
 def validate(metadata,*args,**kwargs):
  if metadata.get('nt4_network_driver_sha256')!=DRIVER or type(metadata.get('nt4_network_driver_bytes'))!=int or metadata['nt4_network_driver_bytes']!=DRIVER_BYTES:raise ValueError('Exact installed08 own driver metadata required')
  return original(metadata,*args,**kwargs)
 c.validate=validate
 return c
