/* No boot-time disk scans (autochk) on volumes other than the system volume
 * of the installed Vista (user request 2026-09-27). Same effect as
 * `chkntfs /x D: E:`: BootExecute becomes "autocheck autochk /k:D /k:E *".
 * The system volume keeps its check: autochk only runs there when the volume
 * is actually dirty (e.g. after a hard power-off), and skipping it risks real
 * corruption. Volumes without a drive letter cannot be excluded with /k:.
 *
 * Pure helpers (no registry access) so tools/tests/test_vista_autochk.py can
 * run them on the host. */
#ifndef USOS_VISTA_AUTOCHK_H
#define USOS_VISTA_AUTOCHK_H

/* The Windows default, the only BootExecute value USOS replaces. */
static const WCHAR usos_autochk_default[]=L"autocheck autochk *";

/* Letters of `fixed_mask` (bit 0 = A:) except `system_letter`, excluding
 * A: and B:. Writes the REG_MULTI_SZ value (one string + double NUL) into
 * `out`; returns its size in WCHARs including both terminators, or 0 when no
 * volume needs excluding (the default stays) or `cap` is too small. */
static unsigned usos_autochk_value(WCHAR *out,unsigned cap,DWORD fixed_mask,WCHAR system_letter){
 static const WCHAR head[]=L"autocheck autochk ";unsigned n=0,excluded=0;
 if(system_letter>=L'a'&&system_letter<=L'z')system_letter=(WCHAR)(system_letter-32);
 for(unsigned i=0;head[i];i++){if(n>=cap)return 0;out[n++]=head[i];}
 for(unsigned d=2;d<26;d++){
  WCHAR letter=(WCHAR)(L'A'+d);
  if(!(fixed_mask&(1u<<d))||letter==system_letter)continue;
  if(n+5>=cap)return 0;
  out[n++]=L'/';out[n++]=L'k';out[n++]=L':';out[n++]=letter;out[n++]=L' ';excluded++;
 }
 if(!excluded||n+3>cap)return 0;
 out[n++]=L'*';out[n++]=0;out[n++]=0;
 return n;
}

/* True when the stored REG_MULTI_SZ is exactly the Windows default (one
 * string, case-insensitive); anything else (another tool's entries, an
 * earlier exclusion) is left alone. `chars` includes the terminators. */
static int usos_autochk_is_default(const WCHAR *value,unsigned chars){
 unsigned i=0;
 for(;usos_autochk_default[i];i++){
  if(i>=chars)return 0;
  WCHAR a=value[i],b=usos_autochk_default[i];
  if(a>=L'A'&&a<=L'Z')a=(WCHAR)(a+32);
  if(a!=b)return 0;
 }
 /* One string: its NUL, then the list's final NUL (or the end of data). */
 return i<chars&&value[i]==0&&(i+1>=chars||value[i+1]==0);
}
#endif
