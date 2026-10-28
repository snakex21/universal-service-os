"""SPDX-License-Identifier: GPL-3.0-or-later
Event-driven evidence from the own native RDP host and the guest COM probe.
The client uses only a restricted QEMU loopback port and disables persistence.
"""
from pathlib import Path
import json,queue,subprocess,threading

def run(executable,port,incoming,serial,out):
    startup=subprocess.STARTUPINFO()
    startup.dwFlags|=subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow=0
    process=subprocess.Popen([str(Path(executable).resolve()),str(port),str(out)],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,
        cwd=out,startupinfo=startup,creationflags=subprocess.CREATE_NO_WINDOW)
    events=queue.Queue()
    def listen(source,reader):
        try:
            while True:
                line=reader.readline()
                if not line:break
                events.put((source,line))
        except OSError as error:events.put((source,str(error).encode()))
        finally:events.put((source,None))
    for source,reader in [('client',process.stdout),('guest',incoming)]:
        threading.Thread(target=listen,args=(source,reader),daemon=True).start()
    connected=False;remote=False;session=None;pending=None;completed=False;ci_ok=False
    try:
        with (out/'native-client.log').open('wb') as client_log, (out/'rdp-serial.log').open('wb') as guest_log:
            while not completed:
                source,line=events.get(timeout=330)
                if line is None:raise RuntimeError(source+' closed before RDP evidence completed')
                log=client_log if source=='client' else guest_log
                log.write(line);log.flush()
                text=line.decode(errors='replace').strip();print(text,flush=True)
                if source=='client':
                    if text=='NATIVE_RDP_LOGON_COMPLETE':
                        connected=True
                        if pending:serial.sendall(b'A');pending=None
                    if text.startswith(('NATIVE_ERROR','NATIVE_KEYS_FAILED','NATIVE_KEYS_UNAVAILABLE','NATIVE_CAPTURE_FAILED','NATIVE_RDP_TIMEOUT','NATIVE_RDP_DISCONNECTED')):
                        raise RuntimeError(text)
                else:
                    if text.startswith('CI_QUERY=') and int(text.split('=')[1],16):raise RuntimeError(text)
                    if text.startswith('CI_OPTIONS='):ci_ok=bool(int(text.split('=')[1],16)&2)
                    if text.startswith('RDP_REMOTE_METRIC='):remote=int(text.split('=')[1],16)!=0
                    if text.startswith('RDP_SESSION_ID='):session=int(text.split('=')[1],16)
                    if text in ('WM_RDP_DESKTOP','WM_RDP_WINVER'):
                        if not ci_ok or not remote or not session:raise RuntimeError('Probe is not in a remote session with TESTSIGNING active')
                        if pending:raise RuntimeError('Overlapping screenshot requests')
                        # Capture comes from GDI inside the proved remote
                        # session, then is retrieved after native shutdown.
                        # An off-screen ActiveX PrintWindow can be blank.
                        if connected:serial.sendall(b'A')
                        else:pending=text
                    if text.startswith(('RDP_CAPTURE_DESKTOP=','RDP_CAPTURE_WINVER=')) and int(text.split('=')[1],16):raise RuntimeError(text)
                    if text=='WM_RDP_COMPLETE':
                        serial.sendall(b'A');completed=True
        process.stdin.write(b'quit\n');process.stdin.flush();code=process.wait(timeout=30)
        if code:raise RuntimeError('Native client exited '+str(code))
        (out/'rdp-result.json').write_text(json.dumps({'protocol_completed':True,
            'client':'own native RDP ActiveX host; persistent bitmap cache disabled',
            'remote_session':remote,'session_id':session,
            'network':'QEMU restrict=on; hostfwd 127.0.0.1 only',
            'visual_acceptance':'inspect screenshots separately'},indent=2))
    finally:
        if process.returncode is None:
            try:
                process.stdin.write(b'quit\n');process.stdin.flush();process.wait(timeout=15)
            except (OSError,subprocess.TimeoutExpired):process.terminate();process.wait(timeout=30)
