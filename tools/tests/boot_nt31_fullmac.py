"""One retained NT31 full-MAC overlay, native NCPA install and manual evidence."""
from pathlib import Path
import asyncio,hashlib,importlib.util,json,os,time
ROOT=Path(__file__).resolve().parents[2]
MATRIX=ROOT.parent/'macierz-windows'
TAG='r24-nt31-intel-fullmac'
WORK=Path(r'G:\USOS-Kolekcja\_vm')/TAG
OUT=ROOT/'artifacts/nt31-fullmac-runtime/vm'/TAG
PREP=ROOT/'artifacts/nt31-fullmac-runtime/r24-preparation.json'
SOURCE=MATRIX/'artifacts/coverage/vm/r19c-nt31-usb-isolation'
QEMU=ROOT.parent/'bety-instalacja/tools/qemu/qemu-system-x86_64.exe'
def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()
def command(prior,qmp_port,capture_args):
    if prior[0]!=str(QEMU):raise ValueError('Pinned QEMU path required')
    for option,value in (('-machine','q35'),('-cpu','EPYC-Rome'),('-smp','2'),('-m','2048'),('-accel','tcg,thread=multi'),('-nic','none')):
        if prior.count(option)!=1 or prior[prior.index(option)+1]!=value:raise ValueError('Unexpected stopped baseline '+option)
    if any('igb' in value or 'isa-debugcon' in value for value in prior):raise ValueError('Baseline must have no NIC/debugcon')
    result=prior.copy();i=result.index('-nic');del result[i:i+2]
    result[result.index('-qmp')+1]=f'tcp:127.0.0.1:{qmp_port},server=off'
    for leaf in ('target.qcow2','vars.fd','stick.qcow2'):
        old=(Path(r'G:\USOS-Kolekcja\_vm\r19c-nt31-usb-isolation')/leaf).as_posix()
        matched=[i for i,v in enumerate(result) if 'file='+old in v]
        if len(matched)!=1:raise ValueError('Exact retained baseline path required')
        i,=matched;result[i]=result[i].replace('file='+old,'file='+(WORK/leaf).as_posix())
    result+=['-netdev','user,id=usabilitynet,hostname=usos-test','-device','igb,addr=0x05,netdev=usabilitynet,mac=52:54:00:55:53:01',
             '-chardev','file,id=us31diag,path='+(OUT/'debug-e9.log').as_posix(),'-device','isa-debugcon,iobase=0xe9,chardev=us31diag']
    return result+capture_args
async def main():
    boot=load('nt31_owned_matrix_boot',MATRIX/'tools/tests/coverage/boot_menu.py');boot.aux.require_operator_channel(True)
    if OUT.exists():raise FileExistsError('Never repeat an existing VM run')
    prep=json.loads(PREP.read_text(encoding='utf-8'))
    if prep.get('tag')!=TAG or prep.get('staged_readback_pass') is not True or prep.get('runtime_pass') is not False:raise ValueError('Actual preparation required')
    for leaf,key in (('target.qcow2','overlay_sha256'),('vars.fd','vars_sha256'),('stick.qcow2','stick_sha256')):
        if sha(WORK/leaf)!=prep[key]:raise ValueError('Prepared own file changed '+leaf)
    if sha(Path(prep['base']))!=prep['base_sha256']:raise ValueError('Readonly stopped base changed')
    if json.loads((SOURCE/'completed.json').read_text(encoding='utf-8')).get('stopped') is not True:raise ValueError('Baseline writer unconfirmed')
    previous=json.loads((SOURCE/'command.json').read_text(encoding='utf-8'))
    command(previous,12345,[]) # all adaptive preflight before resources/listeners
    resources=boot.fixture.check_resources(WORK,2048) # one real memory guard; 8GiB host reserve
    OUT.mkdir(parents=True)
    tools={p.name:sha(p) for p in (Path(__file__),MATRIX/'tools/tests/coverage/boot_menu.py',MATRIX/'tools/tests/coverage/nt351_capture.py')}
    (OUT/'preflight.json').write_bytes((json.dumps(dict(resources=resources,preparation_sha256=sha(PREP),startup_tool_sha256=tools,scope='Native NT31 NCPA; no Windows PASS from preflight'),indent=2)+'\n').encode('utf-8'))
    qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
    cap=boot.nt351_capture.Capture(OUT/'network.pcap')
    process=None;pump=None;failure=None;shutdown=None;capture=None;start=time.monotonic();controlled=False
    env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
    try:
        with (OUT/'serial.log').open('xb') as serial,(OUT/'stderr.log').open('xb') as errors:
            port=await cap.start();cap.mark_prepared_target()
            cmd=command(previous,server.sockets[0].getsockname()[1],boot.nt351_capture.arguments(port))
            (OUT/'command.json').write_bytes((json.dumps(cmd,indent=2)+'\n').encode('utf-8'))
            process=await asyncio.create_subprocess_exec(*cmd,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env)
            print('NT31_FULLMAC_STARTED '+TAG,flush=True)
            async def consume():
                while data:=await process.stdout.read(65536):serial.write(data);serial.flush()
            pump=asyncio.create_task(consume())
            await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
            # Shield the writer wait: endpoint timeout never cancels/restarts QEMU.
            try:await asyncio.wait_for(asyncio.shield(process.wait()),300)
            except asyncio.TimeoutError:
                await boot.capture(qmp,OUT/'endpoint.png');print('ENDPOINT_COMPLETE '+TAG,flush=True)
                await boot.operator_steps(qmp,OUT,False,True,'mouse')
    except Exception as error:failure=type(error).__name__+': '+str(error)
    finally:
        if process and process.returncode is None:
            controlled=True;cap.begin_controlled_shutdown()
            try:await asyncio.wait_for(qmp.command('quit'),3)
            except Exception:pass
            try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
            except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
        elif process:shutdown='guest exited'
        if pump:await pump
        try:capture=await cap.finish(controlled_shutdown=controlled) if cap.server else None
        except Exception as error:capture=dict(error=type(error).__name__+': '+str(error),installed_runtime_pass=False)
        if qmp.writer:
            qmp.writer.close()
            try:await asyncio.wait_for(qmp.writer.wait_closed(),3)
            except (ConnectionError,OSError,asyncio.TimeoutError):pass
        server.close();await asyncio.wait_for(server.wait_closed(),3)
    result=dict(result='ASSESS_GUEST' if failure is None else 'RUNNER_ERROR',error=failure,qemu_returncode=process.returncode if process else None,
        elapsed=round(time.monotonic()-start,2),shutdown=shutdown,retained_overlay=True,base_unchanged=sha(Path(prep['base']))==prep['base_sha256'],
        driver_sha256=prep['driver_sha256'],network_capture=capture,installed_runtime_pass=False,dhcp='not applicable: original NT31 static TCP/IP',
        limits=['UP-kernel-only explicitBDF00:05.0','Intel82576 only','Native NCPA requires install/configuration and reboot','No general PCI/X470 qualification'])
    (OUT/'result.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))
    (OUT/'completed.json').write_bytes(b'{"stopped":true,"retained_overlay":true}\n')
    print('CASE_COMPLETE '+TAG,flush=True)
    return 0 if failure is None else 1
if __name__=='__main__':raise SystemExit(asyncio.run(main()))
