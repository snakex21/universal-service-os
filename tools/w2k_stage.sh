#!/bin/sh
# Windows 2000 SP4 (UEFI profile w2k-x86-sp4-uefi-csm, experimental): the
# pieces NT 5.0 needs on modern boards (docs/windows-2000-modern-2026-09-30.md).
# Applied on the target after the local source copy, before xhci98
# (nt52_usb_stage.sh):
#
# 1. AHCI: AHCINT 1.3.0.0-usos4 (https://github.com/ages2001/AHCINT, GPL-3.0,
#    MODIFIED by USOS: real FLUSH CACHE, FUA, caching mode page;
#    tools/vendor/ahcint/1.3.0.0-usos4), a ScsiPort miniport with
#    polling I/O (no interrupt needed, so it also runs without ACPI). Every
#    import (ntoskrnl, scsiport) resolves on the 2000 SP4 kernel. The
#    GenAHCI/StorPort route of NT 5.2 does not exist on 2000 (no StorPort).
#    Integrated for text-mode AND GUI-mode Setup, as GenAHCI on NT 5.2:
#      - ahcint.sys in $WIN_NT$.~BT (loaded by SETUPLDR) and I386, and a
#        second copy in I386\AHCINT: text-mode Setup MOVES an uncompressed
#        local-source file, and GUI-mode PnP must find one (the NT 5.2
#        lesson: no INF -> NULL driver -> silent STOP 0x7B after Setup);
#      - ahcint.inf (package copy, [SourceDisksNames] and
#        [SourceDisksNames.x86] row 1 = \i386\ahcint) next to TXTSETUP.SIF;
#        TXTSETUP puts it in %windir%\inf (dirid 20);
#      - TXTSETUP.SIF (the three copies): [SourceDisksFiles] ahcint.sys and
#        ahcint.inf, [HardwareIdsDatabase] PCI\CC_010601 plus the AMD SATA
#        IDs AHCINT also claims in RAID class (1022:7901, 43C8, 43EB) ->
#        text mode writes the CriticalDeviceDatabase entries for the boot
#        controller; [SCSI.Load], [SCSI].
#      - usosw2k.inf (ASCII, written here) in ~BT and I386, added to
#        TXTSETUP.SIF [HiveInfs.Fresh] and [SourceDisksFiles] (text mode
#        refuses a hive INF without a row): the CriticalDeviceDatabase rows
#        (pci#cc_010601 and the three AMD IDs -> ahcint) in the new system.
#      - AHCINT mode (USOS_W2K_AHCINT_MODE): "legacy" (default) comments out
#        ahcint.inf's PnpInterface row, so AHCINT stays the legacy
#        (non-PnP) ScsiPort miniport it is in text mode and GUI-mode PnP
#        only records the INF; "pnp" also writes PnpInterface "5" = 1
#        through usosw2k.inf. QEMU 2026-09-30..10-03: the PnP variants ran
#        "Installing devices" into ERROR_NO_SYSTEM_RESOURCES and an ESENT
#        log flood or hung; legacy mode with the ACPI HAL completes Setup.
#        HIVESYS.INF itself is UTF-16 on 2000 and stays as is.
#      - DOSNET.INF lists ahcint.sys, ahcint.inf and usosw2k.inf.
# 2. ACPI: the 2000 ACPI.SYS (5.0.2195, ACPI 1.0b) may stop with 0xA5 on
#    modern tables (as the stock 5.1/5.2 drivers do on the X470), and no
#    ACPI 2.0 driver exists for NT 5.0. Default USOS_W2K_ACPI=on keeps
#    Microsoft's rule (ACPIEnable = 2, the ACPI HAL): in QEMU it is the only
#    setting that completes GUI Setup on AHCI (2026-10-03). USOS_W2K_ACPI=off
#    (legacy_xp_staging.sh sets it when DATA has
#    Systems\Windows\Windows 2000\Unattended\acpi-off.txt) writes
#    ACPIEnable = 0: SETUPLDR never selects an ACPI HAL and NTDETECT's MP
#    table (the firmware's, or CSMWrap's, built from MADT and _PRT) gives
#    the MPS HAL. In QEMU that GUI Setup failed in "Installing devices"
#    (ERROR_NO_SYSTEM_RESOURCES, ESENT log flood) with AHCINT and hung with
#    IDE, so it is the X470 fallback for a STOP 0xA5, not the default.
#    Costs: no ACPI power-off, power button or sleep.
# 3. usosrst.sys (USOS's own GPL driver, tools/w2k/usosrst; diagnostic
#    build): loaded from [BootBusExtenders.Load] in text mode and as a boot
#    driver (group Boot Bus Extender) afterwards. A bugcheck callback writes
#    the STOP code, its parameters and the modules they point into to the
#    VGA text buffer (the X470 without CSM shows only a black "_" for a
#    STOP); while Setup runs (SystemSetupInProgress = 1) a last-chance
#    shutdown handler restarts through the FADT reset register, CF9h and
#    the 8042 (the 2000 HALs know only the 8042, which those boards lack).
#    In text mode it also redirects setupdd.sys's HalReturnToFirmware
#    import (in memory) to the same reset, so the restart at the end of
#    text mode works without an 8042 as well.
#    USOS_W2K_USOSRST=off leaves it out.
# 4. Answer file (WINNT.SIF in $WIN_NT$.~BT, written by
#    prepare_xp_windows_partition.sh through usos_w2k_answer_sif after this
#    step; apply only checks the rows): text-mode Setup stops on its
#    "computer type" confirmation screen whenever a component is unknown,
#    even unattended. On boards without a PS/2 keyboard (USB only, no CSM)
#    NTDETECT reports no keyboard, so the X470 stopped there with
#    "Klawiatura: Nieznane" (2026-10-04). [KeyboardDrivers] names the
#    standard keyboard ("Retail", read only with OemPreinstall=Yes, which
#    is therefore set; from this source's own TXTSETUP.SIF
#    [Keyboard] STANDARD description, so localized media match), which
#    answers the screen; the USB keyboard itself works in GUI mode through
#    xhci98. With ACPI off, [Unattended] ComputerType pins the HAL the same
#    way (USOS_W2K_HAL: mps = "MPS Multiprocessor PC", halmps, the default
#    with ACPI off; standard = "Standard PC", hal.dll, PIC, one CPU; DATA's
#    Windows 2000\Unattended\hal-standard.txt selects it). With ACPI kept no
#    ComputerType is written (Setup's own ACPI choice).
# 5. User ACPI package (opt-in, an X470 bridge "do zastapienia wlasna
#    implementacja"): DATA's Systems\Windows\Windows 2000\Unattended\acpi\
#    (legacy_xp_staging.sh sets USOS_W2K_ACPI_PKG). Needs ACPI kept (with
#    acpi-off.txt it is refused). Every .sys/.dll in that folder or one
#    level below is used as the user provided it; nothing else (sources,
#    READMEs) is read:
#      - a name the source already has (acpi.sys, halacpi.dll, ... plain or
#        compressed) replaces that file in $WIN_NT$.~BT and ~LS\I386 (the
#        compressed copy is removed); no TXTSETUP change;
#      - a new .sys becomes an extra boot driver exactly like usosrst:
#        [SourceDisksFiles], [BootBusExtenders.Load] (after usosrst),
#        [BootBusExtenders], its own [files.<name>] section, DOSNET d1 rows
#        and a usosw2k.inf service (boot start, group Boot Bus Extender,
#        ErrorControl 0: a failed start never stops the boot). Name rules:
#        [a-z0-9_], at most 32 characters, not a USOS driver's name.
#      A new .dll, two files with one name, or a folder without any .sys or
#      .dll is refused before anything is written.
# 6. The clock (default with usosrst; X470 2026-10-04/05): the firmware leaves
#    the HPET in LegacyReplacement mode, so the pre-ACPI HALs got almost no
#    clock interrupts, and the MPS HAL reads the CMOS year without its
#    century (RtcDiag on the X470: HAL year 26), so GUI Setup ran with a
#    negative system time and hung at "Czekaj..." in every wait with a
#    deadline (rsabase, OleInitialize). usosrst 1.4 clears LegacyReplacement
#    (/USOSHPETLEGOFF, Parameters\HpetLegacyOff) and serves ntoskrnl's RTC
#    reads from its own decode, never writing the CMOS clock (/USOSRTCFIX,
#    Parameters\RtcFix). Both options go into the text-mode OsLoadOptions
#    and usosw2k.inf; USOS_W2K_HPET=keep / USOS_W2K_RTC=keep (DATA
#    hpet-keep.txt / rtc-keep.txt) leave them out. With both, GUI Setup got
#    past "Czekaj..." on the X470 (2026-10-05).
# 7. USB keyboard preinstall (USOS_W2K_USB, on when the source has SP4's
#    usbport): usosw2k.inf writes the services xhci98, usbhub20, HidUsb and
#    kbdhid (demand start, as their INFs) and CriticalDeviceDatabase rows for
#    PCI\CC_0C0330, USB\ROOT_HUB20, USB\HubClass, USB\Class_03 and
#    HID_DEVICE_SYSTEM_KEYBOARD, so the first GUI-mode boot already starts a
#    USB keyboard (no PS/2 on xHCI-only boards without CSM). The files come
#    from nt52_usb_stage.sh's forced copy. The mouse (mouhid/mouclass) is only
#    in DRIVER.CAB/SP4.CAB, so GUI-mode PnP installs it later. The answer
#    file also gets [GuiUnattended] OemSkipWelcome=1 (the Welcome page waits
#    for a click before "Installing devices") unless it already decides.
#    With ACPI off (MPS HAL) the xHCI functions get no interrupt resource, so
#    usosw2k.inf also writes Services\xhci98\Parameters PollMode = 1:
#    xhci98 1.1.1.0-usos3 then registers without an interrupt and collects
#    its events from a periodic timer.
# 8. Text boot video (ACPI HAL diagnostic, X470 2026-10-13): with ACPI on,
#    $WIN_NT$.~BT gets USOS's own BOOTVID.DLL (tools/w2k/usosvid, GPL; the
#    compressed BOOTVID.DL_ is removed) and the text-mode OsLoadOptions get
#    /SOS. Behind CSMWrap the Microsoft boot video's 640x480 mode never
#    shows, so a STOP before usosrst starts (acpi.sys, pci.sys, the HAL) was
#    only a black "_". usosvid keeps the text mode: row 11 = kernel phase 1
#    reached, rows 12-13 = HPET/RSDP/RSDT/FACP/DSDT/MADT facts as the kernel
#    sees them (QWord names left, checksums), row 14 = the STOP line, row 15
#    = the "***" driver line, rows 16-24 = the kernel's own text. Only ~BT:
#    ~LS (the installed system) keeps the Microsoft file. USOS_W2K_BOOTVID=ms
#    (DATA bootvid-ms.txt) leaves it out; with ACPI off it is never used.
# 9. NVMe target (TARGET_DEVICE /dev/nvme*, or USOS_W2K_NVME=on/off;
#    docs/nvme-nt-2026-10-11.md): USOS's own usosnvme (GPL, tools/nt/usosnvme)
#    next to AHCINT, integrated the same way and in the same legacy mode:
#    the NT4 build (non-PnP: it scans PCI for class 01-08-02 itself, claims
#    BAR0, polls; the 2KXP build waits for a PnP start, which 2000's text
#    mode never gives without PnpInterface in its own setup hive) in ~BT,
#    I386 and I386\USOSNVME (GUI-mode copy); usosnvme.inf (source path
#    \i386\usosnvme, PnpInterface row commented out) to %windir%\inf;
#    TXTSETUP.SIF [SourceDisksFiles], [HardwareIdsDatabase] PCI\CC_010802,
#    [SCSI.Load], [SCSI]; usosw2k.inf the CriticalDeviceDatabase row
#    pci#cc_010802 -> usosnvme; DOSNET.INF. Polled, so the MPS HAL path
#    (ACPI off, no PCI INTx) needs nothing more. AHCINT stays: it serves
#    the SATA disks and only ever writes to a disk with the USOS gap marker.
# 10. Diagnostic setup (USOS_W2K_DIAG=on, DATA ...\Unattended\w2k-diag.txt
#    or nmi-snapshot.txt; ACPI on only): usosvid 1.3-diag (built with
#    USOS_VID_DIAG: Codex's NMI snapshot, HPET/GPIO _STA signature rows) in
#    ~BT AND in ~LS (BOOTVID.DL_ removed, so the installed system boots with
#    it too), and [SetupData] OsLoadOptionsVar (the installed boot.ini
#    options) gets /SOS /BOOTLOG. Default (off): ~LS keeps the Microsoft
#    BOOTVID and boot.ini gets no extra options.
# 11. VESA display (USOS_W2K_VESA=on by default, DATA ...\Unattended\
#    vesa-off.txt -> off; docs/w2k-vesa-2026-10-17.md): USOS's own usosvbe.sys
#    (GPL video miniport, tools/nt4/usosvbe, the NT 4.0 build unchanged: its
#    imports all exist on 2000 SP4) with the CD's own framebuf.dll, which
#    text-mode Setup installs from [files.vga]; the CD's FRAMEBUF.DL_ goes
#    along as a second source. USOS never ships framebuf.dll. Nothing changes
#    for text-mode or GUI-mode Setup (both stay on VGA, so a VESA problem
#    cannot break the install): usos_w2k_vesa_stage puts USOSVBE.SYS,
#    FRAMEBUF.DL_, VESA.REG and vesa.cmd into C:\USOS\W2K and usos-setup.cmd
#    (UserExecute, setup end) calls vesa.cmd: driver copy, VESA.REG
#    (usosvbe at 1024x768x16), a "[VGA mode]" (/basevideo) entry in boot.ini
#    (timeout 5). The PnP vga service and VgaSave stay (full-screen consoles,
#    Safe Mode, /basevideo).
# No Microsoft file is added or changed except the TXTSETUP.SIF and
# DOSNET.INF copies on the target (and USOS's own WINNT.SIF); with a user
# ACPI package, the user's own files replace the ones they name.
#   sh w2k_stage.sh apply     (XP_TARGET_ROOT, NT5_SOURCE_DIR=I386)
usos_w2k_apply() (
    set -eu
    : "${XP_TARGET_ROOT:?}" "${NT5_SOURCE_DIR:?}"
    [ "$NT5_SOURCE_DIR" = I386 ] || { echo '[W2K_STAGE] STOP: Windows 2000 needs the I386 source'; exit 1; }
    pkg=${USOS_W2K_DIR:-/usr/lib/usos/w2k-drivers}
    # USOS_W2K_STORAGE: ahcint (default) or uniata (legacy_xp_staging.sh sets
    # it from DATA's Windows 2000\Unattended\storage-uniata.txt).
    drv=${USOS_W2K_STORAGE:-ahcint}
    case "$drv" in
        ahcint) need='ahcint.sys ahcint.inf' ;;
        uniata) need='uniata/uniata.sys'; pkg="$pkg" ;;
        *) echo '[W2K_STAGE] STOP: USOS_W2K_STORAGE must be ahcint or uniata'; exit 1 ;;
    esac
    helper=${USOS_W2K_USOSRST:-on}
    case "$helper" in on|off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_USOSRST must be on or off'; exit 1 ;; esac
    USOS_W2K_USOSRST=$helper; export USOS_W2K_USOSRST
    [ "$helper" = off ] || need="$need usosrst.sys"
    for name in $need; do
        [ -f "$pkg/$name" ] || { echo "[W2K_STAGE] STOP: $pkg/$name missing"; exit 1; }
    done
    [ "$drv" = ahcint ] && sys="$pkg/ahcint.sys" || sys="$pkg/uniata/uniata.sys"
    USOS_W2K_DRV=$drv; export USOS_W2K_DRV
    acpi=${USOS_W2K_ACPI:-on}
    mode=${USOS_W2K_AHCINT_MODE:-legacy}
    case "$mode" in legacy|pnp) ;; *) echo "[W2K_STAGE] STOP: USOS_W2K_AHCINT_MODE must be legacy or pnp"; exit 1 ;; esac
    case "$acpi" in on|off) ;; *) echo "[W2K_STAGE] STOP: USOS_W2K_ACPI must be on or off"; exit 1 ;; esac
    hal=$(usos_w2k_hal) || { echo "$hal"; exit 1; }
    # Text boot video (see 8.): default with ACPI on, never with ACPI off.
    if [ "$acpi" = on ]; then bootvid=${USOS_W2K_BOOTVID:-text}; else bootvid=ms; fi
    case "$bootvid" in text|ms) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_BOOTVID must be text or ms'; exit 1 ;; esac
    diag=${USOS_W2K_DIAG:-off}
    case "$diag" in on|off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_DIAG must be on or off'; exit 1 ;; esac
    vidsrc="$pkg/usosvid/bootvid.dll"
    if [ "$diag" = on ]; then
        [ "$acpi" = on ] || { echo '[W2K_STAGE] STOP: the diagnostic setup needs ACPI on'; exit 1; }
        bootvid=text; vidsrc="$pkg/usosvid-diag/bootvid.dll"
    fi
    [ "$bootvid" = ms ] || [ -f "$vidsrc" ] || { echo "[W2K_STAGE] STOP: $vidsrc missing"; exit 1; }
    USOS_W2K_BOOTVID=$bootvid; export USOS_W2K_BOOTVID
    # VESA display (see 11.): only checked here; staged with usos-setup.cmd.
    vesa=${USOS_W2K_VESA:-on}
    case "$vesa" in on|off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_VESA must be on or off'; exit 1 ;; esac
    [ "$vesa" = off ] || [ -f "$pkg/usosvbe/usosvbe.sys" ] || { echo "[W2K_STAGE] STOP: $pkg/usosvbe/usosvbe.sys missing"; exit 1; }
    # The clock (see 6.): USOS_W2K_HPET legacy-off (default with usosrst) or
    # keep; USOS_W2K_RTC fix (default with usosrst) or keep. Both need usosrst.
    if [ "$helper" = on ]; then hpet=${USOS_W2K_HPET:-legacy-off} rtc=${USOS_W2K_RTC:-fix}; else hpet=${USOS_W2K_HPET:-keep} rtc=${USOS_W2K_RTC:-keep}; fi
    case "$hpet" in keep|legacy-off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_HPET must be keep or legacy-off'; exit 1 ;; esac
    case "$rtc" in keep|fix) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_RTC must be keep or fix'; exit 1 ;; esac
    [ "$hpet" = keep ] || [ "$helper" = on ] || { echo '[W2K_STAGE] STOP: USOS_W2K_HPET=legacy-off needs usosrst'; exit 1; }
    [ "$rtc" = keep ] || [ "$helper" = on ] || { echo '[W2K_STAGE] STOP: USOS_W2K_RTC=fix needs usosrst'; exit 1; }
    USOS_W2K_HPET=$hpet USOS_W2K_RTC=$rtc; export USOS_W2K_HPET USOS_W2K_RTC
    bt="$XP_TARGET_ROOT/\$WIN_NT\$.~BT"
    ls="$XP_TARGET_ROOT/\$WIN_NT\$.~LS/I386"
    [ -f "$ls/TXTSETUP.SIF" ] || { echo "[W2K_STAGE] STOP: $ls/TXTSETUP.SIF missing"; exit 1; }
    # USB keyboard preinstall (see 7.): only with SP4's usbport on the source
    # (RTM has none, and nt52_usb_stage.sh then skips xhci98 too).
    if [ -n "$(find "$ls" -maxdepth 1 -type f \( -iname usbport.sys -o -iname usbport.sy_ \) 2>/dev/null)" ]; then usb=${USOS_W2K_USB:-on}; else usb=off; fi
    case "$usb" in on|off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_USB must be on or off'; exit 1 ;; esac
    USOS_W2K_USB=$usb; export USOS_W2K_USB
    # NVMe target (see 9.).
    case "${TARGET_DEVICE:-}" in /dev/nvme*) nvme=on ;; *) nvme=off ;; esac
    nvme=${USOS_W2K_NVME:-$nvme}
    case "$nvme" in on|off) ;; *) echo '[W2K_STAGE] STOP: USOS_W2K_NVME must be on or off'; exit 1 ;; esac
    if [ "$nvme" = on ]; then
        for name in usosnvme.sys usosnvme.inf; do
            [ -f "$pkg/usosnvme/$name" ] || { echo "[W2K_STAGE] STOP: the target is NVMe but $pkg/usosnvme/$name is missing"; exit 1; }
        done
    fi
    USOS_W2K_NVME=$nvme; export USOS_W2K_NVME
    # The user ACPI package (see 5.): resolved before anything is written.
    acpipkg=${USOS_W2K_ACPI_PKG:-}
    pkgplan=
    USOS_W2K_ACPI_EXTRA=
    if [ -n "$acpipkg" ]; then
        [ "$acpi" = on ] || { echo '[W2K_STAGE] STOP: the user ACPI package (Unattended\acpi) needs ACPI on; remove acpi-off.txt or the package'; exit 1; }
        pkgplan=$(usos_w2k_acpi_pkg_plan "$acpipkg" "$ls") || { echo "$pkgplan"; exit 1; }
        USOS_W2K_ACPI_EXTRA=$(printf '%s\n' "$pkgplan" | awk -F '\t' '$1 == "extra" { sub(/\.sys$/, "", $2); printf "%s%s", sep, $2; sep = " " }')
    fi
    export USOS_W2K_ACPI_EXTRA
    # The WINNT.SIF answers (see 4.; prepare_xp_windows_partition.sh writes
    # them): checked here, before anything is written.
    printf '[Unattended]\r\n' | usos_w2k_answer_sif "$ls/TXTSETUP.SIF" 2>&1 > /dev/null || exit 1
    for folder in "$bt" "$ls"; do
        [ -f "$folder/TXTSETUP.SIF" ] || { echo "[W2K_STAGE] STOP: $folder/TXTSETUP.SIF missing"; exit 1; }
        find "$folder" -maxdepth 1 -type f \( -iname "$drv.sys" -o -iname "$drv.sy_" -o -iname "$drv.inf" -o -iname "$drv.in_" -o -iname usosw2k.inf -o -iname usosrst.sys -o -iname usosrst.sy_ \) -exec rm -f '{}' \;
        cp "$sys" "$folder/$drv.sys"
        cmp -s "$sys" "$folder/$drv.sys"
        if [ "$helper" = on ]; then
            cp "$pkg/usosrst.sys" "$folder/usosrst.sys"
            cmp -s "$pkg/usosrst.sys" "$folder/usosrst.sys"
        fi
        # The user ACPI package: replaced and extra files, uncompressed.
        if [ -n "$pkgplan" ]; then
            printf '%s\n' "$pkgplan" | while IFS="$(printf '\t')" read -r kind name src; do
                stem=${name%?}
                find "$folder" -maxdepth 1 -type f \( -iname "$name" -o -iname "${stem}_" \) -exec rm -f '{}' \;
                cp "$src" "$folder/$name"
                cmp -s "$src" "$folder/$name" || exit 1
            done || { echo "[W2K_STAGE] STOP: cannot copy the user ACPI package into $folder"; exit 1; }
        fi
        if [ "$drv" = ahcint ]; then
            usos_w2k_ahcint_inf "$mode" < "$pkg/ahcint.inf" > "$folder/ahcint.inf" || { echo '[W2K_STAGE] STOP: cannot adapt ahcint.inf'; exit 1; }
        else
            usos_w2k_uniata_inf > "$folder/uniata.inf"
        fi
        usos_w2k_hive_inf "$mode" > "$folder/usosw2k.inf"
        find "$folder" -maxdepth 1 -type f \( -iname usosnvme.sys -o -iname usosnvme.sy_ -o -iname usosnvme.inf -o -iname usosnvme.in_ \) -exec rm -f '{}' \;
        if [ "$nvme" = on ]; then
            cp "$pkg/usosnvme/usosnvme.sys" "$folder/usosnvme.sys"
            cmp -s "$pkg/usosnvme/usosnvme.sys" "$folder/usosnvme.sys"
            usos_w2k_nvme_inf < "$pkg/usosnvme/usosnvme.inf" > "$folder/usosnvme.inf" || { echo '[W2K_STAGE] STOP: cannot adapt usosnvme.inf'; exit 1; }
        fi
    done
    find "$ls" -maxdepth 1 -type d -iname usosnvme -exec rm -rf '{}' +
    if [ "$nvme" = on ]; then
        mkdir "$ls/USOSNVME"
        cp "$pkg/usosnvme/usosnvme.sys" "$ls/USOSNVME/usosnvme.sys"
        cmp -s "$pkg/usosnvme/usosnvme.sys" "$ls/USOSNVME/usosnvme.sys"
    fi
    upper=$(printf '%s' "$drv" | tr '[:lower:]' '[:upper:]')
    find "$ls" -maxdepth 1 -type d -iname "$drv" -exec rm -rf '{}' +
    mkdir "$ls/$upper"
    cp "$sys" "$ls/$upper/$drv.sys"
    cmp -s "$sys" "$ls/$upper/$drv.sys"
    for sif in "$bt/TXTSETUP.SIF" "$ls/TXTSETUP.SIF" "$XP_TARGET_ROOT/TXTSETUP.SIF"; do
        [ -f "$sif" ] || continue
        usos_w2k_storage_sif < "$sif" > "$sif.usos" || { rm -f "$sif.usos"; echo "[W2K_STAGE] STOP: cannot patch $sif"; exit 1; }
        if [ "$nvme" = on ]; then
            usos_w2k_nvme_sif < "$sif.usos" > "$sif.nvme" || { rm -f "$sif.usos" "$sif.nvme"; echo "[W2K_STAGE] STOP: cannot add usosnvme to $sif"; exit 1; }
            mv "$sif.nvme" "$sif.usos"
        fi
        if [ "$acpi" = off ]; then
            usos_w2k_acpi_off_sif < "$sif.usos" > "$sif.acpi" || { rm -f "$sif.usos" "$sif.acpi"; echo "[W2K_STAGE] STOP: no [ACPIOptions] ACPIEnable row in $sif"; exit 1; }
            mv "$sif.acpi" "$sif.usos"
        fi
        loadopts=$(usos_w2k_load_options)
        if [ -n "$loadopts" ]; then
            usos_w2k_hpet_sif "$loadopts" < "$sif.usos" > "$sif.hpet" || { rm -f "$sif.usos" "$sif.hpet"; echo "[W2K_STAGE] STOP: no [SetupData] OsLoadOptions row in $sif"; exit 1; }
            mv "$sif.hpet" "$sif.usos"
        fi
        if [ "$diag" = on ]; then
            usos_w2k_diag_sif < "$sif.usos" > "$sif.diag" || { rm -f "$sif.usos" "$sif.diag"; echo "[W2K_STAGE] STOP: no [SetupData] section in $sif"; exit 1; }
            mv "$sif.diag" "$sif.usos"
        fi
        mv "$sif.usos" "$sif"
    done
    if [ "$bootvid" = text ]; then
        find "$bt" -maxdepth 1 -type f \( -iname bootvid.dll -o -iname bootvid.dl_ \) -exec rm -f '{}' \;
        cp "$vidsrc" "$bt/BOOTVID.DLL"
        cmp -s "$vidsrc" "$bt/BOOTVID.DLL" || { echo '[W2K_STAGE] STOP: cannot copy the text boot video into ~BT'; exit 1; }
    fi
    if [ "$diag" = on ]; then
        find "$ls" -maxdepth 1 -type f \( -iname bootvid.dll -o -iname bootvid.dl_ \) -exec rm -f '{}' \;
        cp "$vidsrc" "$ls/BOOTVID.DLL"
        cmp -s "$vidsrc" "$ls/BOOTVID.DLL" || { echo '[W2K_STAGE] STOP: cannot copy the diagnostic boot video into ~LS'; exit 1; }
    fi
    if [ -f "$ls/DOSNET.INF" ]; then
        usos_w2k_dosnet < "$ls/DOSNET.INF" > "$ls/DOSNET.INF.usos" || { rm -f "$ls/DOSNET.INF.usos"; echo '[W2K_STAGE] STOP: cannot patch DOSNET.INF'; exit 1; }
        mv "$ls/DOSNET.INF.usos" "$ls/DOSNET.INF"
    fi
    sync
    printf '[W2K_STAGE] APPLIED PASS %s boot+local source, TXTSETUP.SIF PCI\\CC_010601, usosw2k.inf (CriticalDeviceDatabase), %s mode; ACPI %s; HAL %s; WINNT.SIF answers: standard keyboard; usosrst %s\n' \
        "$(usos_w2k_driver_title)" "$mode" "$([ "$acpi" = off ] && echo 'off (ACPIEnable = 0)' || echo 'kept (ACPIEnable unchanged)')" \
        "$(case "$hal" in mps) echo 'MPS Multiprocessor (ComputerType)' ;; standard) echo 'Standard PC (ComputerType)' ;; *) echo 'chosen by Setup' ;; esac)" \
        "$([ "$helper" = on ] && echo 'on (STOP screen, Setup and text-mode restart via FADT/CF9/8042)' || echo off)$([ "$hpet" = legacy-off ] && echo '; HPET LegacyReplacement off')$([ "$rtc" = fix ] && echo '; RTC fix')$([ "$bootvid" = text ] && echo '; text boot video usosvid + /SOS (~BT)')$([ "$diag" = on ] && echo '; DIAGNOSTIC: usosvid 1.3-diag in ~BT and ~LS, boot.ini /SOS /BOOTLOG')$([ "$usb" = on ] && echo '; USB keyboard preinstall (CriticalDeviceDatabase)')$([ "$nvme" = on ] && echo '; NVMe target: usosnvme 1.0 (legacy mode, PCI\CC_010802)')$([ "$vesa" = on ] && echo '; VESA usosvbe at setup end (vesa.cmd)')$([ -n "$pkgplan" ] && printf '; user ACPI package: %s' "$(printf '%s\n' "$pkgplan" | awk -F '\t' '{ printf "%s%s %s", sep, ($1 == "extra" ? "boot driver" : "replaces"), $2; sep = ", " }')")"
)

