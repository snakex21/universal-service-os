/* XmlLite node copying shared by the driver answer-file editor. */
static HRESULT xml_attr(IXmlWriter *w,const WCHAR *key,const WCHAR *value){return IXmlWriter_WriteAttributeString(w,0,key,0,value);}
static HRESULT xml_copy(IXmlWriter *w,IXmlReader *r,XmlNodeType type,int leave_empty_open){
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
  if(empty&&!leave_empty_open)TRY(IXmlWriter_WriteEndElement(w));
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
