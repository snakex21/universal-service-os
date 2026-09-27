"""Small tests against real XP files and malformed PE input. No target OS boot."""
from pathlib import Path
import ctypes,gzip,hashlib,json,os,shutil,struct,subprocess,sys
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'tools'))
from build_micro_linux import parse_newc
import argparse
# No stick needed (refactor M0): the base is the build's micro-Linux image
# when it is the one the package was built from; the XP ISOs default to the
# copies in the repository root. --base/--images select others (e.g. J:/L:).
parser=argparse.ArgumentParser()
parser.add_argument('--base',type=Path,help='initramfs-usos the XP package was derived from')
parser.add_argument('--images',type=Path,help='folder with the XP ISOs (default: repository root, else L:)')
args=parser.parse_args()
def package_base():
    expected=json.loads((PACKAGE/'manifest.json').read_text())['base_initramfs_sha256']
    candidates=[args.base] if args.base else [root/'zig-out/micro-linux/initramfs-usos',Path('J:/EFI/USOS/micro-linux/initramfs-usos')]
    for path in candidates:
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest()==expected:return path
    raise SystemExit('No initramfs-usos with the package base SHA-256 '+expected+' (tried '+', '.join(map(str,candidates))+')')
def xp_images():
    if args.images:return sorted(args.images.glob('*.iso'))
    # PAE is x86 only: XP x64 media (AMD64 setup source) is not an input here.
    local=sorted(p for p in root.glob('*.iso') if 'xp' in p.name.lower() and 'x64' not in p.name.lower())
    return local or sorted(Path('L:/Systems/Windows/Windows XP/Images').glob('*.iso'))
# USOS_XP_PACKAGE_DIR: check another package folder (e.g. a branch build).
PACKAGE=Path(os.environ.get('USOS_XP_PACKAGE_DIR',root/'zig-out/xp-uefi-csm'))
out=PACKAGE/'checks';out.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,TEMP=str(out),TMP=str(out),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'cache'))
dll=out/'xp-pae-tests.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-Os','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/tests/xp_pae_harness.c'),'-Wl,--entry,DllMain','-lkernel32','-luser32','-ladvapi32','-lversion','-o',str(dll)],env=env,check=True)
api=ctypes.CDLL(str(dll));api.patch_copy.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int];api.find_pattern.argtypes=[ctypes.c_char_p,ctypes.c_uint,ctypes.c_char_p,ctypes.c_uint]
assert api.find_pattern(b'not a PE',8,b'abc',3)==-1
# Localized strings: only the installer-chosen language reaches the stick
# (EFI/USOS/lang-xp.ini -> USOS/XP/pae-strings.ini); English is built in.
lang_out=out/'lang-export';shutil.rmtree(lang_out,ignore_errors=True)
subprocess.run(['go','run','./cmd/usos-i18n-gen','-root','..','-export','pl','-out',str(lang_out)],cwd=root/'installer',check=True,stdout=subprocess.DEVNULL)
catalog={l:json.loads((root/'installer/internal/i18n/locales'/(l+'.json')).read_text('utf-8')) for l in ('en','pl')}
api.pae_string.argtypes=[ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_wchar_p,ctypes.c_uint]
def pae_string(ini,key):
    buf=ctypes.create_unicode_buffer(1024);api.pae_string(ini,key,buf,1024);return buf.value
lang_ini=lang_out/'EFI/USOS/lang-xp.ini'
assert lang_ini.read_bytes()[:2]==b'\xff\xfe'
assert pae_string(str(lang_ini),'restart_prompt')==catalog['pl']['xp_pae.restart_prompt']
assert pae_string(str(lang_ini),'title')==catalog['pl']['xp_pae.title']
assert pae_string(None,'restart_prompt')==catalog['en']['xp_pae.restart_prompt']
assert pae_string(str(out/'missing-pae-strings.ini'),'restart_prompt')==catalog['en']['xp_pae.restart_prompt']
garbage=out/'garbage-pae-strings.ini';garbage.write_bytes(b'garbage without section\r\nrestart_prompt=junk\r\n')
assert pae_string(str(garbage),'restart_prompt')==catalog['en']['xp_pae.restart_prompt']
# Modes: 0 setup-end (default / UserExecute), 1 first-logon fallback, 2 interactive.
api.mode_of.argtypes=[ctypes.c_char_p];api.stage_copy.argtypes=[ctypes.c_char_p,ctypes.c_char_p];api.entry_present.argtypes=[ctypes.c_char_p]
for line,mode in [(b'C:\\USOS\\XP\\pae.exe',0),(b'"C:\\USOS\\XP\\pae.exe"',0),(b'pae.exe /silent',0),(b'pae.exe /QUIET',0),
                  (b'"C:\\USOS\\XP\\pae.exe" /firstlogon',1),(b'pae.exe  /FirstLogon ',1),(b'pae.exe /interactive',2),(b'pae.exe /unknownlongswitchxxxx',0)]:
    assert api.mode_of(line)==mode,(line,api.mode_of(line))
