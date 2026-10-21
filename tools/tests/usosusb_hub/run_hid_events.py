"""NT3/NT4 USB reconnect regression using passive serial and QMP events.

Runs the unchanged real driver in the existing bare-metal test shim. This
is a QEMU driver regression, not a fresh Windows installation or LAN/MSC
PASS. All writes stay in the explicitly selected new artifact directory.
"""
from pathlib import Path
import argparse
import asyncio
import hashlib
import importlib.util
import json
import os
import re

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
spec=importlib.util.spec_from_file_location('hub_build',HERE/'run_hub_qemu.py')
build=importlib.util.module_from_spec(spec);spec.loader.exec_module(build)


class SerialEvents:
    def __init__(self):
        self.lines=[];self.condition=asyncio.Condition();self.closed=False

    async def consume(self,reader,log):
        try:
            while raw:=await reader.readline():
                log.write(raw);log.flush()
                async with self.condition:
                    self.lines.append(raw.decode('ascii',errors='replace').rstrip())
                    self.condition.notify_all()
        finally:
            async with self.condition:
                self.closed=True;self.condition.notify_all()

    async def wait(self,pattern,after=0,timeout=60):
        expression=re.compile(pattern)
        async def completed():
            async with self.condition:
                while True:
                    for line in self.lines[after:]:
                        if expression.search(line):return line
                    if self.closed:raise ConnectionError('Guest serial closed before expected input record')
                    await self.condition.wait()
        return await asyncio.wait_for(completed(),timeout)


class Qmp:
    def __init__(self):self.ready=asyncio.Event();self.pending={};self.deleted={};self.number=0
    async def accept(self,reader,writer):
        self.writer=writer;await reader.readline();self.ready.set()
        try:
            while raw:=await reader.readline():
                message=json.loads(raw)
                if message.get('event')=='DEVICE_DELETED':
                    future=self.deleted.get(message.get('data',{}).get('device'))
                    if future and not future.done():future.set_result(message)
                future=self.pending.pop(message.get('id'),None)
                if future and not future.done():future.set_result(message)
        finally:
            for future in [*self.pending.values(),*self.deleted.values()]:
                if not future.done():future.set_exception(ConnectionError('QMP closed'))
    async def command(self,name,args=None):
        self.number+=1;identifier=self.number
        future=asyncio.get_running_loop().create_future();self.pending[identifier]=future
        try:
            self.writer.write((json.dumps(dict(execute=name,arguments=args or {},id=identifier))+'\n').encode())
            await self.writer.drain();result=await asyncio.wait_for(future,10)
            if 'error' in result:raise RuntimeError(result['error'])
            return result.get('return')
        finally:self.pending.pop(identifier,None)
    async def delete(self,identifier):
        future=asyncio.get_running_loop().create_future();self.deleted[identifier]=future
        try:
            await self.command('device_del',dict(id=identifier));await asyncio.wait_for(future,10)
        finally:
            self.deleted.pop(identifier,None)
            if not future.done():future.cancel()


def mouse_verified(lines):
    records=[line.split() for line in lines if line.startswith('MOU ')]
    moved=any(len(r)==4 and (int(r[1]) or int(r[2])) for r in records)
    buttons=[int(r[3],16) for r in records if len(r)==4]
    return moved and any(b&1 for b in buttons) and any(b&2 for b in buttons)


