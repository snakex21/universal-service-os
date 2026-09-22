/* Servicing-only answer: no disk, edition, account or product-key settings. */
static DWORD vista_kmdf_answer(WCHAR *out,DWORD capacity,const WCHAR *cab){
 static const WCHAR prefix[]=L"\xfeff<?xml version=\"1.0\" encoding=\"utf-16\"?>\r\n"
  L"<unattend xmlns=\"urn:schemas-microsoft-com:unattend\"><servicing><package action=\"install\">"
  L"<assemblyIdentity name=\"Package_for_KB2864202\" version=\"6.0.1.0\" language=\"neutral\" processorArchitecture=\"amd64\" publicKeyToken=\"31bf3856ad364e35\"/>"
  L"<source location=\"";
 static const WCHAR suffix[]=L"\"/></package></servicing></unattend>\r\n";
 DWORD used=0;
 if(!cab||!cab[0])return 0;
 for(DWORD i=0;prefix[i];i++){if(used+1>=capacity)return 0;out[used++]=prefix[i];}
 for(DWORD i=0;cab[i];i++){
  WCHAR c=cab[i];const WCHAR *escaped=0;
  if(c<32)return 0;
  if(c==L'&')escaped=L"&amp;";else if(c==L'<')escaped=L"&lt;";else if(c==L'>')escaped=L"&gt;";else if(c==L'\"')escaped=L"&quot;";
  if(escaped){for(DWORD j=0;escaped[j];j++){if(used+1>=capacity)return 0;out[used++]=escaped[j];}}
  else{if(used+1>=capacity)return 0;out[used++]=c;}
 }
 for(DWORD i=0;suffix[i];i++){if(used+1>=capacity)return 0;out[used++]=suffix[i];}
 out[used]=0;return used;
}