# boot.ini staging on a realistic XP boot.ini (read-only attributes handled by run()).
ini=out/'boot-test.ini';staged=out/'boot-test-pae.ini'
original=(b'[boot loader]\r\ntimeout=30\r\ndefault=multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS\r\n[operating systems]\r\n'
          b'multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS="Microsoft Windows XP Professional" /noexecute=optin /fastdetect\r\n')
ini.write_bytes(original);staged.unlink(missing_ok=True)
assert not api.entry_present(os.fsencode(ini))
assert api.stage_copy(os.fsencode(ini),os.fsencode(staged))
text=staged.read_text('latin1').replace('\r\n','\n').splitlines()
assert ini.read_bytes()==original
assert 'timeout=0' in text and 'timeout=30' not in text
osi=text.index('[operating systems]')
assert text[osi+1].startswith('multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS="Windows XP - USOS PAE (experimental)"') and '/kernel=xpkrnpae.exe /hal=xphalpae.dll' in text[osi+1]
# NTLDR and the kernel match boot switches as substrings of the upper-cased
# options: the entry must not contain any switch it does not intend (v4's
# usospae.exe/usoshal.dll contained "SOS" and enabled /SOS on every boot).
options=text[osi+1].split('"')[2].upper()
for switch in ('SOS','NOGUIBOOT','BOOTLOG','BASEVIDEO','SAFEBOOT','DEBUG','3GB','ONECPU','NUMPROC','MAXMEM','BURNMEMORY','NOPAE','REDIRECT','USERVA','NOLOWMEM'):
    assert switch not in options,(switch,options)
assert options.split()==['/FASTDETECT','/PAE','/NOEXECUTE=OPTIN','/KERNEL=XPKRNPAE.EXE','/HAL=XPHALPAE.DLL'],options
# An install that already has the v4 entry is left alone (not a second entry).
v4=staged.read_bytes().replace(b'xpkrnpae.exe',b'usospae.exe').replace(b'xphalpae.dll',b'usoshal.dll')
v4ini=out/'boot-test-v4.ini';v4ini.write_bytes(v4);assert api.entry_present(os.fsencode(v4ini))
assert text[osi+2]=='multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS="Microsoft Windows XP Professional" /noexecute=optin /fastdetect'
assert api.entry_present(os.fsencode(staged))
# Re-staging overwrites a stale staged file instead of failing.
assert api.stage_copy(os.fsencode(ini),os.fsencode(staged))
ini.write_bytes(b'[boot loader]\r\ntimeout=30\r\n[operating systems]\r\n');staged.unlink(missing_ok=True)
assert not api.stage_copy(os.fsencode(ini),os.fsencode(staged)) and not staged.exists()
# Crash dumps off (GUI setup re-enables 3); AutoReboot and other values untouched.
# Exercised on a scratch HKCU key; the helper itself targets HKLM CrashControl.
import winreg
# usos-xp.ini accounts: usos-users.cmd runs hidden (no console), then is removed.
api.accounts_script.argtypes=[ctypes.c_char_p]
acc=out/'accounts';shutil.rmtree(acc,ignore_errors=True);acc.mkdir()
script=acc/'usos-users.cmd';marker=acc/'ran.txt'
assert api.accounts_script(os.fsencode(script))==0
script.write_bytes(b'@echo off'+bytes([13,10])+b'echo ran> "'+os.fsencode(marker)+b'"'+bytes([13,10])+b'exit /b 0'+bytes([13,10]))
assert api.accounts_script(os.fsencode(script))==1 and marker.read_text().strip()=='ran' and not script.exists()
api.crash_dump_off.argtypes=[ctypes.c_char_p]
test_key='Software\\USOS-XP-PAE-Test\\CrashControl'
def reset_test_key():
    try:winreg.DeleteKey(winreg.HKEY_CURRENT_USER,test_key)
    except FileNotFoundError:pass
reset_test_key()
assert api.crash_dump_off(test_key.encode())==-1
with winreg.CreateKey(winreg.HKEY_CURRENT_USER,test_key) as k:
    winreg.SetValueEx(k,'CrashDumpEnabled',0,winreg.REG_DWORD,3);winreg.SetValueEx(k,'AutoReboot',0,winreg.REG_DWORD,0)
    winreg.SetValueEx(k,'DumpFile',0,winreg.REG_EXPAND_SZ,'%SystemRoot%\\MEMORY.DMP')
