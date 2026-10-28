/* Win9x post-addons repair, before either USOSADD or its caller restarts.
 * W95WS2 may queue unpatched NDIS 4.00.1111 through WININIT.INI. Patch that
 * replacement, when present, so WININIT cannot undo the CPU-speed fix.
 * Otherwise patch SYSTEM\NDIS.VXD directly (9x has no system-file lock).
 * No WININIT entries are executed, removed or changed. Backups are beside
 * USOSADD, not in a profile. Copyright USOS 2026, GPL-3.0-or-later. */
#ifndef USOSADD_NDIS_REPAIR_H
#define USOSADD_NDIS_REPAIR_H
#include "ndis_patch.h"
static int ua_ndis_join(char *out, const char *directory, const char *leaf) {
    unsigned n=(unsigned)lstrlenA(directory);
    if(n+(unsigned)lstrlenA(leaf)+2>MAX_PATH)return 0;
    lstrcpyA(out,directory);if(n&&out[n-1]!='\\')lstrcatA(out,"\\");lstrcatA(out,leaf);return 1;
}
/* 0=refused, 1=already patched, 2=patched and flushed/read back. */
static int ua_ndis_repair(const char *windows, const char *system, const char *app, void (*log)(const char *)) {
    char target[MAX_PATH],init[MAX_PATH],queued[MAX_PATH],backup[MAX_PATH];
    HANDLE file=INVALID_HANDLE_VALUE;unsigned char *data=0,verify[UA_NDIS_PATCH_SIZE];
    DWORD attrs,high=0,size,got,offset=0,n;int found,result=0,changed_attrs=0;
    if(!ua_ndis_join(target,system,"NDIS.VXD")||!ua_ndis_join(init,windows,"WININIT.INI"))return 0;
    n=GetPrivateProfileStringA("Rename",target,"",queued,sizeof queued,init);
    if(n>=sizeof queued-1){log("NDIS repair refused: truncated WININIT source");return 0;}
    if(!ua_ndis_join(backup,app,n?"NDISQ.BAK":"NDIS95.BAK"))return 0;
    if(n){lstrcpyA(target,queued);log("NDIS repair: WININIT replacement selected");}
    else log("NDIS repair: installed driver selected");
    log(target);
    attrs=GetFileAttributesA(target);
    if(attrs==INVALID_FILE_ATTRIBUTES||(attrs&FILE_ATTRIBUTE_DIRECTORY))goto done;
    if(attrs&FILE_ATTRIBUTE_READONLY) {
        if(!SetFileAttributesA(target,attrs&~FILE_ATTRIBUTE_READONLY))goto done;
        changed_attrs=1;
    }
    file=CreateFileA(target,GENERIC_READ,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
    if(file==INVALID_HANDLE_VALUE)goto done;
    size=GetFileSize(file,&high);
    if(high||size<UA_NDIS_PATCH_SIZE||size>2UL*1024*1024)goto done;
    data=VirtualAlloc(0,size,MEM_RESERVE|MEM_COMMIT,PAGE_READWRITE);
    got=0;if(!data||!ReadFile(file,data,size,&got,0)||got!=size)goto done;
    found=ua_ndis_locate(data,size,&offset);
    if(!found){log("NDIS repair refused: unknown or ambiguous byte pattern");goto done;}
    if(found==2){log("NDIS repair: already patched");result=1;goto done;}
    if(!CopyFileA(target,backup,TRUE)&&GetLastError()!=ERROR_FILE_EXISTS) {
        log("NDIS repair refused: backup unavailable");goto done;
    }
    CloseHandle(file);
    file=CreateFileA(target,GENERIC_READ|GENERIC_WRITE,FILE_SHARE_READ,0,OPEN_EXISTING,0,0);
    if(file==INVALID_HANDLE_VALUE)goto done;
    if(SetFilePointer(file,offset,0,FILE_BEGIN)==INVALID_SET_FILE_POINTER)goto done;
    /* Reopening for write must still address the exact bytes we inspected. */
    if(!ReadFile(file,verify,sizeof verify,&got,0)||got!=sizeof verify||!ua_ndis_equal(verify,data+offset))goto done;
    if(SetFilePointer(file,offset,0,FILE_BEGIN)==INVALID_SET_FILE_POINTER)goto done;
    got=0;
    if(WriteFile(file,ua_ndis_patched,UA_NDIS_PATCH_SIZE,&got,0)&&got==UA_NDIS_PATCH_SIZE&&FlushFileBuffers(file)&&
       SetFilePointer(file,offset,0,FILE_BEGIN)!=INVALID_SET_FILE_POINTER&&ReadFile(file,verify,sizeof verify,&got,0)&&
       got==sizeof verify&&ua_ndis_equal(verify,ua_ndis_patched)) {
        log("NDIS repair: Patcher9x 18-byte fix applied and verified");result=2;
    } else {
        /* Retain the full backup too; never restart after an I/O failure. */
        SetFilePointer(file,offset,0,FILE_BEGIN);WriteFile(file,data+offset,UA_NDIS_PATCH_SIZE,&got,0);FlushFileBuffers(file);
        log("NDIS repair failed: rollback attempted; full backup retained");
    }
done:
    if(data)VirtualFree(data,0,MEM_RELEASE);
    if(file!=INVALID_HANDLE_VALUE)CloseHandle(file);
    if(changed_attrs&&!SetFileAttributesA(target,attrs))result=0;
    if(!result)log("NDIS repair incomplete; restart refused");
    return result;
}
#endif
