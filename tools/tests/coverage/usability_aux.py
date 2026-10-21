"""Own small FAT16 sticks and explicit NIC arguments for disposable QEMU tests."""
from pathlib import Path
import struct
import subprocess
import sys
import re
import json

VIRTUAL_BYTES=64*1024**2
PARTITION_LBA=2048
FAT_SECTORS=128
ROOT_ENTRIES=512
KEYLESS_FAILURE_FOLDERS=frozenset((
    'Windows NT 4.0',
    'Windows NT 3.1','Windows NT 3.1 Advanced Server',
    'Windows NT 3.5','Windows NT 3.5 Server',
    'Windows NT 3.51','Windows NT 3.51 Server',
))


def valid_logon_token(token):
    return isinstance(token,str) and re.fullmatch('USOS_COVERAGE_FIRST_LOGON_[a-f0-9]{32}',token) is not None


def logon_notification(token,line):
    return valid_logon_token(token) and line.strip()==token


def manual_test_supported(private_profile,prepared_proof,token):
    return not private_profile or prepared_proof or valid_logon_token(token)


def reject_unanswered_usos_form(line):
    if line.strip().startswith('[UI_SCREEN] form '):
        raise RuntimeError('Automatic fixture reached an unanswered USOS form; Windows has not started: '+line.strip())


def require_operator_channel(enabled,stream=None):
    stream=sys.stdin if stream is None else stream
    if enabled and (stream.closed or not stream.isatty()):
        raise ValueError('Interactive test requires an open TTY; launch exec_command with tty=true')


def input_machine(machine,ps2_input,usb_only):
    if type(usb_only) is not bool or type(ps2_input) is not bool:
        raise ValueError('Input scenario must use explicit boolean flags')
    if usb_only:
        if ps2_input or machine!='q35':
            raise ValueError('USB-only input requires q35 and cannot enable PS/2 input')
        return 'q35,i8042=off'
    return machine


def network_arguments(model):
    if model=='none':return ['-nic','none']
    if model!='igb':raise ValueError('Only the source-verified 82576 NIC is supported')
    return ['-netdev','user,id=usabilitynet,hostname=usos-test',
            '-device','igb,netdev=usabilitynet,mac=52:54:00:55:53:01']


def hid_descriptor(device,pointer):
    if pointer not in ('mouse','tablet'):raise ValueError('Unknown USB pointer model')
    if device=='keyboard':return {'driver':'usb-kbd','id':'coveragekbd','bus':'xhci.0'}
    if device=='mouse':return {'driver':'usb-'+pointer,'id':'coveragepointer','bus':'xhci.0'}
    raise ValueError('Only the owned USB keyboard or pointer may be unplugged')


def usb_block_arguments(kind,path):
    """Named block nodes survive device_del; legacy -drive backends do not."""
    if kind not in ('boot','hot'):raise ValueError('Unknown test stick')
    path=Path(path)
    if not path.is_absolute() or path.suffix.casefold()!='.qcow2':
        raise ValueError('Expected an absolute owned qcow2 test image')
    node={'driver':'qcow2','node-name':'usability'+kind,
          'file':{'driver':'file','filename':str(path.resolve())}}
    return ['-blockdev',json.dumps(node,separators=(',',':'),ensure_ascii=False)]


def framebuffer_menu_keys(line):
    menus={
        '/run/xp-disk-menu.state':('ret',),
        # First row keeps existing partitions and uses unallocated space.
        # The owned test target is initially blank; never choose erase here.
        '/run/xp-disk-mode.txt':('ret',),
        '/run/xp-confirm-menu.state':('up','ret'),
    }
    prefix='[COVERAGE_MENU] '
    name=line.strip().removeprefix(prefix)
    if not line.strip().startswith(prefix) or name not in menus:
        raise ValueError('Unknown framebuffer menu; no input sent: '+name)
    return menus[name]


def validate_failure_collection(enabled,metadata,assets,collection):
    if not enabled:return
    folder=metadata.get('folder')
    if metadata.get('private_profile') is not False or not isinstance(folder,str) or folder not in KEYLESS_FAILURE_FOLDERS:
        raise ValueError('Failure collector accepts only an explicitly keyless allowlisted NT3/NT4 diagnostic case')
    if assets is None or not assets.resolve().is_relative_to(collection/'_assets'):
        raise ValueError('Failure collector needs explicit owned frozen assets')


def fat16_prefix(kind):
    if kind not in ('boot','hot'):raise ValueError('Unknown test stick')
    start=PARTITION_LBA*512
    root_sector=1+2*FAT_SECTORS
    data_sector=root_sector+ROOT_ENTRIES*32//512
    payload=('USOS disposable USB '+kind+' read test\r\n').encode('ascii')
    image=bytearray(start+(data_sector+4)*512)
    struct.pack_into('<B3sB3sII',image,446,0,b'\xfe\xff\xff',6,b'\xfe\xff\xff',
                     PARTITION_LBA,VIRTUAL_BYTES//512-PARTITION_LBA)
    image[510:512]=b'\x55\xaa'
    image[start:start+11]=b'\xeb\x3c\x90USOSTEST'
    struct.pack_into('<HBHBHHBHHHII',image,start+11,512,4,1,2,ROOT_ENTRIES,0,0xf8,
        FAT_SECTORS,63,255,PARTITION_LBA,VIRTUAL_BYTES//512-PARTITION_LBA)
    struct.pack_into('<BBBI',image,start+36,0x80,0,0x29,0x55530001 if kind=='boot' else 0x55530002)
    image[start+43:start+54]=b'USOS_BOOT  ' if kind=='boot' else b'USOS_HOT   '
    image[start+54:start+62]=b'FAT16   '
    image[start+510:start+512]=b'\x55\xaa'
    for sector in (1,1+FAT_SECTORS):
        struct.pack_into('<HHH',image,start+sector*512,0xfff8,0xffff,0xffff)
    root=start+root_sector*512
    image[root:root+11]=b'START   TXT' if kind=='boot' else b'HOTPLUG TXT'
    image[root+11]=0x20
    struct.pack_into('<HHHI',image,root+22,0,0x21,2,len(payload))
    image[start+data_sector*512:start+data_sector*512+len(payload)]=payload
    return bytes(image)


def create_sticks(work,qemu):
    """Only qcow2 is attached; the short metadata prefix is removed immediately."""
    paths=[]
    for kind in ('boot','hot'):
        path=work/('usb-test-'+kind+'.qcow2')
        if path.exists():raise FileExistsError(path)
        prefix=work/('usb-test-'+kind+'.prefix')
        if prefix.exists():raise FileExistsError(prefix)
        try:
            prefix.write_bytes(fat16_prefix(kind))
            subprocess.run([str(qemu.parent/'qemu-img.exe'),'convert','-f','raw','-O','qcow2',
                            str(prefix),str(path)],check=True,capture_output=True)
            subprocess.run([str(qemu.parent/'qemu-img.exe'),'resize','-q','-f','qcow2',
                            str(path),str(VIRTUAL_BYTES)],check=True,capture_output=True)
            paths.append(path)
        finally:prefix.unlink(missing_ok=True)
    return paths
