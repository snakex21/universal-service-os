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
NT4_OBSERVER_HELPER_SHA256='37e7a0f69846d9bab18a718f7d66c3fd937f0f35913d2b0eb22f2d7ce4eae0e9'
NT4_NETWORK_LOGGER_SHA256='ff2585043a882065f9598628ac31afdaba356a3d91f3e55d93a36e313e3983b7'
NT5_FOLDERS={'windows xp','windows xp x64','windows 2000','windows 2000 server',
    'windows server 2003','windows xp media center edition 2005','windows xp tablet pc edition 2005'}
_driver_spec=importlib.util.spec_from_file_location('coverage_driver_inputs',Path(__file__).with_name('driver_inputs.py'))
driver_inputs=importlib.util.module_from_spec(_driver_spec);_driver_spec.loader.exec_module(driver_inputs)
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


def make_observer_iso(path,token,logger=None,logger_sha256=None):
    """Own read-only scripts CD for the existing USOS user_script option."""
    import pycdlib
    if not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token):
        raise ValueError('Invalid observer token')
    payload=None
    if logger is not None:
        payload=logger.read_bytes()
        if not logger_sha256 or hashlib.sha256(payload).hexdigest()!=logger_sha256:
            raise ValueError('Own usability logger hash mismatch')
        if not payload.startswith(b'MZ') or b'USOSLOG' not in payload or len(payload)>4*1024**2:
            raise ValueError('Unexpected own logger input')
    cd=pycdlib.PyCdlib()
    cd.new(interchange_level=3,joliet=3,vol_ident='USOS_EVIDENCE')
    try:
        cd.add_directory(iso_path='/SYSTEMS',joliet_path='/Systems')
        cd.add_directory(iso_path='/SCRIPTS',joliet_path='/Scripts')
        script='@echo off\r\n'
        if payload is not None:
            cd.add_directory(iso_path='/TOOLS',joliet_path='/Tools')
            cd.add_fp(io.BytesIO(payload),len(payload),iso_path='/TOOLS/USOSLOG.EXE;1',joliet_path='/Tools/USOSLOG.EXE')
            script+=('if not exist "%SystemDrive%\\USOS\\Coverage" md "%SystemDrive%\\USOS\\Coverage"\r\n'
                'copy /y "%~d0\\Tools\\USOSLOG.EXE" "%SystemDrive%\\USOS\\Coverage\\USOSLOG.EXE" >nul 2>&1\r\n'
                'if errorlevel 1 goto observed\r\n'
                'start "" /wait "%SystemDrive%\\USOS\\Coverage\\USOSLOG.EXE" /once /nodbg /nohook /out "%SystemDrive%\\USOS\\Coverage\\USABILITY.TXT"\r\n'
                ':observed\r\n')
        script+=('mode COM1: BAUD=115200 PARITY=N DATA=8 STOP=1 >nul 2>&1\r\necho '+token+'>COM1\r\n')
        script=script.encode('ascii')
        cd.add_fp(io.BytesIO(script),len(script),iso_path='/SCRIPTS/FIRSTLO.CMD;1',joliet_path='/Scripts/first-logon.cmd')
        cd.write(str(path))
    finally:cd.close()
