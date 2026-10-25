# Windows 95 under CSMWrap: the vmdisp9x VESA display driver after Setup
# (docs/win9x-modern-2026-09-30.md section 4h). Sourced by
# tools/w9x_csmwrap_target.sh.
#
# Early legacy path: 98 / 98 SE / Me detect the PCI bus as a root device
# (*PNP0A03), so the display card shows up as PCI\VEN_..&DEV_.. and Setup's
# device install picks USOSVESA.INF (DevicePath=1, PCI\CC_0300 or the IDs
# U9FIX /VGA / w9x_add_display_ids add). Windows 95 detection skips the PCI
# bus when a Plug and Play BIOS answers (DETLOG.TXT "SetVar: PNPBIOS="), and
# SeaBIOS (QEMU phase 1, CSMWrap on the PC) has a PnP BIOS that lists no PCI
# bus node: 95 never enumerates PCI. Its display is the legacy-detected
# Enum\Root\*PNP0900\0000, which detection binds to MSDISP.INF [VGA] (16
# colours, 640x480); USOSVESA.INF is never read (X470, 95 OSR2.1 PL,
# 2026-10-07). USOSVESA.INF does list *PNP0900, so this step puts that
# device on the same driver Setup gives 98: the class key Display\0000 gets
# USOSVESA.INF [VESA]'s values (DEFAULT, MODES, vmdisp9x\vesa NoMemTest=1).
#
# w9x_vesa95_write <C:\USOS9X folder> [bpp] [width,height]
# writes VESA95.BAT and VESA95.REG there; AUTOEXEC.BAT
# (src/platform/bios/dos_startup.cmd) calls VESA95.BAT before every Windows
# start. VESA95.BAT acts once, in real-mode DOS, when the registry exists
# and Display\0000 is still MSDISP.INF's:
#   1. copies the driver files (VESAMINI.DRV / .VXD, VMDISP9X.DLL,
#      VMHAL9X.DLL, VMHAL486.DLL) to C:\WINDOWS\SYSTEM and USOSVESA.INF to
#      C:\WINDOWS\INF (Device Manager's driver page),
#   2. backs up SYSTEM.DAT / USER.DAT (C:\USOS9X\SYSTEM.V5 / USER.V5),
#      imports VESA95.REG, checks it with REGEDIT /E + FIND and restores the
#      backup on a failed import (VESA95.RUN: one attempt, never repeated
#      after a crash). Result in C:\USOS9X\VESA95.OK or VESA95.BAD.
# SYSTEM.INI needs nothing: 95 Setup already wrote display.drv=pnpdrvr.drv
# (the registry's DEFAULT drv) and display=*vdd,*vflatd, as on 98.
# Source950 exception: GUI Setup can enumerate a PCI display later and bind
# it to another VGA class. VESALATE.BAT resolves that existing device after
# RunOnce\Setup is gone, before the early step's old completion guard.
# VESALATE.BAT also removes the legacy *PNP0900 devnode with VESBIND DELKEY.

W9X_VESA95_MODES='640,480 800,600 1024,768 1152,864 1280,720 1280,800 1280,960 1280,1024 1400,1050 1600,900 1600,1200 1680,1050 1920,1080 1920,1200'

