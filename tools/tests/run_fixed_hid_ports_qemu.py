"""Actual paused QEMU configuration test. No guest/HID input verdict."""
from pathlib import Path
import argparse,asyncio,importlib.util,json,os,re,subprocess,time

HERE=Path(__file__).resolve().parent
def module(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
ui=module('own_ui',HERE/'coverage/boot_menu.py')
fixed=module('own_fixed',HERE/'coverage/fixed_hid_ports.py')

async def run(qemu,folder):
    resources=ui.fixture.check_resources(folder,64)
    qmp=ui.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
    port=server.sockets[0].getsockname()[1]
    image=folder/'own-blank.qcow2'
    subprocess.run([str(qemu.parent/'qemu-img.exe'),'create','-q','-f','qcow2',str(image),'2M'],check=True)
    command=[str(qemu),'-name','USOS-R84-HID-PORT-CONFIGURATION','-machine','q35','-accel','tcg','-m','64','-S',
             '-display','none','-monitor','none','-serial','none','-nic','none',
             '-qmp',f'tcp:127.0.0.1:{port},server=off','-device','qemu-xhci,id=xhci',
             '-device','usb-kbd,id=coveragekbd,bus=xhci.0','-device','usb-mouse,id=coveragepointer,bus=xhci.0',
             '-drive',f'if=none,id=ownstick,format=qcow2,file={image.as_posix()}',
             '-device','usb-storage,id=ownstickusb,bus=xhci.0,drive=ownstick']
    (folder/'command.json').write_text(json.dumps(command,indent=2)+'\n')
    env=dict(os.environ,TEMP=str(folder),TMP=str(folder),APPDATA=str(folder),LOCALAPPDATA=str(folder))
    record={'kind':'REAL_PAUSED_QEMU_HID_PORT_TEST','resources':resources,'windows_pass':False,'guest_hid_pass':False,'operations':[]}
    start=time.monotonic();failure=None
    with (folder/'stderr.log').open('wb') as errors:
        process=await asyncio.create_subprocess_exec(*command,stdin=asyncio.subprocess.DEVNULL,stdout=asyncio.subprocess.DEVNULL,stderr=errors,env=env)
        try:
            await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
            async def inventory():
                # A completed configuration assertion, never a progress loop.
                text=await qmp.command('human-monitor-command',{'command-line':'info usb'})
                ports={}
                for line in text.splitlines():
                    for identifier in fixed.PORTS:
                        if identifier in line:
                            match=re.search(r'Port ([0-9.]+),',line)
                            if not match:raise ValueError('Unknown info usb port format: '+line)
                            ports[identifier]=match[1]
                if set(ports)!=set(fixed.PORTS):raise ValueError('Owned HID inventory incomplete: '+text)
                return ports
            initial=await inventory();record['initial_ports']=initial
            await qmp.delete_device('coveragepointer')
            await qmp.command('device_add',{'driver':'usb-mouse','id':'coveragepointer','bus':'xhci.0'})
            auto=await inventory();record['automatic_reinsert_ports']=auto
            record['automatic_mouse_moved']=auto['coveragepointer']!=initial['coveragepointer']
            for identifier,driver in [('coveragepointer','usb-mouse'),('coveragekbd','usb-kbd')]:
                for cycle in range(2):
                    await qmp.delete_device(identifier)
                    desc=fixed.pin({'driver':driver,'id':identifier,'bus':'xhci.0'})
                    await qmp.command('device_add',desc)
                    ports=await inventory()
                    if ports[identifier]!=fixed.PORTS[identifier]:raise AssertionError(ports)
                    record['operations'].append({'device':identifier,'cycle':cycle+1,'port':ports[identifier]})
        except Exception as error:failure=type(error).__name__+': '+str(error)
        finally:
            if process.returncode is None:
                try:await qmp.command('quit')
                except Exception:pass
                try:await asyncio.wait_for(process.wait(),10)
                except asyncio.TimeoutError:process.kill();await process.wait()
            server.close();await server.wait_closed()
            if qmp.writer:qmp.writer.close()
    record.update(qemu_exit=process.returncode,seconds=round(time.monotonic()-start,3),error=failure,
                  result='PASS' if failure is None and process.returncode==0 else 'FAIL')
    (folder/'result.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))
    if record['result']!='PASS':raise SystemExit(1)

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--qemu',type=Path,required=True);parser.add_argument('--work',type=Path,required=True)
    args=parser.parse_args();assert not args.work.exists();args.work.mkdir(parents=True)
    asyncio.run(run(args.qemu.resolve(),args.work.resolve()))
