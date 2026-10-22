"""One installed NT35 IRQ qualification boot; never a fresh installation.

Start only after the parent coordinates the R26 result. One normal resource
guard, one planned endpoint, explicit operator actions, bounded capture.
"""
from pathlib import Path
import asyncio
import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[3]
MATRIX = Path(r'C:\Users\ASRock\usos-work\macierz-windows')
PRIOR = Path(r'C:\Users\ASRock\usos-work\nt35-net')
COLLECTION = Path(r'G:\USOS-Kolekcja')
TAG = 'nt35-irq-fixed01'
WORK = COLLECTION / '_vm' / TAG
BASE = COLLECTION / '_vm/r20b-nt35-usb-isolation'
OUT = ROOT / 'artifacts/coverage/vm' / TAG
SOURCE = PRIOR / 'artifacts/coverage/vm/r20b-nt35-usb-isolation'
QEMU = Path(r'C:\Users\ASRock\usos-work\bety-instalacja\tools\qemu\qemu-system-x86_64.exe')
NEW_DRIVER = 'd94ec3e28014a98b6eacdcb75c5b6bc4324a68af814dc00ec8fb574f99fe4c85'
SOURCE_COMMAND_SHA256 = '9fd03a93112d29fa6f65c68ce9aaa772e44e9ae2eec52dac64189f5689b4c8be'


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def digest(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def command(prior, port, capture_port):
    if prior[0] != str(QEMU) or prior[prior.index('-machine') + 1] != 'q35':
        raise ValueError('Unexpected retained command')
    for option, value in (('-cpu', 'EPYC-Rome'), ('-smp', '2'), ('-m', '2048'), ('-accel', 'tcg,thread=multi')):
        if prior.count(option) != 1 or prior[prior.index(option) + 1] != value:
            raise ValueError('Unexpected retained ' + option)
    if prior.count('igb,netdev=usabilitynet,mac=52:54:00:55:53:01') != 1:
        raise ValueError('One exact retained igb required')
    drives = [prior[index + 1] for index, value in enumerate(prior) if value == '-drive']
    expected = [
        'if=pflash,format=raw,readonly=on,file=' + (QEMU.parent / 'share/edk2-x86_64-code.fd').as_posix(),
        'if=pflash,format=raw,file=' + (BASE / 'vars.fd').as_posix(),
        'if=none,id=stick,format=qcow2,file=' + (BASE / 'stick.qcow2').as_posix(),
        'if=none,id=target,format=qcow2,file=' + (BASE / 'target.qcow2').as_posix(),
    ]
    if drives != expected:
        raise ValueError('Only the pinned firmware and three owned image files are allowed')
    result = prior.copy()
    result[result.index('-qmp') + 1] = f'tcp:127.0.0.1:{port},server=off'
    source = BASE.as_posix() + '/'
    mapped = 0
    for index, value in enumerate(result):
        if 'file=' + source in value:
            if value.rsplit('/', 1)[1] not in ('vars.fd', 'stick.qcow2', 'target.qcow2'):
                raise ValueError('Unexpected retained file')
            result[index] = value.replace('file=' + source, 'file=' + WORK.as_posix() + '/')
            mapped += 1
        if value.startswith('socket,id=nt351mirror,'):
            result[index] = f'socket,id=nt351mirror,host=127.0.0.1,port={capture_port},server=off'
    if mapped != 3:
        raise ValueError('Exactly three retained image paths required')
    return result


async def main():
    boot = load('nt35_irq_runtime', MATRIX / 'tools/tests/coverage/boot_menu.py')
    boot.aux.require_operator_channel(True)
    proof = json.loads((ROOT / 'artifacts/nt35-irq/preparation.json').read_text('utf-8'))
    meta = json.loads((WORK / 'fixture.json').read_text('utf-8'))
    if meta.get('private_profile') is not False or meta.get('folder') != 'Windows NT 3.5':
        raise ValueError('Explicit keyless NT35 required')
    if not all(proof.get(name) is True for name in ('base_unchanged', 'system_unchanged',
            'usb_unchanged', 'only_owned_sys_ranges_changed', 'raw_overlay_qemu_compare_pass')):
        raise ValueError('Verified owned-SYS-only overlay required')
    if proof.get('candidate_sha256') != NEW_DRIVER or proof.get('i8042prt_start') != 4:
        raise ValueError('Pinned IRQ candidate and existing USB isolation required')
    if OUT.exists() or (WORK / 'vars.fd').exists() or (WORK / 'stick.qcow2').exists():
        raise FileExistsError('Fresh run required')
    if digest(BASE / 'target.qcow2') != proof['base_sha256'] or digest(WORK / 'target.qcow2') != proof['overlay_sha256']:
        raise ValueError('Retained base or prepared overlay changed')
    if digest(ROOT / 'tools/nt/usosnet/bin/i386/usosnet35.sys') != NEW_DRIVER:
        raise ValueError('Owned candidate changed')
    if digest(SOURCE / 'command.json') != SOURCE_COMMAND_SHA256:
        raise ValueError('Retained source command changed')
    prior = json.loads((SOURCE / 'command.json').read_text('utf-8'))
    command(prior, 1, 2)  # Validate static hardware before the one host guard.
    resources = boot.fixture.check_resources(WORK, 2048)
    OUT.mkdir(parents=True)
    shutil.copyfile(BASE / 'vars.fd', WORK / 'vars.fd')
    subprocess.run([str(QEMU.with_name('qemu-img.exe')), 'create', '-q', '-f', 'qcow2',
        '-F', 'qcow2', '-b', str(BASE / 'stick.qcow2'), str(WORK / 'stick.qcow2')], check=True)
    sources = {str(path): digest(path) for path in (Path(__file__),
        MATRIX / 'tools/tests/coverage/boot_menu.py', MATRIX / 'tools/tests/coverage/nt351_capture.py',
        SOURCE / 'command.json', QEMU)}
    (OUT / 'preflight.json').write_text(json.dumps(dict(resources=resources,
        reserve_mib=8192, candidate_sha256=NEW_DRIVER, preparation=proof, source_sha256=sources), indent=2), encoding='utf-8')
    qmp = boot.Qmp()
    server = await asyncio.start_server(qmp.accept, '127.0.0.1', 0)
    cap = boot.nt351_capture.Capture(OUT / 'network.pcap')
    process = None
    pump = None
    failure = None
    shutdown = None
    capture = None
    started = time.monotonic()
    try:
        with (OUT / 'serial.log').open('wb') as serial, (OUT / 'stderr.log').open('wb') as errors:
            capture_port = await cap.start()
            cap.mark_prepared_target()
            cmd = command(prior, server.sockets[0].getsockname()[1], capture_port)
            (OUT / 'command.json').write_text(json.dumps(cmd, indent=2), encoding='utf-8')
            env = dict(os.environ, TEMP=str(WORK), TMP=str(WORK), APPDATA=str(WORK), LOCALAPPDATA=str(WORK))
            process = await asyncio.create_subprocess_exec(*cmd, stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE, stderr=errors, env=env)
            print('COLD_BOOT_STARTED ' + TAG, flush=True)

            async def consume():
                while data := await process.stdout.read(65536):
                    serial.write(data)
                    serial.flush()

            pump = asyncio.create_task(consume())
            await asyncio.wait_for(qmp.connected.wait(), 30)
            await qmp.command('qmp_capabilities')
            try:
                await asyncio.wait_for(process.wait(), 300)
            except asyncio.TimeoutError:
                await boot.capture(qmp, OUT / 'endpoint.png')
                print('ENDPOINT_COMPLETE ' + TAG, flush=True)
                await boot.operator_steps(qmp, OUT, False, True, 'mouse')
    except Exception as error:
        failure = type(error).__name__ + ': ' + str(error)
    finally:
        if process and process.returncode is None:
            cap.begin_controlled_shutdown()
            try:
                await asyncio.wait_for(qmp.command('quit'), 3)
            except Exception:
                pass
            try:
                await asyncio.wait_for(process.wait(), 5)
                shutdown = 'QMP quit'
            except asyncio.TimeoutError:
                process.kill()
                await process.wait()
                shutdown = 'forced after QMP timeout'
        elif process:
            shutdown = 'guest exited'
        if pump:
            await pump
        try:
            capture = await cap.finish(controlled_shutdown=bool(process and process.returncode == 0 and shutdown == 'QMP quit')) if cap.server else None
        except Exception as error:
            capture = {'error': type(error).__name__ + ': ' + str(error)}
        if qmp.writer:
            qmp.writer.close()
            try:
                await asyncio.wait_for(qmp.writer.wait_closed(), 5)
            except (asyncio.TimeoutError, ConnectionResetError, OSError):
                pass
        server.close()
        await asyncio.wait_for(server.wait_closed(), 5)
    record = dict(result='ASSESS_ENDPOINT' if failure is None else 'RUNNER_ERROR', error=failure,
        elapsed=round(time.monotonic() - started, 2), resources=resources,
        qemu_returncode=process.returncode if process else None, shutdown=shutdown,
        retained_overlay=str(WORK / 'target.qcow2'), retained=True, candidate_sha256=NEW_DRIVER,
        i8042prt_start=4, installed_runtime_pass=False, irq_latency_pass=False,
        network_capture=capture, postquit_readback_pending=True,
        scope='Installed NT35 driver qualification only; manual native guest evidence and stopped readback required')
    (OUT / 'result.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    (OUT / 'completed.json').write_text(json.dumps(dict(stopped=True, retained_overlay=True)), encoding='utf-8')
    print('CASE_COMPLETE ' + TAG, flush=True)
    return 0 if failure is None else 1


if __name__ == '__main__':
    raise SystemExit(asyncio.run(main()))
