/* Add one offline driver path without changing the user's installation choices.
 * Runs on stock WinPE 7; all input/output paths are explicit and never in-place.
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <initguid.h>
#include <shlwapi.h>
#include <xmllite.h>
static const WCHAR ns[]=L"urn:schemas-microsoft-com:unattend";
static const WCHAR wcm[]=L"http://schemas.microsoft.com/WMIConfig/2002/State";
static const WCHAR component[]=L"Microsoft-Windows-PnpCustomizationsNonWinPE";
static const WCHAR key_value[]=L"2147483647";
static const WCHAR *driver_path;
static int protected_disk=-1;
#define TRY(x) do{hr=(x);if(FAILED(hr))goto done;}while(0)
#include "windows_unattend_xml.h"
static int equal(const WCHAR *a,const WCHAR *b){if(!a||!b)return 0;while(*a&&*a==*b){a++;b++;}return *a==*b;}
static int disk_number(const WCHAR *s){
 while(*s==' '||*s=='\t'||*s=='\r'||*s=='\n')s++;if(*s<'0'||*s>'9')return -1;unsigned n=0;
 while(*s>='0'&&*s<='9'){if(n>100000)return -1;n=n*10+(*s++-'0');}
 while(*s==' '||*s=='\t'||*s=='\r'||*s=='\n')s++;return *s?-1:(int)n;
}
static int attribute(IXmlReader *r,const WCHAR *name,const WCHAR *uri,const WCHAR *wanted){
 const WCHAR *value=0;int ok=IXmlReader_MoveToAttributeByName(r,name,uri)==S_OK&&SUCCEEDED(IXmlReader_GetValue(r,&value,0))&&equal(value,wanted);IXmlReader_MoveToElement(r);return ok;
}
/* level 0 adds a settings element, level 1 a component, level 2 DriverPaths,
 * and level 3 just a PathAndCredentials entry inside an existing container. */
