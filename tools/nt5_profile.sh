# Shared identity for the two supported NT5 installation sources.
usos_nt5_profile() {
    NT5_SYSTEM=${NT5_SYSTEM:-windows-xp}
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
            ;;
        *) printf '[NT5_PROFILE] Unsupported system: %s\n' "$NT5_SYSTEM" >&2; return 1 ;;
    esac
    export NT5_SYSTEM NT5_NAME NT5_TITLE NT5_INSTALL_DIR
}
