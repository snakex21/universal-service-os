# Shared identity of the supported NT5 installation sources (one row per
# system; docs/design/nt5-uefi-family.md section 2):
#   NT5_NAME / NT5_TITLE   DATA folder name (Systems\Windows\<name>) and menu title
#   NT5_INSTALL_DIR        TargetPath / InstallDir
#   NT5_SOURCE_DIR         Setup source directory on the media (DOSNET.INF,
#                          TXTSETUP.SIF); AMD64 media also need I386 (loader, WOW64)
#   NT5_SETUP_DIR          C:\USOS\<dir> for the setup-end script (not XP: pae.exe)
usos_nt5_profile() {
    NT5_SYSTEM=${NT5_SYSTEM:-windows-xp}
    NT5_SOURCE_DIR=I386
    NT5_SETUP_DIR=XP
    case "$NT5_SYSTEM" in
        windows-xp)
            NT5_NAME='Windows XP'
            NT5_TITLE='WINDOWS XP'
            NT5_INSTALL_DIR=WINDOWS
            ;;
        windows-2000)
            NT5_NAME='Windows 2000'
            NT5_TITLE='WINDOWS 2000'
            NT5_INSTALL_DIR=WINNT
            NT5_SETUP_DIR=W2K
            ;;
        windows-server-2003)
            NT5_NAME='Windows Server 2003'
            NT5_TITLE='WINDOWS SERVER 2003'
            NT5_INSTALL_DIR=WINDOWS
            NT5_SETUP_DIR=W2K3
            ;;
        windows-xp-x64)
            NT5_NAME='Windows XP x64'
            NT5_TITLE='WINDOWS XP X64'
            NT5_INSTALL_DIR=WINDOWS
            NT5_SOURCE_DIR=AMD64
            NT5_SETUP_DIR=XP64
            ;;
        *) printf '[NT5_PROFILE] Unsupported system: %s\n' "$NT5_SYSTEM" >&2; return 1 ;;
    esac
    export NT5_SYSTEM NT5_NAME NT5_TITLE NT5_INSTALL_DIR NT5_SOURCE_DIR NT5_SETUP_DIR
}

# The NT5 preparation from UEFI (installed system boots through the firmware
# CSM or CSMWrap): XP (xp-x86-sp3-uefi-csm), and experimental Windows 2000
# (w2k-x86-sp4-uefi-csm), Server 2003 x86 (w2k3-x86-sp2-uefi-csm) and XP x64
# (xp-x64-sp2-uefi-csm). All keep their traces under EFI/USOS-XP and use the
# canonical 255/63 geometry.
usos_nt5_uefi_profile() {
    case "${USOS_PLAN_PROFILE:-}" in
        xp-x86-sp3-uefi-csm|w2k-x86-sp4-uefi-csm|w2k3-x86-sp2-uefi-csm|xp-x64-sp2-uefi-csm) return 0 ;;
    esac
    return 1
}

# UEFI profiles other than XP x86: no XP driver bundle, no pae.exe; a
# setup-end script in C:\USOS\$NT5_SETUP_DIR instead.
usos_nt5_uefi_generic_profile() {
    case "${USOS_PLAN_PROFILE:-}" in
        w2k-x86-sp4-uefi-csm|w2k3-x86-sp2-uefi-csm|xp-x64-sp2-uefi-csm) return 0 ;;
    esac
    return 1
}
