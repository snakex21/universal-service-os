"""Step-by-step QEMU driver for docs/design/bios-via-csmwrap.md.

One VM at a time, state in <out>/vm.json. Firmware:
  ovmf     OVMF (edk2-x86_64-code.fd) = UEFI without any CSM
  seabios  plain SeaBIOS (control: the stick's BIOS path with a real BIOS)
Devices mimic the X470 input path: the USOS stick as usb-storage and the
keyboard as usb-kbd, both on qemu-xhci; optional usb-tablet; target disk on
AHCI; std VGA (carries a PC-AT VGA option ROM, like the RX 560).

  python bios_csmwrap_vm.py --out DIR start --fw ovmf --stick S.vhd [--target T.qcow2] [--i8042 off]
  python bios_csmwrap_vm.py --out DIR key ret | shot NAME | type "text" | text | hmp "info ..." | stop
  python bios_csmwrap_vm.py --out DIR mouse DX DY [--steps N] | click [--button 1|2] [--double]
  (start ... --mouse usb adds a relative usb-mouse on the same xHCI)

Disposable images only; nothing here opens a physical disk.
"""
from pathlib import Path
import argparse, json, shutil, socket, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
QEMU = ROOT / 'tools/qemu/qemu-system-x86_64.exe'
OVMF_CODE = ROOT / 'tools/qemu/share/edk2-x86_64-code.fd'
OVMF_VARS = ROOT / 'tools/qemu/share/edk2-i386-vars.fd'
SEABIOS = ROOT / 'tools/qemu/share/bios-256k.bin'

KEYMAP = {' ': 'spc', '\n': 'ret', '\\': 'backslash', '/': 'slash', ':': 'shift-semicolon', '.': 'dot', '-': 'minus',
          '_': 'shift-minus', '*': 'shift-8', '?': 'shift-slash', '>': 'shift-dot', '<': 'shift-comma',
          '=': 'equal', '(': 'shift-9', ')': 'shift-0', ';': 'semicolon', ',': 'comma', '"': 'shift-apostrophe'}


class Hmp:
    def __init__(self, port):
        for _ in range(100):
            try:
                self.s = socket.create_connection(('127.0.0.1', port), timeout=5)
                break
            except OSError:
                time.sleep(0.1)
        self.s.settimeout(0.4)
        self.read()

    def read(self):
        out = b''
        try:
            while True:
                chunk = self.s.recv(65536)
                if not chunk:
                    break
                out += chunk
        except OSError:
            pass
        return out.decode(errors='replace')

    def cmd(self, text, wait=0.3):
        self.s.sendall(text.encode() + b'\n')
        time.sleep(wait)
        return self.read()


def state_path(out):
    return out / 'vm.json'


def start(out, a):
    out.mkdir(parents=True, exist_ok=True)
    port = 45500 + (abs(hash(str(out))) % 400)
    serial = out / (a.tag + '-serial.log')
    machine = 'pc' + (',i8042=off' if a.i8042 == 'off' else '')
    cmd = [QEMU, '-machine', machine, '-accel', a.accel, '-cpu', a.cpu, '-m', str(a.mem), '-smp', str(a.smp),
           '-display', 'none', '-nic', 'none', '-rtc', 'base=localtime', '-serial', f'file:{serial}',
           '-monitor', f'tcp:127.0.0.1:{port},server=on,wait=off', '-vga', 'std']
    if a.fw == 'ovmf':
        vars_copy = out / (a.tag + '-vars.fd')
        shutil.copyfile(OVMF_VARS, vars_copy)
        cmd += ['-drive', f'if=pflash,unit=0,format=raw,readonly=on,file={OVMF_CODE}',
                '-drive', f'if=pflash,unit=1,format=raw,file={vars_copy}']
    else:
        cmd += ['-bios', SEABIOS]
    cmd += ['-device', 'qemu-xhci,id=xhci']
    if a.kbd == 'usb':
        # With usb-kbd present QEMU routes sendkey to it, not to the i8042.
        cmd += ['-device', 'usb-kbd,bus=xhci.0']
    if a.tablet:
        cmd += ['-device', 'usb-tablet,bus=xhci.0']
    if a.mouse == 'usb':
        # Relative USB mouse (SeaBIOS: INT 15h C2 / PS/2-BIOS events).
        cmd += ['-device', 'usb-mouse,bus=xhci.0']
    if a.target:
        cmd += ['-device', 'ahci,id=ahci', '-drive', f'if=none,id=target,format={a.target_format},file={a.target}',
                '-device', f'ide-hd,drive=target,bus=ahci.0,bootindex={2 if a.stick else 0}']
    if a.stick:
        fmt = 'vpc' if str(a.stick).lower().endswith('.vhd') else 'qcow2'
        cmd += ['-drive', f'if=none,id=stick,format={fmt},file={a.stick},readonly={"on" if a.stick_ro else "off"}',
                '-device', f'usb-storage,bus=xhci.0,drive=stick,removable=on,bootindex={0 if not a.target_first else 3}']
    log = open(out / (a.tag + '-qemu.log'), 'wb')
    proc = subprocess.Popen([str(c) for c in cmd], stdout=log, stderr=log, creationflags=getattr(subprocess, 'CREATE_NO_WINDOW', 0))
    state_path(out).write_text(json.dumps({'pid': proc.pid, 'port': port, 'tag': a.tag, 'start': time.time(),
                                           'cmd': [str(c) for c in cmd]}, indent=1))
    print('started', a.tag, 'pid', proc.pid, 'port', port)


