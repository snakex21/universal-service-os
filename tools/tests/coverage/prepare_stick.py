"""Create a thin qcow2 USOS fixture with the unchanged micro-Linux tools.

Only disposable virtual disks are attached writable. Original ISOs and the
asset share are read-only. Direct kernel boot here only formats the test
fixture; the subsequent coverage boot must use OVMF and the actual menu.
"""
from pathlib import Path
import argparse
import asyncio
import ctypes
import importlib.util
import json
import math
import shutil
import subprocess
import sys
import uuid

COLLECTION = Path(r'G:\USOS-Kolekcja').resolve()
LOWRAM = Path(r'C:\Users\ASRock\usos-work\lowram-pomiar\tools\tests\lowram\bootstrap_probe.py')
def load_bootstrap():
    spec = importlib.util.spec_from_file_location('coverage_fixture_bootstrap', LOWRAM)
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    return bootstrap


def trace_overlay():
    """Guest-only observation: announce each framebuffer menu before input.

    The product still opens and handles every menu normally. This avoids
    reading screenshots/logs periodically to discover whether a menu opened.
    No key, answer file or disk content is sent through the observation line.
    """
    source = Path(__file__).resolve().parents[2]/'xp_menu_ui.sh'
    content = source.read_bytes().replace(b'\r\n', b'\n')
    needle = b'    xp_menu_result=$("$USOS_FB_UI" --menu "$xp_menu_file" 2>> "$xp_menu_err")'
    if content.count(needle) != 1:
        raise ValueError('Menu observation insertion point changed')
    content = content.replace(needle,
        b'    printf "[COVERAGE_MENU] %s\\n" "$xp_menu_file" > /dev/ttyS0\n'+needle)
    ui_source = source.with_name('micro_linux_ui.sh')
    ui = ui_source.read_bytes().replace(b'\r\n',b'\n')
    needle = b'usos_ui_notice_continue() {\n    notice_title=$1'
    if ui.count(needle) != 1:
        raise ValueError('Completion-notice observation insertion point changed')
    ui = ui.replace(needle, needle+b'\n    printf "[COVERAGE_NOTICE] %s\\n" "$notice_title" > /dev/ttyS0')
    entries = [('usr/lib/usos/xp_menu_ui.sh', 0o100755, content),
               ('usr/lib/usos/micro_linux_ui.sh',0o100755,ui), ('TRAILER!!!',0,b'')]
    result = bytearray()
    for index, (name, mode, data) in enumerate(entries, 1):
        encoded = name.encode()+b'\0'
        fields = (index,mode,0,0,1,0,len(data),0,0,0,0,len(encoded),0)
        result.extend(b'070701'+b''.join(f'{value:08x}'.encode() for value in fields))
        result.extend(encoded); result.extend(b'\0'*(-len(result)%4))
        result.extend(data); result.extend(b'\0'*(-len(result)%4))
    return bytes(result)


def check_resources(path, ram_mib):
    if shutil.disk_usage(path).free < 100*1024**3:
        raise RuntimeError('Less than 100 GiB free')
    class Memory(ctypes.Structure):
        _fields_ = [('length',ctypes.c_ulong), ('load',ctypes.c_ulong),
                    *[(name,ctypes.c_ulonglong) for name in ('total','available','page_total','page_available','virtual_total','virtual_available','extended')]]
    memory = Memory(); memory.length = ctypes.sizeof(memory)
    if not ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(memory)):
        raise ctypes.WinError()
    if memory.available < (8192+ram_mib)*1024**2:
        raise RuntimeError('Requested VM would leave less than 8 GiB for the user')
    return dict(disk_free=shutil.disk_usage(path).free, host_available=memory.available,
                host_total=memory.total, requested_mib=ram_mib)


