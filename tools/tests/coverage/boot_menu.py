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
spec = importlib.util.spec_from_file_location('usability_aux', Path(__file__).with_name('usability_aux.py'))
aux = importlib.util.module_from_spec(spec)
spec.loader.exec_module(aux)
spec = importlib.util.spec_from_file_location('nt351_own', Path(__file__).with_name('collect_nt351_success.py'))
nt351_own = importlib.util.module_from_spec(spec); spec.loader.exec_module(nt351_own)
spec = importlib.util.spec_from_file_location('nt35_own', Path(__file__).with_name('collect_nt35_success.py'))
nt35_own = importlib.util.module_from_spec(spec); spec.loader.exec_module(nt35_own)
spec = importlib.util.spec_from_file_location('nt351_capture', Path(__file__).with_name('nt351_capture.py'))
nt351_capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(nt351_capture)
spec = importlib.util.spec_from_file_location('nt4_own', Path(__file__).with_name('collect_nt4_success.py'))
nt4_own = importlib.util.module_from_spec(spec); spec.loader.exec_module(nt4_own)
spec = importlib.util.spec_from_file_location('nt4_capture', Path(__file__).with_name('nt4_capture.py'))
nt4_capture = importlib.util.module_from_spec(spec); spec.loader.exec_module(nt4_capture)


class Qmp:
    def __init__(self):
        self.connected = asyncio.Event()
        self.pending = {}
        self.sequence = 0
        self.writer = None
        self.deleted = {}
        self.events = {}

    async def accept(self, reader, writer):
        self.writer = writer
        await reader.readline()  # Greeting.
        self.connected.set()
        try:
            while line := await reader.readline():
                response = json.loads(line)
                event_waiter = self.events.get(response.get('event'))
                if event_waiter and not event_waiter.done():event_waiter.set_result(response)
                if response.get('event') == 'DEVICE_DELETED':
                    future=self.deleted.get(response.get('data',{}).get('device'))
                    if future and not future.done():future.set_result(response)
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
            for future in self.deleted.values():
                if not future.done():future.set_exception(ConnectionError('QMP closed'))
            for future in self.events.values():
                if not future.done():future.set_exception(ConnectionError('QMP closed'))

    def expect_event(self,name):
        if name in self.events:raise ValueError('Duplicate QMP event subscription')
        future=asyncio.get_running_loop().create_future()
        self.events[name]=future
        return future

    def forget_event(self,name,future):
        if self.events.get(name) is future:self.events.pop(name)
        if not future.done():future.cancel()
        elif not future.cancelled():future.exception()

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

    async def delete_device(self,device):
        future=asyncio.get_running_loop().create_future()
        self.deleted[device]=future
        try:
            await self.command('device_del',{'id':device})
            await asyncio.wait_for(future,10)
        finally:
            self.deleted.pop(device,None)
            if not future.done():future.cancel()
            elif not future.cancelled():future.exception()


def redact(text):
    return re.sub(r'\b[A-Z0-9]{5}(?:-[A-Z0-9]{5}){4}\b|\b\d{5}-OEM-\d{7}-\d{5}\b|\b\d{3}-\d{7}\b',
                  '[product key omitted]', text, flags=re.I)


def capture_permitted(private_profile,prepared_proof,prepared,first_logon=False):
    """Staging a private answer is not evidence that Setup passed its key page."""
    return not private_profile or (prepared_proof and prepared) or first_logon


async def start_nt5_target(qmp,usb_test):
    """Answer the real remove-USB/power-off page, then power on the target.

    QEMU stays allocated with -no-shutdown. Wait for the guest's actual
    SHUTDOWN event before reset/cont; no timer or state polling substitutes
    for completed unmount/power-off. This does not prove key acceptance.
    """
    await qmp.delete_device('coverage-install-stick')
    if usb_test:
        await qmp.command('device_add',{'driver':'usb-storage','id':'usability-boot',
            'bus':'xhci.0','drive':'usabilityboot','removable':True,'serial':'USOS-USB-BOOT-TEST'})
    shutdown=qmp.expect_event('SHUTDOWN')
    try:
        await qmp.key('ret')
        notification=await asyncio.wait_for(shutdown,90)
        if notification.get('data',{}).get('guest') is not True:
            raise RuntimeError('Expected guest power-off, not host-requested shutdown')
        await qmp.command('system_reset')
        await qmp.command('cont')
    finally:qmp.forget_event('SHUTDOWN',shutdown)