# stdout: the plan for the user ACPI package folder $1 (see 5.) against the
# local source $2 (~LS\I386), one line per file: kind<TAB>name<TAB>path, kind
# "replace" (the source has that name, plain or compressed) or "extra" (a
# new boot driver); names in lower case. A message on stdout and status 1
# for a refused package (nothing usable, a new .dll, a bad or duplicate
# name, a USOS driver's name).
usos_w2k_acpi_pkg_plan() {
    [ -d "$1" ] || { echo "[W2K_STAGE] STOP: user ACPI package $1 is not a folder"; return 1; }
    found=$(find "$1" -maxdepth 2 -type f \( -iname '*.sys' -o -iname '*.dll' \) | LC_ALL=C sort)
    [ -n "$found" ] || { echo '[W2K_STAGE] STOP: the user ACPI package (Unattended\acpi) has no .sys or .dll file (sources are not built on the target)'; return 1; }
    printf '%s\n' "$found" | {
        seen=' '
        out=
        tab=$(printf '\t')
        while IFS= read -r path; do
            name=$(basename "$path" | tr '[:upper:]' '[:lower:]')
            case "$seen" in *" $name "*) echo "[W2K_STAGE] STOP: user ACPI package has $name twice"; exit 1 ;; esac
            seen="$seen$name "
            stem=${name%?}
            if [ -n "$(find "$2" -maxdepth 1 -type f \( -iname "$name" -o -iname "${stem}_" \) 2>/dev/null)" ]; then
                kind=replace
            else
                case "$name" in
                    *.dll) echo "[W2K_STAGE] STOP: user ACPI package: $name is not a file of this source (only a new .sys can be added)"; exit 1 ;;
                esac
                base=${name%.sys}
                case "$base" in
                    ahcint|uniata|usosrst|usosw2k|xhci98) echo "[W2K_STAGE] STOP: user ACPI package: $name is a USOS driver name"; exit 1 ;;
                esac
                if [ "${#base}" -gt 32 ] || [ -z "$base" ] || [ -n "$(printf '%s' "$base" | tr -d 'a-z0-9_')" ]; then
                    echo "[W2K_STAGE] STOP: user ACPI package: $name is not a valid service name ([a-z0-9_], at most 32)"; exit 1
                fi
                kind=extra
            fi
            out="$out$kind$tab$name$tab$path
