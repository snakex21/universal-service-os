"""SPDX-License-Identifier: GPL-3.0-or-later
Explicit virtual-machine UI actions and consent evidence checkpoints.
"""
import json,socket,threading

def type_run(qmp_call,stream,command):
    qmp_call(stream,'human-monitor-command',{'command-line':'sendkey meta_l-r'})
    threading.Event().wait(1)
    punctuation={':':'shift-semicolon','\\':'backslash','.':'dot',' ':'spc','-':'minus'}
    for char in command:
        key=char if char.isalnum() else punctuation[char]
        qmp_call(stream,'human-monitor-command',{'command-line':'sendkey '+key+' 40'})
        threading.Event().wait(.06)
    qmp_call(stream,'human-monitor-command',{'command-line':'sendkey ret'})

def perform_action(qmp_call,stream,width,height,action):
    if action.startswith('click:'):
        x,y=map(int,action[6:].split(','))
        if not 0<=x<width or not 0<=y<height:raise ValueError('Click outside observed screenshot')
        qmp_call(stream,'input-send-event',{'events':[{'type':'abs','data':{'axis':'x','value':x*32767//width}},{'type':'abs','data':{'axis':'y','value':y*32767//height}}]})
        qmp_call(stream,'input-send-event',{'events':[{'type':'btn','data':{'button':'left','down':True}}]})
        threading.Event().wait(.1)
        qmp_call(stream,'input-send-event',{'events':[{'type':'btn','data':{'button':'left','down':False}}]})
    else:
        sequence={'down-enter':['down','ret'],'left-enter':['left','ret'],'enter':['ret'],'alt-z':['alt-z'],'alt-k':['alt-k'],'cancel':['esc']}.get(action)
        if sequence is None:raise ValueError('Unknown consent action')
        for key in sequence:
            qmp_call(stream,'human-monitor-command',{'command-line':'sendkey '+key+' 60'});threading.Event().wait(.2)


def consent_checkpoint(qmp_call,stream,out,auto_action=None):
    # This event is emitted by our own utility before ShellExecute(runas).
    # Capture that explicit UI step once, then await an operator action.
    threading.Event().wait(2)
    shot=out/'uac-approval.ppm';qmp_call(stream,'screendump',{'filename':str(shot)})
    from PIL import Image
    with Image.open(shot) as screen:
        width,height=screen.size
        screen.save(shot.with_suffix('.png'))
    if auto_action:
        if (width,height)!=(800,600):raise ValueError('Automatic fixture consent requires the inspected 800x600 dialog')
        perform_action(qmp_call,stream,width,height,auto_action)
        (out/'uac-action-done.json').write_text(json.dumps({'action':auto_action,'screenshot':str(shot.with_suffix('.png')),'mode':'explicit isolated fixture; no UAC policy change'}))
        print('Explicit fixture VM consent: '+auto_action,flush=True)
        return
    with socket.socket() as listener:
        listener.bind(('127.0.0.1',0));listener.listen();listener.settimeout(300)
        request=out/'uac-action.json';request.write_text(json.dumps({'port':listener.getsockname()[1],'screenshot':str(shot.with_suffix('.png')),'actions':['down-enter','left-enter','enter','alt-z','alt-k','cancel']}))
        print('UAC_ACTION_REQUIRED '+str(request),flush=True)
        connection,_=listener.accept();connection.settimeout(15)
        with connection:
            action=connection.recv(64).decode().strip()
            perform_action(qmp_call,stream,width,height,action)
            connection.sendall(b'action-sent\n')
    print('Explicit VM consent action: '+action,flush=True)
