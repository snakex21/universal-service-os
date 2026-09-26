"""Run a USOS-prepared XP disk in a throw-away VirtualBox VM (AMD-V, much
faster than QEMU TCG for GUI Setup and repeated boots).

  create  --name usos-test-X --disk target.qcow2|.vdi [--controller ide|ahci] [--memory 3072] [--extra-disk D.vdi]
          [--firmware bios|efi] [--ostype WindowsXP|WindowsVista_64|Windows7_64] [--graphics vboxvga|vmsvga]
          (--firmware efi: VirtualBox EFI has no CSM, i.e. a UEFI class 3 machine)
  boot    --name usos-test-X --output DIR [--minutes 120] [--interval 5]
  destroy --name usos-test-X          (unregister + delete the VM and its disks)

`boot` starts the VM headless, saves every changed screen (PNG) and stops
when the guest powers off, --minutes passes, or DIR/control.txt contains
  powerdown | reset | poweroff | key:<scancodes hex>   (e.g. key:1c 9c = Enter)
Only VMs named usos-test-* are touched; WHPX/Hyper-V are not needed.
Disks are converted with qemu-img into the VM folder, the source stays unchanged.
"""
from pathlib import Path
import argparse, hashlib, json, subprocess, sys, time

ROOT = Path(__file__).resolve().parents[3]
VBOX = Path(r'C:\Program Files\Oracle\VirtualBox\VBoxManage.exe')
QEMU_IMG = ROOT / 'tools/qemu/qemu-img.exe'


def vbox(*args, check=True, quiet=False):
    r = subprocess.run([str(VBOX), *map(str, args)], capture_output=True, text=True, errors='replace')
    if check and r.returncode != 0:
        raise SystemExit(f'VBoxManage {" ".join(map(str, args))} failed:\n{r.stdout}\n{r.stderr}')
    if not quiet and r.stdout.strip():
        print(r.stdout.strip())
    return r


def guard(name):
    if not name.startswith('usos-test-'):
        raise SystemExit('refusing a VM name without the usos-test- prefix')


def state(name):
    r = vbox('showvminfo', name, '--machinereadable', check=False, quiet=True)
    for line in r.stdout.splitlines():
        if line.startswith('VMState='):
            return line.split('=', 1)[1].strip('"')
    return 'missing'


def vm_folder(name):
    r = vbox('showvminfo', name, '--machinereadable', quiet=True)
    for line in r.stdout.splitlines():
        if line.startswith('CfgFile='):
            return Path(line.split('=', 1)[1].strip('"')).parent
    raise SystemExit('VM folder unknown')


def to_vdi(src, dst):
    src = Path(src).resolve()
    if src.suffix.lower() == '.vdi':
        subprocess.run([str(QEMU_IMG), 'convert', '-O', 'vdi', str(src), str(dst)], check=True)
    else:
        fmt = {'.qcow2': 'qcow2', '.vhd': 'vpc', '.raw': 'raw', '.img': 'raw'}.get(src.suffix.lower(), 'qcow2')
        subprocess.run([str(QEMU_IMG), 'convert', '-f', fmt, '-O', 'vdi', str(src), str(dst)], check=True)


