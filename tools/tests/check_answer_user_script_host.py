r"""The user-script hook command lines (options.zig user_script_reg / user_script_cmd, taken
from the rendered 11 answer's FirstLogonCommands) run on this host against a fake USOS_DATA
drive (subst W: -> a scratch folder with Systems\ and Scripts\first-logon.reg/.cmd). The .reg
writes only HKCU\Software\USOS-PO2-Test (deleted afterwards). Run it only when no real USOS
stick is plugged in (its scripts would run too).

    python tools/tests/check_answer_user_script_host.py src/flow/answer/testdata/golden/options.windows-11.amd64.xml
"""
import os
import subprocess
import sys
import tempfile
import winreg
import xml.etree.ElementTree as ET

NS = '{urn:schemas-microsoft-com:unattend}'
lines = [e.text for e in ET.parse(sys.argv[1]).getroot().iter(NS + 'CommandLine')]
assert len(lines) == 2, lines
root = tempfile.mkdtemp(prefix='usosdata-')
os.makedirs(os.path.join(root, 'Systems'))
os.makedirs(os.path.join(root, 'Scripts'))
marker = os.path.join(root, 'ran.txt')
with open(os.path.join(root, 'Scripts', 'first-logon.cmd'), 'w') as f:
    f.write('@echo off\r\necho cmd ran from %~dp0> "' + marker + '"\r\n')
with open(os.path.join(root, 'Scripts', 'first-logon.reg'), 'w') as f:
    f.write('REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\USOS-PO2-Test]\r\n"Script"="reg ran"\r\n\r\n')
subprocess.run(['subst', 'W:', root], check=True)
try:
    for c in lines:
        r = subprocess.run(c, capture_output=True, text=True, timeout=120)
        print('exit', r.returncode, r.stdout.strip(), r.stderr.strip())
finally:
    subprocess.run(['subst', 'W:', '/d'])
ok_cmd = os.path.exists(marker) and open(marker).read().strip()
try:
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Software\\USOS-PO2-Test') as k:
        ok_reg = winreg.QueryValueEx(k, 'Script')[0]
except OSError:
    ok_reg = None
subprocess.run(['reg.exe', 'delete', 'HKCU\\Software\\USOS-PO2-Test', '/f'], capture_output=True)
print('cmd:', ok_cmd)
print('reg:', ok_reg)
print('RESULT', 'PASS' if ok_cmd and ok_reg == 'reg ran' else 'FAIL')
