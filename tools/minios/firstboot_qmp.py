#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""One event-driven endpoint: bounded outputs, terminal disk/EOF errors."""
import asyncio
import contextlib
import json

MAX_ENDPOINT_SECONDS = 10800
MAX_EVENT_BYTES = 1024**2


class Qmp:
    def __init__(self,reader,writer):
        self.reader,self.writer = reader,writer
        self.pending = {}; self.serial = 0; self.events = []; self.event_bytes = 0
        loop = asyncio.get_running_loop()
        self.shutdown = loop.create_future()
        self.stopped = loop.create_future()
        self.io_error = loop.create_future()
        self.closed = loop.create_future()
        self.pump = None
        self.failure = None
        self.failure_code = None

    async def open(self):
        greeting = json.loads(await asyncio.wait_for(self.reader.readline(),15))
        if not isinstance(greeting,dict) or 'QMP' not in greeting:
            raise ValueError('Expected QMP greeting')
        self.pump = asyncio.create_task(self.receive())
        await self.command('qmp_capabilities')

    async def receive(self):
        try:
            while line := await self.reader.readline():
                value = json.loads(line)
                if not isinstance(value,dict):raise ValueError('Expected QMP object')
                if 'event' in value:
                    count = len(json.dumps(value,ensure_ascii=True).encode('ascii'))
                    if len(self.events) >= 4096 or self.event_bytes+count > MAX_EVENT_BYTES:
                        raise ValueError('QMP event evidence bound exceeded')
                    self.event_bytes += count; self.events.append(value)
                    if value['event']=='SHUTDOWN' and not self.shutdown.done():self.shutdown.set_result(value)
                    if value['event']=='STOP' and not self.stopped.done():self.stopped.set_result(value)
                    # Every I/O failure is terminal. In particular ENOTSUP from
                    # fixed raw resize must not slip past nospace-only tests.
                    if value['event']=='BLOCK_IO_ERROR' and not self.io_error.done():self.io_error.set_result(value)
                elif value.get('id') in self.pending:
                    future = self.pending.pop(value['id'])
                    if not future.done():
                        if 'error' in value:future.set_exception(ValueError('QMP command failed: '+str(value['error'])))
                        elif 'return' in value:future.set_result(value['return'])
                        else:future.set_exception(ValueError('Incomplete QMP response'))
        except Exception as error:
            self.failure = str(error)
            self.failure_code = getattr(error,'winerror',None) if isinstance(error,OSError) else None
        finally:
            if not self.closed.done():self.closed.set_result(dict(reason='error' if self.failure else 'eof',error=self.failure))
            for future in self.pending.values():
                if not future.done():future.set_exception(ValueError('QMP connection closed'))
            self.pending.clear()

    async def command(self,name,**arguments):
        if self.closed.done():raise ValueError('QMP transport already closed')
        self.serial += 1
        future = asyncio.get_running_loop().create_future(); serial = self.serial
        self.pending[serial] = future
        request = dict(execute=name,id=serial)
        if arguments:request['arguments']=arguments
        self.writer.write(json.dumps(request).encode('ascii')+b'\n')
        await self.writer.drain()
        try:return await asyncio.wait_for(future,30)
        finally:self.pending.pop(serial,None)

    async def close(self):
        self.writer.close()
        with contextlib.suppress(Exception):await self.writer.wait_closed()
        if self.pump:
            self.pump.cancel()
            with contextlib.suppress(asyncio.CancelledError):await self.pump


def clean_quit_close(qmp, own_quit_ack, returncode):
    """Windows QEMU can reset TCP after acknowledging our successful quit."""
    if not qmp.failure:return True
    return (own_quit_ack and returncode==0 and qmp.failure_code in (64,10054) and
        any(e.get('event')=='SHUTDOWN' and e.get('data',{}).get('reason')=='host-qmp-quit' for e in qmp.events))


async def wake_display(qmp):
    """One harmless modifier press/release at the endpoint, never a progress probe."""
    await qmp.command('input-send-event',events=[
        dict(type='key',data=dict(down=True,key=dict(type='qcode',data='shift'))),
        dict(type='key',data=dict(down=False,key=dict(type='qcode',data='shift')))])
    await asyncio.sleep(2)