assert api.crash_dump_off(test_key.encode())==1
with winreg.OpenKey(winreg.HKEY_CURRENT_USER,test_key) as k:
    assert winreg.QueryValueEx(k,'CrashDumpEnabled')==(0,winreg.REG_DWORD)
    assert winreg.QueryValueEx(k,'AutoReboot')==(0,winreg.REG_DWORD)
    assert winreg.QueryValueEx(k,'DumpFile')==('%SystemRoot%\\MEMORY.DMP',winreg.REG_EXPAND_SZ)
assert api.crash_dump_off(test_key.encode())==0
with winreg.OpenKey(winreg.HKEY_CURRENT_USER,test_key,0,winreg.KEY_SET_VALUE) as k:winreg.SetValueEx(k,'CrashDumpEnabled',0,winreg.REG_SZ,'3')
assert api.crash_dump_off(test_key.encode())==1
with winreg.OpenKey(winreg.HKEY_CURRENT_USER,test_key) as k:assert winreg.QueryValueEx(k,'CrashDumpEnabled')==(0,winreg.REG_DWORD)
reset_test_key()
try:winreg.DeleteKey(winreg.HKEY_CURRENT_USER,'Software\\USOS-XP-PAE-Test')
except OSError:pass
seven=Path('C:/Program Files/7-Zip/7z.exe')
images=xp_images();assert images,'No XP ISO found'
print('XP sources:',', '.join(i.name for i in images),flush=True)
results=[]
for idx,iso in enumerate(images):
    # Fresh scratch per ISO: the index-based folder may hold another ISO's CABs.
    extracted=out/str(idx);shutil.rmtree(extracted,ignore_errors=True);extracted.mkdir()
    subprocess.run([str(seven),'e',str(iso),'I386\\NTKRPAMP.EX_','I386\\HALMACPI.DL_','I386\\SP3.CAB','I386\\SP2.CAB','-o'+str(extracted),'-y'],check=True,stdout=subprocess.DEVNULL)
    for packed,plain,hal in [('NTKRPAMP.EX_','ntkrpamp.exe',0),('HALMACPI.DL_','halmacpi.dll',1)]:
        archive=extracted/packed
        if archive.exists():
            subprocess.run([str(seven),'e',str(archive),'-o'+str(extracted),'-y'],check=True,stdout=subprocess.DEVNULL)
        else:
            cabs=list(extracted.glob('SP?.CAB'))
            if len(cabs)!=1:raise ValueError('Missing or ambiguous XP service pack CAB')
            subprocess.run([str(seven),'e',str(cabs[0]),plain,'-o'+str(extracted),'-y'],check=True,stdout=subprocess.DEVNULL)
        source=extracted/plain;patched=extracted/(plain+'.patched');patched.unlink(missing_ok=True)
        before=source.read_bytes()
        rc=api.patch_copy(os.fsencode(source),os.fsencode(patched),hal)
        assert source.read_bytes()==before
        if rc:
            after=patched.read_bytes();assert after!=before and len(after)==len(before)
            # An already patched file must not silently patch a different match.
            twice=extracted/(plain+'.twice');twice.unlink(missing_ok=True)
            assert not api.patch_copy(os.fsencode(patched),os.fsencode(twice),hal)
            assert not twice.exists()
        results.append({'iso':iso.name,'file':plain,'supported':bool(rc),'sha256':hashlib.sha256(before).hexdigest()})
        print(iso.name,plain,'PATCHED COPY' if rc else 'REFUSED (unsupported pattern)',flush=True)
