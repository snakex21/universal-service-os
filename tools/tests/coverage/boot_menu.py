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
import sys
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
                    future = self.pending.pop(identifier)
                    if not future.done():future.set_result(response)
        except (ConnectionResetError, OSError):
            pass  # Expected when our child is stopped after the endpoint capture.
        finally:
            for future in self.pending.values():
                if not future.done():
                    future.set_exception(ConnectionError('QMP closed'))

    async def command(self, name, arguments=None):
        await asyncio.wait_for(self.connected.wait(),10)
        self.sequence += 1
        identifier = self.sequence
        future = asyncio.get_running_loop().create_future()
        self.pending[identifier] = future
        try:
            self.writer.write((json.dumps(dict(execute=name, arguments=arguments or {}, id=identifier))+'\n').encode())
            await self.writer.drain()
            response = await asyncio.wait_for(future,10)
        finally:
            self.pending.pop(identifier,None)
            if not future.done():future.cancel()
            elif not future.cancelled():future.exception()
        if 'error' in response:
            raise RuntimeError(response['error'])
        return response.get('return')

    async def key(self, key):
        await self.command('human-monitor-command', {'command-line':'sendkey '+key})
        await asyncio.sleep(.35)  # Pace input release; this does not inspect progress.


def redact(text):
    return re.sub(r'\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b|\b\d{5}-OEM-\d{7}-\d{5}\b|\b\d{3}-\d{7}\b',
                  '[product key omitted]', text, flags=re.I)


async def capture(qmp, path):
    from PIL import Image
    ppm = path.with_suffix('.ppm')
    await qmp.command('screendump', {'filename':str(ppm.resolve())})
    with Image.open(ppm) as frame:
        frame.save(path)
    ppm.unlink()


async def operator_steps(qmp, output):
    """Block for an explicit operator action, then emit its completed frame.

    This is manual UI interaction, not a recurring progress observer. The
    operator can answer an actual visible Setup question and assess the
    resulting frame. Never use this adapter with a real product key visible.
    """
    print('AWAITING_OPERATOR: endpoint.png; send JSON keys/settle, or finish=true',flush=True)
    count = 0
    while line := await asyncio.to_thread(sys.stdin.readline):
        action = json.loads(line)
        if action.get('finish'):
            break
        keys = action.get('keys',[])
        settle = float(action.get('settle',2))
        if len(keys)>64 or not 0<=settle<=3600 or any(not re.fullmatch('[a-z0-9_-]+',key) for key in keys):
            raise ValueError('Invalid operator input')
        for key in keys:
            await qmp.key(key)
        await asyncio.sleep(settle)
        count += 1
        destination = output/f'operator-{count:02}.png'
        await capture(qmp,destination)
        print('STEP_COMPLETE: '+destination.name,flush=True)