async def endpoint(command,out,env,seconds,scope=None,header=b'',*,wake_screen=False):
    """One fixed endpoint, with bounded output and immediate EOF/error wakeup."""
    import firstboot_output as output
    import subprocess
    if type(seconds) is not int or not 1<=seconds<=MAX_ENDPOINT_SECONDS:
        raise ValueError('One explicit endpoint of at most10800seconds required')
    if type(wake_screen) is not bool:raise ValueError('Explicit boolean display wake selection required')
    scope=scope or output.Scope(out)
    loop=asyncio.get_running_loop()
    connected=loop.create_future();failed=loop.create_future()
    async def accept(reader,writer):
        if connected.done():writer.close();return
        connected.set_result(Qmp(reader,writer))
    server=await asyncio.start_server(accept,'127.0.0.1',0,limit=MAX_EVENT_BYTES)
    port=server.sockets[0].getsockname()[1]
    full_command=[*command,'-qmp',f'tcp:127.0.0.1:{port}','-no-shutdown']
    child=wait=qmp=pipe=None;pumps=[];own_quit_ack=False
    evidence=dict(endpoint_seconds=seconds,progress_polling=False,windows_gate_passed=False,
        review_required=True,screenshot_created=False,command=list(map(str,full_command)))
    try:
        with scope.open('qemu.stdout',header) as stdout,scope.open('qemu.stderr',header) as stderr:
            child=await asyncio.create_subprocess_exec(*map(str,full_command),stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,stdin=asyncio.subprocess.DEVNULL,env=env,
                creationflags=getattr(subprocess,'CREATE_NO_WINDOW',0))
            wait=asyncio.create_task(child.wait())
            pumps=[asyncio.create_task(output.drain(child.stdout,stdout,failed)),
                   asyncio.create_task(output.drain(child.stderr,stderr,failed))]
            try:
                first,_=await asyncio.wait({connected,wait,failed},timeout=30,return_when=asyncio.FIRST_COMPLETED)
                if failed.done():raise ValueError(failed.result())
                if connected not in first:raise ValueError('QEMU exited or failed before QMP handshake')
                qmp=connected.result();await qmp.open()
                done,_=await asyncio.wait({qmp.shutdown,qmp.stopped,qmp.io_error,qmp.closed,wait,failed},timeout=seconds,
                                          return_when=asyncio.FIRST_COMPLETED)
                if failed.done():raise ValueError(failed.result())
                if qmp.io_error.done():
                    evidence['block_io_error']=qmp.io_error.result()
                    raise ValueError('Terminal BLOCK_IO_ERROR; no CONT')
                if qmp.closed.done():raise ValueError('QMP closed: '+str(qmp.closed.result()))
                unexpected_stop=qmp.stopped in done and qmp.shutdown not in done and wait not in done
                evidence['endpoint_reason']=('unexpected_stop' if unexpected_stop else
                    'guest_shutdown' if qmp.shutdown in done else
                    'qemu_exit' if wait in done else 'fixed_deadline')
                if unexpected_stop:evidence['unexpected_stop']=qmp.stopped.result()
                if wait not in done:
                    if wake_screen and evidence['endpoint_reason']=='fixed_deadline':
                        await wake_display(qmp)
                        evidence['display_wake_sent']=True
                    await qmp.command('stop')
                    pipe=output.ScreenshotPipe(scope)
                    await qmp.command('screendump',filename=pipe.name)
                    capture=await asyncio.wait_for(asyncio.shield(pipe.done),30)
                    if capture.get('error'):raise ValueError(capture['error'])
                    evidence['screenshot']=capture;evidence['screenshot_created']=True
                    await qmp.command('quit')
                    own_quit_ack=True
                evidence['returncode']=await asyncio.wait_for(asyncio.shield(wait),15)
                await asyncio.wait_for(asyncio.gather(*pumps),15)
                # Final flush/stop/quit can emit a late disk error. Consume EOF
                # before judging transport, even if QEMU returned success.
                await asyncio.wait_for(asyncio.shield(qmp.closed),15)
                if qmp.io_error.done():
                    evidence['block_io_error']=qmp.io_error.result()
                    raise ValueError('Terminal late BLOCK_IO_ERROR; no CONT')
                if not clean_quit_close(qmp,own_quit_ack,evidence['returncode']):
                    raise ValueError('Final QMP failure: '+qmp.failure)
                if qmp.failure:evidence['acknowledged_quit_tcp_reset']=qmp.failure_code
                if failed.done():raise ValueError(failed.result())
                if unexpected_stop:
                    evidence['transport_error']='Unexpected QMP STOP before endpoint; no CONT attempted'
            except Exception as error:
                evidence['transport_error']=str(error)
                if not wait.done():child.kill()
                evidence['returncode']=await asyncio.wait_for(asyncio.shield(wait),15)
            finally:
                if not wait.done():child.kill()
                await asyncio.wait_for(asyncio.shield(wait),15)
                await asyncio.wait_for(asyncio.gather(*pumps),15)
    finally:
        server.close()
        if pipe:await pipe.close()
        if qmp:
            evidence['events']=qmp.events;evidence['event_bytes']=qmp.event_bytes
            await qmp.close()
        elif connected.done():await connected.result().close()
        await server.wait_closed()
        if child and wait and not wait.done():child.kill();await asyncio.wait_for(wait,15)
    return evidence
