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
            # XP Media Center Edition 2005 (menu entry windows-xp-mce) and
            # XP Tablet PC Edition 2005 (windows-xp-tablet): the same flow
            # from their own DATA folders; the UEFI menu adds
            # usos.xp_edition=mce|tablet (src/platform/uefi/xp_preparation.zig).
            case "${USOS_XP_EDITION:-}" in
                mce | tablet) ;;
                *)
                    case " $(cat /proc/cmdline 2>/dev/null) " in
                        *' usos.xp_edition=mce '*) USOS_XP_EDITION=mce ;;
                        *' usos.xp_edition=tablet '*) USOS_XP_EDITION=tablet ;;
                        *) USOS_XP_EDITION= ;;
                    esac
                    ;;
            esac
            case "$USOS_XP_EDITION" in
                mce)
                    NT5_NAME='Windows XP Media Center Edition 2005'
                    NT5_TITLE='WINDOWS XP MEDIA CENTER EDITION 2005'
                    ;;
                tablet)
                    NT5_NAME='Windows XP Tablet PC Edition 2005'
                    NT5_TITLE='WINDOWS XP TABLET PC EDITION 2005'
                    ;;
            esac
            export USOS_XP_EDITION
            NT5_INSTALL_DIR=WINDOWS
            ;;
        windows-2000)
            NT5_NAME='Windows 2000'
            NT5_TITLE='WINDOWS 2000'
            # Windows 2000 Server (menu entry windows-2000-server): the same
            # flow from its own DATA folder; the UEFI menu adds
            # usos.w2k_edition=server (src/platform/uefi/xp_preparation.zig).
            if [ "${USOS_W2K_EDITION:-}" != server ]; then
                case " $(cat /proc/cmdline 2>/dev/null) " in
                    *' usos.w2k_edition=server '*) USOS_W2K_EDITION=server ;;
                    *) USOS_W2K_EDITION= ;;
                esac
            fi
            if [ "$USOS_W2K_EDITION" = server ]; then
                NT5_NAME='Windows 2000 Server'
                NT5_TITLE='WINDOWS 2000 SERVER'
            fi
            export USOS_W2K_EDITION
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
    NT5_CATEGORY=Windows
    case "${USOS_NT5_VARIANT:-}" in
        whistler|neptune|w2k-beta) ;;
        *)
            case " $(cat /proc/cmdline 2>/dev/null) " in
                *' usos.nt5_variant=whistler '*) USOS_NT5_VARIANT=whistler ;;
                *' usos.nt5_variant=neptune '*) USOS_NT5_VARIANT=neptune ;;
                *' usos.nt5_variant=w2k-beta '*) USOS_NT5_VARIANT=w2k-beta ;;
                *) USOS_NT5_VARIANT= ;;
            esac ;;
    esac
    case "$NT5_SYSTEM:$USOS_NT5_VARIANT" in
        windows-xp:whistler) NT5_NAME='Windows Whistler'; NT5_CATEGORY=Betas ;;
        windows-2000:neptune) NT5_NAME='Windows Neptune'; NT5_CATEGORY=Betas ;;
        windows-2000:w2k-beta) NT5_NAME='Windows 2000 Beta'; NT5_CATEGORY=Betas ;;
        *:) ;;
        *) printf '[NT5_PROFILE] STOP mismatched beta/base identity\n' >&2; return 1 ;;
    esac
    export NT5_CATEGORY USOS_NT5_VARIANT
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
