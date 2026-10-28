#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Pure plan for the isolated DISM reference boot; does not create images."""
import json
import re
import uuid
from pathlib import Path
import diagnostic_boot_guard as guard
import firstboot_bounds as bounds

MIB=1024**2
UTILITY_BYTES=65*MIB
LIMITS={'utility.raw':UTILITY_BYTES,'vars.fd':4*MIB,'debug.stdout':16*MIB,'qemu.stderr':16*MIB,
        'creation_logs':8*MIB,'manifest_and_config':4*MIB,'offline_readback':64*MIB,'other':16*MIB}
if sum(LIMITS.values())>guard.AUX_BOUND:raise ValueError('Diagnostic auxiliary limits exceed reservation')

def configuration(layout_sha,policy_sha,loader):
    if not all(re.fullmatch('[0-9a-f]{64}',x) for x in (layout_sha,policy_sha)) or layout_sha==policy_sha:
        raise ValueError('Distinct layout and deferred-policy SHA pins required')
    if not isinstance(loader,uuid.UUID) or loader.version!=4 or loader.variant!=uuid.RFC_4122 or str(loader) in (guard.DISK,guard.WINDOWS,guard.ESP,guard.MSR):
        raise ValueError('Independent random loader GUID required')
    ids={'disk_guid':guard.DISK,'windows_guid':guard.WINDOWS,'esp_guid':guard.ESP,'msr_guid':guard.MSR}
    fields={'target_bytes':str(32*1024**3),**{k:uuid.UUID(v).bytes_le.hex() for k,v in ids.items()},
            'loader_guid':loader.bytes_le.hex(),'ntfs_serial':'e46231e86231c05a','mbr_signature':'0',
            'layout_receipt_sha256':layout_sha,'bcd_receipt_sha256':policy_sha,'layout_gate':'pass',
            'bcd_gate':'deferred','arch':'x64','locale':'pl-PL'}
    data=('USOSBOOT_REFERENCE_QEMU_ONLY_V1\n'+''.join(k+'='+v+'\n' for k,v in fields.items())).encode('ascii')
    if len(data)>4096:raise ValueError('Reference config too large')
    return data

def plan_paths(case,out):
    if not case.is_absolute() or not out.is_absolute() or out.parent!=case:
        raise ValueError('Direct fresh case output required')
    if not re.fullmatch(r'diag-boot-[0-9a-f-]+',out.name):raise ValueError('Diagnostic output name required')
    for p in (case,out):
        if str(p).startswith('\\\\') or any(c in str(p) for c in ',\r\n\0') or '..' in p.parts:
            raise ValueError('Unsafe diagnostic path')

def command(qemu,code,vars_path,utility,overlay,entropy):
    paths=(qemu,code,vars_path,utility,overlay,entropy)
    if any(not p.is_absolute() or str(p).startswith('\\\\') or any(c in str(p) for c in ',\r\n\0') for p in paths):
        raise ValueError('Explicit local QEMU inputs required')
    guard.check_budget(guard.BOOT_BOUND,guard.FIRSTBOOT_BOUND,guard.AUX_BOUND)
    nodes=[{'driver':'file','node-name':'utility-file','filename':str(utility)},
           {'driver':'raw','node-name':'utility','file':'utility-file','offset':0,'size':UTILITY_BYTES}]
    args=[str(qemu),'-machine','q35','-accel','whpx','-cpu','qemu64,-xsave','-smp','2','-m','512',
          '-nodefaults','-display','none','-no-reboot','-nic','none',
          '-drive',f'if=pflash,format=raw,readonly=on,file={code}',
          # The diagnostic does not persist firmware/NVRAM changes. Read-only
          # vars avoid an unbounded pflash writer outside the RAW envelopes.
          '-drive',f'if=pflash,format=raw,readonly=on,file={vars_path}',
          '-fw_cfg',f'name=opt/usosprep-entropy,file={entropy}']
    for node in nodes:args+=['-blockdev',json.dumps(node,separators=(',',':'))]
    args+=bounds.blockdev_arguments(overlay,guard.BOOT_BOUND)
    args+=['-device','ide-hd,drive=utility,bus=ide.0,bootindex=1','-device','ide-hd,drive=windows,bus=ide.1',
           '-device','VGA','-serial','none','-debugcon','stdio','-global','isa-debugcon.iobase=0xe9',
           '-device','isa-debug-exit,iobase=0xf4,iosize=0x04']
    return args
