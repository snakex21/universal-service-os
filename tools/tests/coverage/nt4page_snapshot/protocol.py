"""Closed public-ID UART grammar; never returns unknown serial contents."""
import re
BOOLS={'EXCLUDED_EDIT_PRESENT','POLISH_NEXT_PRESENT','OK_PRESENT','PUBLIC_ERROR_MATCH','ERROR_OWNER_UNIQUE','CAPTURE_BUDGET_EXHAUSTED','ORACLE_MODULES_COMPLETE','ORACLE_MESSAGE1010_READ','ORACLE_CODEPAGE1250','UNMATCHED_STATIC_PRESENT'}
FLAGS={'INPUT_DESKTOP_ATTACHED','NATIVE_CHILD_EXIT_ZERO','COM_CHANNEL_AVAILABLE','FILE_CHANNEL_AVAILABLE','OBSERVER_SYNC_READY'}
STATES={'WRAPPER_READY','READY','NATIVE_CHILD_STARTED','NATIVE_CHILD_CREATE_FAILED','REJECTED'}
class Protocol:
 def __init__(self,manifest):
  self.ids={(m['name'],r['kind'],r['id']) for m in manifest['original_modules'] for r in m['allowed_resources']}
  self.errors={(m['name'],r['kind'],r['id']) for m in manifest['original_modules'] for r in m['allowed_resources'] if r['error']}
  self.named_dialogs={(m['name'],i) for m in manifest['original_modules'] for i in m.get('allowed_named_dialogs',[])}
  self.dialogs={(m['name'],i) for m in manifest['original_modules'] for i in m['allowed_dialogs']}
  self.buffer=bytearray();self.frame=None;self.sequence=0;self.discarded_lines=0;self.overlong=False
 def line(self,raw):
  try:line=raw.decode('ascii')
  except UnicodeDecodeError:self.discarded_lines+=1;return None
  if line=='NT4PAGE BEGIN':
   if self.frame is not None:raise ValueError('Nested frame')
   self.frame={'matches':[],'fragments':[],'dialogs':[],'named_dialogs':[],'flags':{}};return None
  if line=='NT4PAGE END':
   if self.frame is None or set(self.frame['flags'])!=BOOLS:raise ValueError('Incomplete frame')
   self.sequence+=1;result=dict(kind='FRAME',sequence=self.sequence,**self.frame);self.frame=None;return result
  m=re.fullmatch(r'NT4PAGE MATCH ([A-Z0-9]+) (MSG|STR) ([0-9]{1,10}) (TITLE|STATIC|BUTTON)',line)
  if m:
   module,kind,num,role=m.groups();num=int(num)
   if self.frame is None or (module,kind,num) not in self.ids:raise ValueError('Public resource not allowlisted')
   if len(self.frame['matches'])>=4096:raise ValueError('Match count bound')
   self.frame['matches'].append({'module':module,'kind':kind,'id':num,'role':role});return None
  m=re.fullmatch(r'NT4PAGE FRAGMENT ([A-Z0-9]+) (MSG|STR) ([0-9]{1,10}) STATIC',line)
  if m:
   module,kind,num=m.groups();num=int(num)
   if self.frame is None or (module,kind,num) not in self.ids or len(self.frame['fragments'])>=4096:raise ValueError('Public fragment not allowlisted')
   self.frame['fragments'].append({'module':module,'kind':kind,'id':num,'role':'STATIC','strength':'DIAGNOSTIC_LITERAL_FRAGMENT_ONLY'});return None
  m=re.fullmatch(r'NT4PAGE DIALOGNAME ([A-Z0-9]+) ([A-Z0-9_]{1,64}) ([0-9]{1,3}) (TITLE|STATIC|BUTTON)',line)
  if m:
   module,name,slot,role=m.groups();slot=int(slot)
   if self.frame is None or (module,name) not in self.named_dialogs or slot>256 or len(self.frame['named_dialogs'])>=4096:raise ValueError('Named dialog not allowlisted')
   self.frame['named_dialogs'].append({'module':module,'name':name,'slot':slot,'role':role});return None
  m=re.fullmatch(r'NT4PAGE DIALOG ([A-Z0-9]+) ([0-9]{1,5}) ([0-9]{1,3}) (TITLE|STATIC|BUTTON)',line)
  if m:
   module,num,slot,role=m.groups();num=int(num);slot=int(slot)
   if self.frame is None or (module,num) not in self.dialogs or slot>256:raise ValueError('Dialog not allowlisted')
   if len(self.frame['dialogs'])>=4096:raise ValueError('Dialog count bound')
   self.frame['dialogs'].append({'module':module,'id':num,'slot':slot,'role':role});return None
  m=re.fullmatch(r'NT4PAGE ([A-Z0-9_]+)=(YES|NO)',line)
  if m:
   name,value=m.groups();value=value=='YES'
   if name in BOOLS:
    if self.frame is None or name in self.frame['flags']:raise ValueError('Duplicate or misplaced flag')
    self.frame['flags'][name]=value;return None
   if name in FLAGS and self.frame is None:return {'kind':'FLAG','name':name,'value':value}
   raise ValueError('Flag not allowlisted')
  m=re.fullmatch(r'NT4PAGE ACTION (ACK_ERROR|NEXT_PL)',line)
  if m and self.frame is None:return {'kind':'ACTION','name':m.group(1)}
  if line.startswith('NT4PAGE ') and line[8:] in STATES and self.frame is None:return {'kind':'STATE','name':line[8:]}
  if self.frame is not None or line.startswith('NT4PAGE '):raise ValueError('Closed grammar violation')
  self.discarded_lines+=1;return None
 def feed(self,data):
  events=[]
  for c in data:
   if c==10:
    if self.overlong:
     self.overlong=False;self.buffer.clear();self.discarded_lines+=1
     if self.frame is not None:raise ValueError('Overlong frame line')
     continue
    raw=bytes(self.buffer).rstrip(b'\r');self.buffer.clear();event=self.line(raw)
    if event is not None:events.append(event)
   elif not self.overlong:
    self.buffer.append(c)
    if len(self.buffer)>160:self.overlong=True;self.buffer.clear()
  return events
 def eof(self):
  if self.frame is not None or self.buffer or self.overlong:raise ValueError('Truncated UART record')
