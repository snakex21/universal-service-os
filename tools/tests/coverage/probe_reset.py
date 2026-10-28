"""Compare OVMF warm reset with WHPX/TCG using only the own USOS EFI menu.

No Windows installer, key, writable system disk, periodic screenshots or
status sampling. Each reset waits for the actual first-frame serial event.
"""
from pathlib import Path
import argparse
import asyncio
import importlib.util
import json
import os
import re
import shutil
import time

spec=importlib.util.spec_from_file_location('menu',Path(__file__).with_name('boot_menu.py'))
menu=importlib.util.module_from_spec(spec);spec.loader.exec_module(menu)


async def case(args,accel):
    work=menu.fixture.COLLECTION/'_vm'/(args.tag+'-'+accel)
    out=args.out/accel
    menu.fixture.check_resources(menu.fixture.COLLECTION,2048)
    work.mkdir(parents=True,exist_ok=False);out.mkdir(parents=True,exist_ok=False)
    esp=work/'esp';boot=esp/'EFI/BOOT';boot.mkdir(parents=True)
    shutil.copyfile(args.assets/'zig-out/bin/usos-x86_64.efi',boot/'BOOTX64.EFI')
    settings=esp/'EFI/USOS';settings.mkdir()
    (settings/'usos-settings.ini').write_text('language=en\nboot_logo=0\n')
    variables=work/'vars.fd';shutil.copyfile(args.qemu.parent/'share/edk2-i386-vars.fd',variables)
    qmp=menu.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
    port=server.sockets[0].getsockname()[1]
    command=[str(args.qemu),'-machine','q35','-accel','whpx,kernel-irqchip=off' if accel=='whpx' else 'tcg,thread=multi',
        '-cpu','qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt','-smp','2','-m','2048','-display','none','-nic','none',
        '-monitor','none','-serial','stdio','-qmp',f'tcp:127.0.0.1:{port},server=off',
        '-drive',f'if=pflash,format=raw,readonly=on,file={(args.qemu.parent/"share/edk2-x86_64-code.fd").as_posix()}',
        '-drive',f'if=pflash,format=raw,file={variables.as_posix()}',
        '-drive',f'if=none,id=esp,format=raw,readonly=on,file=fat:ro:{esp.as_posix()}',
        '-device','qemu-xhci,id=xhci','-device','usb-kbd,bus=xhci.0',
        '-device','usb-storage,drive=esp,bus=xhci.0,bootindex=0']
    (out/'command.json').write_text(json.dumps(command,indent=2))
    first=asyncio.Event();events=[];start=time.monotonic();consumer=None
    result=dict(scope='own EFI menu reset probe; no Windows test',accel=accel,events=events)
    with (out/'serial.log').open('wb') as log,(out/'stderr.log').open('wb') as errors:
        process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,
            env=dict(os.environ,TEMP=str(work),TMP=str(work),APPDATA=str(work),LOCALAPPDATA=str(work)))
        async def consume():
            while line:=await process.stdout.readline():
                log.write(line);log.flush()
                if b'first frame presented' in line:
                    events.append(dict(seconds=round(time.monotonic()-start,2),event='menu first frame'))
                    first.set()
        try:
            await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
            consumer=asyncio.create_task(consume())
            await asyncio.wait_for(first.wait(),60)
            result['stage']='send warm reset after first frame'
            first.clear();await qmp.command('system_reset')
            try:
                await asyncio.wait_for(first.wait(),45)
                result['reset']='menu first frame received'
            except asyncio.TimeoutError:
                result['reset']='no first-frame event within the defined 45-second reset trial'
            result['stage']='reset notification trial complete'
        except Exception as error:result['error']=type(error).__name__+': '+str(error)
        finally:
            if process.returncode is None:
                try:await asyncio.wait_for(qmp.command('quit'),3)
                except Exception:pass
                try:await asyncio.wait_for(process.wait(),5)
                except asyncio.TimeoutError:process.kill();await process.wait()
            if consumer:await asyncio.gather(consumer,return_exceptions=True)
            server.close();await server.wait_closed()
            if qmp.writer:qmp.writer.close()
    result['exit_code']=process.returncode
    variables.unlink()
    (boot/'BOOTX64.EFI').unlink();(settings/'usos-settings.ini').unlink()
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result),flush=True)


async def main(args):
    if not re.fullmatch('[a-z0-9-]+',args.tag):raise ValueError('Invalid owned probe tag')
    if not args.out.resolve().is_relative_to(Path(__file__).resolve().parents[3]/'artifacts/coverage'):
        raise ValueError('Reset evidence must stay in this coverage worktree')
    for accel in ('whpx','tcg'):await case(args,accel)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('assets','qemu','out'):parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--tag',default='reset-probe')
    asyncio.run(main(parser.parse_args()))