static HRESULT add(IXmlWriter *w,unsigned level){
 HRESULT hr=S_OK;
 if(level==0){TRY(IXmlWriter_WriteStartElement(w,0,L"settings",ns));TRY(xml_attr(w,L"pass",L"offlineServicing"));}
 if(level<=1){
  TRY(IXmlWriter_WriteStartElement(w,0,L"component",ns));TRY(xml_attr(w,L"name",component));TRY(xml_attr(w,L"processorArchitecture",L"amd64"));
  TRY(xml_attr(w,L"publicKeyToken",L"31bf3856ad364e35"));TRY(xml_attr(w,L"language",L"neutral"));TRY(xml_attr(w,L"versionScope",L"nonSxS"));
 }
 if(level<=2)TRY(IXmlWriter_WriteStartElement(w,0,L"DriverPaths",ns));
 TRY(IXmlWriter_WriteStartElement(w,0,L"PathAndCredentials",ns));
 TRY(IXmlWriter_WriteAttributeString(w,L"wcm",L"action",wcm,L"add"));TRY(IXmlWriter_WriteAttributeString(w,L"wcm",L"keyValue",wcm,key_value));
 TRY(IXmlWriter_WriteElementString(w,0,L"Path",ns,driver_path));TRY(IXmlWriter_WriteEndElement(w));
 if(level<=2)TRY(IXmlWriter_WriteEndElement(w));
 if(level<=1)TRY(IXmlWriter_WriteEndElement(w));
 if(level==0)TRY(IXmlWriter_WriteEndElement(w));
 done:return hr;
}
static int run(const WCHAR *input,const WCHAR *output){
 HRESULT hr=S_OK;IXmlReader *r=0;IXmlWriter *w=0;IStream *in=0,*out=0;int created=0;
 int root=0,offline_seen=0,in_offline=0,component_seen=0,in_component=0,paths_seen=0,written=0;
 int in_disk=0;unsigned disk_depth=0,disk_chars=0;WCHAR disk_text[32];
 if(GetFileAttributesW(output)!=INVALID_FILE_ATTRIBUTES)return 1;
 TRY(CreateXmlWriter(&IID_IXmlWriter,(void**)&w,0));
 TRY(SHCreateStreamOnFileEx(output,STGM_WRITE|STGM_SHARE_EXCLUSIVE|STGM_FAILIFTHERE,FILE_ATTRIBUTE_NORMAL,TRUE,0,&out));created=1;
 TRY(IXmlWriter_SetOutput(w,(IUnknown*)out));TRY(IXmlWriter_WriteStartDocument(w,XmlStandalone_Omit));
 if(equal(input,L"-")){
  TRY(IXmlWriter_WriteStartElement(w,0,L"unattend",ns));TRY(add(w,0));TRY(IXmlWriter_WriteEndElement(w));
 }else{
  WIN32_FILE_ATTRIBUTE_DATA data;if(!GetFileAttributesExW(input,GetFileExInfoStandard,&data)||data.nFileSizeHigh||data.nFileSizeLow>8*1024*1024){hr=E_INVALIDARG;goto done;}
  TRY(SHCreateStreamOnFileEx(input,STGM_READ|STGM_SHARE_DENY_WRITE,FILE_ATTRIBUTE_NORMAL,FALSE,0,&in));
  TRY(CreateXmlReader(&IID_IXmlReader,(void**)&r,0));TRY(IXmlReader_SetProperty(r,XmlReaderProperty_DtdProcessing,DtdProcessing_Prohibit));
  TRY(IXmlReader_SetProperty(r,XmlReaderProperty_MaxElementDepth,64));TRY(IXmlReader_SetInput(r,(IUnknown*)in));
  XmlNodeType type;
  while((hr=IXmlReader_Read(r,&type))==S_OK){
   if(type==XmlNodeType_XmlDeclaration)continue;
   UINT depth=0;const WCHAR *local=0,*uri=0;TRY(IXmlReader_GetDepth(r,&depth));
   if(type==XmlNodeType_EndElement){if(!depth){hr=E_INVALIDARG;goto done;}depth--;}
   if(type==XmlNodeType_Element||type==XmlNodeType_EndElement){TRY(IXmlReader_GetLocalName(r,&local,0));TRY(IXmlReader_GetNamespaceUri(r,&uri,0));}
   if(protected_disk>=0&&type==XmlNodeType_Element&&equal(local,L"DiskID")&&equal(uri,ns)){
    if(in_disk||IXmlReader_IsEmptyElement(r)){hr=E_INVALIDARG;goto done;}in_disk=1;disk_depth=depth;disk_chars=0;
   }else if(in_disk&&type==XmlNodeType_Element){hr=E_INVALIDARG;goto done;}
   if(in_disk&&(type==XmlNodeType_Text||type==XmlNodeType_CDATA||type==XmlNodeType_Whitespace)){
    const WCHAR *value=0;TRY(IXmlReader_GetValue(r,&value,0));while(*value){if(disk_chars+1>=32){hr=E_INVALIDARG;goto done;}disk_text[disk_chars++]=*value++;}
   }
   if(in_disk&&type==XmlNodeType_EndElement&&depth==disk_depth){
    disk_text[disk_chars]=0;int target=disk_number(disk_text);in_disk=0;if(target<0||target==protected_disk){hr=E_INVALIDARG;goto done;}
   }
   if(type==XmlNodeType_Element){
    if(depth==0){if(root++||!equal(local,L"unattend")||!equal(uri,ns)){hr=E_INVALIDARG;goto done;}
     if(IXmlReader_IsEmptyElement(r)){TRY(xml_copy(w,r,type,1));TRY(add(w,0));TRY(IXmlWriter_WriteEndElement(w));written=1;continue;}
    }
    int level=-1;
    if(depth==1&&equal(local,L"settings")&&equal(uri,ns)&&attribute(r,L"pass",0,L"offlineServicing")){
     if(offline_seen++){hr=E_INVALIDARG;goto done;}in_offline=1;level=1;
    }else if(depth==2&&in_offline&&equal(local,L"component")&&equal(uri,ns)&&attribute(r,L"name",0,component)){
     if(component_seen++||!attribute(r,L"processorArchitecture",0,L"amd64")){hr=E_INVALIDARG;goto done;}in_component=1;level=2;
    }else if(depth==3&&in_component&&equal(local,L"DriverPaths")&&equal(uri,ns)){
     if(paths_seen++){hr=E_INVALIDARG;goto done;}level=3;
    }else if(depth==4&&in_component&&equal(local,L"PathAndCredentials")&&attribute(r,L"keyValue",wcm,key_value)){hr=E_INVALIDARG;goto done;}
    if(level>=0&&IXmlReader_IsEmptyElement(r)){
     TRY(xml_copy(w,r,type,1));TRY(add(w,(unsigned)level));TRY(IXmlWriter_WriteEndElement(w));written=1;
     if(level==1)in_offline=0;if(level==2)in_component=0;continue;
    }
   }
   if(type==XmlNodeType_EndElement){
    if(depth==3&&in_component&&equal(local,L"DriverPaths")&&equal(uri,ns)&&!written){TRY(add(w,3));written=1;}
    if(depth==2&&in_component){if(!written){TRY(add(w,2));written=1;}in_component=0;}
    if(depth==1&&in_offline){if(!written){TRY(add(w,1));written=1;}in_offline=0;}
    if(depth==0&&!written){TRY(add(w,0));written=1;}
   }
   TRY(xml_copy(w,r,type,0));
  }
  if(FAILED(hr)||root!=1||!written){hr=E_INVALIDARG;goto done;}
 }
 TRY(IXmlWriter_WriteEndDocument(w));TRY(IXmlWriter_Flush(w));TRY(IStream_Commit(out,STGC_DEFAULT));hr=S_OK;
 done:if(r)IXmlReader_Release(r);if(w)IXmlWriter_Release(w);if(in)IStream_Release(in);if(out)IStream_Release(out);
 if(FAILED(hr)&&created)DeleteFileW(output);return FAILED(hr)?1:0;
}
void entry(void){
 static WCHAR args[5][MAX_PATH];const WCHAR *s=GetCommandLineW();unsigned count=0;
 while(*s){while(*s==' '||*s=='\t')s++;if(!*s)break;if(count==5)ExitProcess(2);int quote=0;unsigned n=0;
  while(*s&&(quote||(*s!=' '&&*s!='\t'))){if(*s=='"'){quote=!quote;s++;continue;}if(n+1>=MAX_PATH)ExitProcess(2);args[count][n++]=*s++;}if(quote)ExitProcess(2);args[count++][n]=0;
 }
 if(count!=4&&count!=5)ExitProcess(2);driver_path=args[3];
 if(count==5){protected_disk=disk_number(args[4]);if(protected_disk<0)ExitProcess(2);}
 ExitProcess(run(args[1],args[2]));
}