w9x_vesa95_write() {
    dir=$1 bpp=${2:-16} res=${3:-1024,768} source_version=${4:-}
    case "$bpp" in 8|16|24|32) ;; *) return 1 ;; esac
    case " $W9X_VESA95_MODES " in *" $res "*) ;; *) return 1 ;; esac
    [ -d "$dir" ] || return 1
    cls='HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\Display\0000'
    mfg='JHRobotics (vmdisp9x, via USOS)'
    desc='VESA ISA Adapter (vmdisp9x)'
    {
        printf 'REGEDIT4\r\n\r\n[%s]\r\n' "$cls"
        printf '"Ver"="4.0"\r\n"DevLoader"="*vdd"\r\n"InfPath"="USOSVESA.INF"\r\n"InfSection"="VESA"\r\n'
        printf '"ProviderName"="%s"\r\n"DriverDate"=" 8- 3-2025"\r\n"DriverDesc"="%s"\r\n\r\n' "$mfg" "$desc"
        printf '[%s\\DEFAULT]\r\n"drv"="vesamini.drv"\r\n"minivdd"="vesamini.vxd"\r\n"vdd"="*vdd"\r\n' "$cls"
        printf '"Mode"="%s,%s"\r\n"RefreshRate"="-1"\r\n"DDC"="1"\r\n\r\n' "$bpp" "$res"
        printf '[%s\\MODES\\4\\640,480]\r\n"drv"="vga.drv"\r\n"vdd"="*vdd"\r\n\r\n' "$cls"
        printf '[%s\\MODES\\4\\800,600]\r\n"drv"="supervga.drv"\r\n"vdd"="*vdd"\r\n\r\n' "$cls"
        for depth in 8 16 24 32; do
            for mode in $W9X_VESA95_MODES; do printf '[%s\\MODES\\%s\\%s]\r\n\r\n' "$cls" "$depth" "$mode"; done
        done
        printf '[HKEY_LOCAL_MACHINE\\Software\\vmdisp9x\\vesa]\r\n"VRAMLimit"="128"\r\n"NoMemTest"="1"\r\n\r\n'
        printf '[HKEY_LOCAL_MACHINE\\Enum\\Root\\*PNP0900\\0000]\r\n"DeviceDesc"="%s"\r\n"Mfg"="%s"\r\n\r\n' "$desc" "$mfg"
        printf '[HKEY_LOCAL_MACHINE\\Config\\0001\\Display\\Settings]\r\n"BitsPerPixel"="%s"\r\n"Resolution"="%s"\r\n\r\n' "$bpp" "$res"
    } > "$dir/VESA95.REG" || return 1
    U='C:\USOS9X\'
    S='C:\WINDOWS\SYSTEM\'
    R='REGEDIT /L:SYSTEM.DAT /R:USER.DAT'
    F='C:\WINDOWS\COMMAND\FIND.EXE'
    A='C:\WINDOWS\COMMAND\ATTRIB.EXE'
    sed 's/$/\r/' > "$dir/VESA95.BAT" <<EOF || return 1
@ECHO OFF
REM USOS: Windows 95 VESA display driver (tools/w9x_vesa95.sh), $bpp-bit $res.
REM Runs from AUTOEXEC.BAT before Windows starts, at most once.
REM Undo: copy ${U}SYSTEM.V5 / USER.V5 back over C:\WINDOWS\*.DAT.
IF EXIST ${U}VESA95.OK GOTO END
IF EXIST ${U}VESA95.BAD GOTO END
IF EXIST ${U}VESA95.RUN GOTO END
IF NOT EXIST ${U}VESA95.REG GOTO END
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST $F GOTO END
IF NOT EXIST $A GOTO END
IF NOT EXIST ${U}VESAMINI.VXD GOTO END
IF NOT EXIST ${U}VMDISP9X.DLL GOTO END
C:
CD \WINDOWS
$A -S -R -H SYSTEM.DAT
$A -S -R -H USER.DAT
$R /E VG0.CHK $cls
IF NOT EXIST VG0.CHK GOTO ATTR
$F /I "msdisp.inf" VG0.CHK > NUL
IF NOT ERRORLEVEL 1 GOTO PENDING
ECHO not-pending> ${U}VESA95.OK
GOTO ATTR
REM One attempt only: a crash in the middle never repeats it.
:PENDING
ECHO run> ${U}VESA95.RUN
FOR %%F IN (VESAMINI.DRV VESAMINI.VXD VMDISP9X.DLL) DO COPY /Y ${U}%%F C:\WINDOWS\SYSTEM > NUL
FOR %%F IN (VMHAL9X.DLL VMHAL486.DLL) DO COPY /Y ${U}%%F C:\WINDOWS\SYSTEM > NUL
IF NOT EXIST ${S}VESAMINI.VXD GOTO NOFILES
IF NOT EXIST ${S}VMDISP9X.DLL GOTO NOFILES
IF EXIST ${U}USOSVESA.INF COPY /Y ${U}USOSVESA.INF C:\WINDOWS\INF > NUL
COPY /Y SYSTEM.DAT ${U}SYSTEM.V5 > NUL
COPY /Y USER.DAT ${U}USER.V5 > NUL
IF NOT EXIST ${U}SYSTEM.V5 GOTO ATTR
IF NOT EXIST ${U}USER.V5 GOTO ATTR
$R ${U}VESA95.REG
$R /E VG1.CHK $cls
IF NOT EXIST VG1.CHK GOTO BAD
$F /I "vesamini.drv" VG1.CHK > NUL
IF ERRORLEVEL 1 GOTO BAD
$F /I "USOSVESA.INF" VG1.CHK > NUL
IF ERRORLEVEL 1 GOTO BAD
ECHO ok> ${U}VESA95.OK
GOTO ATTR
:NOFILES
ECHO no-files> ${U}VESA95.BAD
GOTO ATTR
:BAD
ECHO USOS: VESA display registry change failed, restoring the registry backup.
COPY /Y ${U}SYSTEM.V5 SYSTEM.DAT > NUL
COPY /Y ${U}USER.V5 USER.DAT > NUL
ECHO bad> ${U}VESA95.BAD
REM SYSTEM.DAT / USER.DAT stay as Setup left them otherwise.
:ATTR
FOR %%F IN (VG0 VG1) DO IF EXIST %%F.CHK DEL %%F.CHK
$A +S +R +H SYSTEM.DAT
$A +S +R +H USER.DAT
CD \\
:END
EOF
    if [ "$source_version" = '4 0 0 950' ]; then
        [ -f "$dir/VESBIND.EXE" ] || return 1
        w9x_vesa950_late_write "$dir" || return 1
        {
            printf '@ECHO OFF\r\n'
            printf '%s\r\n' 'CALL C:\USOS9X\VESALATE.BAT' \
                'IF EXIST C:\USOS9X\VLATE.ERR GOTO VLFAIL' \
                'IF EXIST C:\USOS9X\VLATE.RUN GOTO VLFAIL' 'GOTO VLNEXT' \
                ':VLFAIL' 'REM Fail-soft: log to the target disk, Windows starts with the display it has.' \
                'ECHO USOS: display preparation failed, see C:\USOS9X. Windows starts with its current display.' \
                'ECHO VESA95: 950 late display binding failed, see C:\USOS9X\VLATE.*; Windows started>> C:\USOS9X\USOSLOG.TXT' \
                ':VLNEXT'
            tail -n +2 "$dir/VESA95.BAT"
        } > "$dir/VESA95.NEW" && mv "$dir/VESA95.NEW" "$dir/VESA95.BAT" || return 1
    fi
}