"
        done
        printf '%s' "$out"
    }
}

# Every output line ends in CRLF, as the NT5 setup files do (BusyBox awk
# keeps the input CR, other awks drop it; both give the same bytes here).

# The PCI IDs that get a [HardwareIdsDatabase] row (the class code first).
USOS_W2K_AHCI_IDS='CC_010601 VEN_1022&DEV_7901 VEN_1022&DEV_43C8 VEN_1022&DEV_43EB'

# The text-mode title of the selected driver (USOS_W2K_DRV, default ahcint).
usos_w2k_driver_title() {
    case "${USOS_W2K_DRV:-ahcint}" in
        uniata) echo 'UniATA 0.47b' ;;
        *) echo 'AHCINT 1.3.0.0-usos4 diagnostic' ;;
    esac
}

# stdin TXTSETUP.SIF -> stdout with the AHCINT rows (first block of each
# section; the same rows twice are refused) and, unless USOS_W2K_USOSRST=off,
# usosrst.sys: [SourceDisksFiles] (System32\drivers), [BootBusExtenders.Load]
# (SETUPLDR loads it from ~BT, the kernel starts it before the storage
# drivers), [BootBusExtenders] and its own [files.usosrst] section.
usos_w2k_storage_sif() {
    awk -v ids="$USOS_W2K_AHCI_IDS" -v drv="${USOS_W2K_DRV:-ahcint}" -v title="$(usos_w2k_driver_title)" -v helper="${USOS_W2K_USOSRST:-on}" -v extra="${USOS_W2K_ACPI_EXTRA:-}" '
        BEGIN { bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " "); ne = split(extra, ex, " ") }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, drv) == 1 || low ~ "^[ \t]+" drv || index(low, "pci" bs "cc_010601") || index(low, "usosw2k.inf") || index(low, "usosrst") { dup = 1 }
        { for (i = 1; i <= ne; i++) if (index(low, ex[i] ".sys") || index(low, ex[i] " ") == 1 || index(low, "[files." ex[i] "]")) dup = 1 }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f {
            print drv ".sys = 1,,,,,,4_,4,1,,,1,4\r"; print drv ".inf = 1,,,,,,,20,0,0\r"; print "usosw2k.inf = 1,,,,,,_x,20,3,3\r"
            if (helper == "on") print "usosrst.sys = 1,,,,,,4_,4,1,,,1,4\r"
            for (i = 1; i <= ne; i++) print ex[i] ".sys = 1,,,,,,4_,4,1,,,1,4\r"
            f = 1
        }
        low == "[hardwareidsdatabase]" && !h { for (i = 1; i <= n; i++) print "PCI" bs id[i] " = " q drv q "\r"; h = 1 }
        low == "[scsi.load]" && !l { print drv " = " drv ".sys,4\r"; l = 1 }
        low == "[scsi]" && !s { print drv " = " q "AHCI SATA Controller (" title ", USOS)" q "\r"; s = 1 }
        low == "[hiveinfs.fresh]" && !r { print "AddReg = usosw2k.inf,AddReg\r"; r = 1 }
        low == "[bootbusextenders.load]" && !bl {
            if (helper == "on") print "usosrst  = usosrst.sys\r"
            for (i = 1; i <= ne; i++) print ex[i] " = " ex[i] ".sys\r"
            bl = 1
        }
        low == "[bootbusextenders]" && !bb {
            if (helper == "on") print "usosrst  = " q "USOS STOP screen and restart helper" q ",files.usosrst,usosrst\r"
            for (i = 1; i <= ne; i++) print ex[i] " = " q "User ACPI package driver " ex[i] ".sys (DATA, USOS)" q ",files." ex[i] "," ex[i] "\r"
            bb = 1
        }
        END {
            if (dup || !(f && h && l && s && r)) exit 3
            if ((helper == "on" || ne) && !(bl && bb)) exit 3
            if (helper == "on") { print "\r"; print "[files.usosrst]\r"; print "usosrst.sys,4\r" }
            for (i = 1; i <= ne; i++) { print "\r"; print "[files." ex[i] "]\r"; print ex[i] ".sys,4\r" }
        }
    '
}

