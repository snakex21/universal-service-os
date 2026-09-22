from pathlib import Path
path=Path('M:/Windows/Panther/UnattendGC/setupact.log')
b=path.read_bytes();s=b.decode('utf-16') if b.startswith(b'\xff\xfe') else b.decode('utf-8',errors='replace')
print(s[-9000:])
