"""One cold boot of the stopped R18b target on a retained overlay; no installer."""
from pathlib import Path
import argparse,asyncio,hashlib,importlib.util,json,os,re,shutil,subprocess,time
ROOT=Path(__file__).resolve().parents[3]
MATRIX=Path(r'C:\Users\ASRock\usos-work\macierz-windows')
COLLECTION=Path(r'G:\USOS-Kolekcja')
SOURCE=MATRIX/'artifacts/coverage/vm/r18b-nt351-network-hid'
BASE=COLLECTION/'_vm/r18b-nt351-preserved/target.qcow2'
BASE_HASH='2ca8e3e39f9d97be387c9eabc1d7f61526e32fdd28ba58b3bf223fe7d67364b9'
QEMU=Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-system-x86_64.exe')

def load(name,path):
    s=importlib.util.spec_from_file_location(name,path);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m

def command(prior,work,qmp_port,capture_port,i8042):
    if i8042 not in ('on','off'):raise ValueError('Explicit i8042 comparison required')
    if prior[0]!=str(QEMU) or prior[prior.index('-machine')+1]!='q35,i8042=off':raise ValueError('Unexpected R18b machine')
    for option,value in (('-cpu','EPYC-Rome'),('-smp','2'),('-m','2048'),('-accel','tcg,thread=multi')):
        if prior.count(option)!=1 or prior[prior.index(option)+1]!=value:raise ValueError('Unexpected baseline '+option)
    result=prior.copy()
    result[result.index('-machine')+1]='q35,i8042='+i8042
    result[result.index('-qmp')+1]=f'tcp:127.0.0.1:{qmp_port},server=off'
    replacements={'vars.fd':'vars.fd','stick.qcow2':'stick.qcow2','target.qcow2':'target.qcow2'}
    for index,value in enumerate(result):
        for old,new in replacements.items():
            previous=(COLLECTION/'_vm/r18b-nt351-network-hid'/old).as_posix()
            if 'file='+previous in value:result[index]=value.replace('file='+previous,'file='+(work/new).as_posix())
        if value.startswith('socket,id=nt351mirror,'):
            result[index]=f'socket,id=nt351mirror,host=127.0.0.1,port={capture_port},server=off'
    return result