async def trial(args):
    work=args.out.resolve()
    if not work.is_relative_to(ROOT/'artifacts') or work.exists():
        raise ValueError('Use a new artifact directory in this worktree')
    work.mkdir(parents=True)
    pe=build.build(args.variant,work)
    kernel=work/'usosusb-hid.mb';build.to_multiboot(pe,kernel)
    source=ROOT/'tools/nt4/usosusb/src/usosusb.c'
    if args.after_file:
        if args.completion_helper is None:raise ValueError('Explicit completion helper required with after-file')
        spec=importlib.util.spec_from_file_location('completion',args.completion_helper)
        completion=importlib.util.module_from_spec(spec);spec.loader.exec_module(completion)
        await asyncio.to_thread(completion.after_file,args.after_file)
    qmp=Qmp();serial=SerialEvents();readers=[];connections=[]
    async def serial_accept(reader,writer):
        connections.append(writer)
        with (work/'serial.log').open('wb') as log:
            await serial.consume(reader,log)
    async def qmp_accept(reader,writer):
        connections.append(writer);await qmp.accept(reader,writer)
    servers=[await asyncio.start_server(qmp_accept,'127.0.0.1',0),
             await asyncio.start_server(serial_accept,'127.0.0.1',0)]
    ports=[s.sockets[0].getsockname()[1] for s in servers]
    command=[str(args.qemu),'-machine','q35,i8042=off','-accel','tcg','-cpu','max','-m','256',
        '-display','none','-nic','none','-no-reboot','-kernel',str(kernel),'-monitor','none',
        '-qmp',f'tcp:127.0.0.1:{ports[0]},server=off',
        '-serial',f'tcp:127.0.0.1:{ports[1]},server=off',
        '-device','qemu-xhci,id=xhci',
        '-device','usb-hub,bus=xhci.0,port=1,id=hub',
        '-device','usb-kbd,bus=xhci.0,port=2,id=kroot',
        '-device','usb-mouse,bus=xhci.0,port=3,id=mroot',
        '-device','usb-kbd,bus=xhci.0,port=1.1,id=khub',
        '-device','usb-mouse,bus=xhci.0,port=1.2,id=mhub']
    result=dict(variant=args.variant,scope='QEMU real driver with test kernel/class shims; no installed Windows',
        source_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),cases=[],windows_installation_pass=False,
        mass_storage_tested=False,network_tested=False,physical_writes=False)
    (work/'command.json').write_text(json.dumps(command,indent=2)+'\n',encoding='utf-8')
    async def check(label,action,pattern):
        before=len(serial.lines)
        await action()
        record=await serial.wait(pattern,after=before)
        result['cases'].append(dict(name=label,result='PASS',record=record))
        print('HID_CASE_COMPLETE '+args.variant+' '+label,flush=True)
    async def keyboard(label):
        before=len(serial.lines)
        await qmp.command('human-monitor-command',{'command-line':'sendkey a'})
        await serial.wait(r'^KBD .* d$',after=before)
        await serial.wait(r'^KBD .* u$',after=before)
        result['cases'].append(dict(name=label,result='PASS',make_and_break=True))
    async def mouse(label):
        before=len(serial.lines)
        await qmp.command('input-send-event',{'events':[{'type':'rel','data':{'axis':'x','value':17}},
            {'type':'rel','data':{'axis':'y','value':9}}]})
        await serial.wait(r'^MOU (?!0 0 )',after=before)
        await qmp.command('input-send-event',{'events':[{'type':'btn','data':{'down':True,'button':'left'}}]})
        await serial.wait(r'^MOU .* 0*1$',after=before)
        await qmp.command('input-send-event',{'events':[{'type':'btn','data':{'down':False,'button':'left'}}]})
        await serial.wait(r'^MOU .* 0*2$',after=before)
        if not mouse_verified(serial.lines[before:]):raise RuntimeError('Missing mouse motion or button down/up records')
        result['cases'].append(dict(name=label,result='PASS',movement_and_buttons=True))
    error=None;process=None
    with (work/'stderr.log').open('wb') as stderr:
        try:
            process=await asyncio.create_subprocess_exec(*command,stdout=asyncio.subprocess.DEVNULL,stderr=stderr,
                env=dict(os.environ,TEMP=str(work),TMP=str(work)))
            await asyncio.wait_for(qmp.ready.wait(),30);await qmp.command('qmp_capabilities')
            await serial.wait(r'REG Diag=.* p5\.2:s\d+-M',timeout=240)
            await keyboard('boot keyboard');await mouse('boot mouse')
            # Remove the newer hub devices first, leaving only root inputs.
            await check('hub keyboard removed',lambda:qmp.delete('khub'),r'REG Diag=.* p5\.1-gone')
            await check('hub mouse removed',lambda:qmp.delete('mhub'),r'REG Diag=.* p5\.2-gone')
            await keyboard('root keyboard remains usable');await mouse('root mouse remains usable')
            for attempt in (1,2):
                old='kroot' if attempt==1 else 'kroot1'
                await check(f'root keyboard removed {attempt}',lambda:qmp.delete(old),r'REG Diag=(?:.* p6-gone){'+str(attempt)+'}')
                await check(f'root keyboard reattached {attempt}',lambda:qmp.command('device_add',
                    dict(driver='usb-kbd',id='kroot'+str(attempt),bus='xhci.0',port='2')),r'REG Diag=(?:.* p6-gone.* p6:s\d+K-){'+str(attempt)+'}')
                await keyboard(f'root keyboard make/break after replug {attempt}')
                old='mroot' if attempt==1 else 'mroot1'
                await check(f'root mouse removed {attempt}',lambda:qmp.delete(old),r'REG Diag=(?:.* p7-gone){'+str(attempt)+'}')
                await check(f'root mouse reattached {attempt}',lambda:qmp.command('device_add',
                    dict(driver='usb-mouse',id='mroot'+str(attempt),bus='xhci.0',port='3')),r'REG Diag=(?:.* p7-gone.* p7:s\d+-M){'+str(attempt)+'}')
                await mouse(f'root mouse move/click after replug {attempt}')
            await check('hub keyboard reattached',lambda:qmp.command('device_add',
                dict(driver='usb-kbd',id='khub2',bus='xhci.0',port='1.1')),r'REG Diag=.* p5\.1-gone.* p5\.1:s\d+K-')
            await keyboard('hub keyboard make/break after replug')
            await check('hub mouse reattached',lambda:qmp.command('device_add',
                dict(driver='usb-mouse',id='mhub2',bus='xhci.0',port='1.2')),r'REG Diag=.* p5\.2-gone.* p5\.2:s\d+-M')
            await mouse('hub mouse move/click after replug')
        except Exception as exception:error=type(exception).__name__+': '+str(exception)
        finally:
            if process:
                try:await qmp.command('quit')
                except Exception:pass
                try:await asyncio.wait_for(process.wait(),10)
                except asyncio.TimeoutError:process.kill();await process.wait()
            for server in servers:server.close();await server.wait_closed()
            for writer in connections:writer.close()
    result.update(result='FAIL' if error else 'PASS',error=error,exit_code=process.returncode if process else None)
    kernel.unlink(missing_ok=True)
    result['multiboot_image_removed']=not kernel.exists()
    (work/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    print('HID_TRIAL_COMPLETE '+args.variant+' '+result['result'],flush=True)
    return 1 if error else 0


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--variant',choices=('nt31','nt4'),required=True)
    parser.add_argument('--qemu',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    parser.add_argument('--after-file',type=Path,help='Reserve this single engine only after an owned completion notification')
    parser.add_argument('--completion-helper',type=Path,help='Reviewed coverage run_plan.py exposing the blocking after_file')
    raise SystemExit(asyncio.run(trial(parser.parse_args())))