# stdout: usosw2k.inf, the text-mode registry rows (see the header):
# PnpInterface for AHCINT and the CriticalDeviceDatabase entries of
# USOS_W2K_AHCI_IDS. Loaded through TXTSETUP.SIF [HiveInfs.Fresh].
usos_w2k_hive_inf() {
    awk -v ids="$USOS_W2K_AHCI_IDS" -v mode="${1:-legacy}" -v drv="${USOS_W2K_DRV:-ahcint}" -v helper="${USOS_W2K_USOSRST:-on}" -v acpi="${USOS_W2K_ACPI:-on}" -v hpet="${USOS_W2K_HPET:-keep}" -v rtc="${USOS_W2K_RTC:-keep}" -v usb="${USOS_W2K_USB:-off}" -v extra="${USOS_W2K_ACPI_EXTRA:-}" -v nvme="${USOS_W2K_NVME:-off}" '
        BEGIN {
            bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " ")
            base = "HKLM," q "SYSTEM" bs "CurrentControlSet" bs
            cddb = base "Control" bs "CriticalDeviceDatabase" bs "pci#"
            print "; USOS: Windows 2000 " toupper(drv) " registry rows (tools/w2k_stage.sh)\r"
            print "[Version]\r"; print "Signature = " q "$Windows NT$" q "\r"; print "\r"; print "[AddReg]\r"
            # UniATA drives PCI IDE controllers too (its own uniata_w2k.reg):
            # SkipRaids as shipped, and pciide/atapi off so the two never
            # claim the same channel (modern boards have no IDE mode anyway).
            if (drv == "uniata") {
                print base "Services" bs "uniata" bs "Parameters" q "," q "SkipRaids" q ",0x00010001,1\r"
                print base "Services" bs "PciIde" q "," q "Start" q ",0x00010001,4\r"
                print base "Services" bs "atapi" q "," q "Start" q ",0x00010001,4\r"
            }
            if (mode == "pnp") print base "Services" bs drv bs "Parameters" bs "PnpInterface" q "," q "5" q ",0x00010001,1\r"
            # ACPI off: in QEMU every ACPI-off GUI Setup failed its registry
            # writes with 1450 (ERROR_NO_SYSTEM_RESOURCES) while the hives were
            # small (SYSTEM 421 KB): the largest paged pool (FFFFFFFF = as large
            # as the system allows) and a 128 MB registry quota (clamped by the
            # kernel to what paged pool permits), both documented values. With
            # them the same run had no 1450 and passed device install and the
            # security setup (2026-10-04). (isapnp Start = 4 was tried too: text
            # mode overwrites it, and text mode needs isapnp for the keyboard.)
            if (acpi == "off") {
                print base "Control" q "," q "RegistrySizeLimit" q ",0x00010001,0x08000000\r"
                print base "Control" bs "Session Manager" bs "Memory Management" q "," q "PagedPoolSize" q ",0x00010001,0xFFFFFFFF\r"
            }
            # usosrst: a boot driver of the first group, ErrorControl 0 (a
            # failed start never stops the boot).
            if (helper == "on") {
                svc = base "Services" bs "usosrst" q ","
                print svc q "Type" q ",0x00010001,1\r"
                print svc q "Start" q ",0x00010001,0\r"
                print svc q "ErrorControl" q ",0x00010001,0\r"
                print svc q "Group" q ",0x00000000," q "Boot Bus Extender" q "\r"
                print svc q "ImagePath" q ",0x00020000," q "System32" bs "DRIVERS" bs "usosrst.sys" q "\r"
                # The clock (see 6.): the same on every later boot.
                if (hpet == "legacy-off") print base "Services" bs "usosrst" bs "Parameters" q "," q "HpetLegacyOff" q ",0x00010001,1\r"
                if (rtc == "fix") print base "Services" bs "usosrst" bs "Parameters" q "," q "RtcFix" q ",0x00010001,1\r"
            }
            # USB keyboard preinstall (see 7.): the services and their
            # CriticalDeviceDatabase rows, as the INFs (xhci98, usb, input,
            # keyboard) would write them.
            if (usb == "on") {
                ns = split("xhci98:Base:1:xhci98.sys usbhub20:Base:1:usbhub20.sys HidUsb:extended_base:0:hidusb.sys kbdhid:Keyboard_Port:0:kbdhid.sys", sv, " ")
                for (i = 1; i <= ns; i++) {
                    split(sv[i], fl, ":"); gsub(/_/, " ", fl[2])
                    svc = base "Services" bs fl[1] q ","
                    print svc q "Type" q ",0x00010001,1\r"
                    print svc q "Start" q ",0x00010001,3\r"
                    print svc q "ErrorControl" q ",0x00010001," fl[3] "\r"
                    print svc q "Group" q ",0x00000000," q fl[2] q "\r"
                    print svc q "ImagePath" q ",0x00020000," q "System32" bs "DRIVERS" bs fl[4] q "\r"
                }
                # MPS HAL (ACPI off): PCI.SYS gives the xHCI functions no
                # interrupt (the CSMWrap MP table has no PCI INTx entries; X470
                # 2026-10-05, Code 10), so xhci98 1.1.1.0-usos3 polls.
                if (acpi == "off") print base "Services" bs "xhci98" bs "Parameters" q "," q "PollMode" q ",0x00010001,1\r"
                usbc = "{36FC9E60-C465-11CF-8056-444553540000}"
                nc = split("pci#cc_0c0330:xhci98:" usbc " usb#root_hub20:usbhub20:" usbc " usb#hubclass:usbhub20:" usbc " usb#class_03:HidUsb:{745a17a0-74d3-11d0-b6fe-00a0c90f57da} hid_device_system_keyboard:kbdhid:{4D36E96B-E325-11CE-BFC1-08002BE10318}", cv, " ")
                for (i = 1; i <= nc; i++) {
                    split(cv[i], fl, ":")
                    key = base "Control" bs "CriticalDeviceDatabase" bs fl[1] q ","
                    print key q "Service" q ",0x00000000," q fl[2] q "\r"
                    print key q "ClassGUID" q ",0x00000000," q fl[3] q "\r"
                }
            }
            # The extra drivers of the user ACPI package (see 5.): the same boot service rows.
            ne = split(extra, ex, " ")
            for (i = 1; i <= ne; i++) {
                svc = base "Services" bs ex[i] q ","
                print svc q "Type" q ",0x00010001,1\r"
                print svc q "Start" q ",0x00010001,0\r"
                print svc q "ErrorControl" q ",0x00010001,0\r"
                print svc q "Group" q ",0x00000000," q "Boot Bus Extender" q "\r"
                print svc q "ImagePath" q ",0x00020000," q "System32" bs "DRIVERS" bs ex[i] ".sys" q "\r"
            }
            for (i = 1; i <= n; i++) {
                key = tolower(id[i])
                print cddb key q "," q "Service" q ",0x00000000," q drv q "\r"
                print cddb key q "," q "ClassGUID" q ",0x00000000," q "{4D36E97B-E325-11CE-BFC1-08002BE10318}" q "\r"
            }
            # NVMe target (see 9.): the NVMe class code -> usosnvme.
            if (nvme == "on") {
                print cddb "cc_010802" q "," q "Service" q ",0x00000000," q "usosnvme" q "\r"
                print cddb "cc_010802" q "," q "ClassGUID" q ",0x00000000," q "{4D36E97B-E325-11CE-BFC1-08002BE10318}" q "\r"
            }
        }
    '
}

