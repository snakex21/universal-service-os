#!/usr/bin/env python3
# Copyright (C) 2026 Maksymilian and the USOS Authors
# SPDX-License-Identifier: GPL-3.0-or-later
"""Original mIRC evaluation on an app COW, controlled localhost IRC only."""
from pathlib import Path
import argparse
import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import threading

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE))
import run_win16_stage3_qemu as stage
server_path=HERE.parent/'win16/irc_stage3_server.py'
spec=importlib.util.spec_from_file_location('irc_gate_server',server_path)
irc=importlib.util.module_from_spec(spec);sys.modules[spec.name]=irc;spec.loader.exec_module(irc)
LIBRARY=Path(r'G:\USOS-Kolekcja\Programy\Win16\mIRC-5.91-16bit\files')


def client_plan():
    allowed={'MIRC.EXE','MIRC.HLP','IRCINTRO.HLP','ALIASES.INI','POPUPS.INI','README.TXT','URLS.INI','VERSIONS.TXT'}
    files=[{'source':str(path),'target':'NET/WIN16/MIRC/'+path.name}
           for path in LIBRARY.iterdir() if path.is_file() and path.name.upper() in allowed]
    config=('''[mirc]
user=USOS Local Win16 Test
email=usos@localhost
nick=USOS16
anick=USOS16a
host=USOS LocalSERVER:172.31.8.2:16667GROUP:USOS
[rfiles]
n0=remote.ini
[afiles]
n0=aliases.ini
[pfiles]
n0=popups.ini
[files]
servers=servers.ini
''')
    remote=('''[script]
n0=on 1:CONNECT:{
n1=  join #usos-test
n2=}
''')
    return {'command1':r'C:\NET\WIN16\MIRC\MIRC.EXE','files':files,
            'text':{'NET/WIN16/MIRC/MIRC.INI':config,'NET/WIN16/MIRC/REMOTE.INI':remote,
                'NET/WIN16/MIRC/SERVERS.INI':'[servers]\nn0=USOS LocalSERVER:172.31.8.2:16667GROUP:USOS\n'},
            'collect':['NET/WIN16/MIRC/MIRC.INI','NET/WIN16/MIRC/REMOTE.INI']}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out',type=Path,required=True)
    p.add_argument('--base',type=Path,required=True)
    p.add_argument('--provider',type=Path,required=True)
    p.add_argument('--controller',type=Path,required=True)
    p.add_argument('--build-root',type=Path,required=True)
    p.add_argument('--qemu',type=Path,required=True)
    p.add_argument('--seconds',type=int,default=120)
    args=p.parse_args();out=stage.guarded(args.out);out.mkdir(parents=True,exist_ok=False)
    if not 65<=args.seconds<=180:raise ValueError('Bounded final inventory run required')
    plan=out/'plan.json';stage.receipt(plan,client_plan())
    server=irc.IrcStage3Server(out/'server',timeout=args.seconds+120,linger=args.seconds+30,allow_legacy_lf=True)
    worker=threading.Thread(target=server.run,daemon=True);worker.start()
    if not server.ready.wait(10):raise RuntimeError('Local IRC endpoint did not become ready')
    command=[sys.executable,'-I','-B',str(HERE/'run_win16_stage3_app.py'),
            '--out',str(out/'guest'),'--base',str(args.base),'--tag','client','--plan',str(plan),
            '--provider',str(args.provider),'--controller',str(args.controller),
            '--build-root',str(args.build_root),'--qemu',str(args.qemu),'--seconds',str(args.seconds)]
    with (out/'runner.log').open('xb') as log:
        result=subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,timeout=args.seconds+500)
    if not server.finished.wait(args.seconds+140):raise RuntimeError('Local endpoint completion timeout')
    worker.join()
    pcap=out/'guest/client-run/network.pcap'
    network=irc.parse_pcap(pcap,server_ip='172.31.8.2',allow_legacy_lf=True)
    stage.receipt(out/'pcap-summary.json',network)
    receipt={'scope':irc.SCOPE,'runner_exit':result.returncode,'server_pass':server.summary['pass'],
             'pcap_pass':network['pass'],'protocol_pass':result.returncode==0 and server.summary['pass'] and network['pass'],
             'original_mirc_sha256':stage.sha(LIBRARY/'MIRC.EXE'),'provider_sha256':stage.sha(args.provider),
             'pcap_sha256':stage.sha(pcap),'visual_review_required':True,'application_binary_patched':False,
             'registration_data_used':False,'new_os_installation':False,'command':command}
    receipt['allow_legacy_lf']=True
    stage.receipt(out/'irc-verdict.json',receipt);print(json.dumps(receipt))
    return 0 if receipt['protocol_pass'] else 1


if __name__=='__main__':raise SystemExit(main())
