"""One native NT35 USB-isolation boot of a verified stopped overlay.

Retains the target/stick overlays and copied stopped NVRAM. A single timed
endpoint and explicit operator actions replace progress polling.
"""
from pathlib import Path
import asyncio, hashlib, importlib.util, json, os, shutil, subprocess, time

ROOT=Path(__file__).resolve().parents[3]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
COLLECTION=Path(r'G:\USOS-Kolekcja')
TAG='r20b-nt35-usb-isolation'
WORK=COLLECTION/'_vm'/TAG
BASE=COLLECTION/'_vm/r20-nt35-preserved'
SOURCE=MATRIX/'artifacts/coverage/vm/r20-nt35-network-hid'
OUT=ROOT/'artifacts/coverage/vm'/TAG
QEMU=Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-system-x86_64.exe')
ASSETS=COLLECTION/'_assets/B261020-200536-968CCBE8-nt35-net1'

def load(name,path):
    spec=importlib.util.spec_from_file_location(name,path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);return module

def command(prior,port,capture_port):
    if prior[0]!=str(QEMU) or prior[prior.index('-machine')+1]!='q35':raise ValueError('Unexpected source q35 command')
    for option,value in (('-cpu','EPYC-Rome'),('-smp','2'),('-m','2048'),('-accel','tcg,thread=multi')):
        if prior.count(option)!=1 or prior[prior.index(option)+1]!=value:raise ValueError('Unexpected baseline '+option)
    result=prior.copy();result[result.index('-qmp')+1]=f'tcp:127.0.0.1:{port},server=off'
    source=(COLLECTION/'_vm/r20-nt35-network-hid').as_posix()+'/'
    for index,value in enumerate(result):
        if 'file='+source in value:result[index]=value.replace('file='+source,'file='+WORK.as_posix()+'/')
        if value.startswith('socket,id=nt351mirror,'):
            result[index]=f'socket,id=nt351mirror,host=127.0.0.1,port={capture_port},server=off'
    return result

async def main():
    boot=load('nt35_usb_boot',MATRIX/'tools/tests/coverage/boot_menu.py')
    boot.aux.require_operator_channel(True)
    proof=json.loads((ROOT/'artifacts/nt35-network/r20b-usb-isolation-preparation.json').read_text(encoding='utf-8'))
    meta=json.loads((WORK/'fixture.json').read_text(encoding='utf-8'))
    if meta.get('private_profile') is not False or meta.get('folder')!='Windows NT 3.5':raise ValueError('Explicit keyless NT35 required')
    if not all(proof.get(n) is True for n in ('base_unchanged','hive_only_one_dword_changed','own_sys_unchanged','raw_overlay_qemu_compare_pass')):
        raise ValueError('Verified single-DWORD stopped overlay required')
    if (proof.get('before'),proof.get('after'))!=(1,4):raise ValueError('Only i8042prt Start1 to4')
    if OUT.exists() or (WORK/'vars.fd').exists() or (WORK/'stick.qcow2').exists():raise FileExistsError('Fresh run required')
    with (BASE/'target.qcow2').open('rb') as stream:
        if hashlib.file_digest(stream,'sha256').hexdigest()!=proof['base_sha256']:raise ValueError('Stopped backing changed')
    resources=boot.fixture.check_resources(WORK,2048)  # Exactly one host guard.
    OUT.mkdir(parents=True)
    shutil.copyfile(BASE/'vars.fd',WORK/'vars.fd')
    subprocess.run([str(QEMU.with_name('qemu-img.exe')),'create','-q','-f','qcow2','-F','qcow2','-b',str(BASE/'stick.qcow2'),str(WORK/'stick.qcow2')],check=True)
    qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
    cap=boot.nt351_capture.Capture(OUT/'network.pcap')
    process=None;pump=None;failure=None;shutdown=None;started=time.monotonic()
    capture=None;collection=None;collection_error=None
    try:
        prior=json.loads((SOURCE/'command.json').read_text(encoding='utf-8'))
        # All image/preflight work precedes opening the capture listener.
        with (OUT/'serial.log').open('wb') as serial,(OUT/'stderr.log').open('wb') as errors:
            capture_port=await cap.start();cap.mark_prepared_target()
            cmd=command(prior,server.sockets[0].getsockname()[1],capture_port)
            (OUT/'command.json').write_bytes((json.dumps(cmd,indent=2)+'\n').encode('utf-8'))
            env=dict(os.environ,TEMP=str(WORK),TMP=str(WORK),APPDATA=str(WORK),LOCALAPPDATA=str(WORK))
            process=await asyncio.create_subprocess_exec(*cmd,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env)
            print('COLD_BOOT_STARTED '+TAG,flush=True)
            async def consume():
                while data:=await process.stdout.read(65536):serial.write(data);serial.flush()
            pump=asyncio.create_task(consume())
            await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
            try:await asyncio.wait_for(process.wait(),300)
            except asyncio.TimeoutError:
                await boot.capture(qmp,OUT/'endpoint.png')
                print('ENDPOINT_COMPLETE '+TAG,flush=True)
                await boot.operator_steps(qmp,OUT,False,True,'mouse')
    except Exception as error:failure=type(error).__name__+': '+str(error)
    finally:
        if process and process.returncode is None:
            cap.begin_controlled_shutdown()
            try:await asyncio.wait_for(qmp.command('quit'),3)
            except Exception:pass
            try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
            except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
        elif process:shutdown='guest exited'
        if pump:await pump
        try:capture=await cap.finish(controlled_shutdown=bool(process and process.returncode==0 and shutdown=='QMP quit')) if cap.server else None
        except Exception as error:capture={'error':type(error).__name__+': '+str(error)}
        if qmp.writer:
            qmp.writer.close()
            try:await asyncio.wait_for(qmp.writer.wait_closed(),5)
            except (asyncio.TimeoutError,ConnectionResetError,OSError):pass
        server.close();await asyncio.wait_for(server.wait_closed(),5)
    (OUT/'writer-stopped.json').write_bytes((json.dumps({'stopped':True,'qemu_returncode':process.returncode if process else None})+'\n').encode('utf-8'))
    if process and process.returncode==0:
        import argparse
        try:
            # The imported collector deliberately owns only matrix artifacts.
            collection=await boot.nt35_own.main(argparse.Namespace(qemu=QEMU,assets=ASSETS,fixture=WORK,
                out=MATRIX/'artifacts/coverage/nt35-stopped-r20b/own-evidence'))
        except Exception as error:collection_error=type(error).__name__+': '+str(error)
    result=dict(result='ASSESS_ENDPOINT' if failure is None else 'RUNNER_ERROR',error=failure,
        elapsed=round(time.monotonic()-started,2),resources=resources,qemu_returncode=process.returncode if process else None,
        shutdown=shutdown,retained_overlay=str(WORK/'target.qcow2'),retained=True,
        ps2_controller_enabled=True,i8042prt_start=4,installed_runtime_pass=False,usb_path_pass=False,
        network_capture=capture,nt35_own_evidence=collection,collection_error=collection_error,
        scope='Manual guest assessment required; only i8042prt Start changed on the stopped target')
    (OUT/'result.json').write_bytes((json.dumps(result,indent=2)+'\n').encode('utf-8'))
    (OUT/'completed.json').write_bytes((json.dumps({'stopped':True,'retained_overlay':True})+'\n').encode('utf-8'))
    print('CASE_COMPLETE '+TAG,flush=True)
    return 0 if failure is None else 1

if __name__=='__main__':raise SystemExit(asyncio.run(main()))