# 950 Setup may create a new PCI Display instance after the early VESA import.
# Wait for the real RunOnce\Setup boundary, then bind the one existing VGA
# device to the existing VESA class. VESBIND reads exports, never hive bytes.
# A PCI display next to the legacy Root\*PNP0900 (950 keeps both as two
# adapters; OSR2 drops the legacy one itself): VESBIND PLAN exits 3, the
# batch writes VLDEL.FLG and, before the import, deletes
# Enum\Root\*PNP0900 with its subtree through VESBIND DELKEY (an in-place
# CREG edit of SYSTEM.DAT: 950's real-mode REGEDIT has no /D, its usage text
# lists only import, /C and /E, so the earlier REGEDIT /D lines did nothing).
# DELKEY exit 2 / 3 -> rollback to SYSTEM.VL; exit 1 (no such key) is logged
# and left to CHECK, which refuses a *PNP0900 display that is still there ->
# rollback.
w9x_vesa950_late_write() {
    sed 's/$/\r/' > "$1/VESALATE.BAT" <<'EOF'
@ECHO OFF
IF EXIST C:\USOS9X\VLATE.ERR GOTO FAIL
IF EXIST C:\USOS9X\VLATE.RUN GOTO FAIL
IF EXIST C:\USOS9X\VLATE.OK GOTO END
IF NOT EXIST C:\USOS9X\REG95.OK GOTO END
IF NOT EXIST C:\USOS9X\VESA95.OK GOTO END
IF NOT EXIST C:\USOS9X\VESBIND.EXE GOTO FAIL
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO FAIL
IF NOT EXIST C:\WINDOWS\USER.DAT GOTO FAIL
IF NOT EXIST C:\WINDOWS\COMMAND\FIND.EXE GOTO FAIL
IF NOT EXIST C:\WINDOWS\COMMAND\ATTRIB.EXE GOTO FAIL
C:
CD \WINDOWS
IF EXIST C:\USOS9X\VL1.REG DEL C:\USOS9X\VL1.REG > NUL
IF EXIST C:\USOS9X\VL1.REG GOTO FAIL
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\VL1.REG HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce
IF NOT EXIST C:\USOS9X\VL1.REG GOTO FAIL
C:\WINDOWS\COMMAND\FIND.EXE /I "\RunOnce]" C:\USOS9X\VL1.REG > NUL
IF ERRORLEVEL 1 GOTO FAIL
C:\WINDOWS\COMMAND\FIND.EXE /I "\RunOnce\Setup]" C:\USOS9X\VL1.REG > NUL
IF ERRORLEVEL 2 GOTO FAIL
IF NOT ERRORLEVEL 1 GOTO PENDING
FOR %%F IN (VL2 VL3 VL4 VL5 VL6 VLATE) DO IF EXIST C:\USOS9X\%%F.REG DEL C:\USOS9X\%%F.REG > NUL
FOR %%F IN (VL2 VL3 VL4 VL5 VL6 VLATE) DO IF EXIST C:\USOS9X\%%F.REG GOTO FAIL
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\VL2.REG HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\Display
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\VL3.REG HKEY_LOCAL_MACHINE\Enum
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\VL4.REG HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\IDConfigDB
IF NOT EXIST C:\USOS9X\VL2.REG GOTO FAIL
IF NOT EXIST C:\USOS9X\VL3.REG GOTO FAIL
IF NOT EXIST C:\USOS9X\VL4.REG GOTO FAIL
CD \USOS9X
IF EXIST C:\USOS9X\VLDEL.FLG DEL C:\USOS9X\VLDEL.FLG > NUL
IF EXIST C:\USOS9X\VLDEL.FLG GOTO FAIL
VESBIND.EXE PLAN VL2.REG VL3.REG VL4.REG VLATE.REG
IF ERRORLEVEL 4 GOTO FAIL
IF ERRORLEVEL 3 GOTO VLDEL
IF ERRORLEVEL 1 GOTO FAIL
GOTO VLPLAN
:VLDEL
ECHO legacy> C:\USOS9X\VLDEL.FLG
IF NOT EXIST C:\USOS9X\VLDEL.FLG GOTO FAIL
:VLPLAN
IF NOT EXIST C:\USOS9X\VLATE.REG GOTO FAIL
CD \WINDOWS
ECHO run> C:\USOS9X\VLATE.RUN
IF NOT EXIST C:\USOS9X\VLATE.RUN GOTO FAIL
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H USER.DAT
COPY /Y SYSTEM.DAT C:\USOS9X\SYSTEM.VL > NUL
IF ERRORLEVEL 1 GOTO ATTRFAIL
COPY /Y USER.DAT C:\USOS9X\USER.VL > NUL
IF ERRORLEVEL 1 GOTO ATTRFAIL
REM One adapter as on OSR2: the legacy VGA devnode and its subtree go.
REM 950's real-mode REGEDIT has no /D: VESBIND DELKEY edits SYSTEM.DAT.
REM REGEDIT restores R/S/H, so deletion must precede its import.
IF NOT EXIST C:\USOS9X\VLDEL.FLG GOTO VLIMPORT
C:\USOS9X\VESBIND.EXE DELKEY C:\WINDOWS\SYSTEM.DAT HKEY_LOCAL_MACHINE\Enum\Root\*PNP0900 C:\USOS9X\VLDEL.LOG
IF ERRORLEVEL 3 ECHO VESALATE: DELKEY failed while writing SYSTEM.DAT, backup restored>> C:\USOS9X\USOSLOG.TXT
IF ERRORLEVEL 3 GOTO ROLLBACK
IF ERRORLEVEL 2 ECHO VESALATE: DELKEY refused SYSTEM.DAT, backup restored>> C:\USOS9X\USOSLOG.TXT
IF ERRORLEVEL 2 GOTO ROLLBACK
IF ERRORLEVEL 1 ECHO VESALATE: DELKEY found no Enum\Root\*PNP0900>> C:\USOS9X\USOSLOG.TXT
:VLIMPORT
REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\VLATE.REG
:VLEXP
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\VL5.REG HKEY_LOCAL_MACHINE\Enum
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\VL6.REG HKEY_LOCAL_MACHINE\Config
IF NOT EXIST C:\USOS9X\VL5.REG GOTO ROLLBACK
IF NOT EXIST C:\USOS9X\VL6.REG GOTO ROLLBACK
CD \USOS9X
VESBIND.EXE CHECK VL2.REG VL5.REG VL4.REG VL6.REG
IF ERRORLEVEL 1 GOTO ROLLBACK
CD \WINDOWS
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT
ECHO complete> C:\USOS9X\VLATE.OK
DEL C:\USOS9X\VLATE.RUN > NUL
GOTO PENDING
:ROLLBACK
C:
CD \WINDOWS
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H USER.DAT
COPY /Y C:\USOS9X\SYSTEM.VL SYSTEM.DAT > NUL
COPY /Y C:\USOS9X\USER.VL USER.DAT > NUL
:ATTRFAIL
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT
:FAIL
ECHO late display preparation failed; see VLDEL.LOG> C:\USOS9X\VLATE.ERR
IF EXIST C:\USOS9X\VLDEL.LOG TYPE C:\USOS9X\VLDEL.LOG >> C:\USOS9X\VLATE.ERR
IF EXIST C:\USOS9X\VLDEL.LOG TYPE C:\USOS9X\VLDEL.LOG >> C:\USOS9X\USOSLOG.TXT
IF EXIST C:\USOS9X\VLATE.RUN DEL C:\USOS9X\VLATE.RUN > NUL
:PENDING
C:
CD \
:END
EOF
}