entries=parse_newc(gzip.decompress((out.parent/'initramfs-xp').read_bytes()))
# Since refactor M4 the UEFI-CSM answer is its own base file; the BIOS one has no PAE.
SIF='usr/lib/usos/xp_selected_partition_uefi_csm.sif'
assert b'rdinit' not in entries[SIF].data
assert b'[GuiRunOnce]' in entries[SIF].data
assert b'[GuiRunOnce]' not in entries['usr/lib/usos/xp_selected_partition.sif'].data
sif_text=entries[SIF].data
assert b'[SetupParams]\nUserExecute="C:\\USOS\\XP\\pae.exe"\n' in sif_text and sif_text.count(b'[SetupParams]')==1
assert b'Command0="%SystemDrive%\\USOS\\XP\\pae.exe /firstlogon"' in sif_text
assert b'cmdlines' not in sif_text.lower() and b'detachedprogram' not in sif_text.lower()
prepare=entries['usr/lib/usos/prepare_xp_ntfs_target.sh'].data
assert b'xp_verify_target.sh' in prepare and b'blockdev --flushbufs' in prepare
assert b'cp /mnt/esp/EFI/USOS/lang-xp.ini "$work/volume/USOS/XP/pae-strings.ini"' in prepare and b'PAE strings readback mismatch' in prepare
assert entries['usr/lib/usos/xp_verify_target.sh'].data==(root/'tools/xp_verify_target.sh').read_bytes()
for name,entry in entries.items():
    if name.startswith('usr/lib/usos/xp-drivers/') and name.endswith('/I386/HIVESYS.INF'):
        hivesys=entry.data.decode('utf-16') if entry.data[:2]==b'\xff\xfe' else entry.data.decode('latin1')
        rows=[l for l in hivesys.splitlines() if '"CrashDumpEnabled"' in l]
        assert len(rows)==1 and rows[0].rstrip().endswith(',0'),(name,rows)
        assert '\r\n' in hivesys,name
# Physical-trial diagnostics must never ship in the USB flow.
for marker in [b'NUMPROC',b'/BOOTLOG',b'd.cmd',b'usos-diag']:
    for name in ['usos-init',SIF,'usr/lib/usos/prepare_xp_ntfs_target.sh','usr/lib/usos/legacy_xp_staging.sh']:
        assert marker not in entries[name].data,(name,marker)
assert entries['usr/lib/usos/xp-pae.exe'].data==(out.parent/'pae.exe').read_bytes()
base_path=package_base();print('Package base:',base_path,flush=True)
base=parse_newc(gzip.decompress(base_path.read_bytes()))
changed={n for n in entries if n not in base or entries[n].data!=base[n].data}
driver_entries={n for n in entries if n=='usr/lib/usos/xp-drivers' or n.startswith('usr/lib/usos/xp-drivers/')}
# Refactor M4: the package only ADDS the PAE helper, its notice and the driver
# bundles; every base entry (scripts, UI, init) is the base's own.
overlay={'usr/lib/usos/xp-pae.exe','usr/lib/usos/xp-pae-LICENSE.txt'}
assert changed==overlay|driver_entries,(changed-(overlay|driver_entries),(overlay|driver_entries)-changed)
assert all(n not in base for n in overlay|driver_entries)
assert driver_entries
for name in ['usos-init','usr/lib/usos/legacy_xp_staging.sh','usr/lib/usos/prepare_xp_ntfs_target.sh','usr/lib/usos/xp_verify_target.sh']:
    script=out/(Path(name).name+'.sh');script.write_bytes(entries[name].data)
    subprocess.run(['C:/Program Files/Git/bin/bash.exe','-n',str(script)],check=True)
exe=(out.parent/'pae.exe').read_bytes();pe=struct.unpack_from('<I',exe,60)[0]
assert struct.unpack_from('<H',exe,pe+4)[0]==0x14c
assert struct.unpack_from('<HH',exe,pe+24+48)==(5,1)
assert struct.unpack_from('<H',exe,pe+24+68)[0]==2,'PAE helper must use the GUI subsystem (no console)'
helper_source=(root/'tools/windows_xp_pae.c').read_text()
assert '"timeout","0"' in helper_source and 'OPEN_ALWAYS' in helper_source
# Setup-end and first-logon runs both disable crash dumps in the live CrashControl key.
assert 'if(mode!=MODE_INTERACTIVE)disable_crash_dump(HKEY_LOCAL_MACHINE,"SYSTEM\\\\CurrentControlSet\\\\Control\\\\CrashControl");' in helper_source
assert '"AutoReboot"' not in helper_source
assert b'CrashDumpEnabled' in exe and b'SYSTEM\\CurrentControlSet\\Control\\CrashControl' in exe
# The only message box outside /interactive is the first-logon fallback prompt.
assert helper_source.count('MessageBoxW(')==1 and 'if(mode==MODE_FIRST_LOGON&&r==RUN_ENABLED)' in helper_source
# Only English is compiled in; other languages come from pae-strings.ini.
assert 'pae-strings.ini' in helper_source and 'USOS_XP_PAE_RESTART_PROMPT_EN' in helper_source
assert catalog['pl']['xp_pae.restart_prompt'].encode('utf-16-le') not in exe and catalog['en']['xp_pae.restart_prompt'].encode('utf-16-le') in exe
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['supported'] for r in results),'At least one source does not support this strict PAE patch'
print('PASS: real XP kernel/HAL patch copies; repeat patch refused; original files unchanged; experimental archive isolation')
