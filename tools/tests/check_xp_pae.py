"""Small tests against real XP files and malformed PE input. No target OS boot."""
from pathlib import Path
import ctypes,gzip,hashlib,json,os,shutil,struct,subprocess,sys
root=Path(__file__).resolve().parents[2];sys.path.insert(0,str(root/'tools'))
from build_micro_linux import parse_newc
out=root/'zig-out/xp-uefi-csm/checks';out.mkdir(parents=True,exist_ok=True)
env=dict(os.environ,TEMP=str(out),TMP=str(out),ZIG_GLOBAL_CACHE_DIR=str(root/'tools/cache/zig-global'),ZIG_LOCAL_CACHE_DIR=str(out/'cache'))
dll=out/'xp-pae-tests.dll'
subprocess.run([str(root/'tools/zig/zig.exe'),'cc','-target','x86_64-windows-gnu','-shared','-nostdlib','-fno-builtin','-fno-stack-protector','-Os','-I'+str(root/'tools/zig/lib/libc/include/any-windows-any'),str(root/'tools/tests/xp_pae_harness.c'),'-Wl,--entry,DllMain','-lkernel32','-luser32','-ladvapi32','-lversion','-o',str(dll)],env=env,check=True)
api=ctypes.CDLL(str(dll));api.patch_copy.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_int];api.find_pattern.argtypes=[ctypes.c_char_p,ctypes.c_uint,ctypes.c_char_p,ctypes.c_uint]
assert api.find_pattern(b'not a PE',8,b'abc',3)==-1
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
assert text[osi+1].startswith('multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS="Windows XP - USOS PAE (experimental)"') and '/kernel=usospae.exe /hal=usoshal.dll' in text[osi+1]
assert text[osi+2]=='multi(0)disk(0)rdisk(0)partition(1)\\WINDOWS="Microsoft Windows XP Professional" /noexecute=optin /fastdetect'
assert api.entry_present(os.fsencode(staged))
# Re-staging overwrites a stale staged file instead of failing.
assert api.stage_copy(os.fsencode(ini),os.fsencode(staged))
ini.write_bytes(b'[boot loader]\r\ntimeout=30\r\n[operating systems]\r\n');staged.unlink(missing_ok=True)
assert not api.stage_copy(os.fsencode(ini),os.fsencode(staged)) and not staged.exists()
seven=Path('C:/Program Files/7-Zip/7z.exe')
images=sorted(Path('L:/Systems/Windows/Windows XP/Images').glob('*.iso'))
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
assert b'rdinit' not in entries['usr/lib/usos/xp_selected_partition.sif'].data
assert b'[GuiRunOnce]' in entries['usr/lib/usos/xp_selected_partition.sif'].data
sif_text=entries['usr/lib/usos/xp_selected_partition.sif'].data
assert b'[SetupParams]\nUserExecute="C:\\USOS\\XP\\pae.exe"\n' in sif_text and sif_text.count(b'[SetupParams]')==1
assert b'Command0="%SystemDrive%\\USOS\\XP\\pae.exe /firstlogon"' in sif_text
assert b'cmdlines' not in sif_text.lower() and b'detachedprogram' not in sif_text.lower()
prepare=entries['usr/lib/usos/prepare_xp_ntfs_target.sh'].data
assert b'xp_verify_target.sh' in prepare and b'blockdev --flushbufs' in prepare
assert entries['usr/lib/usos/xp_verify_target.sh'].data==(root/'tools/xp_verify_target.sh').read_bytes()
for name,entry in entries.items():
    if name.startswith('usr/lib/usos/xp-drivers/') and name.endswith('/I386/HIVESYS.INF'):
        hivesys=entry.data.decode('utf-16') if entry.data[:2]==b'\xff\xfe' else entry.data.decode('latin1')
        rows=[l for l in hivesys.splitlines() if '"CrashDumpEnabled"' in l]
        assert len(rows)==1 and rows[0].rstrip().endswith(',0'),(name,rows)
        assert '\r\n' in hivesys,name
# Physical-trial diagnostics must never ship in the USB flow.
for marker in [b'NUMPROC',b'/BOOTLOG',b'd.cmd',b'usos-diag']:
    for name in ['usos-init','usr/lib/usos/xp_selected_partition.sif','usr/lib/usos/prepare_xp_ntfs_target.sh','usr/lib/usos/legacy_xp_staging.sh']:
        assert marker not in entries[name].data,(name,marker)
assert entries['usr/lib/usos/xp-pae.exe'].data==(out.parent/'pae.exe').read_bytes()
base=parse_newc(gzip.decompress(Path('J:/EFI/USOS/micro-linux/initramfs-usos').read_bytes()))
changed={n for n in entries if n not in base or entries[n].data!=base[n].data}
driver_entries={n for n in entries if n=='usr/lib/usos/xp-drivers' or n.startswith('usr/lib/usos/xp-drivers/')}
assert changed=={'usos-init','usr/bin/usos-fb-ui','usr/lib/usos/xp_menu_ui.sh','usr/lib/usos/legacy_xp_staging.sh','usr/lib/usos/prepare_xp_ntfs_target.sh','usr/lib/usos/xp_selected_partition.sif','usr/lib/usos/xp-pae.exe','usr/lib/usos/xp-pae-LICENSE.txt','usr/lib/usos/xp_driver_stage.sh','usr/lib/usos/xp_verify_target.sh','usr/lib/usos/micro_linux_ui.sh'}|driver_entries,changed
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
# The only message box outside /interactive is the first-logon fallback prompt.
assert helper_source.count('MessageBoxW(')==1 and 'if(mode==MODE_FIRST_LOGON&&r==RUN_ENABLED)' in helper_source
(out/'results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(r['supported'] for r in results),'At least one source does not support this strict PAE patch'
print('PASS: real XP kernel/HAL patch copies; repeat patch refused; original files unchanged; experimental archive isolation')
