"""Read-only kernel signing policy check; does not change boot policy or trust."""
from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[1]
out = root / 'artifacts/vista/signature-policy-20260921'
out.mkdir(parents=True, exist_ok=True)
tool = Path('C:/Program Files (x86)/Windows Kits/10/bin/10.0.26100.0/x64/signtool.exe')
for name in ('usbxhci.sys', 'usbhub3.sys', 'ucx01000.sys', 'usbd8.sys'):
    result = subprocess.run([str(tool), 'verify', '/kp', '/v',
                             'M:/Windows/System32/drivers/' + name], capture_output=True)
    (out / (name + '.txt')).write_bytes(result.stdout + result.stderr)
    print(name, 'exit=', result.returncode)
    print((result.stdout + result.stderr).decode(errors='replace'))