def hmp(out):
    st = json.loads(state_path(out).read_text())
    return Hmp(st['port']), st


def shot(out, name):
    h, st = hmp(out)
    ppm = out / (name + '.ppm')
    h.cmd(f'screendump "{ppm.as_posix()}"', 1.0)
    try:
        from PIL import Image
        Image.open(ppm).save(out / (name + '.png'))
        ppm.unlink()
        print(out / (name + '.png'), 't=%.0fs' % (time.time() - st['start']))
    except Exception as e:
        print(ppm, e)


def text(out):
    h, _ = hmp(out)
    dump = out / 'b8000.bin'
    dump.unlink(missing_ok=True)
    h.cmd(f'pmemsave 0xb8000 4000 "{dump.as_posix()}"', 0.8)
    b = dump.read_bytes()
    for r in range(25):
        line = ''.join(chr(c) if 32 <= c < 127 else ' ' for c in b[r * 160:r * 160 + 160:2]).rstrip()
        print(line)


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--out', type=Path, required=True)
    sub = p.add_subparsers(dest='action', required=True)
    s = sub.add_parser('start')
    s.add_argument('--fw', choices=('ovmf', 'seabios'), default='ovmf')
    s.add_argument('--stick', type=Path)
    s.add_argument('--stick-ro', action='store_true')
    s.add_argument('--target', type=Path)
    s.add_argument('--target-format', default='qcow2')
    s.add_argument('--target-first', action='store_true')
    s.add_argument('--tablet', action='store_true')
    s.add_argument('--mouse', choices=('none', 'usb'), default='none')
    s.add_argument('--kbd', choices=('usb', 'ps2'), default='usb')
    s.add_argument('--i8042', choices=('on', 'off'), default='on')
    s.add_argument('--accel', default='tcg,thread=multi')
    s.add_argument('--cpu', default='max')
    s.add_argument('--mem', type=int, default=1024)
    s.add_argument('--smp', type=int, default=2)
    s.add_argument('--tag', default='run')
    k = sub.add_parser('key'); k.add_argument('keys', nargs='+'); k.add_argument('--delay', type=float, default=0.3)
    sh = sub.add_parser('shot'); sh.add_argument('name')
    t = sub.add_parser('type'); t.add_argument('text')
    sub.add_parser('text')
    hm = sub.add_parser('hmp'); hm.add_argument('command')
    mo = sub.add_parser('mouse'); mo.add_argument('dx', type=int); mo.add_argument('dy', type=int); mo.add_argument('--steps', type=int, default=1)
    cl = sub.add_parser('click'); cl.add_argument('--button', type=int, default=1); cl.add_argument('--double', action='store_true')
    sub.add_parser('stop')
    a = p.parse_args()
    out = a.out.resolve()
    if a.action == 'start':
        start(out, a)
    elif a.action == 'key':
        h, _ = hmp(out)
        for key in a.keys:
            h.cmd('sendkey ' + key, a.delay)
    elif a.action == 'type':
        h, _ = hmp(out)
        for ch in a.text.replace('\\n', '\n'):
            spec = KEYMAP.get(ch, 'shift-' + ch.lower() if ch.isupper() else ch)
            h.cmd('sendkey ' + spec, 0.6 if ch == '\n' else 0.15)
    elif a.action == 'shot':
        shot(out, a.name)
    elif a.action == 'text':
        text(out)
    elif a.action == 'hmp':
        h, _ = hmp(out)
        print(h.cmd(a.command, 1.0))
    elif a.action == 'mouse':
        h, _ = hmp(out)
        for _ in range(a.steps):
            h.cmd(f'mouse_move {a.dx} {a.dy}', 0.15)
    elif a.action == 'click':
        h, _ = hmp(out)
        for _ in range(2 if a.double else 1):
            h.cmd(f'mouse_button {a.button}', 0.1)
            h.cmd('mouse_button 0', 0.15)
    elif a.action == 'stop':
        h, st = hmp(out)
        h.cmd('quit', 1.0)
        print('stopped', st['tag'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
