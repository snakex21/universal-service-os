"""Drive real USOS menu transitions using serial events, with one endpoint image.

No screenshot, QMP state or log-file progress polling. QMP is a client of
an already listening local server; commands answer concrete UI events.
The single endpoint capture requires a separate human/agent assessment:
the runner never calls a visible menu or a timeout a Windows desktop PASS.
"""
from pathlib import Path
import argparse
import asyncio
import importlib.util
import json
import os
import re
import shutil
import subprocess
import time

spec = importlib.util.spec_from_file_location('coverage_fixture', Path(__file__).with_name('prepare_stick.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class Qmp:
    def __init__(self):
        self.connected = asyncio.Event()
        self.pending = {}
        self.sequence = 0
        self.writer = None

    async def accept(self, reader, writer):
        self.writer = writer
        await reader.readline()  # Greeting.
        self.connected.set()
        try:
            while line := await reader.readline():
                response = json.loads(line)
                identifier = response.get('id')
                if identifier in self.pending:
                    self.pending.pop(identifier).set_result(response)
        except (ConnectionResetError, OSError):
            pass  # Expected when our child is stopped after the endpoint capture.
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(ConnectionError('QMP closed'))

    async def command(self, name, arguments=None):
        await self.connected.wait()
        self.sequence += 1
        identifier = self.sequence
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        self.writer.write((json.dumps(dict(execute=name, arguments=arguments or {}, id=identifier))+'\n').encode())
        await self.writer.drain()
        response = await future
        if 'error' in response:
            raise RuntimeError(response['error'])
        return response.get('return')

    async def key(self, key):
        await self.command('human-monitor-command', {'command-line':'sendkey '+key})
        await asyncio.sleep(.35)  # Pace input release; this does not inspect progress.


def redact(text):
    return re.sub(r'\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b|\b\d{5}-OEM-\d{7}-\d{5}\b|\b\d{3}-\d{7}\b',
                  '[product key omitted]', text, flags=re.I)


async def main(args):
    work = args.fixture.resolve()
    if not work.is_relative_to(fixture.COLLECTION/'_vm'):
        raise ValueError('Only owned collection VM fixtures may be opened writable')
    metadata = json.loads((work/'fixture.json').read_text())
    if metadata['result']['result'] != 'PASS':
        raise ValueError('Fixture preparation was not successful')
    catalog = [json.loads(line) for line in args.catalog.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    matches = [index for index,row in enumerate(catalog) if row['directory'].split('\\')[-2] == metadata['folder']]
    if len(matches) != 1:
        raise ValueError('Fixture folder must match one real catalogue entry')
    desired_system = matches[0]
    resources = fixture.check_resources(work, 2048)
    args.out.mkdir(parents=True, exist_ok=False)
    target = work/'target.qcow2'
    if target.exists() or (work/'vars.fd').exists():
        raise FileExistsError('Refusing to overwrite a previous VM disk or NVRAM')
    subprocess.run([str(args.qemu.parent/'qemu-img.exe'),'create','-q','-f','qcow2',str(target),'4G'], check=True)
    variables = work/'vars.fd'
    shutil.copyfile(args.qemu.parent/'share/edk2-i386-vars.fd', variables)
    qmp = Qmp()
    server = await asyncio.start_server(qmp.accept, '127.0.0.1', 0)
    port = server.sockets[0].getsockname()[1]
    command = [str(args.qemu), '-machine','q35', '-accel','tcg,thread=multi',
        '-cpu','EPYC-Rome', '-smp','2', '-m','2048', '-display','none', '-nic','none',
        '-serial','stdio', '-monitor','none', '-qmp',f'tcp:127.0.0.1:{port},server=off',
        '-drive',f'if=pflash,format=raw,readonly=on,file={(args.qemu.parent/"share/edk2-x86_64-code.fd").as_posix()}',
        '-drive',f'if=pflash,format=raw,file={variables.as_posix()}',
        '-drive',f'if=none,id=stick,format=qcow2,file={(work/"stick.qcow2").as_posix()}',
        '-device','qemu-xhci,id=xhci', '-device','usb-kbd,bus=xhci.0',
        '-device','usb-tablet,bus=xhci.0',
        '-device','usb-storage,bus=xhci.0,drive=stick,removable=on,serial=USOS-COVERAGE-STICK,bootindex=1',
        '-drive',f'if=none,id=target,format=qcow2,file={target.as_posix()}',
        '-device','pcie-root-port,id=nvmeroot,chassis=20,slot=20',
        '-device','nvme,drive=target,serial=USOS-COVERAGE-TARGET,bus=nvmeroot,bootindex=0']
    (args.out/'command.json').write_text(json.dumps(command,indent=2))
    start = time.monotonic()
    events = []
    ui_count = 0
    last_screen = None
    failure = None
    env = dict(os.environ, TEMP=str(work), TMP=str(work), APPDATA=str(work), LOCALAPPDATA=str(work))
    with (args.out/'stderr.log').open('wb') as errors, (args.out/'serial.log').open('w',encoding='utf-8') as log:
        process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=errors, env=env)
        (args.out/'pid.txt').write_text(str(process.pid))
        await asyncio.wait_for(qmp.connected.wait(),30)
        await qmp.command('qmp_capabilities')

        async def consume():
            nonlocal ui_count, last_screen
            while raw := await process.stdout.readline():
                line = redact(raw.decode('utf-8',errors='replace'))
                log.write(line); log.flush()
                if 'first frame presented' in line and ui_count == 0:
                    # The home view has no UI_SCREEN trace in this build.
                    # Its timing marker is the actual first-frame notification.
                    ui_count += 1
                    events.append(dict(seconds=round(time.monotonic()-start,2),text='Home frame presented'))
                    await qmp.key('ret')
                elif '[UI_SCREEN]' in line:
                    if line.strip() == last_screen:
                        continue
                    last_screen = line.strip()
                    events.append(dict(seconds=round(time.monotonic()-start,2), text=line.strip()))
                    ui_count += 1
                    if ui_count > 20:
                        raise RuntimeError('Repeated menu transitions; refusing an input loop')
                    if line.strip().endswith('[UI_SCREEN] list Windows'):
                        # Empty-image rows remain navigable in the actual menu;
                        # Enter alone always selects Windows 11, not our only ISO.
                        for index in range(desired_system):
                            await qmp.key('down')
                        await qmp.key('ret')
                    elif any(kind in line for kind in (' home ', ' list ', ' summary ')):
                        await qmp.key('ret')
                elif '[COVERAGE_MENU]' in line:
                    events.append(dict(seconds=round(time.monotonic()-start,2),text=line.strip()))
                    await asyncio.sleep(1)  # Give the just-opened input device its first frame.
                    if '/run/xp-disk-menu.state' in line:
                        await qmp.key('ret')
                    elif '/run/xp-confirm-menu.state' in line:
                        await qmp.key('up'); await qmp.key('ret')
                elif '[COVERAGE_NOTICE]' in line:
                    events.append(dict(seconds=round(time.monotonic()-start,2),text=line.strip()))
                    await asyncio.sleep(1)
                    await qmp.key('ret')

        consumer = asyncio.create_task(consume())
        try:
            done, _ = await asyncio.wait([consumer,asyncio.create_task(process.wait())],
                                         timeout=args.seconds,return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if task is consumer:
                    task.result()
            if process.returncode is None:
                await qmp.command('screendump',{'filename':str((args.out/'endpoint.ppm').resolve())})
                await qmp.command('human-monitor-command',{'command-line':
                    f'pmemsave 0xb8000 4000 "{(args.out/"endpoint-vga.bin").resolve().as_posix()}"'})
        except Exception as error:
            failure = f'{type(error).__name__}: {error}'
        finally:
            if process.returncode is None:
                process.kill()
            await process.wait()
            await asyncio.gather(consumer,return_exceptions=True)
            server.close(); await server.wait_closed()
            if qmp.writer:
                qmp.writer.close()
                try: await qmp.writer.wait_closed()
                except (ConnectionResetError, OSError): pass
    sizes = {path.name:path.stat().st_size for path in (work/'stick.qcow2',target)}
    variables.unlink(missing_ok=True)
    from PIL import Image
    if (args.out/'endpoint.ppm').exists():
        with Image.open(args.out/'endpoint.ppm') as frame:
            frame.save(args.out/'endpoint.png')
        (args.out/'endpoint.ppm').unlink()
    result = dict(result='RUNNER_ERROR' if failure else 'ASSESS_ENDPOINT', error=failure,
        source=metadata['source'], folder=metadata['folder'],
        events=events, elapsed=round(time.monotonic()-start,2), resources=resources,
        disk_bytes=sizes, total_disk_bytes=sum(sizes.values()), menu_observation=metadata.get('menu_observation'))
    (args.out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    (args.out/'fixture.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
    for path in (work/'stick.qcow2',target):
        path.unlink()  # These exact per-test files only; result is already saved.
    (args.out/'cleanup.json').write_text(json.dumps({'removed':['stick.qcow2','target.qcow2','vars.fd']}),encoding='utf-8')
    print(json.dumps(dict(result=result['result'],events=len(events),seconds=result['elapsed'])),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('qemu','fixture','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--seconds',type=int,default=600)
    parser.add_argument('--catalog',type=Path,default=Path('artifacts/coverage/catalog.ndjson'))
    asyncio.run(main(parser.parse_args()))
