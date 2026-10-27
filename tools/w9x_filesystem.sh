# Own filesystem/MBR policy for the confirmed disposable or user-selected
# 9x target. No disk I/O here. GPL-3.0-or-later.

# Windows 95 OSR2 / OSR2.1 / OSR2.5: the root SETUP.EXE file versions
# (pe-file-version) of the FAT32-capable 95 CDs.
usos_w9x_95_osr2() {
    case "$1" in '4 0 0 1068'|'4 0 0 1111'|'4 0 0 1212'|'4 0 0 1214'|'4 0 0 1216') return 0 ;; esac
    return 1
}

usos_w9x_fs_select() {
    W9X_FAT_BITS=32 W9X_MBR_TYPE=12 W9X_FAT_RESERVED=32
    case "$1" in
        95)
            case "$2" in
                '4 0 0 950') W9X_FAT_BITS=16 W9X_MBR_TYPE=6 W9X_FAT_RESERVED=1 ;;
                *) usos_w9x_95_osr2 "$2" || return 1 ;;
            esac ;;
        98|98SE|ME) ;;
        *) return 1 ;;
    esac
}

usos_w9x_fs_layout() {
    # Requested sectors already clipped to the free space before the ESP.
    W9X_FS_SECTORS=$1
    if [ "$W9X_FAT_BITS" = 16 ]; then
        # 2047 MiB, 32 KiB clusters: below FAT16's 65525-cluster boundary.
        [ "$W9X_FS_SECTORS" -le 4192256 ] || W9X_FS_SECTORS=4192256
        W9X_FS_CLUSTER=64
    elif [ "$W9X_FAT_BITS" = 32 ]; then
        if [ "$W9X_FS_SECTORS" -le 16777216 ]; then W9X_FS_CLUSTER=8
        elif [ "$W9X_FS_SECTORS" -le 33554432 ]; then W9X_FS_CLUSTER=16
        else W9X_FS_CLUSTER=32; fi
    else return 1; fi
}

usos_w9x_le32() {
    _wf_v=$1
    printf "\\$(printf %03o $((_wf_v & 255)))\\$(printf %03o $(((_wf_v >> 8) & 255)))\\$(printf %03o $(((_wf_v >> 16) & 255)))\\$(printf %03o $(((_wf_v >> 24) & 255)))"
}
usos_w9x_chs() {
    _wf_c=$(( $1 / (255 * 63) ))
    if [ "$_wf_c" -gt 1023 ]; then printf '\376\377\377'; return; fi
    _wf_h=$(( ($1 / 63) % 255 ))
    _wf_s=$(( ($1 % 63 + 1) | ( (_wf_c >> 2) & 192 ) ))
    printf "\\$(printf %03o "$_wf_h")\\$(printf %03o "$_wf_s")\\$(printf %03o $((_wf_c & 255)))"
}
usos_w9x_partition_entry() {
    # FAT32 keeps the original byte-for-byte LBA entry. RTM FAT16 needs
    # type 06 and real, representable CHS, not FAT32's sentinel CHS.
    case "$1" in
        16) printf '\200'; usos_w9x_chs "$2"; printf '\006'; usos_w9x_chs $(( $2 + $3 - 1 )) ;;
        32) printf '\200\376\377\377\014\376\377\377' ;;
        *) return 1 ;;
    esac
    usos_w9x_le32 "$2"; usos_w9x_le32 "$3"
}