# stdin TXTSETUP.SIF -> stdout with [ACPIOptions] ACPIEnable = 0. Exit 3
# unless exactly one ACPIEnable row was found in that section. (isapnp stays
# a text-mode boot bus extender: without ACPI it enumerates the legacy
# devices, and text mode stops with "no keyboard" without it; QEMU
# 2026-10-04.)
# stdout: the usosrst load options for text mode (see 6.), from
# USOS_W2K_HPET and USOS_W2K_RTC; empty when neither is wanted.
usos_w2k_load_options() {
    o=
    [ "${USOS_W2K_HPET:-keep}" = legacy-off ] && o="/USOSHPETLEGOFF"
    [ "${USOS_W2K_RTC:-keep}" = fix ] && o="${o:+$o }/USOSRTCFIX"
    [ "${USOS_W2K_BOOTVID:-ms}" = text ] && o="${o:+$o }/SOS"
    printf '%s' "$o"
}

# stdin TXTSETUP.SIF -> stdout with /SOS /BOOTLOG added (each once) to
# [SetupData] OsLoadOptionsVar, the options text-mode Setup writes into the
# installed boot.ini (see 10.); without that row one is added after the
# section header with /fastdetect /SOS /BOOTLOG. Status 3 without [SetupData].
usos_w2k_diag_sif() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ {
            if (section == "[setupdata]" && !done) { print "OsLoadOptionsVar = \"/fastdetect /SOS /BOOTLOG\"\r"; done++ }
            section = low; sub(/[ \t]+$/, "", section)
            if (section == "[setupdata]") seen++
            print line "\r"; next
        }
        section == "[setupdata]" && low ~ /^[ \t]*osloadoptionsvar[ \t]*=/ {
            n = split("/SOS /BOOTLOG", opt, " ")
            for (i = 1; i <= n; i++) {
                if (index(low, tolower(opt[i]))) continue
                if (line ~ /"[ \t]*$/) sub(/"[ \t]*$/, " " opt[i] "\"", line); else line = line " " opt[i]
                low = tolower(line)
            }
            done++
        }
        { print line "\r" }
        END {
            if (section == "[setupdata]" && !done) { print "OsLoadOptionsVar = \"/fastdetect /SOS /BOOTLOG\"\r"; done++ }
            if (!seen) exit 3
        }
    '
}

