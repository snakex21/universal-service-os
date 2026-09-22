/* Merge the native NVMe servicing packages into a separate answer file.
 * XmlLite preserves the user's setup settings and prohibits external entities.
 * This utility only reads/writes its explicit files; it never services the host.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <shlwapi.h>
#include <xmllite.h>

static const WCHAR ns[]=L"urn:schemas-microsoft-com:unattend";
enum { package_count=4 };
static const WCHAR *names[]={L"Package_for_KB4474419",L"Package_for_KB2990941",L"Package_for_KB3087873",L"Package_for_KB2685811"};
static const WCHAR *versions[]={L"6.1.3.2",L"6.1.3.0",L"6.1.2.0",L"6.1.1.11"};
static WCHAR source_paths[package_count][MAX_PATH];
static const WCHAR *sources[]={source_paths[0],source_paths[1],source_paths[2],source_paths[3]};
static int sha2_available,kmdf_available;
static int source_locations(void){
 static const WCHAR *files[]={L"Windows6.1-KB4474419-v3-x64.cab",L"Windows6.1-KB2990941-v3-x64.cab",L"Windows6.1-KB3087873-v2-x64.cab",L"Windows6.1-KB2685811-x64.cab"};
 WCHAR directory[MAX_PATH];DWORD n=GetModuleFileNameW(0,directory,MAX_PATH);
 if(!n||n>=MAX_PATH-64)return 0;while(n&&directory[n-1]!='\\')n--;directory[n]=0;
 for(unsigned i=0;i<package_count;i++){
  lstrcpyW(source_paths[i],directory);lstrcatW(source_paths[i],L"updates\\");lstrcatW(source_paths[i],files[i]);
  if(GetFileAttributesW(source_paths[i])==INVALID_FILE_ATTRIBUTES){lstrcpyW(source_paths[i],directory);lstrcatW(source_paths[i],files[i]);}
 }
 sha2_available=GetFileAttributesW(source_paths[0])!=INVALID_FILE_ATTRIBUTES;
 WCHAR flag[MAX_PATH];lstrcpyW(flag,directory);lstrcatW(flag,L"usos-sha2-required.flag");
 if(GetFileAttributesW(flag)!=INVALID_FILE_ATTRIBUTES&&!sha2_available)return 0;
 kmdf_available=GetFileAttributesW(source_paths[3])!=INVALID_FILE_ATTRIBUTES;
 lstrcpyW(flag,directory);lstrcatW(flag,L"usos-kmdf-required.flag");
 if(GetFileAttributesW(flag)!=INVALID_FILE_ATTRIBUTES&&!kmdf_available)return 0;
 return 1;
}
static int seen[package_count];
static int failed_line;
static int protected_disk=-1;
#define TRY(x) do { hr=(x); if(FAILED(hr)){failed_line=__LINE__;goto done;} } while(0)

static HRESULT attr(IXmlWriter *w,const WCHAR *key,const WCHAR *value){return IXmlWriter_WriteAttributeString(w,0,key,0,value);}
static HRESULT add_packages(IXmlWriter *w,int container){
 HRESULT hr=S_OK;
 if(container)TRY(IXmlWriter_WriteStartElement(w,0,L"servicing",ns));
 for(int i=sha2_available?0:1;i<package_count;i++)if(!seen[i]){
  if(i==3&&!kmdf_available)continue;
  TRY(IXmlWriter_WriteStartElement(w,0,L"package",ns));TRY(attr(w,L"action",L"install"));
  TRY(IXmlWriter_WriteStartElement(w,0,L"assemblyIdentity",ns));
  TRY(attr(w,L"name",names[i]));TRY(attr(w,L"version",versions[i]));
  TRY(attr(w,L"processorArchitecture",L"amd64"));TRY(attr(w,L"publicKeyToken",L"31bf3856ad364e35"));TRY(attr(w,L"language",L"neutral"));
  TRY(IXmlWriter_WriteEndElement(w));
  TRY(IXmlWriter_WriteStartElement(w,0,L"source",ns));TRY(attr(w,L"location",sources[i]));TRY(IXmlWriter_WriteEndElement(w));
  TRY(IXmlWriter_WriteEndElement(w));
 }
 if(container)TRY(IXmlWriter_WriteEndElement(w));
 done:return hr;
}
static int equal(const WCHAR *a,const WCHAR *b){if(!a||!b)return 0;while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int attribute_is(IXmlReader *r,const WCHAR *key,const WCHAR *expected,int optional){
 const WCHAR *value=0;int ok=optional;
 HRESULT hr=IXmlReader_MoveToAttributeByName(r,key,0);
 if(hr==S_OK)ok=SUCCEEDED(IXmlReader_GetValue(r,&value,0))&&equal(value,expected);
 else if(FAILED(hr))ok=0;
 IXmlReader_MoveToElement(r);return ok;
}
static void say(const char *s){DWORD n=0,w;while(s[n])n++;WriteFile(GetStdHandle(STD_OUTPUT_HANDLE),s,n,&w,0);}
static void hex(DWORD n){char s[11]="0x00000000";for(int i=9;i>=2;i--){s[i]="0123456789abcdef"[n&15];n>>=4;}say(s);}
static int disk_number(const WCHAR *s){
 while(*s==' '||*s=='\t'||*s=='\r'||*s=='\n')s++;
 if(*s<'0'||*s>'9')return -1;unsigned n=0;
 while(*s>='0'&&*s<='9'){if(n>100000)return -1;n=n*10+(*s++-'0');}
 while(*s==' '||*s=='\t'||*s=='\r'||*s=='\n')s++;
 return *s?-1:(int)n;
}

static HRESULT copy_node(IXmlWriter *w,IXmlReader *r,XmlNodeType type){
 HRESULT hr=S_OK;const WCHAR *local=0,*uri=0,*prefix=0,*value=0;
 if(type==XmlNodeType_Element){
  BOOL empty=IXmlReader_IsEmptyElement(r);
  TRY(IXmlReader_GetLocalName(r,&local,0));TRY(IXmlReader_GetNamespaceUri(r,&uri,0));TRY(IXmlReader_GetPrefix(r,&prefix,0));
  TRY(IXmlWriter_WriteStartElement(w,prefix,local,uri));
  hr=IXmlReader_MoveToFirstAttribute(r);
  while(hr==S_OK){
   TRY(IXmlReader_GetLocalName(r,&local,0));TRY(IXmlReader_GetNamespaceUri(r,&uri,0));TRY(IXmlReader_GetPrefix(r,&prefix,0));TRY(IXmlReader_GetValue(r,&value,0));
   TRY(IXmlWriter_WriteAttributeString(w,prefix,local,uri,value));hr=IXmlReader_MoveToNextAttribute(r);
  }
  if(FAILED(hr))goto done;IXmlReader_MoveToElement(r);
  if(empty)TRY(IXmlWriter_WriteEndElement(w));
 }else if(type==XmlNodeType_EndElement)TRY(IXmlWriter_WriteFullEndElement(w));
 else{
  TRY(IXmlReader_GetValue(r,&value,0));
  switch(type){
   case XmlNodeType_Text:TRY(IXmlWriter_WriteString(w,value));break;
   case XmlNodeType_Whitespace:TRY(IXmlWriter_WriteWhitespace(w,value));break;
   case XmlNodeType_CDATA:TRY(IXmlWriter_WriteCData(w,value));break;
   case XmlNodeType_Comment:TRY(IXmlWriter_WriteComment(w,value));break;
   case XmlNodeType_ProcessingInstruction:TRY(IXmlReader_GetLocalName(r,&local,0));TRY(IXmlWriter_WriteProcessingInstruction(w,local,value));break;
   default:hr=E_INVALIDARG;goto done;
  }
 }
 hr=S_OK;done:return hr;
}

static int run(WCHAR **argv){
 if(!source_locations())return 1;
 HRESULT hr=S_OK;IXmlReader *r=0;IXmlWriter *w=0;IStream *in=0,*out=0;
 int created=0,root=0,servicing=0,written=0,install_action=0,disk_value=0;
 WCHAR disk_text[32];unsigned disk_chars=0,disk_depth=0;
 TRY(CreateXmlWriter(&IID_IXmlWriter,(void**)&w,0));
 if(GetFileAttributesW(argv[2])!=INVALID_FILE_ATTRIBUTES){hr=HRESULT_FROM_WIN32(ERROR_FILE_EXISTS);goto done;}
 TRY(SHCreateStreamOnFileEx(argv[2],STGM_WRITE|STGM_SHARE_EXCLUSIVE|STGM_FAILIFTHERE,FILE_ATTRIBUTE_NORMAL,TRUE,0,&out));created=1;
 TRY(IXmlWriter_SetOutput(w,(IUnknown*)out));
 TRY(IXmlWriter_WriteStartDocument(w,XmlStandalone_Omit));
 if(equal(argv[1],L"-")){
  TRY(IXmlWriter_WriteStartElement(w,0,L"unattend",ns));TRY(add_packages(w,1));TRY(IXmlWriter_WriteEndElement(w));
 }else{
  WIN32_FILE_ATTRIBUTE_DATA data;
  if(!GetFileAttributesExW(argv[1],GetFileExInfoStandard,&data)||data.nFileSizeHigh||data.nFileSizeLow>8*1024*1024){hr=E_INVALIDARG;goto done;}
  TRY(SHCreateStreamOnFileEx(argv[1],STGM_READ|STGM_SHARE_DENY_WRITE,FILE_ATTRIBUTE_NORMAL,FALSE,0,&in));
  TRY(CreateXmlReader(&IID_IXmlReader,(void**)&r,0));
  TRY(IXmlReader_SetProperty(r,XmlReaderProperty_DtdProcessing,DtdProcessing_Prohibit));
  TRY(IXmlReader_SetProperty(r,XmlReaderProperty_MaxElementDepth,64));
  TRY(IXmlReader_SetInput(r,(IUnknown*)in));
  XmlNodeType type;
  while((hr=IXmlReader_Read(r,&type))==S_OK){
   UINT depth=0;const WCHAR *local=0,*uri=0;TRY(IXmlReader_GetDepth(r,&depth));
   /* XmlLite reports an end tag one level below its opening tag. */
   if(type==XmlNodeType_EndElement){if(!depth){hr=E_INVALIDARG;goto done;}depth--;}
   if(type==XmlNodeType_XmlDeclaration)continue;
   if(type==XmlNodeType_Element||type==XmlNodeType_EndElement){TRY(IXmlReader_GetLocalName(r,&local,0));TRY(IXmlReader_GetNamespaceUri(r,&uri,0));}
   if(protected_disk>=0&&type==XmlNodeType_Element&&equal(local,L"DiskID")&&equal(uri,ns)){
    if(disk_value||IXmlReader_IsEmptyElement(r)){hr=E_INVALIDARG;goto done;}
    disk_value=1;disk_chars=0;disk_depth=depth;
   }else if(disk_value&&type==XmlNodeType_Element){hr=E_INVALIDARG;goto done;}
   if(disk_value&&(type==XmlNodeType_Text||type==XmlNodeType_Whitespace||type==XmlNodeType_CDATA)){
    const WCHAR *value=0;TRY(IXmlReader_GetValue(r,&value,0));
    while(*value){if(disk_chars+1>=32){hr=E_INVALIDARG;goto done;}disk_text[disk_chars++]=*value++;}
   }
   if(disk_value&&type==XmlNodeType_EndElement&&depth==disk_depth){
    disk_text[disk_chars]=0;int target=disk_number(disk_text);disk_value=0;
    if(target<0||target==protected_disk){say("Unattended Setup stopped: DiskID is invalid or selects the USOS source disk.\r\n");hr=E_INVALIDARG;goto done;}
   }
   if(type==XmlNodeType_Element&&depth==0){
    if(root++||!equal(local,L"unattend")||!equal(uri,ns)||IXmlReader_IsEmptyElement(r)){failed_line=__LINE__;hr=E_INVALIDARG;goto done;}
   }
   if(type==XmlNodeType_Element&&depth==1&&equal(local,L"servicing")&&equal(uri,ns)){
    if(servicing++){hr=E_INVALIDARG;goto done;}
    if(IXmlReader_IsEmptyElement(r)){TRY(add_packages(w,1));written=1;continue;}
   }
   if(type==XmlNodeType_Element&&depth==2&&servicing&&!written&&equal(local,L"package")&&equal(uri,ns)){
    const WCHAR *value=0;install_action=0;
    if(IXmlReader_MoveToAttributeByName(r,L"action",0)==S_OK){TRY(IXmlReader_GetValue(r,&value,0));install_action=equal(value,L"install");IXmlReader_MoveToElement(r);}
   }
   if(type==XmlNodeType_Element&&depth==3&&servicing&&!written&&equal(local,L"assemblyIdentity")&&equal(uri,ns)){
    const WCHAR *value=0;
    if(IXmlReader_MoveToAttributeByName(r,L"name",0)==S_OK){
     TRY(IXmlReader_GetValue(r,&value,0));
     int known=-1;for(int i=0;i<package_count;i++)if(equal(value,names[i]))known=i;
     IXmlReader_MoveToElement(r);
     if(known>=0){
      if(!install_action||seen[known]||
       !attribute_is(r,L"version",versions[known],0)||
       !attribute_is(r,L"processorArchitecture",L"amd64",0)||
       !attribute_is(r,L"publicKeyToken",L"31bf3856ad364e35",0)||
       !attribute_is(r,L"language",L"neutral",1)){hr=E_INVALIDARG;goto done;}
      seen[known]=1;
     }
    }
   }
   if(type==XmlNodeType_EndElement&&depth==1&&equal(local,L"servicing")&&equal(uri,ns)){TRY(add_packages(w,0));written=1;}
   if(type==XmlNodeType_EndElement&&depth==0&&!written){TRY(add_packages(w,1));written=1;}
   TRY(copy_node(w,r,type));
  }
  if(FAILED(hr)||root!=1||!written){failed_line=__LINE__;if(SUCCEEDED(hr))hr=E_INVALIDARG;goto done;}
 }
 TRY(IXmlWriter_WriteEndDocument(w));TRY(IXmlWriter_Flush(w));TRY(IStream_Commit(out,STGC_DEFAULT));hr=S_OK;
 done:
 if(r)IXmlReader_Release(r);if(w)IXmlWriter_Release(w);if(in)IStream_Release(in);if(out)IStream_Release(out);
 if(FAILED(hr)){if(created)DeleteFileW(argv[2]);say("NVMe answer-file merge failed: ");hex((DWORD)hr);say(" at step ");hex((DWORD)failed_line);say("\r\n");return 1;}
 say(sha2_available?"Target servicing: KB4474419 (SHA-2), KB2990941 and KB3087873 added to answer file.\r\n":"Target servicing: KB2990941 and KB3087873 added to answer file.\r\n");
 if(kmdf_available)say("Target servicing: KB2685811 (KMDF 1.11, USB dependency) added to answer file.\r\n");return 0;
}

void entry(void){
 static WCHAR args[4][MAX_PATH];WCHAR *argv[4]={args[0],args[1],args[2],args[3]};
 const WCHAR *c=GetCommandLineW();unsigned count=0;
 while(*c){
  while(*c==' '||*c=='\t')c++;if(!*c)break;if(count==4)ExitProcess(2);
  int quoted=*c=='"';if(quoted)c++;unsigned n=0;
  while(*c&&(quoted?*c!='"':*c!=' '&&*c!='\t')){if(n+1>=MAX_PATH||*c=='"')ExitProcess(2);args[count][n++]=*c++;}
  if(quoted){if(*c!='"')ExitProcess(2);c++;if(*c&&*c!=' '&&*c!='\t')ExitProcess(2);}
  args[count++][n]=0;
 }
 if(count!=3&&count!=4){say("Usage: usos-win7-unattend.exe input.xml|- new-output.xml [protected-source-disk]\r\n");ExitProcess(2);}
 if(count==4){protected_disk=disk_number(argv[3]);if(protected_disk<0)ExitProcess(2);}
 ExitProcess((UINT)run(argv));
}
