"""Fast Windows CryptoAPI regression check, in-memory stores only; no VM.

Unknown roots are allowed ONLY for this isolated policy check so no host trust
store has to be changed. Basic Constraints and Authenticode remain enforced.
"""
import ctypes as c
from ctypes import wintypes as w
from pathlib import Path
from cryptography import x509
from cryptography.hazmat.primitives.serialization import Encoding

class Usage(c.Structure):
    _fields_=[('count',w.DWORD),('oids',c.POINTER(c.c_char_p))]
class Match(c.Structure):
    _fields_=[('type',w.DWORD),('usage',Usage)]
class ChainPara(c.Structure):
    _fields_=[('size',w.DWORD),('usage',Match)]
class PolicyPara(c.Structure):
    _fields_=[('size',w.DWORD),('flags',w.DWORD),('extra',c.c_void_p)]
class PolicyStatus(c.Structure):
    _fields_=[('size',w.DWORD),('error',w.DWORD),('chain',w.LONG),('element',w.LONG),('extra',c.c_void_p)]

dll=c.WinDLL('crypt32',use_last_error=True)
def api(name,args,result):
    fn=getattr(dll,name);fn.argtypes=args;fn.restype=result;return fn
create=api('CertCreateCertificateContext',[w.DWORD,c.c_void_p,w.DWORD],c.c_void_p)
openstore=api('CertOpenStore',[c.c_void_p,w.DWORD,c.c_void_p,w.DWORD,c.c_void_p],c.c_void_p)
add=api('CertAddCertificateContextToStore',[c.c_void_p,c.c_void_p,w.DWORD,c.c_void_p],w.BOOL)
getchain=api('CertGetCertificateChain',[c.c_void_p,c.c_void_p,c.c_void_p,c.c_void_p,c.POINTER(ChainPara),w.DWORD,c.c_void_p,c.POINTER(c.c_void_p)],w.BOOL)
policy=api('CertVerifyCertificateChainPolicy',[c.c_void_p,c.c_void_p,c.POINTER(PolicyPara),c.POINTER(PolicyStatus)],w.BOOL)
freecert=api('CertFreeCertificateContext',[c.c_void_p],w.BOOL)
freechain=api('CertFreeCertificateChain',[c.c_void_p],None)
closestore=api('CertCloseStore',[c.c_void_p,w.DWORD],w.BOOL)

def check(leaf,root):
    store=openstore(2,0,None,0,None) # CERT_STORE_PROV_MEMORY
    assert store
    contexts=[];chain=c.c_void_p()
    try:
        for cert in (leaf,root):
            der=cert.public_bytes(Encoding.DER);buf=c.create_string_buffer(der)
            ctx=create(1,buf,len(der));assert ctx;contexts.append(ctx)
            assert add(store,ctx,4,None)
        para=ChainPara();para.size=c.sizeof(para)
        # Cache-only URL retrieval; no root auto-update or AIA fetch.
        assert getchain(None,contexts[0],None,store,c.byref(para),0x4|0x100|0x2000,None,c.byref(chain)),c.get_last_error()
        results={}
        for name,oid,flags in [('basic_constraints',5,0x40000000|0x10),('authenticode',2,0x10)]:
            pp=PolicyPara(c.sizeof(PolicyPara),flags,None)
            ps=PolicyStatus();ps.size=c.sizeof(ps)
            assert policy(oid,chain,c.byref(pp),c.byref(ps)),c.get_last_error()
            results[name]=ps.error
        return results
    finally:
        if chain:freechain(chain)
        for ctx in contexts:freecert(ctx)
        closestore(store,0)

root=Path(__file__).resolve().parents[2]
old=x509.load_pem_x509_certificate((root/'zig-out/vista/usb-test-package/local-test.pem').read_bytes())
out=root/'zig-out/vista/local-catalog'
leaf=x509.load_der_x509_certificate((out/'publisher.cer').read_bytes())
anchor=x509.load_der_x509_certificate((out/'root.cer').read_bytes())
before=check(old,old);after=check(leaf,anchor)
print('V9_CA_AS_SIGNER', {k:hex(v) for k,v in before.items()})
print('V10_DISTINCT_PUBLISHER', {k:hex(v) for k,v in after.items()})
assert before['basic_constraints']==0x80096019
assert all(v==0 for v in after.values()),after
print('WINDOWS_CERTIFICATE_POLICY_REGRESSION_PASS; HOST_STORES_UNCHANGED')