async def capture(qmp, path):
    from PIL import Image
    ppm = path.with_suffix('.ppm')
    await qmp.command('screendump', {'filename':str(ppm.resolve())})
    with Image.open(ppm) as frame:
        frame.save(path)
    ppm.unlink()


async def operator_steps(qmp, output,usb_test=False,hid_test=False,pointer='tablet'):
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
            return
        if action.get('hid'):
            if not hid_test:raise ValueError('USB input devices were not reserved by this test')
            hid=action['hid'];descriptor=aux.hid_descriptor(hid['device'],pointer)
            if hid['state']=='insert':await qmp.command('device_add',descriptor)
            elif hid['state']=='remove':await qmp.delete_device(descriptor['id'])
            else:raise ValueError('HID action must be insert or remove')
        if action.get('usb'):
            if not usb_test:raise ValueError('No disposable USB test images reserved')
            if action['usb']=='insert':
                await qmp.command('device_add',{'driver':'usb-storage','id':'usability-hot',
                    'bus':'xhci.0','drive':'usabilityhot','removable':True,'serial':'USOS-USB-HOT-TEST'})
            elif action['usb']=='remove':await qmp.delete_device('usability-hot')
            else:raise ValueError('Only insert/remove of the owned hot-plug test stick is allowed')
        keys = action.get('keys',[])
        settle = float(action.get('settle',2))
        if len(keys)>64 or not 0<=settle<=3600 or any(not re.fullmatch('[a-z0-9_-]+',key) for key in keys):
            raise ValueError('Invalid operator input')
        for key in keys:
            await qmp.key(key)
        if action.get('pointer'):
            move=action['pointer']
            if not hid_test or pointer!='mouse':raise ValueError('Relative test requires the owned boot-protocol USB mouse')
            dx,dy=move.get('dx',0),move.get('dy',0)
            click=move.get('click')
            if type(dx)!=int or type(dy)!=int or not -2048<=dx<=2048 or not -2048<=dy<=2048:
                raise ValueError('Invalid bounded relative mouse movement')
            if click is not None and click not in ('left','right','middle'):raise ValueError('Unsupported mouse button')
            await qmp.command('input-send-event',{'events':[
                {'type':'rel','data':{'axis':'x','value':dx}},
                {'type':'rel','data':{'axis':'y','value':dy}}]})
            if click:
                await qmp.command('input-send-event',{'events':[{'type':'btn','data':{'down':True,'button':click}}]})
                await asyncio.sleep(.1)
                await qmp.command('input-send-event',{'events':[{'type':'btn','data':{'down':False,'button':click}}]})
        await asyncio.sleep(settle)
        count += 1
        destination = output/f'operator-{count:02}.png'
        await capture(qmp,destination)
        with (output/'operator-actions.jsonl').open('a',encoding='utf-8') as log:
            log.write(json.dumps({'image':destination.name,'usb':action.get('usb'),
                'hid':action.get('hid'),'pointer':action.get('pointer'),'keys_count':len(keys)})+'\n')
        print('STEP_COMPLETE: '+destination.name,flush=True)
    raise EOFError('Operator channel closed before an explicit finish; test is incomplete')


