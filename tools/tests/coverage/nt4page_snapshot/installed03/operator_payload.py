"""Bound one public operator request before its Windows TTY write.

The runtime accepts at most 64 QEMU keys. ConPTY also corrupted an actual
JSON line near byte511; a conservative450-byte ASCII cap rejects it before
the keyboard channel is touched. No input, screen or progress is read.
"""
import json,re
def bounded_action(keys,settle=2):
 if not isinstance(keys,list) or len(keys)>64 or any(not isinstance(k,str) or not re.fullmatch('[a-z0-9_-]+',k) for k in keys):
  raise ValueError('Invalid bounded public key action')
 if type(settle) not in (int,float) or not 0<=settle<=3600:raise ValueError('Invalid fixed settle duration')
 line=json.dumps({'keys':keys,'settle':settle},separators=(',',':'),allow_nan=False)+'\n'
 if len(line.encode('ascii'))>450:raise ValueError('Operator JSON exceeds conservative TTY byte bound')
 return line
