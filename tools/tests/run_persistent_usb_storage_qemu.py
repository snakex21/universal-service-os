"""Real paused-QEMU backend lifetime test; no Windows or guest USB PASS."""
from pathlib import Path
import argparse,json,os,socket,subprocess,sys,time

ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/tests/coverage'))
from persistent_usb_storage import STICKS,block_arguments

class Qmp:
    def __init__(self,stream):self.stream=stream;self.ident=0;self.events=[]
    def read(self):
        line=self.stream.readline()
        if not line:raise EOFError('QMP closed before operation completion')
        return json.loads(line)
    def command(self,name,arguments=None):
        self.ident+=1
        item={'execute':name,'id':self.ident}
        if arguments is not None:item['arguments']=arguments
        self.stream.write(json.dumps(item).encode()+b'\n');self.stream.flush()
        while True:
            answer=self.read()
            if 'event' in answer:self.events.append(answer);continue
            if answer.get('id')!=self.ident:raise RuntimeError('Unexpected QMP response')
            if 'error' in answer:raise RuntimeError(answer['error'])
            return answer['return']
    def remove(self,device):
        self.command('device_del',{'id':device})
        while True:
            for index,event in enumerate(self.events):
                if event.get('event')=='DEVICE_DELETED' and event.get('data',{}).get('device')==device:
                    self.events.pop(index);return
            event=self.read()
            if 'event' not in event:raise RuntimeError('Unexpected reply while waiting for DEVICE_DELETED')
            self.events.append(event)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--qemu',type=Path,required=True)
    parser.add_argument('--work',type=Path,required=True)
    args=parser.parse_args()
    work=args.work.resolve()
    if work.exists():raise FileExistsError('Use a new owned test folder')
    work.mkdir(parents=True)
    qemu=args.qemu.resolve();qimg=qemu.with_name('qemu-img.exe' if qemu.suffix=='.exe' else 'qemu-img')
    for _,leaf in STICKS:
        subprocess.run([str(qimg),'create','-q','-f','qcow2',str(work/leaf),'2M'],check=True,capture_output=True)
    started=time.monotonic();record={'kind':'REAL_QEMU_PERSISTENT_STORAGE_TEST','guest_usb_pass':False,'windows_pass':False,'operations':[]}
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0));listener.listen(1);listener.settimeout(30)
        port=listener.getsockname()[1]
        command=[str(qemu),'-name','USOS-OWN-STORAGE-BACKEND-LIFETIME','-machine','q35','-accel','tcg',
                 '-m','64','-smp','1','-S','-nodefaults','-display','none','-monitor','none','-serial','none','-nic','none',
                 '-qmp',f'tcp:127.0.0.1:{port},server=off','-device','qemu-xhci,id=xhci',*block_arguments(work)]
        (work/'command.json').write_text(json.dumps(command,indent=2)+'\n')
        environment=dict(os.environ,TEMP=str(work),TMP=str(work),APPDATA=str(work),LOCALAPPDATA=str(work))
        with (work/'stderr.log').open('wb') as errors:
            process=subprocess.Popen(command,stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=errors,env=environment)
            try:
                connection,_=listener.accept();connection.settimeout(30)
                with connection,connection.makefile('rwb') as stream:
                    qmp=Qmp(stream)
                    assert 'QMP' in qmp.read()
                    qmp.command('qmp_capabilities')
                    for backend,_ in STICKS:
                        device='owned-'+backend
                        properties={'driver':'usb-storage','id':device,'bus':'xhci.0','drive':backend,'removable':True}
                        qmp.command('device_add',properties)
                        for cycle in (1,2):
                            qmp.remove(device)  # blocking DEVICE_DELETED notification
                            qmp.command('device_add',properties)
                            record['operations'].append({'backend':backend,'cycle':cycle,'remove_notified':True,'reinsert_accepted':True})
                        qmp.remove(device)
                    # One final inventory, after every operation completed.
                    nodes=qmp.command('query-named-block-nodes')
                    names={node['node-name'] for node in nodes}
                    assert all(name in names for name,_ in STICKS)
                    record['named_nodes_survived']=True
                    qmp.command('quit')
                process.wait(timeout=30)
                assert process.returncode==0
                record.update(result='PASS',qemu_exit=process.returncode,seconds=round(time.monotonic()-started,3))
            finally:
                if process.poll() is None:process.kill();process.wait()
    (work/'result.json').write_text(json.dumps(record,indent=2)+'\n')
    print(json.dumps(record))

if __name__=='__main__':main()
