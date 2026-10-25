#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Inject original Win16 applications only into a stage3 disposable overlay.

JSON plan: command1, optional command2, files=[{source,target}], optional
text={target:ASCII text}, collect=[guest paths]. Sources must be in the external
Win16 application library. Provider and controller are explicit own artifacts.
One bounded application run and one final screenshot; no live status queries.
"""
from pathlib import Path, PurePosixPath
from types import SimpleNamespace
import argparse
import hashlib
import json
import re
import shlex
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import run_win16_stage3_qemu as stage

LIBRARY = Path(r'G:\USOS-Kolekcja\Programy\Win16')


def guest_path(value):
    path = PurePosixPath(value)
    if (not isinstance(value, str) or '\\' in value or path.is_absolute() or
            any(part in ('', '.', '..') for part in value.split('/')) or
            not re.fullmatch(r'[A-Za-z0-9_./ -]+', value) or
            not (value.startswith('NET/WIN16/') or value.startswith('WINDOWS/'))):
        raise ValueError('Guest file must be a safe application or Windows support file')
    return path.as_posix()


def load_plan(path):
    plan = json.loads(path.read_text(encoding='utf-8'))
    commands = []
    for key in ('command1', 'command2'):
        value = plan.get(key, '')
        if any(c in value for c in '\r\n\x00') or len(value) > 230:
            raise ValueError('Invalid application command')
        if value and not value.upper().startswith('C:\\NET\\WIN16\\'):
            raise ValueError('Application must launch from its own guest directory')
        commands.append(value)
    if not commands[0]: raise ValueError('command1 is required')
    copies, data = {}, {}
    for entry in plan.get('files', []):
        source = Path(entry['source']).resolve(strict=True)
        if not source.is_relative_to(LIBRARY.resolve()) or not source.is_file():
            raise ValueError('Applications must come from the external Win16 library')
        target = guest_path(entry['target'])
        if target in data: raise ValueError('Duplicate guest file')
        data[target] = source.read_bytes()
        copies[target] = {'source': str(source), 'sha256': hashlib.sha256(data[target]).hexdigest()}
    for target, value in plan.get('text', {}).items():
        target = guest_path(target)
        if target in data: raise ValueError('Duplicate guest file')
        data[target] = value.replace('\r\n', '\n').replace('\n', '\r\n').encode('ascii')
    collected = [guest_path(name) for name in plan.get('collect', [])]
    actions=plan.get('actions', [])
    if len(actions)>3: raise ValueError('At most three one-shot dialog actions')
    for action in actions:
        for key in ('dialog','button'):
            value=action[key]
            if not isinstance(value,str) or not 1<=len(value)<=75 or any(c in value for c in '\r\n\x00'):
                raise ValueError('Invalid one-shot dialog action')
            value.encode('ascii')
        if action['dialog'].startswith('@control:'):
            raw=action['dialog'][9:]
            if not raw.isdigit() or not 1<=int(raw)<=65535 or action['button']!='@id:'+raw:
                raise ValueError('Control selector requires the same explicit button ID')
    keys=plan.get('keys',[])
    if len(keys)>3: raise ValueError('At most three finite keyboard inputs')
    previous=0
    for action in keys:
        when,key=action['at_seconds'],action['key']
        if not isinstance(when,(int,float)) or not previous<when<=120 or not re.fullmatch(r'[a-z0-9]+(?:-[a-z0-9]+)*',key):
            raise ValueError('Invalid finite keyboard input')
        previous=when
    return commands, copies, data, collected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--tag', required=True)
    parser.add_argument('--plan', type=Path, required=True)
    parser.add_argument('--provider', type=Path, required=True)
    parser.add_argument('--controller', type=Path, required=True)
    parser.add_argument('--api-test', type=Path, help='Own APITEST.EXE artifact, never a third-party application')
    parser.add_argument('--build-root', type=Path, required=True)
    parser.add_argument('--qemu', type=Path, required=True)
    parser.add_argument('--seconds', type=int, default=120)
    parser.add_argument('--windows-mode', choices=('standard', 'enhanced'), default='enhanced')
    args = parser.parse_args()
    args.out = stage.guarded(args.out); args.out.mkdir(parents=True, exist_ok=True)
    commands, copies, data, collected = load_plan(args.plan)
    if 'NET/WIN16/APPCTL.INI' in data or 'NET/WIN16/APPCTL.EXE' in data or 'WINDOWS/WINSOCK.DLL' in data:
        raise ValueError('Plan cannot replace fixture or provider')
    required_mode = args.windows_mode.upper()
    mode_switch = 'S' if args.windows_mode == 'standard' else '3'
    config='[test]\r\nmode=' + required_mode + '\r\ncommand1=' + commands[0] + '\r\ncommand2=' + commands[1] + '\r\n'
    for i,action in enumerate(json.loads(args.plan.read_text(encoding='utf-8')).get('actions',[]),1):
        config+='dialog%d=%s\r\nbutton%d=%s\r\n'%(i,action['dialog'],i,action['button'])
    data['NET/WIN16/APPCTL.INI'] = config.encode('ascii')
    data['NET/WIN16/APPCTL.EXE'] = args.controller.read_bytes()
    if args.api_test:
        if 'NET/WIN16/APITEST.EXE' in data: raise ValueError('Plan cannot replace the own API client')
        data['NET/WIN16/APITEST.EXE'] = args.api_test.read_bytes()
    data['NET/WIN16/WINSOCK.DLL'] = args.provider.read_bytes()
    data['WINDOWS/WINSOCK.DLL'] = args.provider.read_bytes()
    input_events=[(entry['at_seconds'],entry['key']) for entry in json.loads(args.plan.read_text(encoding='utf-8')).get('keys',[])]
    if any(delay>=args.seconds for delay,_ in input_events): raise ValueError('Keyboard input must precede final capture')
    disk = stage.make_overlay(args.out, args.base, args.tag, args.qemu)
    stage.flow.nt3.set_root(args.build_root)
    vm = SimpleNamespace(out=args.out, build_root=args.build_root, qemu=args.qemu, netdev=stage.LAN)
    vm.input_events=input_events
    files, script = {}, []
    for i, (target, content) in enumerate(data.items()):
        source = 'F%06d.BIN' % i
        files[source] = content
        dest = '/target/' + target
        script += ['mkdir -p ' + shlex.quote(str(PurePosixPath(dest).parent)),
                   'cp /ws/' + source + ' ' + shlex.quote(dest)]
    script += ["rm -f /target/NET/MTCP.CFG /target/NET/DHCP.LOG /target/NET/USOSPKT.LOG",
               "grep -q '^WIN.COM /[S3] /B' /target/AUTOEXEC.BAT",
               "sed -i 's@^WIN.COM /[S3] /B.*@WIN.COM /" + mode_switch + " /B C:\\\\NET\\\\WIN16\\\\APPCTL.EXE\\r@' /target/AUTOEXEC.BAT"]
    stage.flow.ws.linux(vm, disk, args.tag+'-stage', '\n'.join(script)+'\n', files)
    stage.receipt(args.out/(args.tag+'-inputs.json'), {
        'plan': json.loads(args.plan.read_text(encoding='utf-8')), 'applications': copies,
        'injected_sha256': {k: hashlib.sha256(v).hexdigest() for k,v in data.items()},
        'normal_base_preserved': True, 'required_mode': required_mode, 'run_seconds': args.seconds})
    stage.boot(vm, disk, args.tag+'-run', args.seconds)
    names = ['NET/WIN16/APPCTL.LOG', 'NET/WIN16/WINSOCK.LOG', 'NET/WIN16/WSDIAG.LOG',
             'NET/MTCP.CFG', 'NET/DHCP.LOG', 'NET/USOSPKT.LOG'] + collected
    raw = stage.flow.ws.linux(vm, disk, args.tag+'-read', stage.flow.dump(names))
    dumped = stage.flow.files_of(raw)
    evidence = stage.guarded(args.out/(args.tag+'-files')); evidence.mkdir(exist_ok=False)
    for name, content in dumped.items(): (evidence/name.replace('/','-')).write_bytes(content)
    log = dumped.get('NET/WIN16/APPCTL.LOG', b'')
    stage.receipt(args.out/(args.tag+'-verdict.json'), {
        'qemu_only': True, 'actual_enhanced_mode': b'mode=ENHANCED' in log,
        'required_mode': required_mode, 'actual_required_mode': ('mode=' + required_mode).encode('ascii') in log,
        'one_inventory_completed': b'APPCTL inventory complete' in log,
        'application_pass': None, 'requires_final_screenshot_and_closed_pcap_review': True,
        'files': {k: {'bytes':len(v), 'sha256':hashlib.sha256(v).hexdigest()} for k,v in dumped.items()}})
    print(log.decode('ascii', 'backslashreplace'))
    return 0 if ('mode=' + required_mode).encode('ascii') in log else 1


if __name__ == '__main__': raise SystemExit(main())