# stdin TXTSETUP.SIF -> stdout with the options $1 (default /USOSHPETLEGOFF;
# each one only once) appended to [SetupData] OsLoadOptions (the text-mode
# load options; usosrst reads them from SystemStartOptions). Status 3 when
# there is no single OsLoadOptions row.
usos_w2k_hpet_sif() {
    awk -v opts="${1:-/USOSHPETLEGOFF}" '
        BEGIN { no = split(opts, opt, " ") }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        section == "[setupdata]" && low ~ /^[ \t]*osloadoptions[ \t]*=/ {
            for (i = 1; i <= no; i++) {
                if (index(low, tolower(opt[i]))) continue
                if (line ~ /"[ \t]*$/) sub(/"[ \t]*$/, " " opt[i] "\"", line); else line = line " " opt[i]
                low = tolower(line)
            }
            done++
        }
        { print line "\r" }
        END { if (done != 1) exit 3 }
    '
}

usos_w2k_acpi_off_sif() {
    awk '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        section == "[acpioptions]" && low ~ /^[ \t]*acpienable[ \t]*=/ { line = "ACPIEnable = 0"; done++ }
        { print line "\r" }
        END { if (done != 1) exit 3 }
    '
}

# stdout: the HAL the answer file pins (none, mps or standard) from
# USOS_W2K_ACPI (default on) and USOS_W2K_HAL (auto: mps with ACPI off, none
# with ACPI kept). A message on stdout and status 1 for a bad value.
usos_w2k_hal() {
    case "${USOS_W2K_HAL:-auto}:${USOS_W2K_ACPI:-on}" in
        auto:off|mps:off) echo mps ;;
        standard:off) echo standard ;;
        auto:on) echo none ;;
        mps:on|standard:on) echo '[W2K_STAGE] STOP: USOS_W2K_HAL needs ACPI off (acpi-off.txt)'; return 1 ;;
        *) echo '[W2K_STAGE] STOP: USOS_W2K_HAL must be auto, mps or standard'; return 1 ;;
    esac
}

# stdin WINNT.SIF -> stdout with the hardware answers of section 4, the
# descriptions taken from TXTSETUP.SIF $1 (the source's own, localized).
# Messages on stderr; status 1 if a row is missing or a value is bad.
usos_w2k_answer_sif() {
    hal=$(usos_w2k_hal) || { echo "$hal" >&2; return 1; }
    kbd=$(usos_w2k_sif_desc keyboard STANDARD < "$1") || { echo '[W2K_STAGE] STOP: no [Keyboard] STANDARD row in TXTSETUP.SIF' >&2; return 1; }
    computer=
    case "$hal" in
        mps) computer=$(usos_w2k_sif_desc computer mps_mp < "$1") || { echo '[W2K_STAGE] STOP: no [Computer] mps_mp row in TXTSETUP.SIF' >&2; return 1; } ;;
        standard) computer=$(usos_w2k_sif_desc computer e_isa_up < "$1") || { echo '[W2K_STAGE] STOP: no [Computer] e_isa_up row in TXTSETUP.SIF' >&2; return 1; } ;;
    esac
    usos_w2k_hw_sif "$computer" "$kbd" || { echo '[W2K_STAGE] STOP: no [Unattended] section in WINNT.SIF' >&2; return 1; }
}

# stdin TXTSETUP.SIF -> stdout: the quoted description (without the quotes,
# bytes as in the file: localized media are ANSI) of row $2 in section [$1]
# (both case-insensitive), e.g. "computer mps_mp" or "keyboard STANDARD".
# The first such row counts. Exit 3 if there is none.
usos_w2k_sif_desc() {
    LC_ALL=C awk -v want="[$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')]" -v key="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" '
        BEGIN { q = sprintf("%c", 34) }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/^[ \t]+/, "", section); sub(/[ \t]+$/, "", section); next }
        section != want || found { next }
        {
            eq = index(line, "="); if (!eq) next
            name = tolower(substr(line, 1, eq - 1)); gsub(/[ \t]/, "", name)
            if (name != key) next
            rest = substr(line, eq + 1); a = index(rest, q); if (!a) next
            rest = substr(rest, a + 1); b = index(rest, q); if (b < 2) next
            printf "%s", substr(rest, 1, b - 1); found = 1
        }
        END { if (!found) exit 3 }
    '
}

# stdin WINNT.SIF -> stdout (CRLF): [Unattended] OemPreinstall=Yes and
# ComputerType = "$1","Retail" (no ComputerType row when $1 is empty;
# existing rows are replaced) and a [KeyboardDrivers] section with
# "$2" = "Retail" (an existing section is replaced). Text-mode Setup reads
# the component sections and ComputerType only in preinstall mode
# (setupdd.sys checks its OemPreinstall flag first; QEMU 2026-10-04: with
# OemPreinstall=No the "Klawiatura: Nieznane" screen stayed). "Retail"
# entries need no $OEM$ files. Exit 3 without an [Unattended] section.
usos_w2k_hw_sif() {
    LC_ALL=C awk -v computer="$1" -v keyboard="$2" '
        BEGIN { q = sprintf("%c", 34) }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/^[ \t]+/, "", section); sub(/[ \t]+$/, "", section) }
        section == "[keyboarddrivers]" { next }
        section == "[unattended]" && low ~ /^[ \t]*(computertype|oempreinstall)[ \t]*=/ { next }
        section == "[guiunattended]" && low ~ /^[ \t]*oemskipwelcome[ \t]*=/ { welcome = 1 }
        { print line "\r" }
        section == "[unattended]" && low ~ /^[ \t]*\[/ && !u {
            u = 1
            print "OemPreinstall=Yes\r"
            if (computer != "") print "ComputerType = " q computer q "," q "Retail" q "\r"
        }
        END {
            if (!u) exit 3
            # The Welcome page comes before "Installing devices" and waits for
            # a click; skipped unless the answer file already decides.
            if (!welcome) { print "[GuiUnattended]\r"; print "OemSkipWelcome=1\r" }
            print "[KeyboardDrivers]\r"
            print q keyboard q " = " q "Retail" q "\r"
        }
    '
}

# stdin ahcint.inf -> stdout with [SourceDisksNames] and
# [SourceDisksNames.x86] row 1 given the path \i386\ahcint (the folder of
# the local source that holds the GUI-mode copy). Exit 3 unless both rows
# changed.
usos_w2k_ahcint_inf() {
    awk -v mode="${1:-legacy}" '
        BEGIN { bs = sprintf("%c", 92); dir = bs "i386" bs "ahcint" }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        # legacy mode: the PnpInterface row is commented out (see the header).
        mode == "legacy" && index(low, "pnpinterface") && low !~ /^[ \t]*;/ { line = "; USOS legacy mode: " line; pnp++ }
        (section == "[sourcedisksnames]" || section == "[sourcedisksnames.x86]") && line ~ /^[ \t]*1[ \t]*=/ {
            m = split(line, v, ",")
            if (m != 4) { bad = 1 } else { line = v[1] ",," v[3] "," dir; done[section] = 1 }
        }
        { print line "\r" }
        END { if (bad || !done["[sourcedisksnames]"] || !done["[sourcedisksnames.x86]"] || (mode == "legacy" && pnp != 1)) exit 3 }
    '
}

# stdin DOSNET.INF -> stdout with d1,ahcint.sys, d1,ahcint.inf, d1,usosw2k.inf
# (and d1,usosrst.sys unless USOS_W2K_USOSRST=off) in the first [Files] and
# [FloppyFiles.1] blocks.
usos_w2k_dosnet() {
    awk -v drv="${USOS_W2K_DRV:-ahcint}" -v helper="${USOS_W2K_USOSRST:-on}" -v extra="${USOS_W2K_ACPI_EXTRA:-}" -v nvme="${USOS_W2K_NVME:-off}" '
        BEGIN { ne = split(extra, ex, " ") }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, drv) || index(low, "usosw2k") || index(low, "usosrst") || index(low, "usosnvme") { dup = 1 }
        { for (i = 1; i <= ne; i++) if (index(low, "d1," ex[i] ".sys")) dup = 1 }
        { print line "\r" }
        low == "[files]" && !f { rowsfor(); f = 1 }
        low == "[floppyfiles.1]" && !b { rowsfor(); b = 1 }
        function rowsfor() { print "d1," drv ".sys\r"; print "d1," drv ".inf\r"; print "d1,usosw2k.inf\r"; if (helper == "on") print "d1,usosrst.sys\r"; for (i = 1; i <= ne; i++) print "d1," ex[i] ".sys\r"; if (nvme == "on") { print "d1,usosnvme.sys\r"; print "d1,usosnvme.inf\r" } }
        END { if (dup || !(f && b)) exit 3 }
    '
}