async def main(args):
    boot=load('owned_matrix_boot',MATRIX/'tools/tests/coverage/boot_menu.py')
    boot.aux.require_operator_channel(True)
    if args.tag!='r18c-nt351-cold-i8042-'+args.i8042:raise ValueError('This matched pair has fixed tags')
    work=COLLECTION/'_vm'/args.tag;out=ROOT/'artifacts/coverage/vm'/args.tag
    assert work.resolve().is_relative_to(COLLECTION.resolve()/'_vm')
    assert not work.exists() and not out.exists()
    metadata=json.loads((SOURCE/'fixture.json').read_text(encoding='utf-8'))
    if metadata.get('private_profile') is not False or metadata.get('folder')!='Windows NT 3.51':raise ValueError('Not explicit keyless NT351')
    previous=json.loads((SOURCE/'result.json').read_text(encoding='utf-8'))
    if previous.get('qemu_returncode')!=0 or not (SOURCE/'cleanup.json').is_file():raise ValueError('Baseline writer completion unconfirmed')
    with BASE.open('rb') as stream:
        if hashlib.file_digest(stream,'sha256').hexdigest()!=BASE_HASH:raise ValueError('Stopped baseline changed')
    resources=boot.fixture.check_resources(COLLECTION/'_vm',2048) # exactly one host guard
    work.mkdir();out.mkdir(parents=True)
    metadata.update(preserved_base=str(BASE),base_sha256=BASE_HASH,comparison='Matched cold boot; i8042='+args.i8042,result={'result':'PASS'})
    (work/'fixture.json').write_text(json.dumps(metadata,indent=2)+'\n',encoding='utf-8')
    img=QEMU.with_name('qemu-img.exe')
    subprocess.run([str(img),'create','-q','-f','qcow2','-F','qcow2','-b',str(BASE),str(work/'target.qcow2')],check=True)
    subprocess.run([str(img),'create','-q','-f','qcow2',str(work/'stick.qcow2'),'10G'],check=True)
    shutil.copyfile(QEMU.parent/'share/edk2-i386-vars.fd',work/'vars.fd')
    qmp=boot.Qmp();server=await asyncio.start_server(qmp.accept,'127.0.0.1',0)
    cap=boot.nt351_capture.Capture(out/'network.pcap')
    process=None;pump=None;started=time.monotonic();failure=None;shutdown=None
    env=dict(os.environ,TEMP=str(work),TMP=str(work),APPDATA=str(work),LOCALAPPDATA=str(work))
    try:
        with (out/'serial.log').open('wb') as serial,(out/'stderr.log').open('wb') as errors:
            port=await cap.start();cap.mark_prepared_target()
            cmd=command(json.loads((SOURCE/'command.json').read_text(encoding='utf-8')),work,server.sockets[0].getsockname()[1],port,args.i8042)
            (out/'command.json').write_text(json.dumps(cmd,indent=2)+'\n',encoding='utf-8')
            process=await asyncio.create_subprocess_exec(*cmd,stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,stderr=errors,env=env)
            print('COLD_BOOT_STARTED '+args.tag,flush=True)
            async def consume():
                while data:=await process.stdout.read(65536):serial.write(data);serial.flush()
            pump=asyncio.create_task(consume())
            try:
                await asyncio.wait_for(qmp.connected.wait(),30);await qmp.command('qmp_capabilities')
                try:await asyncio.wait_for(process.wait(),args.endpoint_seconds)
                except asyncio.TimeoutError:
                    await boot.capture(qmp,out/'endpoint.png')
                    print('ENDPOINT_COMPLETE '+args.tag,flush=True)
                    await boot.operator_steps(qmp,out,False,True,'mouse')
            except Exception as error:failure=type(error).__name__+': '+str(error)
            finally:
                if process.returncode is None:
                    try:await asyncio.wait_for(qmp.command('quit'),3)
                    except Exception:pass
                    try:await asyncio.wait_for(process.wait(),5);shutdown='QMP quit'
                    except asyncio.TimeoutError:process.kill();await process.wait();shutdown='forced after QMP timeout'
                else:shutdown='guest exited'
                if pump:await pump
    except Exception as error:failure=type(error).__name__+': '+str(error)
    finally:
        if process and process.returncode is None:process.kill();await process.wait();shutdown='forced finalizer'
        try:capture=await cap.finish() if cap.server else None
        except Exception as error:capture={'error':type(error).__name__+': '+str(error),'installed_runtime_pass':False}
        server.close();await server.wait_closed()
        if qmp.writer:
            qmp.writer.close()
            try:await qmp.writer.wait_closed()
            except (ConnectionResetError,OSError):pass
    result=dict(result='ASSESS_ENDPOINT' if failure is None else 'RUNNER_ERROR',error=failure,
        resources=resources,elapsed=round(time.monotonic()-started,2),qemu_returncode=process.returncode if process else None,
        shutdown=shutdown,base=str(BASE),base_sha256=BASE_HASH,overlay=str(work/'target.qcow2'),retained=True,
        installed_runtime_pass=False,usb_path_pass=False,ps2_controller_enabled=args.i8042=='on',network_capture=capture,
        comparison_caveats=['Cold boot replaces the previous warm restart','Fresh NVRAM template; original was cleaned',
            'Blank 10GiB USB placeholder preserves device topology; original installer contents were cleaned'])
    (out/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
    (out/'completed.json').write_text(json.dumps({'stopped':True,'retained_overlay':True})+'\n',encoding='utf-8')
    print('CASE_COMPLETE '+args.tag,flush=True)
    return 0 if failure is None else 1

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--tag',required=True);parser.add_argument('--i8042',choices=('off','on'),required=True);parser.add_argument('--endpoint-seconds',type=int,default=300)
    a=parser.parse_args()
    if a.endpoint_seconds!=300:parser.error('Fixed single 300-second endpoint')
    raise SystemExit(asyncio.run(main(a)))
