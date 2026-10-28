r"""Run the reg.exe specialize commands of rendered answers against a scratch HKCU key
(HKLM -> HKCU\Software\USOS-PO2-Test\M, HKU\USOSDefault -> ...\U, HKU\.DEFAULT -> ...\D),
then read every value back with winreg. Syntax/quoting/packing check only (Windows host, no
elevation; only reg.exe commands run, the scratch key is deleted).

    python tools/tests/check_answer_regexe_host.py src/flow/answer/testdata/golden/options.windows-11.amd64.xml ...
"""
import shlex
import subprocess
import sys
import winreg
import xml.etree.ElementTree as ET

NS = '{urn:schemas-microsoft-com:unattend}'
BASE = 'Software\\USOS-PO2-Test'
MAP = [('HKU\\USOSDefault\\', 'HKCU\\' + BASE + '\\U\\'), ('HKU\\.DEFAULT\\', 'HKCU\\' + BASE + '\\D\\'), ('HKLM\\', 'HKCU\\' + BASE + '\\M\\')]


def conv(cmd):
    for a, b in MAP:
        cmd = cmd.replace('"' + a, '"' + b)
    return cmd


fails = 0
checked = 0
for path in sys.argv[1:]:
    subprocess.run(['reg.exe', 'delete', 'HKCU\\' + BASE, '/f'], capture_output=True)
    expect = []
    for p in ET.parse(path).getroot().iter(NS + 'Path'):
        c = p.text
        if not (c.startswith('reg.exe add') or c.startswith('reg.exe delete') or c.startswith('cmd.exe /c reg')):
            continue
        c2 = conv(c)
        r = subprocess.run(c2, capture_output=True)
        if r.returncode:
            # a delete of a value that does not exist fails harmlessly
            if ' delete ' not in c2:
                print('FAIL run', c2, r.stderr.decode('cp1250', 'replace'))
                fails += 1
        body = c[len('cmd.exe /c '):] if c.startswith('cmd.exe') else 'reg' + c[7:]
        for op in body.split(' & '):
            t = shlex.split(op.replace('\\', '\\\\'), posix=True)
            if t[1] != 'add':
                continue
            key = conv('"' + t[2]).strip('"')
            name = t[t.index('/v') + 1]
            typ = t[t.index('/t') + 1]
            data = t[t.index('/d') + 1]
            expect.append((key, name, typ, data))
    for key, name, typ, data in expect:
        sub = key[len('HKCU\\'):]
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, sub) as k:
                v, t = winreg.QueryValueEx(k, name)
        except OSError:
            print('FAIL missing', key, name)
            fails += 1
            continue
        want = {'REG_DWORD': lambda: (int(data), winreg.REG_DWORD), 'REG_SZ': lambda: (data, winreg.REG_SZ),
                'REG_BINARY': lambda: (bytes.fromhex(data), winreg.REG_BINARY)}[typ]()
        if (v, t) != want:
            print('FAIL value', key, name, (v, t), want)
            fails += 1
        checked += 1
    print(path.split('\\')[-1], 'values checked so far', checked)
subprocess.run(['reg.exe', 'delete', 'HKCU\\' + BASE, '/f'], capture_output=True)
print('RESULT', 'PASS' if not fails else f'FAIL {fails}', checked)
