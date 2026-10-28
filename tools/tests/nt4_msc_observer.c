/* Own, explicit NT4 VM storage observer. Windowless; data beside this EXE.
 * Only uniquely labelled/marked disposable FAT volumes are written. */
#include <windows.h>
static HANDLE logFile=INVALID_HANDLE_VALUE;
static char base[512];
static DWORD length(const char *s){DWORD n=0;while(s[n])n++;return n;}
static void copy(char *d,const char *s){while((*d++=*s++));}
static int same(const char *a,const char *b){char x,y;do{x=*a++;y=*b++;if(x>='a'&&x<='z')x+=32;if(y>='a'&&y<='z')y+=32;if(x!=y)return 0;}while(x);return 1;}
static int bytes(const char *a,const char *b,DWORD n){while(n--)if(*a++!=*b++)return 0;return 1;}
static void text(const char *s){DWORD n;if(logFile!=INVALID_HANDLE_VALUE)WriteFile(logFile,s,length(s),&n,NULL);}
static void row(const char *s,DWORD v){char b[9];int i;text(s);text("=");for(i=0;i<8;i++)b[i]="0123456789ABCDEF"[(v>>(28-i*4))&15];b[8]=0;text(b);text("\r\n");}
static void local(char *out,const char *name){copy(out,base);copy(out+length(out),name);}
static int read_exact(const char *path,const char *expected){char b[256];DWORD n=0;HANDLE f=CreateFileA(path,GENERIC_READ,FILE_SHARE_READ,NULL,OPEN_EXISTING,0,NULL);int ok=0;
 if(f==INVALID_HANDLE_VALUE){row("ReadOpenError",GetLastError());return 0;}if(ReadFile(f,b,sizeof(b),&n,NULL)&&n==length(expected)&&bytes(b,expected,n))ok=1;CloseHandle(f);return ok;}
static char volume(const char *label,const char *marker){DWORD mask=GetLogicalDrives(),i;char root[4]="D:\\",name[64],fs[32],path[64],letter=0;int count=0;
 for(i=3;i<26;i++){if(!(mask&(1UL<<i)))continue;root[0]=(char)('A'+i);if(!GetVolumeInformationA(root,name,sizeof(name),NULL,NULL,NULL,fs,sizeof(fs)))continue;
  if(!same(name,label))continue;if(!same(fs,"FAT")){text("REFUSED_NON_FAT\r\n");return 0;}copy(path,root);copy(path+3,"MSC4VOL.ON");if(!read_exact(path,marker))return 0;count++;letter=root[0];}
 if(count!=1){row("MatchingVolumeCount",count);return 0;}text("VolumeLabel=");text(label);text(" Letter=");root[0]=letter;text(root);text("\r\n");return letter;}
static int test(const char *stage){char drive,path[64];HANDLE f;DWORD n=0;int ok=0;
 static const char roundtrip[]="USOS NT4 MSC ROUNDTRIP persisted\r\n";
 if(same(stage,"STARTUP")){drive=volume("USOS_BOOT","USOS NT4 MSC volume boot\r\n");if(!drive)return 0;copy(path,"D:\\START.TXT");path[0]=drive;
  if(!read_exact(path,"USOS disposable USB boot read test\r\n"))return 0;text("START_FILE_READ_PASS\r\n");return 1;}
 drive=volume("USOS_HOT","USOS NT4 MSC volume hot\r\n");if(!drive)return 0;copy(path,"D:\\HOTPLUG.TXT");path[0]=drive;
 if(!read_exact(path,"USOS disposable USB hot read test\r\n"))return 0;text("HOTPLUG_FILE_READ_PASS\r\n");copy(path,"D:\\ROUNDTRIP.TXT");path[0]=drive;
 if(same(stage,"HOT")){f=CreateFileA(path,GENERIC_WRITE,0,NULL,CREATE_NEW,FILE_ATTRIBUTE_NORMAL,NULL);if(f==INVALID_HANDLE_VALUE){row("WriteOpenError",GetLastError());return 0;}
  ok=WriteFile(f,roundtrip,sizeof(roundtrip)-1,&n,NULL)&&n==sizeof(roundtrip)-1&&FlushFileBuffers(f);if(!CloseHandle(f))ok=0;if(!ok)return 0;text("ROUNDTRIP_WRITE_FLUSH_CLOSE_PASS\r\n");}
 if(!read_exact(path,roundtrip))return 0;text("ROUNDTRIP_READBACK_PASS\r\n");return 1;}
void __cdecl entry(void){char path[600],data[80],packet[80];DWORD n,v,written=0;const char *arg;const char *stage=NULL;HANDLE port=INVALID_HANDLE_VALUE;int ok=0;
 n=GetModuleFileNameA(NULL,base,sizeof(base));if(!n||n>=sizeof(base))ExitProcess(3);while(n&&base[n-1]!='\\')n--;if(!n||n>470)ExitProcess(3);base[n]=0;
 local(path,"MSC4LOG.TXT");logFile=CreateFileA(path,GENERIC_WRITE,FILE_SHARE_READ,NULL,OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL,NULL);if(logFile==INVALID_HANDLE_VALUE)ExitProcess(3);SetFilePointer(logFile,0,NULL,FILE_END);
 text("MSC4_BEGIN\r\n");v=GetVersion();if((v&0xffff)!=4||(v&0x80000000)){text("REFUSED_OS\r\n");goto done;}
 arg=GetCommandLineA();if(*arg=='"'){arg++;while(*arg&&*arg!='"')arg++;if(*arg)arg++;}else while(*arg&&*arg!=' '&&*arg!='\t')arg++;while(*arg==' '||*arg=='\t')arg++;
 if(same(arg,"/startup"))stage="STARTUP";else if(same(arg,"/hot"))stage="HOT";else if(same(arg,"/replug"))stage="REPLUG";else{text("REFUSED_STAGE\r\n");goto done;}
 local(path,"MSC4TEST.ON");if(!read_exact(path,"USOS NT4 MSC fixture only\r\n")){text("REFUSED_FIXTURE\r\n");goto done;}
 port=CreateFileA("COM1",GENERIC_WRITE,0,NULL,OPEN_EXISTING,0,NULL);if(port==INVALID_HANDLE_VALUE){text("REFUSED_COMPLETION_PORT\r\n");goto done;}
 SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOOPENFILEERRORBOX);text("Stage=");text(stage);text("\r\n");ok=test(stage);text(ok?"MSC4_PASS\r\n":"MSC4_REFUSED\r\n");
 FlushFileBuffers(logFile);CloseHandle(logFile);logFile=INVALID_HANDLE_VALUE;copy(packet,"\r\nUSOS_MSC4_DONE=");copy(packet+length(packet),stage);copy(packet+length(packet),ok?":0\r\n":":3\r\n");WriteFile(port,packet,length(packet),&written,NULL);FlushFileBuffers(port);CloseHandle(port);port=INVALID_HANDLE_VALUE;
done:if(logFile!=INVALID_HANDLE_VALUE)CloseHandle(logFile);if(port!=INVALID_HANDLE_VALUE)CloseHandle(port);ExitProcess(ok?0:3);}
