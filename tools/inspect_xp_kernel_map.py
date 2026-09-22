from pathlib import Path
for p in [Path('zig-out/xp-uefi-csm/driver-source/TXTSETUP.SIF'),Path('M:/$WIN_NT$.~LS/I386/TXTSETUP.SIF')]:
 b=p.read_bytes();s=b.decode('utf-16' if b.startswith(b'\xff\xfe') else 'latin1')
 print(p)
 for l in s.splitlines():
  if any(t in l.lower() for t in ['ntkr','ntos','sprest','initpki','kernel']): print(l)