def create(a):
    guard(a.name)
    if state(a.name) != 'missing':
        raise SystemExit('VM exists already: ' + a.name)
    base = a.base.resolve(); base.mkdir(parents=True, exist_ok=True)
    vbox('createvm', '--name', a.name, '--ostype', a.ostype, '--basefolder', base, '--register')
    folder = vm_folder(a.name)
    vbox('modifyvm', a.name, '--memory', a.memory, '--cpus', a.cpus, '--firmware', a.firmware, '--ioapic', 'on', '--pae', 'on',
         '--acpi', 'on', '--nic1', 'none', '--audio-enabled', 'off', '--usb-ohci', 'off', '--graphicscontroller', a.graphics,
         '--vram', '32', '--boot1', 'disk', '--boot2', 'none', '--boot3', 'none', '--boot4', 'none', '--rtc-use-utc', 'off')
    if a.controller == 'ahci':
        vbox('storagectl', a.name, '--name', 'SATA', '--add', 'sata', '--controller', 'IntelAhci', '--portcount', '4')
        bus = 'SATA'
    else:
        vbox('storagectl', a.name, '--name', 'IDE', '--add', 'ide', '--controller', 'PIIX4')
        bus = 'IDE'
    for i, src in enumerate([a.disk, *a.extra_disk]):
        vdi = folder / f'disk{i}.vdi'
        to_vdi(src, vdi)
        port, device = (i, 0) if bus == 'SATA' else (i // 2, i % 2)
        vbox('storageattach', a.name, '--storagectl', bus, '--port', port, '--device', device, '--type', 'hdd', '--medium', vdi)
    print('[PASS] created', a.name, folder)


def boot(a):
    guard(a.name)
    from PIL import Image
    out = a.output.resolve(); shots = out / 'screens'; shots.mkdir(parents=True, exist_ok=True)
    control = out / 'control.txt'; control.unlink(missing_ok=True)
    log = open(out / 'events.log', 'a', encoding='utf-8'); start = time.time(); events = []

    def note(text):
        t = round(time.time() - start, 1); line = f'{t:8.1f}s {text}'
        print(line, flush=True); log.write(line + '\n'); log.flush(); events.append({'t': t, 'event': text})

    n = len(list(shots.glob('*.png'))); last = None; result = 'timeout'
    vbox('startvm', a.name, '--type', 'headless'); note('started')
    try:
        while time.time() - start < a.minutes * 60:
            s = state(a.name)
            if s == 'missing':
                # VBoxManage can fail transiently while the VM session is busy.
                time.sleep(1); s = state(a.name)
            if s in ('poweroff', 'aborted', 'missing'):
                result = s; note('state ' + s); break
            if control.exists():
                order = control.read_text(encoding='utf-8').strip(); control.unlink(); note('control ' + order)
                if order == 'powerdown':
                    vbox('controlvm', a.name, 'acpipowerbutton', check=False)
                elif order in ('reset', 'poweroff'):
                    vbox('controlvm', a.name, order, check=False)
                elif order.startswith('key:'):
                    vbox('controlvm', a.name, 'keyboardputscancode', *order[4:].split(), check=False)
            cur = shots / 'cur.png'; cur.unlink(missing_ok=True)
            vbox('controlvm', a.name, 'screenshotpng', cur, check=False, quiet=True)
            if cur.exists():
                try:
                    image = Image.open(cur); image.load()
                    h = hashlib.sha256(image.tobytes()).hexdigest()
                except Exception:
                    h = None
                if h and h != last:
                    last = h; n += 1; image.save(shots / f'{n:04d}.png'); note(f'screen {n:04d} {image.size[0]}x{image.size[1]}')
            time.sleep(a.interval)
    finally:
        if state(a.name) == 'running' and result == 'timeout':
            note('timeout: VM left running')
        (out / 'result.json').write_text(json.dumps({'result': result, 'events': events}, indent=1), encoding='utf-8')
        note('result ' + result)
    return 0 if result == 'poweroff' else 1


def destroy(a):
    guard(a.name)
    if state(a.name) == 'missing':
        print('no VM', a.name); return 0
    if state(a.name) == 'running':
        vbox('controlvm', a.name, 'poweroff', check=False); time.sleep(3)
    vbox('unregistervm', a.name, '--delete-all')
    print('[PASS] destroyed', a.name)


def export(a):
    """Copy the VM's first disk to qcow2 (for ntfs_volume_flags.py, target_digest.py)."""
    guard(a.name)
    vdi = vm_folder(a.name) / 'disk0.vdi'
    subprocess.run([str(QEMU_IMG), 'convert', '-f', 'vdi', '-O', 'qcow2', str(vdi), str(a.output.resolve())], check=True)
    print('[PASS] exported', a.output)


if __name__ == '__main__':
    p = argparse.ArgumentParser(); sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('create'); c.add_argument('--name', required=True); c.add_argument('--disk', type=Path, required=True)
    c.add_argument('--extra-disk', type=Path, action='append', default=[]); c.add_argument('--controller', choices=['ide', 'ahci'], default='ide')
    c.add_argument('--firmware', choices=['bios', 'efi'], default='bios'); c.add_argument('--ostype', default='WindowsXP')
    c.add_argument('--graphics', choices=['vboxvga', 'vmsvga'], default='vboxvga')
    c.add_argument('--memory', default='3072'); c.add_argument('--cpus', default='2'); c.add_argument('--base', type=Path, default=ROOT / 'zig-out/vbox')
    b = sub.add_parser('boot'); b.add_argument('--name', required=True); b.add_argument('--output', type=Path, required=True)
    b.add_argument('--minutes', type=float, default=120); b.add_argument('--interval', type=float, default=5)
    d = sub.add_parser('destroy'); d.add_argument('--name', required=True)
    e = sub.add_parser('export'); e.add_argument('--name', required=True); e.add_argument('--output', type=Path, required=True)
    a = p.parse_args()
    sys.exit({'create': create, 'boot': boot, 'destroy': destroy, 'export': export}[a.cmd](a) or 0)
