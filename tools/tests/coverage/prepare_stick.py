"""Create a thin qcow2 USOS fixture with the unchanged micro-Linux tools.

Only disposable virtual disks are attached writable. Original ISOs and the
asset share are read-only. Direct kernel boot here only formats the test
fixture; the subsequent coverage boot must use OVMF and the actual menu.
"""
from pathlib import Path
import argparse
import asyncio
import ctypes
import hashlib
import importlib.util
import io
import json
import math
import re
import shutil
import subprocess
import sys
import uuid

COLLECTION = Path(r'G:\USOS-Kolekcja').resolve()
LOWRAM = Path(r'C:\Users\ASRock\usos-work\lowram-pomiar\tools\tests\lowram\bootstrap_probe.py')
PRIVATE_KEYS = Path(r'C:\Users\ASRock\AppData\Local\USOS\test-assets\private-keys').resolve()
NT5_FOLDERS={'windows xp','windows xp x64','windows 2000','windows 2000 server',
    'windows server 2003','windows xp media center edition 2005','windows xp tablet pc edition 2005'}
LEGACY_OBSERVER_AWK = r'''
{
    sub(/\r$/, "")
    if (tolower($0) == "[install]") active=1
    else if ($0 ~ /^\[/) active=0
    if (active && tolower($0) ~ /^addreg[ \t]*=/) { $0=$0 ",USOS.Coverage"; hits++ }
    printf "%s\r\n", $0
}
END {
    if (hits != 1) exit 1
    printf "\r\n[USOS.Coverage]\r\n"
    b=sprintf("%c",92)
    printf "HKLM,\"Software%sMicrosoft%sWindows%sCurrentVersion%sRunOnce\",USOSCoverage,,\"command.com /c C:%sUSOS9X%sCOVOBS.BAT\"\r\n",b,b,b,b,b,b
}
'''


def private_key(path, root=PRIVATE_KEYS, index=None):
    path = path.resolve()
    if not path.is_relative_to(root.resolve()) or path.suffix.lower() != '.txt':
        raise ValueError('Key source must be a text file in the approved private-key directory')
    content = path.read_text(encoding='utf-8-sig')
    values = list(dict.fromkeys(value.upper() for value in re.findall(r'\b(?:[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}|\d{5}-OEM-\d{7}-\d{5}|\d{3}-\d{7})\b',content,re.I)))
    if index is not None:
        if not 0 <= index < len(values):
            raise ValueError('Private key index outside the supplied candidate list')
        return values[index]
    if len(values) != 1:
        raise ValueError('Private key file needs exactly one unambiguous candidate; no value is printed')
    return values[0]


def make_observer_iso(path,token):
    """Own read-only scripts CD for the existing USOS user_script option."""
    import pycdlib
    if not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token):
        raise ValueError('Invalid observer token')
    cd=pycdlib.PyCdlib()
    cd.new(interchange_level=3,joliet=3,vol_ident='USOS_EVIDENCE')
    try:
        cd.add_directory(iso_path='/SYSTEMS',joliet_path='/Systems')
        cd.add_directory(iso_path='/SCRIPTS',joliet_path='/Scripts')
        script=('@echo off\r\nmode COM1: BAUD=115200 PARITY=N DATA=8 STOP=1 >nul 2>&1\r\necho '+token+'>COM1\r\n').encode('ascii')
        cd.add_fp(io.BytesIO(script),len(script),iso_path='/SCRIPTS/FIRSTLO.CMD;1',joliet_path='/Scripts/first-logon.cmd')
        cd.write(str(path))
    finally:cd.close()
def load_bootstrap():
    spec = importlib.util.spec_from_file_location('coverage_fixture_bootstrap', LOWRAM)
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    return bootstrap


