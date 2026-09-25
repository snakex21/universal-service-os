# Sourced only for a supported Windows BIOS preparation request.
legacy_windows_name() {
    value=$1; decoded=''
    case "$value" in ''|*[!0-9a-fA-F]*) return 1 ;; esac
    [ $(( ${#value} % 2 )) -eq 0 ] || return 1
    while [ -n "$value" ]; do
        pair=$(printf '%s' "$value" | cut -c1-2); value=$(printf '%s' "$value" | cut -c3-)
        byte=$((0x$pair)); [ "$byte" -ge 32 ] && [ "$byte" -ne 127 ] || return 1
        decoded=$decoded$(printf "\\$(printf '%03o' "$byte")")
    done
    case "$decoded" in */*|*\\*|.|..) return 1 ;; esac
    printf '%s' "$decoded"
}

legacy_windows_request() {
    case "$LEGACY_ACTION" in
        windows7-iso) windows_folder='Windows 7'; system_id=windows-7; USOS_WINDOWS_BIOS_HANDOFF=direct; USOS_WINDOWS_SETUP_FROM_SOURCE=0; USOS_WINDOWS_BIOS_ORDERED=0 ;;
        windows-vista-iso) windows_folder='Windows Vista'; system_id=windows-vista; USOS_WINDOWS_BIOS_HANDOFF=direct; USOS_WINDOWS_SETUP_FROM_SOURCE=1; USOS_WINDOWS_BIOS_ORDERED=1 ;;
        *) stop 'Unsupported Windows BIOS request' ;;
    esac
    # Windows Server 2008 R2 / 2008 use the Windows 7 / Vista request with
    # their own DATA folder (usos.legacy_folder_hex); only these two.
    if [ -n "${LEGACY_FOLDER_HEX:-}" ]; then
        folder=$(legacy_windows_name "$LEGACY_FOLDER_HEX") || stop 'Invalid Windows system folder'
        case "$LEGACY_ACTION:$folder" in
            'windows7-iso:Windows Server 2008 R2') system_id=windows-server-2008-r2 ;;
            'windows-vista-iso:Windows Server 2008') system_id=windows-server-2008 ;;
            *) stop 'Unsupported Windows system folder' ;;
        esac
        windows_folder=$folder
    fi
    export USOS_WINDOWS_BIOS_HANDOFF USOS_WINDOWS_SETUP_FROM_SOURCE USOS_WINDOWS_BIOS_ORDERED
    image=$(legacy_windows_name "$LEGACY_IMAGE_HEX") || stop 'Invalid Windows image name'
    case "$image" in *.iso|*.ISO) ;; *) stop 'Windows Setup requires an ISO image' ;; esac
    unattended=none
    if [ -n "$LEGACY_UNATTENDED_HEX" ]; then
        name=$(legacy_windows_name "$LEGACY_UNATTENDED_HEX") || stop 'Invalid unattended file name'
        case "$name" in *.xml|*.XML) ;; *) stop 'Windows unattended file must be XML' ;; esac
        unattended="Systems/Windows/$windows_folder/Unattended/$name"
    fi
    # Invalidate a previous one-shot before starting a new preparation.
    rm -f /mnt/esp/EFI/USOS/windows-bios-ready.ini
    state=/mnt/esp/EFI/USOS/install-state.ini
    {
        printf 'phase=prepare-requested\nselected_method=iso\n'
        printf 'selected_system=%s\n' "$system_id"
        printf 'selected_iso=Systems/Windows/%s/Images/%s\n' "$windows_folder" "$image"
        printf 'selected_unattend=%s\n' "$unattended"
    } > "$state.tmp"
    mv "$state.tmp" "$state" || stop 'Cannot publish Windows preparation request'
    export USOS_WINDOWS_BIOS=yes
    printf '[WINDOWS_BIOS] REQUEST %s image=%s handoff=%s\n' "$windows_folder" "$image" "$USOS_WINDOWS_BIOS_HANDOFF"
}
