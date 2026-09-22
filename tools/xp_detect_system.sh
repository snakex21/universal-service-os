# Read markers only; never execute files found on the inspected disk.
usos_xp_detect_system() {
    detect_root=$1
    for detect_dir in "$detect_root"/WINDOWS "$detect_root"/Windows "$detect_root"/windows "$detect_root"/WINNT; do
        [ -d "$detect_dir" ] && [ ! -L "$detect_dir" ] || continue
        for detect_system32 in "$detect_dir"/system32 "$detect_dir"/System32 "$detect_dir"/SYSTEM32; do
            [ ! -L "$detect_system32" ] || continue
            [ ! -L "$detect_system32/config" ] && [ ! -L "$detect_system32/CONFIG" ] || continue
            [ -f "$detect_system32/ntoskrnl.exe" ] || [ -f "$detect_system32/NTOSKRNL.EXE" ] || continue
            if [ -f "$detect_system32/config/SYSTEM" ] || [ -f "$detect_system32/config/system" ] || [ -f "$detect_system32/CONFIG/SYSTEM" ]; then
                printf 'Windows (system files)'; return
            fi
        done
    done
    if [ ! -L "$detect_root/etc" ] && [ -f "$detect_root/etc/os-release" ] && [ ! -L "$detect_root/etc/os-release" ]; then
        detect_name=$(awk -F= '$1=="PRETTY_NAME" {sub(/^[^=]*=/, ""); gsub(/^"|"$/, ""); print; exit}' "$detect_root/etc/os-release" | tr -cd '[:alnum:] ._()-' | cut -c1-60)
        printf 'Linux%s' "${detect_name:+: $detect_name}"; return
    fi
    if [ -d "$detect_root/\$WIN_NT\$.~BT" ] || [ -d "$detect_root/\$WIN_NT\$.~LS" ]; then
        printf 'XP installation files'; return
    fi
    if [ -f "$detect_root/bootmgr" ] || [ -f "$detect_root/NTLDR" ] || [ -f "$detect_root/ntldr" ]; then
        printf 'Windows boot files'; return
    fi
    printf 'No system detected'
}