NT4_OBSERVER_STAGE=r'''
# Test-only target-local notification; no unsupported NT4 user_script/CD hook.
coverage="$work/c/USOS/Coverage"
mkdir -p "$coverage" || fail 'coverage directory'
for coverage_file in FIRSTLO.CMD TESTNET.CMD OBS.REG NT4OBS.EXE; do
 cp "$LIB/coverage-nt4/$coverage_file" "$coverage/$coverage_file" &&
 cmp -s "$LIB/coverage-nt4/$coverage_file" "$coverage/$coverage_file" || fail 'coverage script readback'
done
coverage_digest=$(sha256sum "$LIB/network/USOSLOG.EXE"); coverage_digest=${coverage_digest%% *}
[ "$coverage_digest" = LOGGER_SHA ] || fail 'coverage logger pin'
cp "$LIB/network/USOSLOG.EXE" "$coverage/USOSLOG.EXE" &&
cmp -s "$LIB/network/USOSLOG.EXE" "$coverage/USOSLOG.EXE" || fail 'coverage logger readback'
'''
NT4_OBSERVER_ARM=r'''    # Test-only: inner QEMU returned and SP6a/target checks passed. No arming in POST.
    if [ "$status" = 0 ] && [ "$sub" = NT4 ] && coverage_first=$(nt4_ci_path "$c" USOS/Coverage/FIRSTLO.CMD); then
        coverage_dir=${coverage_first%/*}
        printf 'NT4_PREPARED_FIRST_LOGON_READY\r\n' > "$coverage_dir/ARMED.TXT" || status=1
    fi
'''


def nt4_observer_entries(script,finish,token,helper,target_mode=0o100755,finish_mode=0o100755):
    if not re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token):raise ValueError('Invalid NT4 observer token')
    import_anchor=br'%SystemRoot%\regedit.exe /s C:\USOS\NT4\DONE.REG'+b'\n'
    stage_anchor=br'''printf 'answer=%s\r\ncrypto=%s\r\nedition=%s\r\n' "$ANSWER_KIND" "$crypto" "${tse:+tse}" > "$usos/SOURCE.TXT"'''+b'\n'
    arm_anchor=b'    sync\n    umount "$c" || status=1\n'
    if script.count(import_anchor)!=1 or script.count(stage_anchor)!=1 or finish.count(arm_anchor)!=1:
        raise ValueError('Frozen NT4 observer insertion point changed')
    if b'coverage-nt4/' in script or b'NT4_PREPARED_FIRST_LOGON_READY' in finish:raise ValueError('NT4 observer already installed')
    staged=script.replace(import_anchor,import_anchor+br'%SystemRoot%\regedit.exe /s C:\USOS\Coverage\OBS.REG'+b'\n')
    staged=staged.replace(stage_anchor,stage_anchor+NT4_OBSERVER_STAGE.replace('LOGGER_SHA',NT4_NETWORK_LOGGER_SHA256).encode('ascii'))
    finished=finish.replace(arm_anchor,NT4_OBSERVER_ARM.encode('ascii')+arm_anchor)
    # RunOnce is installed only at POST's end. The Run fallback is idempotent:
    # if NT4 enumerates the new RunOnce in the inner logon, no ARM exists and
    # no token is emitted. The fallback survives to the native target logon.
    # ARM is created only after inner QEMU has returned, and removed on use.
    firstlo=('@echo off\n'
        'mode COM1: BAUD=115200 PARITY=N DATA=8 STOP=1 >nul 2>&1\n'
        'if errorlevel 1 exit 1\n'
        'echo '+token+'>COM1\nif errorlevel 1 exit 1\nexit 0\n')
    testnet=('@echo off\n'
        '"%SystemRoot%\\system32\\ipconfig.exe" /release >nul 2>&1\n'
        'if errorlevel 1 exit 31\n'
        '"%SystemRoot%\\system32\\ipconfig.exe" /renew >nul 2>&1\n'
        'if errorlevel 1 exit 32\n'
        'start "" /wait "C:\\USOS\\Coverage\\USOSLOG.EXE" /once /nodbg /nohook /nodisk /out "C:\\USOS\\Coverage\\USABILITY.TXT"\n'
        'if errorlevel 1 exit 33\nexit 0\n')
    obs='REGEDIT4\n\n'
    for key in ('RunOnce','Run'):
        section='[HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\'+key+']\n'
        obs+=section+'"USOSCoverage"="C:\\\\USOS\\\\Coverage\\\\NT4OBS.EXE /firstlogon"\n\n'
    entries=[('usr/lib/usos/nt4_csmwrap_target.sh',target_mode,staged),('usr/lib/usos/nt4_qemu_install.sh',finish_mode,finished)]
    for name,text in (('FIRSTLO.CMD',firstlo),('TESTNET.CMD',testnet),('OBS.REG',obs)):
        entries.append(('usr/lib/usos/coverage-nt4/'+name,0o100644,text.replace('\n','\r\n').encode('ascii')))
    entries.append(('usr/lib/usos/coverage-nt4/NT4OBS.EXE',0o100755,helper))
    return entries