async def main(args):
    work = args.out.resolve()
    if not work.is_relative_to(COLLECTION/'_vm'):
        raise ValueError('Fixture must be inside the authorized _vm directory')
    resources = check_resources(COLLECTION, 1024)
    for name in ('usb','dos-native/msdos/INSTALL.BAT','micro-linux','bin/usos-x86_64.efi','xp-uefi-csm'):
        if not (args.assets/'zig-out'/name).exists():
            raise FileNotFoundError('Missing fixture asset: '+name)
    work.mkdir(parents=True, exist_ok=False)
    share = work/'share'
    shutil.copytree(args.assets/'zig-out/usb', share)
    shutil.copyfile(args.assets/'zig-out/bin/usos-x86_64.efi', share/'EFI/BOOT/BOOTX64.EFI')
    for source, destination in [('micro-linux','EFI/USOS/micro-linux'),
                                ('dos-native','EFI/USOS/dos-native'),
                                ('xp-uefi-csm','EFI/USOS-XP')]:
        source = args.assets/'zig-out'/source
        target = share/destination
        target.mkdir(parents=True, exist_ok=True)
        if source.name == 'dos-native':
            shutil.copytree(source,target,dirs_exist_ok=True)
            continue
        for item in source.iterdir():
            if item.is_file() and not item.name.endswith(('.pdb','.json')):
                shutil.copyfile(item, target/item.name)
    if args.trace_menus:
        with (share/'EFI/USOS/micro-linux/initramfs-usos').open('ab') as stream:
            stream.write(b'\0'*(-stream.tell()%4))
            stream.write(trace_overlay())
    (share/'EFI/USOS/usos-settings.ini').write_text('language=en\nboot_logo=0\n', encoding='ascii')
    disk_guid, esp_guid, data_guid, work_guid = [str(uuid.uuid4()) for _ in range(4)]
    nonce = uuid.uuid4().hex
    (share/'EFI/USOS/usos-device.ini').write_text(
        f'[device]\nnonce={nonce}\ndisk_ptuuid={disk_guid}\nesp_partuuid={esp_guid}\n'
        f'data_partuuid={data_guid}\nwork_partuuid={work_guid}\nwork_label=USOS_WORK\ndata_label=USOS_DATA\n', encoding='ascii')
    (share/'EFI/USOS/install-state.ini').write_text('phase=pending\n', encoding='ascii')
    if any(ch in args.folder for ch in "'\r\n"):
        raise ValueError('Unexpected catalogue folder')
    inputs = args.iso.stat().st_size + (args.dos.stat().st_size if args.dos else 0)
    data_gib = max(2, math.ceil((inputs+1024**3)/1024**3))
    virtual_gib = data_gib+8  # ESP 1 GiB, WORK at least 6 GiB, GPT/alignment margin.
    disk = work/'stick.qcow2'
    subprocess.run([str(args.qemu.parent/'qemu-img.exe'),'create','-q','-f','qcow2',str(disk),f'{virtual_gib}G'], check=True)
    commands = f'''
/bin/busybox --install -s /bin
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
set -e
mount -t proc proc /proc
mount -t sysfs sys /sys
mount -t devtmpfs dev /dev
for m in virtio_pci virtio_blk vfat fat ntfs3; do modprobe "$m"; done
mdev -s
sfdisk /dev/vda <<'LAYOUT'
label: gpt
label-id: {disk_guid}
start=2048,size=2097152,type=U,uuid={esp_guid},name="USOS_ESP"
size={data_gib*2097152},type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7,uuid={data_guid},name="USOS_DATA"
type=EBD0A0A2-B9E5-4433-87C0-68B6B72699C7,uuid={work_guid},name="USOS_WORK"
LAYOUT
mdev -s
mkfs.fat -F 32 -n USOS_ESP /dev/vda1
mkfs.ntfs -F -Q -L USOS_DATA /dev/vda2
mkfs.ntfs -F -Q -L USOS_WORK /dev/vda3
mkdir -p /mnt/esp /mnt/data /mnt/work /mnt/share
mount /dev/vda1 /mnt/esp
mount -t ntfs3 /dev/vda2 /mnt/data
mount -t ntfs3 /dev/vda3 /mnt/work
mount -t vfat -o ro /dev/vdb1 /mnt/share || mount -t vfat -o ro /dev/vdb /mnt/share
cp -R /mnt/share/EFI /mnt/esp/
mkdir -p '/mnt/data/Systems/Windows/{args.folder}/Images' /mnt/data/Programs /mnt/data/Drivers
dd if=/dev/vdc of='/mnt/data/Systems/Windows/{args.folder}/Images/source.iso' bs=1M
printf 'nonce={nonce}\\n' > /mnt/work/.usos-work
'''
    if args.dos:
        commands += "mkdir -p '/mnt/data/Systems/DOS/MS-DOS/Images'\ndd if=/dev/vdd of='/mnt/data/Systems/DOS/MS-DOS/Images/MS-DOS 6.22.iso' bs=1M\n"
    commands += 'sync\numount /mnt/esp\numount /mnt/data\numount /mnt/work\necho LOWRAM-RESULT=PASS\npoweroff -f\n'
    disks = ['-drive',f'file={disk.as_posix()},format=qcow2,if=virtio',
             '-drive',f'file=fat:ro:{share.as_posix()},format=raw,if=virtio,readonly=on',
             '-drive',f'file={args.iso.resolve().as_posix()},format=raw,if=virtio,readonly=on']
    if args.dos:
        disks += ['-drive',f'file={args.dos.resolve().as_posix()},format=raw,if=virtio,readonly=on']
    result = await load_bootstrap().run_case(args.qemu, args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos', work, 1024, 'qemu64', 900,
        disks, commands=commands, suffix='-fixture')
    metadata = dict(disk=str(disk), disk_guid=disk_guid, esp_guid=esp_guid,
        data_guid=data_guid, work_guid=work_guid, source=str(args.iso), folder=args.folder,
        resources=resources, result=result, menu_observation=args.trace_menus,
        virtual_bytes=virtual_gib*1024**3,
        current_bytes=disk.stat().st_size)
    (work/'fixture.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    shutil.rmtree(share)  # Only the new per-test copied asset share.
    if result['result'] != 'PASS':
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('assets','qemu','iso','out'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--folder', required=True)
    parser.add_argument('--dos', type=Path)
    parser.add_argument('--trace-menus', action='store_true')
    asyncio.run(main(parser.parse_args()))