# stdin TXTSETUP.SIF (after usos_w2k_storage_sif) -> stdout with the usosnvme
# rows (see 9.): [SourceDisksFiles] usosnvme.sys / usosnvme.inf,
# [HardwareIdsDatabase] PCI\CC_010802, [SCSI.Load], [SCSI]; the first block of
# each section. Exit 3 if a section is missing or usosnvme is already there.
usos_w2k_nvme_sif() {
    awk '
        BEGIN { bs = sprintf("%c", 92); q = sprintf("%c", 34) }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        index(low, "usosnvme") || index(low, "pci" bs "cc_010802") { dup = 1 }
        { print line "\r" }
        low == "[sourcedisksfiles]" && !f { print "usosnvme.sys = 1,,,,,,4_,4,1,,,1,4\r"; print "usosnvme.inf = 1,,,,,,,20,0,0\r"; f = 1 }
        low == "[hardwareidsdatabase]" && !h { print "PCI" bs "CC_010802 = " q "usosnvme" q "\r"; h = 1 }
        low == "[scsi.load]" && !l { print "usosnvme = usosnvme.sys,4\r"; l = 1 }
        low == "[scsi]" && !s { print "usosnvme = " q "NVM Express Controller (usosnvme 1.0, USOS)" q "\r"; s = 1 }
        END { if (dup || !(f && h && l && s)) exit 3 }
    '
}