def nt4_observer_assets(assets,token,helper):
    import gzip
    spec=importlib.util.spec_from_file_location('nt4_observer_cpio',Path(__file__).resolve().parents[2]/'build_micro_linux.py')
    cpio=importlib.util.module_from_spec(spec);spec.loader.exec_module(cpio)
    entries=cpio.parse_newc(gzip.decompress((assets/'zig-out/micro-linux/initramfs-usos').read_bytes()))
    target=entries['usr/lib/usos/nt4_csmwrap_target.sh'];finish=entries['usr/lib/usos/nt4_qemu_install.sh']
    logger=entries['usr/lib/usos/network/USOSLOG.EXE'].data
    if hashlib.sha256(logger).hexdigest()!=NT4_NETWORK_LOGGER_SHA256:raise ValueError('Frozen NT4 observer logger differs')
    return nt4_observer_entries(target.data,finish.data,token,helper,target.mode,finish.mode)


def load_bootstrap():
    spec = importlib.util.spec_from_file_location('coverage_fixture_bootstrap', LOWRAM)
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    return bootstrap


def trace_overlay(legacy_token=None,nt4_entries=None):
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
    if nt4_entries:entries.extend(nt4_entries)
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
    if getattr(args,'usability_logger',None) and not args.first_logon_observer:
        raise ValueError('Own logger requires the scripts-CD first-logon observer')
    nt4_network=getattr(args,'nt4_network_evidence',False)
    if nt4_network and (args.folder!='Windows NT 4.0' or not args.private_key or not args.first_logon_observer or not args.trace_menus or
                        not getattr(args,'usability_logger',None) or getattr(args,'logger_sha256',None)!=NT4_NETWORK_LOGGER_SHA256):
        raise ValueError('Explicit private NT4 first-logon network policy requires exact strict logger')
    nt4_helper=None
    if nt4_network:
        if hashlib.sha256(args.usability_logger.read_bytes()).hexdigest()!=NT4_NETWORK_LOGGER_SHA256:
            raise ValueError('NT4 strict logger input differs')
        helper_path=getattr(args,'nt4_observer_helper',None)
        if not helper_path:raise ValueError('Explicit NT4 GUI observer helper required')
        nt4_helper=helper_path.read_bytes()
        helper_sha=getattr(args,'nt4_observer_helper_sha256',None)
        if helper_sha!=NT4_OBSERVER_HELPER_SHA256 or hashlib.sha256(nt4_helper).hexdigest()!=helper_sha or len(nt4_helper)>131072 or not nt4_helper.startswith(b'MZ'):
            raise ValueError('NT4 GUI observer helper pin differs')
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
    driver_bundle=None
    if getattr(args,'user_drivers_zip',None):
        driver_bundle=driver_inputs.load(args.user_drivers_zip,getattr(args,'user_drivers_sha256',None))
    elif getattr(args,'user_drivers_sha256',None):
        raise ValueError('Driver ZIP required with its hash')
    inputs = args.iso.stat().st_size + sum(path.stat().st_size for path,_ in extras)+(driver_bundle['bytes'] if driver_bundle else 0)
    profile = None
    if args.profile:
        profile = args.profile.read_bytes()
        if re.search(rb'(?im)^\s*key(?:\.[^=\r\n]+)?\s*=\s*\S', profile):
            raise ValueError('Keyed profiles require a private test adapter')
        if args.private_key:
            if not args.key_for or not re.fullmatch('[a-z0-9-]+',args.key_for):
                raise ValueError('Private key needs its exact catalogue system ID')
            profile += ('\nremember_key=yes\nkey.'+args.key_for+'='+private_key(args.private_key,index=args.key_index)+'\n').encode('ascii')
        if args.first_logon_observer and not nt4_network:profile += b'\nuser_script=yes\n'
    elif args.private_key:
        raise ValueError('Private key injection requires a USOS profile')
    work.mkdir(parents=True, exist_ok=False)
    observer_token='USOS_COVERAGE_FIRST_LOGON_'+uuid.uuid4().hex if (args.first_logon_observer or args.legacy_first_logon) else None
    if args.first_logon_observer and not nt4_network:make_observer_iso(work/'observer.iso',observer_token,
        getattr(args,'usability_logger',None),getattr(args,'logger_sha256',None))
    share = work/'share'
    shutil.copytree(args.assets/'zig-out/usb', share)
    if driver_bundle:driver_inputs.stage(driver_bundle,share/'coverage-user-drivers',work)
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
        nt4_entries=nt4_observer_assets(args.assets,observer_token,nt4_helper) if nt4_network else None
        overlay=trace_overlay(observer_token if args.legacy_first_logon else None,nt4_entries)
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
    if driver_bundle:
        commands += f"mkdir -p '/mnt/data/Drivers/{args.folder}'\ncp -R /mnt/share/coverage-user-drivers/. '/mnt/data/Drivers/{args.folder}/'\n"
        commands += "(cd /mnt/share/coverage-user-drivers && find . -type f | while IFS= read -r file; do cmp -s \"$file\" \"/mnt/data/Drivers/"+args.folder+"/$file\" || exit 1; done)\n"
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
        nt4_network_evidence=nt4_network,
        nt4_observer_helper_sha256=getattr(args,'nt4_observer_helper_sha256',None),
        nt4_observer_overlay={name:hashlib.sha256(data).hexdigest() for name,mode,data in (nt4_entries or [])} if nt4_network else None,
        usability_logger_sha256=getattr(args,'logger_sha256',None),
        observer_ide=args.observer_ide,
        observer_kind='nt4-test-run' if nt4_network else '9x-runonce' if args.legacy_first_logon else 'scripts-cd' if args.first_logon_observer else None,
        donor=str(args.donor) if args.donor else None,
        user_drivers=driver_inputs.metadata(driver_bundle) if driver_bundle else None,
        legacy_service_pack=str(service_pack) if service_pack else None,
        boot_floppy=str(args.boot_floppy) if args.boot_floppy else None, nvme_9x=args.nvme_9x,
        virtual_bytes=virtual_gib*1024**3,
        current_bytes=disk.stat().st_size)
    (work/'fixture.json').write_text(json.dumps(metadata, indent=2), encoding='utf-8')
    if not share.resolve().is_relative_to(work):raise ValueError('Fixture share escaped the owned work directory')
    shutil.rmtree(share)  # Only the new per-test copied asset share.
    if result['result'] != 'PASS':
        raise SystemExit(1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('assets','qemu','iso','out'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--folder', required=True)
    parser.add_argument('--nt4-observer-helper',type=Path,help='Own exact GUI helper for target-local NT4 observer')
    parser.add_argument('--nt4-observer-helper-sha256',help='Exact own GUI observer binary hash')
    parser.add_argument('--nt4-network-evidence',action='store_true',help='Explicit private NT4 policy: stage target-local test Run notification and manual TESTNET after actual logon')
    parser.add_argument('--usability-logger',type=Path,help='Own GUI diagnostic executable for the test-only first-logon CD')
    parser.add_argument('--logger-sha256',help='Required exact hash of the own logger, never a Windows file')
    parser.add_argument('--dos', type=Path)
    parser.add_argument('--donor', type=Path, help='Unchanged read-only PE10 donor ISO')
    parser.add_argument('--user-drivers-zip',type=Path,help='Private hashed Other/package ZIP staged through ordinary DATA/Drivers')
    parser.add_argument('--user-drivers-sha256',help='Exact SHA-256 required for the private driver input')
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