async def main(args):
    aux.require_operator_channel(args.interactive)
    usb_only=getattr(args,'usb_only_input',False)
    machine=aux.input_machine(args.machine,args.ps2_input,usb_only)
    work = args.fixture.resolve()
    if not work.is_relative_to(fixture.COLLECTION/'_vm'):
        raise ValueError('Only owned collection VM fixtures may be opened writable')
    metadata = json.loads((work/'fixture.json').read_text(encoding='utf-8'))
    aux.validate_failure_collection(getattr(args,'collect_nt4_failure',False),metadata,
                                    getattr(args,'evidence_assets',None),fixture.COLLECTION)
    collect_nt351=getattr(args,'collect_nt351_success',False)
    capture_nt351=getattr(args,'capture_nt351_network',False)
    collect_nt35=getattr(args,'collect_nt35_success',False)
    capture_nt35=getattr(args,'capture_nt35_network',False)
    collect_nt4=getattr(args,'collect_nt4_success',False)
    capture_nt4=getattr(args,'capture_nt4_network',False)
    if sum(bool(v) for v in (collect_nt4 or capture_nt4, collect_nt351 or capture_nt351, collect_nt35 or capture_nt35)) > 1:
        raise ValueError('Choose one explicit OS evidence policy')
    if capture_nt4 and (not collect_nt4 or args.nic!='igb'):
        raise ValueError('NT4 DHCP capture needs NT4 own collector and sole pinned igb')
    if collect_nt4:
        if args.evidence_assets is None:raise ValueError('NT4 collector needs explicit frozen cache')
        nt4_own.validate(metadata,work,args.evidence_assets,args.out/'nt4-network-evidence',
            fixture.COLLECTION,Path(__file__).resolve().parents[3],preflight=True)
    if capture_nt351 and (not collect_nt351 or args.nic!='igb'):
        raise ValueError('NT351 capture requires its own collector and the sole pinned igb')
    if collect_nt351:
        if args.evidence_assets is None:raise ValueError('NT351 collector needs explicit frozen assets')
        nt351_own.validate(metadata,work,args.evidence_assets,args.out/'nt351-own-evidence',
            fixture.COLLECTION,Path(__file__).resolve().parents[3],require_target=False)
    if capture_nt35 and (not collect_nt35 or args.nic!='igb'):
        raise ValueError('NT35 capture requires its own collector and the sole pinned igb')
    if collect_nt35:
        if args.evidence_assets is None:raise ValueError('NT35 collector needs explicit frozen assets')
        nt35_own.validate(metadata,work,args.evidence_assets,args.out/'nt35-own-evidence',
            fixture.COLLECTION,Path(__file__).resolve().parents[3],require_target=False)
    if metadata['result']['result'] != 'PASS':
        raise ValueError('Fixture preparation was not successful')
    if args.auto_native and args.interactive:
        raise ValueError('Choose either the fixed native input scenario or manual interaction')
    catalog = [json.loads(line) for line in args.catalog.read_text(encoding='utf-8-sig').splitlines() if line.strip()]
    matches = [index for index,row in enumerate(catalog) if row['directory'].split('\\')[-2] == metadata['folder']]
    if len(matches) != 1:
        raise ValueError('Fixture folder must match one real catalogue entry')
    desired_system = matches[0]
    system=catalog[desired_system]
    nt5_handoff=metadata['folder'].casefold() in fixture.NT5_FOLDERS
    prepared_proves_key_passed=(system['id']=='windows-95' or
        system.get('uefi_profile','').startswith(('nt3-','nt4-','posready-')))
    if args.interactive and not aux.manual_test_supported(metadata.get('private_profile'),prepared_proves_key_passed,metadata.get('observer_token')):
        raise ValueError('Manual keyed tests need a post-key preparation boundary or an exact first-logon notification')
    usb_test=getattr(args,'usability_usb',False)
    if usb_test and not (prepared_proves_key_passed or aux.valid_logon_token(metadata.get('observer_token'))):
        raise ValueError('USB instrumentation needs a prepared-disk boundary or verified first logon')
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
    command = [str(args.qemu), '-machine',machine, '-accel',acceleration,
        '-cpu',cpu, '-smp','2', '-m',str(args.ram_mib), '-display','none',
        '-serial','stdio', '-monitor','none', '-qmp',f'tcp:127.0.0.1:{port},server=off',
        '-drive',f'if=pflash,format=raw,readonly=on,file={(args.qemu.parent/"share/edk2-x86_64-code.fd").as_posix()}',
        '-drive',f'if=pflash,format=raw,file={variables.as_posix()}',
        '-drive',f'if=none,id=stick,format=qcow2,file={(work/"stick.qcow2").as_posix()}',
        '-device','qemu-xhci,id=xhci']
    command += aux.network_arguments(getattr(args,'nic','none'))
    network_capture=None
    network_capture_result=None
    if capture_nt351 or capture_nt35 or capture_nt4:
        capture_module=nt4_capture if capture_nt4 else nt351_capture
        # The sole NIC and MAC are defined by network_arguments('igb').
        expected=['-netdev','user,id=usabilitynet,hostname=usos-test',
                  '-device','igb,netdev=usabilitynet,mac='+nt351_capture.MAC]
        if aux.network_arguments('igb')!=expected:raise ValueError('Pinned capture NIC changed')
        network_capture=capture_module.Capture(args.out/'network.pcap')
    usb_disks=aux.create_sticks(work,args.qemu) if usb_test else []
    for kind,path in zip(('boot','hot'),usb_disks):
        command+=aux.usb_block_arguments(kind,path)
    if not args.ps2_input:
        pointer=getattr(args,'usb_pointer','tablet')
        command += ['-device','usb-kbd,id=coveragekbd,bus=xhci.0',
                    '-device',f'usb-{pointer},id=coveragepointer,bus=xhci.0']
    command += [
        '-device','usb-storage,id=coverage-install-stick,bus=xhci.0,drive=stick,removable=on,serial=USOS-COVERAGE-STICK,bootindex=1',
        '-drive',f'if=none,id=target,format=qcow2,file={target.as_posix()}']
    if nt5_handoff:command+=['-no-shutdown']
    if args.target_bus == 'nvme':
        if args.machine != 'q35':raise ValueError('NVMe coverage requires q35')
        command += ['-device','pcie-root-port,id=nvmeroot,chassis=20,slot=20',
                    '-device','nvme,drive=target,serial=USOS-COVERAGE-TARGET,bus=nvmeroot,bootindex=0']
    else:
        command += ['-device','ich9-ahci,id=coverageahci',
                    '-device','ide-hd,drive=target,bus=coverageahci.0,serial=USOS-COVERAGE-TARGET,bootindex=0']
    if metadata.get('observer_token') and metadata.get('observer_kind') not in ('9x-runonce','nt4-test-run'):
        command += ['-drive',f'if=none,id=evidencecd,format=raw,readonly=on,media=cdrom,file={(work/"observer.iso").as_posix()}']
        controller='piix3-ide' if metadata.get('observer_ide') else 'ich9-ahci'
        command += ['-device',controller+',id=evidencehba','-device','ide-cd,drive=evidencecd,bus=evidencehba.0']
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
    boot_usb_attached=False
    nt5_synced=False
    nt5_started=False
    env = dict(os.environ, TEMP=str(work), TMP=str(work), APPDATA=str(work), LOCALAPPDATA=str(work))
    with (args.out/'stderr.log').open('wb') as errors, (args.out/'serial.log').open('w',encoding='utf-8') as log:
        try:
            if network_capture:
                capture_port=await network_capture.start()
                command+=capture_module.arguments(capture_port)
            (args.out/'command.json').write_text(json.dumps(command,indent=2))
            process = await asyncio.create_subprocess_exec(*command, stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=errors, env=env)
        except BaseException:
            if network_capture and network_capture.server:await network_capture.finish()
            server.close();await server.wait_closed()
            raise
        (args.out/'pid.txt').write_text(str(process.pid))
        async def consume():
            nonlocal ui_count, last_screen, answer_row, product_failure, native_started, boot_usb_attached, nt5_synced, nt5_started
            while raw := await process.stdout.readline():
                line = redact(raw.decode('utf-8',errors='replace'))
                log.write(line); log.flush()
                if line.strip()=='[LEGACY_XP] PREPARED SYNC PASS; USOS media may now be removed safely':
                    nt5_synced=True
                if line.strip()=='[LEGACY_XP] WAITING FOR USER: remove USOS USB, then press ENTER to power off; target will boot XPSETUP as BIOS 0x80 on next power-on':
                    if not nt5_handoff or not nt5_synced or nt5_started:
                        raise RuntimeError('Unexpected NT5 power-off handoff; no input sent')
                    await start_nt5_target(qmp,usb_test)
                    nt5_started=True
                    boot_usb_attached=usb_test
                    events.append(dict(seconds=round(time.monotonic()-start,2),text='Guest powered off after safe USB removal; reset/cont started the prepared NT5 target; key acceptance still unverified'))
                if aux.logon_notification(metadata.get('observer_token'),line) and not first_logon.is_set():
                    events.append(dict(seconds=round(time.monotonic()-start,2),text='First-logon script COM1 marker received; desktop still needs visual review'))
                    if usb_test and not boot_usb_attached:
                        await qmp.command('device_add',{'driver':'usb-storage','id':'usability-boot',
                            'bus':'xhci.0','drive':'usabilityboot','removable':True,'serial':'USOS-USB-BOOT-TEST'})
                        boot_usb_attached=True
                        events.append(dict(seconds=round(time.monotonic()-start,2),text='Own FAT16 stick attached after first logon; start test requires a subsequent explicit reboot'))
                    if capture_nt4:network_capture.mark_first_logon()
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
                    aux.reject_unanswered_usos_form(line)
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
                    for key in aux.framebuffer_menu_keys(line):
                        await qmp.key(key)
                elif '[COVERAGE_NOTICE]' in line:
                    events.append(dict(seconds=round(time.monotonic()-start,2),text=line.strip()))
                    await asyncio.sleep(1)
                    if 'start the prepared disk' in line and usb_test and not boot_usb_attached:
                        await qmp.command('device_add',{'driver':'usb-storage','id':'usability-boot',
                            'bus':'xhci.0','drive':'usabilityboot','removable':True,'serial':'USOS-USB-BOOT-TEST'})
                        events.append(dict(seconds=round(time.monotonic()-start,2),text='Own FAT16 test stick attached before first prepared-target boot'))
                        boot_usb_attached=True
                    if 'start the prepared disk' in line and network_capture and not capture_nt4:
                        network_capture.mark_prepared_target()
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
                if capture_permitted(metadata.get('private_profile'),prepared_proves_key_passed,prepared.is_set(),first_logon.is_set()):
                    await capture(qmp,args.out/'endpoint.png')
                if args.interactive and not product_failure:
                    if not capture_permitted(metadata.get('private_profile'),prepared_proves_key_passed,prepared.is_set(),first_logon.is_set()):
                        raise RuntimeError('Private Setup has not reached its verified post-key boundary; no manual capture')
                    await operator_steps(qmp,args.out,usb_test,not args.ps2_input,getattr(args,'usb_pointer','tablet'))
                    await capture(qmp,args.out/'endpoint.png')
                if capture_permitted(metadata.get('private_profile'),prepared_proves_key_passed,prepared.is_set(),first_logon.is_set()):
                    await qmp.command('human-monitor-command',{'command-line':
                        f'pmemsave 0xb8000 4000 "{(args.out/"endpoint-vga.bin").resolve().as_posix()}"'})
        except Exception as error:
            failure = f'{type(error).__name__}: {error}'
        finally:
            if process.returncode is None:
                try:
                    if network_capture:network_capture.begin_controlled_shutdown()
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
    if network_capture:
        try:network_capture_result=await network_capture.finish(controlled_shutdown=shutdown_method=='QMP quit' and process.returncode==0)
        except Exception as error:network_capture_result={'error':type(error).__name__+': '+str(error),'installed_runtime_pass':False}
    all_disks=[work/'stick.qcow2',target,*usb_disks]
    sizes = {path.name:path.stat().st_size for path in all_disks}
    allocated = {path.name:fixture.allocated_bytes(path) for path in all_disks}
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
    result['ps2_controller_enabled']=not usb_only
    result['usb_only_input']=usb_only
    result['accel'] = args.accel
    result['cpu'] = cpu
    result['shutdown_method'] = shutdown_method
    result['qemu_returncode'] = process.returncode
    result['first_logon_observed'] = first_logon.is_set()
    result['nt5_target_started'] = nt5_started
    result['native_fixed_input_scenario'] = args.auto_native
    result['nic']=getattr(args,'nic','none')
    result['usb_test_images']=usb_test
    result['usb_pointer']=None if args.ps2_input else getattr(args,'usb_pointer','tablet')
    result['allocated_disk_bytes'] = allocated
    result['total_allocated_disk_bytes'] = sum(allocated.values())
    result['network_capture']=network_capture_result
    if collect_nt4:
        # Target is stopped; actual first logon is checked again before any read.
        if not first_logon.is_set():
            result['nt4_network_evidence_skipped']='actual first logon not observed'
        else:
            try:
                from types import SimpleNamespace
                await nt4_own.main(SimpleNamespace(qemu=args.qemu,assets=args.evidence_assets,
                    fixture=work,out=args.out/'nt4-network-evidence',
                    first_logon_observed=True,network_capture=network_capture_result))
                result['nt4_network_evidence']='nt4-network-evidence/collection.json'
            except Exception as error:
                result['nt4_network_evidence_error']=type(error).__name__+': '+str(error)
    if collect_nt351:
        # Only after outer QEMU ended, before this exact target is deleted.
        # Fits the existing nested reservation; does not run alongside it.
        try:
            from types import SimpleNamespace
            await nt351_own.main(SimpleNamespace(qemu=args.qemu,assets=args.evidence_assets,
                fixture=work,out=args.out/'nt351-own-evidence'))
            result['nt351_own_evidence']='nt351-own-evidence/collection.json'
        except Exception as error:
            result['nt351_own_evidence_error']=type(error).__name__+': '+str(error)
    if collect_nt35:
        # Target writer has ended; collect before this exact target is removed.
        try:
            from types import SimpleNamespace
            await nt35_own.main(SimpleNamespace(qemu=args.qemu,assets=args.evidence_assets,
                fixture=work,out=args.out/'nt35-own-evidence'))
            result['nt35_own_evidence']='nt35-own-evidence/collection.json'
        except Exception as error:
            result['nt35_own_evidence_error']=type(error).__name__+': '+str(error)
    if product_failure and getattr(args,'collect_nt4_failure',False):
        # Outer QEMU and its nested installer have ended. One read-only
        # collector fits the already reserved nested lane; no extra live OS.
        try:
            spec = importlib.util.spec_from_file_location('coverage_failure_collector',Path(__file__).with_name('collect_guest_logs.py'))
            collector = importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
            from types import SimpleNamespace
            await collector.main(SimpleNamespace(qemu=args.qemu,assets=args.evidence_assets,
                fixture=work,out=args.out/'guest-evidence'))
            result['failure_evidence']='guest-evidence/collection.json'
        except Exception as error:
            result['failure_evidence_error']=type(error).__name__+': '+str(error)
    if getattr(args,'collect_nt4_text',False) and not prepared.is_set() and not first_logon.is_set():
        try:
            spec=importlib.util.spec_from_file_location('nt4_native_text',Path(__file__).with_name('collect_nt4_text.py'))
            collector=importlib.util.module_from_spec(spec);spec.loader.exec_module(collector)
            from types import SimpleNamespace
            await collector.main(SimpleNamespace(qemu=args.qemu,assets=args.evidence_assets,
                fixture=work,out=args.out/'native-text-evidence'))
            result['native_text_evidence']='native-text-evidence/collection.json'
        except Exception as error:
            result['native_text_evidence_error']=type(error).__name__+': '+str(error)
    (args.out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    (args.out/'fixture.json').write_text(json.dumps(metadata,indent=2),encoding='utf-8')
    for path in all_disks:
        path.unlink()  # These exact per-test files only; result is already saved.
    (work/'observer.iso').unlink(missing_ok=True)
    (args.out/'cleanup.json').write_text(json.dumps({'removed':[*sizes,'vars.fd','observer.iso (if present)']}),encoding='utf-8')
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
    parser.add_argument('--usb-only-input',action='store_true',help='Disable q35 i8042 so USB HID cannot be replaced by default PS/2 input')
    parser.add_argument('--auto-native',action='store_true',help='Known language-auto + selected-image profile: Enter language, then real disk UI; requires endpoint review')
    parser.add_argument('--nic',choices=('none','igb'),default='none',help='82576 is explicitly supported by usosnet; user-mode networking only')
    parser.add_argument('--collect-nt4-success',action='store_true',help='Private NT4 only: guest-filtered own NET excerpt and driver hash after actual first logon')
    parser.add_argument('--capture-nt4-network',action='store_true',help='DHCP-only mirror after actual NT4 first logon, 8 MiB capped, sole pinned igb')
    parser.add_argument('--collect-nt35-success',action='store_true',help='Read-only five own NT35 files plus pinned installed-driver hash; never runtime PASS')
    parser.add_argument('--capture-nt35-network',action='store_true',help='Passive 8MiB-capped sole igb mirror; needs explicit keyless NT35 collector')
    parser.add_argument('--collect-nt351-success',action='store_true',help='Read-only five own NT351 files plus installed own-driver hash before cleanup; never runtime PASS')
    parser.add_argument('--capture-nt351-network',action='store_true',help='Passive 8 MiB-capped localhost mirror of sole pinned igb; needs keyless NT351 collector')
    parser.add_argument('--collect-nt4-failure',action='store_true',help='Read-only inner Setup evidence before cleanup; exact allowlisted keyless NT3/NT4 cases only')
    parser.add_argument('--collect-nt4-text',action='store_true',help='Read-only sanitized NT4 Setup text logs; no native screenshots or answers')
    parser.add_argument('--evidence-assets',type=Path,help='Explicit frozen cache for the one post-failure collector')
    parser.add_argument('--usb-pointer',choices=('mouse','tablet'),default='tablet',help='Use mouse for the NT4 driver boot-HID path')
    parser.add_argument('--usability-usb',action='store_true',help='Own disposable FAT16 boot/hot-plug sticks; attach boot stick after disk preparation')
    asyncio.run(main(parser.parse_args()))