# stdin usosnvme.inf -> stdout (CRLF): [SourceDisksNames] row 1 with the path
# \i386\usosnvme (the GUI-mode copy) and the PnpInterface row commented out
# (legacy mode, see 9.). Exit 3 unless both changed exactly once.
usos_w2k_nvme_inf() {
    awk '
        BEGIN { bs = sprintf("%c", 92); dir = bs "i386" bs "usosnvme" }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*\[/ { section = low; sub(/[ \t]+$/, "", section) }
        index(low, "pnpinterface") && low !~ /^[ \t]*;/ { line = "; USOS legacy mode (Windows 2000): " line; pnp++ }
        section == "[sourcedisksnames]" && line ~ /^[ \t]*1[ \t]*=/ {
            m = split(line, v, ",")
            if (m != 4) bad = 1; else { line = v[1] ",," v[3] "," dir; sdn++ }
        }
        { print line "\r" }
        END { if (bad || pnp != 1 || sdn != 1) exit 3 }
    '
}

# stdout: uniata.inf, written by USOS for UniATA 0.47b (the package's own
# uata_2k.inf targets IDE controllers of 2006 and lists no AHCI class code).
# A legacy ScsiPort miniport like AHCINT in legacy mode: PCI\CC_010601 and
# the AMD SATA IDs, service uniata, boot start, GUI-mode copy in
# \i386\uniata. No PnpInterface row.
usos_w2k_uniata_inf() {
    awk -v ids="$USOS_W2K_AHCI_IDS" '
        BEGIN {
            bs = sprintf("%c", 92); q = sprintf("%c", 34); n = split(ids, id, " ")
            print "; uniata.inf - UniATA 0.47b for Windows 2000, written by USOS (tools/w2k_stage.sh)\r"
            print "[Version]\r"; print "Signature=" q "$Windows NT$" q "\r"; print "Class=SCSIAdapter\r"
            print "ClassGUID={4D36E97B-E325-11CE-BFC1-08002BE10318}\r"; print "Provider=%Provider%\r"
            print "DriverVer=10/16/2021,0.47.2.0\r"; print "\r"
            print "[DestinationDirs]\r"; print "DefaultDestDir = 12\r"; print "\r"
            print "[SourceDisksNames]\r"; print "1 = %DiskName%,,," bs "i386" bs "uniata\r"; print "\r"
            print "[SourceDisksNames.x86]\r"; print "1 = %DiskName%,,," bs "i386" bs "uniata\r"; print "\r"
            print "[SourceDisksFiles]\r"; print "uniata.sys=1\r"; print "\r"
            print "[Manufacturer]\r"; print "%Mfg%=UniATA_Models\r"; print "\r"
            print "[UniATA_Models]\r"
            for (i = 1; i <= n; i++) print "%Desc% = UniATA_Inst, PCI" bs id[i] "\r"
            print "\r"
            print "[UniATA_Inst]\r"; print "CopyFiles = UniATA_Files\r"; print "\r"
            print "[UniATA_Files]\r"; print "uniata.sys\r"; print "\r"
            print "[UniATA_Inst.Services]\r"; print "AddService = uniata, 0x00000002, UniATA_Service\r"; print "\r"
            print "[UniATA_Service]\r"; print "ServiceType    = 1\r"; print "StartType      = 0\r"
            print "ErrorControl   = 1\r"; print "ServiceBinary  = %12%" bs "uniata.sys\r"
            print "LoadOrderGroup = SCSI Miniport\r"; print "\r"
            print "[Strings]\r"; print "Provider = " q "Alexander A. Telyatnikov (UniATA), packaged by USOS" q "\r"
            print "Mfg = " q "UniATA" q "\r"; print "Desc = " q "AHCI SATA Controller (UniATA 0.47b)" q "\r"
            print "DiskName = " q "UniATA 0.47b" q "\r"
        }
    '
}

# Windows 2000 Server (catalog windows-2000-server, the same flow): status 0
# when TXTSETUP.SIF $1 has [SetupData] ProductType = 1 (Server / Advanced
# Server; Professional is 0). The answers below follow the CD, so a Server
# CD in the Professional folder gets them as well.
usos_w2k_server_source() {
    LC_ALL=C awk '
        { line = $0; sub(/;.*/, "", line); sub(/\r$/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line); low = tolower(line) }
        low ~ /^\[/ { active = (low == "[setupdata]"); next }
        active && low ~ /^producttype[ \t]*=/ { v = substr(low, index(low, "=") + 1); gsub(/[ \t"]/, "", v); product = v }
        END { exit !(product == "1") }
    ' "$1"
}

# The Server CD's GUI Setup pages USOS answers (only keys the answer file
# does not set yet, so a .sif chosen in the menu wins):
#   [LicenseFilePrintData] AutoMode=PerServer, AutoUsers=5 (the licensing page);
#   [Components] IIS and the FrontPage extensions off (2000 Server installs
#   IIS by default; nothing else is on by default);
#   [GuiUnattended] AutoLogon=Yes, AutoLogonCount=1 when the answer sets the
#   Administrator password (usos-xp.ini / profile: one automatic logon, as on
#   Server 2003);
#   [GuiRunOnce] regedit /s C:\USOS\W2K\srvwiz.reg (usos_w2k_server_reg) at
#   that first logon: "Configure Your Server" stays closed.
# The workgroup and the default network components come from the merged
# usos-xp.ini answer ([Identification] JoinWorkgroup, [Networking]); no
# domain controller promotion (dcpromo is never run).
# stdin WINNT.SIF -> stdout (CRLF).
usos_w2k_server_sif() {
    LC_ALL=C awk '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function want(sec, key, value) { n++; wsec[n] = sec; wkey[n] = tolower(key); wline[n] = key "=" value }
        BEGIN {
            want("licensefileprintdata", "AutoMode", "PerServer")
            want("licensefileprintdata", "AutoUsers", "5")
            split("iis_common iis_inetmgr iis_www iis_ftp iis_smtp iis_nntp iis_doc iis_htmla iis_pwmgr iis_www_vdir_scripts iis_www_vdir_printers fp_extensions", iis, " ")
            for (i = 1; i in iis; i++) want("components", iis[i], "Off")
            names["licensefileprintdata"] = "LicenseFilePrintData"; names["components"] = "Components"; names["guiunattended"] = "GuiUnattended"; names["guirunonce"] = "GuiRunOnce"
            run = "regedit /s C:" sprintf("%c", 92) "USOS" sprintf("%c", 92) "W2K" sprintf("%c", 92) "srvwiz.reg"
        }
        { sub(/\r$/, ""); lines[++count] = $0; t = trim($0); low = tolower(t) }
        substr(t, 1, 1) == "[" { s = substr(low, 2); e = index(s, "]"); sec = trim(e ? substr(s, 1, e - 1) : s); last[sec] = count; next }
        sec != "" && index(t, "=") > 0 && substr(t, 1, 1) != ";" {
            key = tolower(trim(substr(t, 1, index(t, "=") - 1)))
            have[sec, key] = 1; last[sec] = count
            if (sec == "guirunonce") runs++
            if (sec == "guiunattended" && key == "adminpassword") admin = 1
        }
        END {
            for (i = 1; i <= n; i++) if (!((wsec[i], wkey[i]) in have)) add[wsec[i]] = add[wsec[i]] wline[i] "\r\n"
            if (admin && !(("guiunattended", "autologon") in have)) add["guiunattended"] = add["guiunattended"] "AutoLogon=Yes\r\nAutoLogonCount=1\r\n"
            add["guirunonce"] = "Command" (runs + 0) "=" sprintf("%c", 34) run sprintf("%c", 34) "\r\n"
            for (i = 1; i <= count; i++) {
                printf "%s\r\n", lines[i]
                for (s in add) if ((s in last) && last[s] == i && !(s in done)) { printf "%s", add[s]; done[s] = 1 }
            }
            split("licensefileprintdata components guiunattended guirunonce", order, " ")
            for (i = 1; i in order; i++) if ((order[i] in add) && !(order[i] in done)) printf "[%s]\r\n%s", names[order[i]], add[order[i]]
        }
    '
}

# stdout (CRLF): C:\USOS\W2K\srvwiz.reg, the first logon's "Configure Your
# Server" off for that user (HKCU ...\Setup\Welcome srvwiz = 0).
usos_w2k_server_reg() {
    printf 'REGEDIT4\r\n\r\n[HKEY_CURRENT_USER\\Software\\Microsoft\\Windows NT\\CurrentVersion\\Setup\\Welcome]\r\n"srvwiz"=dword:00000000\r\n\r\n'
}

# stdout (CRLF): C:\USOS\W2K\VESA.REG (see 11.). usosvbe as a legacy (non-PnP)
# video miniport in group Video, framebuf as its display driver, 1024x768x16
# (the mode proven with this miniport on the X470 under NT 4.0; the Display
# applet lists every VBE mode). The DefaultSettings go to the service's
# Device0 key (NT 4.0's place) and to the current hardware profile's copy,
# which the 2000 Display applet writes. InstalledDisplayDrivers is
# REG_MULTI_SZ "framebuf": REGEDIT4 hex(7) is read as ANSI bytes and widened.
usos_w2k_vesa_reg() {
    printf 'REGEDIT4\r\n\r\n'
    printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Services\\usosvbe]\r\n'
    printf '"Type"=dword:00000001\r\n"Start"=dword:00000001\r\n"ErrorControl"=dword:00000000\r\n"Group"="Video"\r\n\r\n'
    for key in 'Services\usosvbe\Device0' 'Hardware Profiles\Current\System\CurrentControlSet\Services\usosvbe\Device0'; do
        printf '[HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\%s]\r\n' "$key"
        if [ "$key" = 'Services\usosvbe\Device0' ]; then
            printf '"InstalledDisplayDrivers"=hex(7):66,72,61,6d,65,62,75,66,00,00\r\n"VgaCompatible"=dword:00000000\r\n'
        fi
        printf '"DefaultSettings.BitsPerPel"=dword:00000010\r\n"DefaultSettings.XResolution"=dword:00000400\r\n"DefaultSettings.YResolution"=dword:00000300\r\n'
        printf '"DefaultSettings.VRefresh"=dword:0000003c\r\n"DefaultSettings.Flags"=dword:00000000\r\n"DefaultSettings.XPanning"=dword:00000000\r\n"DefaultSettings.YPanning"=dword:00000000\r\n\r\n'
    done
}

# stdout (CRLF): C:\USOS\W2K\vesa.cmd (see 11.), called by usos-setup.cmd at
# setup end (USOS_DIR, USOS_LOG set there). framebuf.dll from Setup, else
# expanded from the CD's FRAMEBUF.DL_ with 2000's own expand.exe; without it
# VGA stays. Then usosvbe.sys, VESA.REG and the boot.ini "[VGA mode]" entry:
# the default entry's ARC path with /fastdetect /basevideo, timeout 5 (one
# entry gives no menu; two would wait 30 s). boot.ini is rewritten through a
# copy that must still hold default= and the new entry; the old one stays
# as C:\USOS\W2K\boot.ini.usos.
usos_w2k_vesa_cmd() {
    sed 's/$/\r/' <<'EOF'
@echo off
rem USOS: Windows 2000 VESA display (usosvbe + the CD's framebuf.dll), setup end.
if not defined USOS_DIR set USOS_DIR=%SystemDrive%\USOS\W2K
if not defined USOS_LOG set USOS_LOG=%SystemRoot%\usos-setup.log
if exist "%SystemRoot%\system32\framebuf.dll" goto vesa
if not exist "%USOS_DIR%\FRAMEBUF.DL_" goto novesa
"%SystemRoot%\system32\expand.exe" "%USOS_DIR%\FRAMEBUF.DL_" "%SystemRoot%\system32\framebuf.dll" >> "%USOS_LOG%"
if not exist "%SystemRoot%\system32\framebuf.dll" goto novesa
:vesa
copy /y "%USOS_DIR%\USOSVBE.SYS" "%SystemRoot%\system32\drivers\usosvbe.sys" >> "%USOS_LOG%"
if not exist "%SystemRoot%\system32\drivers\usosvbe.sys" goto novesa
"%SystemRoot%\regedit.exe" /s "%USOS_DIR%\VESA.REG"
echo vesa on: usosvbe + framebuf.dll, 1024x768x16 >> "%USOS_LOG%"
call :vgaentry
goto end
:novesa
echo vesa off: no framebuf.dll, VGA stays >> "%USOS_LOG%"
goto end
:vgaentry
set USOS_BINI=%SystemDrive%\boot.ini
if not exist "%USOS_BINI%" goto vganone
findstr /i /c:"/basevideo" "%USOS_BINI%" > nul && goto :eof
set USOS_ARC=
for /f "tokens=1* delims==" %%a in ('findstr /b /i /c:"default=" "%USOS_BINI%"') do set USOS_ARC=%%b
if not defined USOS_ARC goto vganone
attrib -r -s -h "%USOS_BINI%"
copy /y "%USOS_BINI%" "%USOS_DIR%\boot.ini.usos" > nul
(for /f "usebackq eol=| delims=" %%l in ("%USOS_DIR%\boot.ini.usos") do (echo %%l| findstr /b /i "timeout=" > nul && echo timeout=5|| echo %%l)) > "%USOS_DIR%\boot.ini.new"
>> "%USOS_DIR%\boot.ini.new" echo %USOS_ARC%="Windows 2000 [VGA mode]" /fastdetect /basevideo
findstr /b /i /c:"default=" "%USOS_DIR%\boot.ini.new" > nul || goto vgafail
findstr /i /c:"/basevideo" "%USOS_DIR%\boot.ini.new" > nul || goto vgafail
copy /y "%USOS_DIR%\boot.ini.new" "%USOS_BINI%" > nul
echo boot.ini: [VGA mode] entry added (/basevideo), timeout 5 >> "%USOS_LOG%"
goto vgaattr
:vgafail
echo boot.ini: [VGA mode] entry FAILED, boot.ini unchanged >> "%USOS_LOG%"
:vgaattr
del /f /q "%USOS_DIR%\boot.ini.new" 2> nul
attrib +r +s +h "%USOS_BINI%"
goto :eof
:vganone
echo boot.ini: no default= line, no [VGA mode] entry >> "%USOS_LOG%"
goto :eof
:end
EOF
}

# usos_w2k_vesa_stage DIR LS_I386: the setup-end VESA files (see 11.) in DIR
# (C:\USOS\W2K): USOSVBE.SYS from the package, FRAMEBUF.DL_ from the local
# source when it has one (the CD's own file), VESA.REG, vesa.cmd. Messages on
# stdout; status 1 when a copy fails.
usos_w2k_vesa_stage() {
    pkg=${USOS_W2K_DIR:-/usr/lib/usos/w2k-drivers}
    cp "$pkg/usosvbe/usosvbe.sys" "$1/USOSVBE.SYS" && cmp -s "$pkg/usosvbe/usosvbe.sys" "$1/USOSVBE.SYS" || { echo '[W2K_STAGE] STOP: cannot stage USOSVBE.SYS'; return 1; }
    fb=$(find "$2" -maxdepth 1 -type f \( -iname framebuf.dl_ -o -iname framebuf.dll \) | LC_ALL=C sort | head -n 1)
    case "$fb" in
        *_) cp "$fb" "$1/FRAMEBUF.DL_" && cmp -s "$fb" "$1/FRAMEBUF.DL_" || { echo '[W2K_STAGE] STOP: cannot stage FRAMEBUF.DL_'; return 1; } ;;
        ?*) echo '[W2K_STAGE] VESA: the local source has an uncompressed framebuf.dll (Setup installs it)' ;;
        *) echo '[W2K_STAGE] VESA: no FRAMEBUF.DL_ in the local source (VESA only if Setup installs framebuf.dll)' ;;
    esac
    usos_w2k_vesa_reg > "$1/VESA.REG" && usos_w2k_vesa_cmd > "$1/vesa.cmd" || { echo '[W2K_STAGE] STOP: cannot write VESA.REG / vesa.cmd'; return 1; }
    echo '[W2K_STAGE] VESA staged: usosvbe.sys + framebuf.dll at setup end (vesa.cmd), 1024x768x16, boot.ini [VGA mode]'
}

# stdout: the 512-byte marker sector USOS writes at LBA 2046 of the prepared
# disk ("USOSW2KTRACE", boot counter 0 at offset 16, the MBR disk signature
# $1 as hex at offset 32). AHCINT usos2+ only touches a disk with this marker
# (write/read-back test at 2045, trace ring at 2040-2043; ahcint.h).
usos_w2k_gap_marker() {
    printf 'USOSW2KTRACE'
    printf '\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000'
    printf '%-8s' "${1:-00000000}" | cut -c1-8 | tr -d '\n'
    head -c 472 /dev/zero
}

if [ "${1:-}" = apply ]; then usos_w2k_apply; fi