def trace_overlay(legacy_token=None):
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
    needle = b'usos_ui_fail() {\n    title=$1\n    detail=${2:-}'
    if ui.count(needle) != 1:
        raise ValueError('Failure observation insertion point changed')
    ui = ui.replace(needle,needle+b'\n    printf "[COVERAGE_FAILURE] %s\\n" "$title" > /dev/ttyS0')
    entries = [('usr/lib/usos/xp_menu_ui.sh', 0o100755, content),
               ('usr/lib/usos/micro_linux_ui.sh',0o100755,ui)]
    if legacy_token:
        if not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',legacy_token):raise ValueError('Invalid observer token')
        script=(source.with_name('w9x_csmwrap_target.sh')).read_bytes().replace(b'\r\n',b'\n')
        needle=b'cp "$ANSWER_INF" "$work/c/USOS9X/MSBATCH.INF" || fail \'cannot copy MSBATCH.INF\''
        if script.count(needle)!=1:raise ValueError('9x observer insertion point changed')
        hook=(r'''
# Test-only RunOnce notification; all installation answers remain from the profile.
awk '''+"'"+LEGACY_OBSERVER_AWK+"'"+r''' "$work/c/USOS9X/MSBATCH.INF" > "$work/coverage-answer.inf" || fail 'coverage observer: unexpected profile INF'
cp "$work/coverage-answer.inf" "$work/c/USOS9X/MSBATCH.INF" || fail 'coverage observer: answer staging failed'
printf '@echo off\r\nmode COM1:9600,n,8,1 >nul\r\necho '''+legacy_token+r'''>COM1\r\n' > "$work/c/USOS9X/COVOBS.BAT"
''').encode('ascii')
        entries.append(('usr/lib/usos/w9x_csmwrap_target.sh',0o100755,script.replace(needle,needle+hook)))
    entries.append(('TRAILER!!!',0,b''))
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


def allocated_bytes(path):
    """Measure filesystem allocation only after our VM stops, before cleanup."""
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    function = kernel.GetCompressedFileSizeW
    function.argtypes = [ctypes.c_wchar_p, ctypes.POINTER(ctypes.c_ulong)]
    function.restype = ctypes.c_ulong
    high = ctypes.c_ulong()
    ctypes.set_last_error(0)
    low = function(str(path), ctypes.byref(high))
    if low == 0xffffffff and ctypes.get_last_error():
        raise ctypes.WinError(ctypes.get_last_error())
    return (high.value << 32) | low