async def main(args):
    work = args.fixture.resolve()
    if not work.is_relative_to(fixture.COLLECTION/'_vm'):
        raise ValueError('Only owned collection VM fixtures may be opened writable')
    metadata = json.loads((work/'fixture.json').read_text(encoding='utf-8'))
    if metadata['result']['result'] != 'PASS':
        raise ValueError('Fixture preparation was not successful')
    if args.interactive and metadata.get('private_profile'):
        raise ValueError('Manual screenshots are restricted to keyless tests')
    if args.auto_native and args.interactive:
        raise ValueError('Choose either the fixed native input scenario or manual interaction')
    catalog = [json.loads(line) for line in args.catalog.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    matches = [index for index,row in enumerate(catalog) if row['directory'].split('\\')[-2] == metadata['folder']]
    if len(matches) != 1:
        raise ValueError('Fixture folder must match one real catalogue entry')
    desired_system = matches[0]
    system=catalog[desired_system]
    prepared_proves_key_passed=(system['id']=='windows-95' or
        system.get('uefi_profile','').startswith(('nt3-','nt4-','posready-')))
    resources = fixture.check_resources(work, args.ram_mib)
    args.out.mkdir(parents=True, exist_ok=False)
    target = work/'target.qcow2'
    if target.exists() or (work/'vars.fd').exists():
        raise FileExistsError('Refusing to overwrite a previous VM disk or NVRAM')
    subprocess.run([str(args.qemu.parent/'qemu-img.exe'),'create','-q','-f','qcow2',str(target),f'{args.target_gib}G'], check=True)
    variables = work/'vars.fd'
    shutil.copyfile(args.qemu.parent/'share/edk2-i386-vars.fd', variables)
    qmp = Qmp()
    server = await asyncio.start_server(qmp.accept, '127.0.0.1', 0)
    port = server.sockets[0].getsockname()[1]
    acceleration = ('whpx,kernel-irqchip=off' if args.accel == 'whpx' else 'tcg,thread=multi')
    cpu = ('qemu64,+ssse3,+sse4.1,+sse4.2,+popcnt' if args.accel == 'whpx' else 'EPYC-Rome')
    command = [str(args.qemu), '-machine',args.machine, '-accel',acceleration,
        '-cpu',cpu, '-smp','2', '-m',str(args.ram_mib), '-display','none', '-nic','none',
        '-serial','stdio', '-monitor','none', '-qmp',f'tcp:127.0.0.1:{port},server=off',
        '-drive',f'if=pflash,format=raw,readonly=on,file={(args.qemu.parent/"share/edk2-x86_64-code.fd").as_posix()}',
        '-drive',f'if=pflash,format=raw,file={variables.as_posix()}',
        '-drive',f'if=none,id=stick,format=qcow2,file={(work/"stick.qcow2").as_posix()}',
        '-device','qemu-xhci,id=xhci']
    if not args.ps2_input:
        command += ['-device','usb-kbd,id=coveragekbd,bus=xhci.0',
                    '-device','usb-tablet,id=coveragepointer,bus=xhci.0']
    command += [
        '-device','usb-storage,bus=xhci.0,drive=stick,removable=on,serial=USOS-COVERAGE-STICK,bootindex=1',
        '-drive',f'if=none,id=target,format=qcow2,file={target.as_posix()}']
    if args.target_bus == 'nvme':
        if args.machine != 'q35':raise ValueError('NVMe coverage requires q35')
        command += ['-device','pcie-root-port,id=nvmeroot,chassis=20,slot=20',
                    '-device','nvme,drive=target,serial=USOS-COVERAGE-TARGET,bus=nvmeroot,bootindex=0']
    else:
        command += ['-device','ich9-ahci,id=coverageahci',
                    '-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0']
    if metadata.get('observer_token') and metadata.get('observer_kind')!='9x-runonce':
        command += ['-drive',f'if=none,id=evidencecd,format=raw,readonly=on,media=cdrom,file={(work/"observer.iso").as_posix()}']
        controller='piix3-ide' if metadata.get('observer_ide') else 'ich9-ahci'
        command += ['-device',controller+',id=evidencehba','-device','ide-cd,drive=evidencecd,bus=evidencehba.0']
    (args.out/'command.json').write_text(json.dumps(command,indent=2))
    start = time.monotonic()
    events = []
    ui_count = 0
    last_screen = None
    answer_row = None
    failure = None
    shutdown_method = 'already exited'
    prepared = asyncio.Event()
    product_failed = asyncio.Event()
    first_logon = asyncio.Event()
    product_failure = None
    native_actions=[]
    native_started=False
    env = dict(os.environ, TEMP=str(work), TMP=str(work), APPDATA=str(work), LOCALAPPDATA=str(work))
    with (args.out/'stderr.log').open('wb') as errors, (args.out/'serial.log').open('w',encoding='utf-8') as log:
        process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE, stderr=errors, env=env)
        (args.out/'pid.txt').write_text(str(process.pid))
        async def consume():
            nonlocal ui_count, last_screen, answer_row, product_failure, native_started
            while raw := await process.stdout.readline():
                line = redact(raw.decode('utf-8',errors='replace'))
                log.write(line); log.flush()
                if metadata.get('observer_token') and metadata['observer_token'] in line:
                    events.append(dict(seconds=round(time.monotonic()-start,2),text='First-logon script COM1 marker received; desktop still needs visual review'))
                    first_logon.set()
                elif 'first frame presented' in line and ui_count == 0:
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
                    elif metadata.get('answer_profile') and ' list ' in line and any(word in line.lower() for word in ('answer','unattended')):
                        answer_row = 0  # Wait for the real profile row trace.
                    elif any(kind in line for kind in (' home ', ' list ', ' summary ')):
                        await qmp.key('ret')
                elif '[UI_ROW]' in line and answer_row is not None:
                    if line.strip().startswith('[UI_ROW] profile |'):
                        await qmp.key('home')
                        for index in range(answer_row):
                            await qmp.key('down')
                        await qmp.key('ret')
                        answer_row = None
                        events.append(dict(seconds=round(time.monotonic()-start,2),text='Selected real USOS profile'))
                    else:
                        answer_row += 1
                elif '[PROFILE]' in line and 'skipped:' in line and metadata.get('answer_profile'):
                    raise RuntimeError('The real UEFI profile parser rejected the test profile: '+line.strip())
                elif args.auto_native and 'CORE -> WIMBOOT UEFI' in line and not native_started:
                    native_started=True
                    async def native_input():
                        # Explicit scenario: language=auto preserves Setup's
                        # first language page; the profile chooses its image
                        # and accepts EULA. The next page is the real disk UI.
                        # No screen/status sampling, and only disposable
                        # targets are present writable in this test.
                        await asyncio.sleep(180)
                        await qmp.key('ret')
                        await asyncio.sleep(20)
                        await qmp.key('ret')
                    native_actions.append(asyncio.create_task(native_input()))
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
                    if 'start the prepared disk' in line:
                        prepared.set()
                elif '[COVERAGE_FAILURE]' in line:
                    product_failure = line.strip()
                    events.append(dict(seconds=round(time.monotonic()-start,2),text=product_failure))
                    product_failed.set()

        consumer = None
        waiters = []
        async def boot_endpoint():
            await prepared.wait()
            await asyncio.sleep(args.boot_seconds)
        async def failure_endpoint():
            await product_failed.wait()
            await asyncio.sleep(2)  # Complete the error frame that emitted the event.
        async def first_logon_endpoint():
            await first_logon.wait()
            await asyncio.sleep(30)
        try:
            await asyncio.wait_for(qmp.connected.wait(),30)
            await qmp.command('qmp_capabilities')
            consumer = asyncio.create_task(consume())
            waiters = [consumer,asyncio.create_task(process.wait()),asyncio.create_task(failure_endpoint())]
            if args.boot_seconds is not None:
                waiters.append(asyncio.create_task(boot_endpoint()))
            if metadata.get('observer_token'):
                waiters.append(asyncio.create_task(first_logon_endpoint()))
            done, _ = await asyncio.wait(waiters,
                                         timeout=args.seconds,return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if task is consumer:
                    task.result()
            if process.returncode is None:
                # A keyed nested Setup may still be displaying the supplied
                # value on failure. Only capture after the product itself
                # verified preparation and offered its finished target boot.
                if not metadata.get('private_profile') or (prepared.is_set() and prepared_proves_key_passed) or first_logon.is_set():
                    await capture(qmp,args.out/'endpoint.png')
                if args.interactive:
                    await operator_steps(qmp,args.out)
                    await capture(qmp,args.out/'endpoint.png')
                if not metadata.get('private_profile') or (prepared.is_set() and prepared_proves_key_passed) or first_logon.is_set():
                    await qmp.command('human-monitor-command',{'command-line':
                        f'pmemsave 0xb8000 4000 "{(args.out/"endpoint-vga.bin").resolve().as_posix()}"'})
        except Exception as error:
            failure = f'{type(error).__name__}: {error}'
        finally:
            if process.returncode is None:
                try:
                    await asyncio.wait_for(qmp.command('quit'),3)
                except Exception:
                    pass  # QEMU may close QMP before its quit reply arrives.
                try:
                    await asyncio.wait_for(process.wait(),5)
                    shutdown_method = 'QMP quit'
                except asyncio.TimeoutError:
                    process.kill();await process.wait()
                    shutdown_method = 'forced termination after QMP timeout'
            if consumer:await asyncio.gather(consumer,return_exceptions=True)
            for task in waiters:
                if not task.done():task.cancel()
            await asyncio.gather(*waiters,return_exceptions=True)
            for task in native_actions:
                if not task.done():task.cancel()
            await asyncio.gather(*native_actions,return_exceptions=True)
            server.close(); await server.wait_closed()
            if qmp.writer:
                qmp.writer.close()
                try: await qmp.writer.wait_closed()
                except (ConnectionResetError, OSError): pass
    sizes = {path.name:path.stat().st_size for path in (work/'stick.qcow2',target)}
    allocated = {path.name:fixture.allocated_bytes(path) for path in (work/'stick.qcow2',target)}
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
    result['product_failure'] = product_failure
    result['input'] = 'PS/2' if args.ps2_input else 'USB xHCI'
    result['accel'] = args.accel
    result['cpu'] = cpu
    result['shutdown_method'] = shutdown_method
    result['first_logon_observed'] = first_logon.is_set()
    result['native_fixed_input_scenario'] = args.auto_native
    result['allocated_disk_bytes'] = allocated
    result['total_allocated_disk_bytes'] = sum(allocated.values())
    (args.out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    (args.out/'fixture.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
    for path in (work/'stick.qcow2',target):
        path.unlink()  # These exact per-test files only; result is already saved.
    (work/'observer.iso').unlink(missing_ok=True)
    (args.out/'cleanup.json').write_text(json.dumps({'removed':['stick.qcow2','target.qcow2','vars.fd','observer.iso (if present)']}),encoding='utf-8')
    print(json.dumps(dict(result=result['result'],events=len(events),seconds=result['elapsed'])),flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('qemu','fixture','out'):
        parser.add_argument('--'+name,type=Path,required=True)
    parser.add_argument('--seconds',type=int,default=600)
    parser.add_argument('--catalog',type=Path,default=Path('artifacts/coverage/catalog.ndjson'))
    parser.add_argument('--interactive',action='store_true',help='Keep keyless VM at endpoint for explicit manual UI actions')
    parser.add_argument('--ram-mib',type=int,default=2048)
    parser.add_argument('--target-gib',type=int,default=4)
    parser.add_argument('--target-bus',choices=('nvme','ahci'),default='nvme')
    parser.add_argument('--machine',choices=('q35','pc'),default='q35')
    parser.add_argument('--accel',choices=('tcg','whpx'),default='tcg',help='Explicit host accelerator; record CPU differences, never silently fall back')
    parser.add_argument('--boot-seconds',type=int,help='One endpoint after the real prepared-disk notice and target boot')
    parser.add_argument('--ps2-input',action='store_true',help='Use default QEMU PS/2 keyboard/mouse; USB stick stays on xHCI')
    parser.add_argument('--auto-native',action='store_true',help='Known language-auto + selected-image profile: Enter language, then real disk UI; requires endpoint review')
    asyncio.run(main(parser.parse_args()))