async def main(args):
    work = args.out.resolve()
    if not work.is_relative_to(COLLECTION/'_vm'):
        raise ValueError('Fixture must be inside the authorized _vm directory')
    resources = check_resources(COLLECTION, 1024)
    if (args.first_logon_observer or args.legacy_first_logon) and not args.profile:
        raise ValueError('First-logon observer needs an actual USOS profile')
    if args.legacy_first_logon and (not args.trace_menus or args.folder not in ('Windows 98','Windows 98 SE','Windows Me')):
        raise ValueError('Legacy observer is only for profile-based 98/98SE/Me with trace overlay')
    required=['usb','dos-native/msdos/INSTALL.BAT','micro-linux','bin/usos-x86_64.efi']
    if args.folder.casefold() in NT5_FOLDERS:required.append('xp-uefi-csm/initramfs-xp')
    for name in required:
        if not (args.assets/'zig-out'/name).exists():
            raise FileNotFoundError('Missing fixture asset: '+name)
    if any(ch in args.folder for ch in "'\r\n"):
        raise ValueError('Unexpected catalogue folder')
    service_pack=getattr(args,'legacy_service_pack',None)
    extras = [(path,destination) for path,destination in (
        (args.dos,'/mnt/data/Systems/DOS/MS-DOS/Images/MS-DOS 6.22.iso'),
        (args.donor,'/mnt/data/Programs/USOS/WinPE/PE10-donor.iso'),
        (service_pack,f'/mnt/data/Systems/Windows/{args.folder}/ServicePack/SP6I386.EXE'),
        (args.boot_floppy,f'/mnt/data/Systems/Windows/{args.folder}/Boot/BOOTDISK.IMG')) if path]
    # Fail on missing inputs before constructing a copied share with private data.
    inputs = args.iso.stat().st_size + sum(path.stat().st_size for path,_ in extras)
    profile = None
    if args.profile:
        profile = args.profile.read_bytes()
        if re.search(rb'(?im)^\s*key(?:\.[^=\r\n]+)?\s*=\s*\S', profile):
            raise ValueError('Keyed profiles require a private test adapter')
        if args.private_key:
            if not args.key_for or not re.fullmatch('[a-z0-9-]+',args.key_for):
                raise ValueError('Private key needs its exact catalogue system ID')
            profile += ('\nremember_key=yes\nkey.'+args.key_for+'='+private_key(args.private_key,index=args.key_index)+'\n').encode('ascii')
        if args.first_logon_observer:profile += b'\nuser_script=yes\n'
    elif args.private_key:
        raise ValueError('Private key injection requires a USOS profile')
    work.mkdir(parents=True, exist_ok=False)
    observer_token='USOS_COVERAGE_FIRST_LOGON_'+uuid.uuid4().hex if (args.first_logon_observer or args.legacy_first_logon) else None
    if args.first_logon_observer:make_observer_iso(work/'observer.iso',observer_token)
    share = work/'share'
    shutil.copytree(args.assets/'zig-out/usb', share)
    shutil.copyfile(args.assets/'zig-out/bin/usos-x86_64.efi', share/'EFI/BOOT/BOOTX64.EFI')
    for source, destination in [('micro-linux','EFI/USOS/micro-linux'),
                                ('dos-native','EFI/USOS/dos-native'),
                                ('xp-uefi-csm','EFI/USOS-XP')]:
        source = args.assets/'zig-out'/source
        if source.name=='xp-uefi-csm' and not source.exists():continue
        target = share/destination
        target.mkdir(parents=True, exist_ok=True)
        if source.name == 'dos-native':
            shutil.copytree(source,target,dirs_exist_ok=True)
            continue
        for item in source.iterdir():
            if item.is_file() and not item.name.endswith(('.pdb','.json')):
                shutil.copyfile(item, target/item.name)
    native = args.assets/'zig-out/windows-native'
    if native.is_dir():
        destination = share/'EFI/USOS/windows-native'
        destination.mkdir(parents=True,exist_ok=True)
        for item in native.iterdir():
            if item.is_file():shutil.copyfile(item,destination/item.name)
    observed_initrds=[]
    if args.trace_menus:
        overlay=trace_overlay(observer_token if args.legacy_first_logon else None)
        # NT5 boots the separate XP package; step 620 boots micro-linux.
        # Both frozen bundles contain the verified same own UI script bases.
        for relative in ('EFI/USOS/micro-linux/initramfs-usos','EFI/USOS-XP/initramfs-xp'):
            if not (share/relative).exists():continue
            with (share/relative).open('ab') as stream:
                stream.write(b'\0'*(-stream.tell()%4))
                stream.write(overlay)
            observed_initrds.append(relative)
    if args.profile:
        profiles = share/'EFI/USOS/profiles'
        profiles.mkdir(parents=True,exist_ok=True)
        (profiles/'coverage.ini').write_bytes(profile)
    (share/'EFI/USOS/usos-settings.ini').write_text('language=en\nboot_logo=0\n', encoding='ascii')
    disk_guid, esp_guid, data_guid, work_guid = [str(uuid.uuid4()) for _ in range(4)]
    nonce = uuid.uuid4().hex
    (share/'EFI/USOS/usos-device.ini').write_text(
        f'[device]\nnonce={nonce}\ndisk_ptuuid={disk_guid}\nesp_partuuid={esp_guid}\n'
        f'data_partuuid={data_guid}\nwork_partuuid={work_guid}\nwork_label=USOS_WORK\ndata_label=USOS_DATA\n', encoding='ascii')
    (share/'EFI/USOS/install-state.ini').write_text('phase=pending\n', encoding='ascii')
    data_gib = max(2, math.ceil((inputs+1024**3)/1024**3))
    virtual_gib = data_gib+max(8,args.work_gib+2)  # ESP and GPT/alignment margin.
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
    for index,(_,destination) in enumerate(extras,3):
        commands += f"mkdir -p '{destination.rsplit('/',1)[0]}'\n"
        commands += f"dd if=/dev/vd{chr(ord('a')+index)} of='{destination}' bs=1M\n"
    if args.nvme_9x:
        directory=f'/mnt/data/Systems/Windows/{args.folder}/Unattended'
        commands += f"mkdir -p '{directory}'\ntouch '{directory}/nvme-experimental.txt'\n"
    commands += 'sync\numount /mnt/esp\numount /mnt/data\numount /mnt/work\necho LOWRAM-RESULT=PASS\npoweroff -f\n'
    disks = ['-drive',f'file={disk.as_posix()},format=qcow2,if=virtio',
             '-drive',f'file=fat:ro:{share.as_posix()},format=raw,if=virtio,readonly=on',
             '-drive',f'file={args.iso.resolve().as_posix()},format=raw,if=virtio,readonly=on']
    for path,_ in extras:
        disks += ['-drive',f'file={path.resolve().as_posix()},format=raw,if=virtio,readonly=on']
    result = await load_bootstrap().run_case(args.qemu, args.assets/'zig-out/micro-linux/vmlinuz-virt',
        args.assets/'zig-out/micro-linux/initramfs-usos', work, 1024, 'qemu64', 900,
        disks, commands=commands, suffix='-fixture')
    metadata = dict(disk=str(disk), disk_guid=disk_guid, esp_guid=esp_guid,
        data_guid=data_guid, work_guid=work_guid, source=str(args.iso), folder=args.folder,
        resources=resources, result=result, menu_observation=args.trace_menus,
        observed_initrds=observed_initrds,
        answer_profile=bool(args.profile),
        profile_sha256=hashlib.sha256(profile).hexdigest() if args.profile else None,
        private_profile=bool(args.private_key),
        observer_token=observer_token,
        observer_ide=args.observer_ide,
        observer_kind='9x-runonce' if args.legacy_first_logon else 'scripts-cd' if args.first_logon_observer else None,
        donor=str(args.donor) if args.donor else None,
        legacy_service_pack=str(service_pack) if service_pack else None,
        boot_floppy=str(args.boot_floppy) if args.boot_floppy else None, nvme_9x=args.nvme_9x,
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
    parser.add_argument('--donor', type=Path, help='Unchanged read-only PE10 donor ISO')
    parser.add_argument('--legacy-service-pack',type=Path,help='Unchanged read-only NT4 SP6a/TSE SP6 prerequisite')
    parser.add_argument('--boot-floppy',type=Path,help='Read-only Windows 95 prerequisite boot disk')
    parser.add_argument('--nvme-9x',action='store_true',help='Use the product NVMe experimental opt-in file')
    parser.add_argument('--first-logon-observer',action='store_true',help='Use user_script with an own scripts CD; marker is not desktop PASS')
    parser.add_argument('--observer-ide',action='store_true',help='Legacy PIIX IDE for the scripts CD (default: auxiliary AHCI)')
    parser.add_argument('--legacy-first-logon',action='store_true',help='Test-only 98/98SE/Me RunOnce COM1 notification; no Windows binary edits')
    parser.add_argument('--trace-menus', action='store_true')
    parser.add_argument('--profile', type=Path, help='Keyless USOS profile, staged for selection in the real menu')
    parser.add_argument('--private-key',type=Path,help='One existing private-key text file; no key in tool arguments')
    parser.add_argument('--key-for',help='Catalogue system ID for the supplied private key')
    parser.add_argument('--key-index',type=int,help='Explicit zero-based selection in a supplied multi-key file; never generates a key')
    parser.add_argument('--work-gib', type=int, default=6)
    asyncio.run(main(parser.parse_args()))
