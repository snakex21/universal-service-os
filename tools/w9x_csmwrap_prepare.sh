# Windows 95/98/Me from the UEFI menu without firmware CSM (profile
# w9x-uefi-csmwrap, experimental; docs/win9x-modern-2026-09-30.md section 4c).
# Sourced by pipeline step 620. The UEFI menu wrote
# EFI/USOS/win9x/request.ini (system, folder, iso, answer, size) and, for a
# profile, the rendered EFI/USOS/answer/<tag>.INF.
#
# The user picks the target disk (XP disk picker: the USOS stick and read-only
# disks are never offered, nothing is picked automatically) and confirms the
# erase on the "FORMAT THE ENTIRE DISK?" screen; tools/w9x_csmwrap_target.sh
# then writes that disk only. The restart boots the disk through its CSMWrap
# ESP and Windows Setup runs from it; the USOS stick is not needed any more.
#
# Screens: the Vista CSMWrap page layout (USOS_UI_VISTA, 5 stages); every
# tool writes to EFI/USOS/win9x/prepare.log, nothing reaches the screen.

w9x_csmwrap_log() {
    printf '[W9X_CSMWRAP] %s\n' "$*"
    printf '%s\n' "$*" >> "$W9X_DIR/prepare.log" 2>/dev/null || true
}

w9x_csmwrap_value() {
    awk -F= -v key="$1" '{ sub(/\r$/, "") } $1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$2"
}

# The USOS default MSBATCH.INF has no TimeZone: the UEFI menu passes the
# menu language's 9x zone key (request.ini timezone=), inserted after
# [Setup], so the Date/Time page of Setup's hardware phase does not wait.
w9x_msbatch_time_zone() {
    case "$1" in ''|*[!A-Za-z0-9.\ -]*) return 0 ;; esac
    awk -v tz="$1" '{ print } !done && /^\[[Ss][Ee][Tt][Uu][Pp]\]/ { printf "TimeZone=\"%s\"\r\n", tz; done = 1 }' "$2" > "$2.tz" &&
        mv "$2.tz" "$2"
}

# The menu's zone list is 98 SE's TIMEZONE.INF; the Windows 98 CD has every
# key of it except "Pacific SA" (added in 98 SE). That key does not exist on
# 98, so it gets no TimeZone / TZFIX for it (Setup asks on its Date/Time page).
# Windows 95 (OSR2.1 TIMEZONE.INF, 52 keys) names some zones differently and
# lacks others: the 98 key is mapped to the 95 key with the same TZI, or
# dropped (Setup asks). src/flow/answer/msbatch.zig timeZoneName95 is the same
# table for answer profiles.
w9x_release_time_zone() {
    case "$1:$2" in
        98:'Pacific SA') return 0 ;;
        95:'Central European') printf 'Warsaw'; return 0 ;;
        95:'Central Europe') printf 'Prague Bratislava'; return 0 ;;
        95:China) printf 'Beijing'; return 0 ;;
        95:'SE Asia') printf 'Bangkok'; return 0 ;;
        95:Arab) printf 'Saudi Arabia'; return 0 ;;
        95:GMT|95:Romance|95:'W. Europe'|95:'E. Europe'|95:'E. South America'|95:Atlantic|95:Eastern|95:Central|\
        95:Mountain|95:Pacific|95:Alaskan|95:Hawaiian|95:Samoa|95:'New Zealand'|95:'AUS Eastern'|95:'Cen. Australia'|\
        95:Tokyo|95:Taipei|95:India|95:Arabian|95:Iran|95:Israel|95:Newfoundland|95:Azores|95:Mid-Atlantic|\
        95:Greenwich|95:'SA Eastern'|95:'SA Western'|95:'US Eastern'|95:'SA Pacific'|95:'Canada Central'|95:Mexico|\
        95:'US Mountain'|95:Dateline|95:Fiji|95:'Central Pacific'|95:Tasmania|95:'West Pacific'|95:'AUS Central'|\
        95:'Central Asia'|95:'West Asia'|95:Afghanistan|95:Egypt|95:'South Africa'|95:Russian|95:'E. Australia') ;;
        95:*) return 0 ;;
    esac
    printf '%s' "$2"
}

usos_w9x_csmwrap_prepare() {
    W9X_DIR=/mnt/esp/EFI/USOS/win9x
    request=$W9X_DIR/request.ini
    [ -f "$request" ] || stop 'the Windows 9x request is missing on the USOS ESP'
    : > "$W9X_DIR/prepare.log" 2>/dev/null || true
    [ -d /sys/firmware/efi ] || stop 'the Windows 9x preparation requires UEFI'
    for helper in target_disk_identity.sh xp_confirmation_ui.sh xp_menu_ui.sh xp_disk_overview.sh xp_detect_system.sh w9x_csmwrap_target.sh dos_csmwrap_target.sh xp_csmwrap_esp.sh; do
        [ -r "/usr/lib/usos/$helper" ] || stop "$helper is missing"
    done
    . /usr/lib/usos/target_disk_identity.sh
    . /usr/lib/usos/xp_confirmation_ui.sh
    xp_stage_set() { :; }

    system=$(w9x_csmwrap_value system "$request") || stop 'request.ini has no system'
    iso=$(w9x_csmwrap_value iso "$request") || stop 'request.ini has no iso'
    folder=$(w9x_csmwrap_value folder "$request") || stop 'request.ini has no folder'
    answer=$(w9x_csmwrap_value answer "$request") || answer=none
    size_gib=$(w9x_csmwrap_value size "$request") || size_gib=32
    for value in "$iso" "$folder" "$answer"; do
        case "$value" in *..*|/*) stop 'request.ini has an unsafe path' ;; esac
    done
    case "$system" in
        windows-98-se) tag=98SE setup=WIN98 ;;
        windows-98) tag=98 setup=WIN98 ;;
        windows-me) tag=ME setup=WIN9X ;;
        windows-95) tag=95 setup=WIN95 ;;
        # DOS family (tools/dos_csmwrap_target.sh): MS-DOS 6.22, and Windows
        # 3.x on top of the MS-DOS 6.22 ISO from Systems\DOS\MS-DOS\Images.
        ms-dos) tag=DOS setup='' ;;
        windows-3-1|windows-3-11) tag=W3 setup='' ;;
        # Windows NT 4.0 (tools/nt4_csmwrap_target.sh + nt4_qemu_install.sh):
        # the whole install in the VM, then the finished SP6a system starts.
        windows-nt-4) tag=NT4 setup='' ;;
        windows-nt-4-server) tag=NT4S setup='' ;;
        *) stop "request.ini names an unsupported system: $system" ;;
    esac
    w9x_csmwrap_log "REQUEST system=$system iso=$iso folder=$folder answer=${answer%%:*} size=$size_gib"
    NT5_NAME=$folder
    NT5_TITLE=$(printf '%s' "$NT5_NAME" | tr '[:lower:]' '[:upper:]')
    USOS_UI_HEADING=$NT5_NAME
    export NT5_TITLE NT5_NAME USOS_UI_HEADING
    usos_ui_stage 3 5 'Detecting disks' 'The disk will only be changed after your confirmation.' || true

    DEVICE_INI=/mnt/esp/EFI/USOS/usos-device.ini
    DATA_PARTUUID=$(awk -F= '$1 == "data_partuuid" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$DEVICE_INI") || stop 'DATA PARTUUID missing'
    DATA_PATH=$(wait_for_partuuid_path "$DATA_PARTUUID") || stop "DATA partition not found: $DATA_PARTUUID"
    modprobe ntfs3 2>/dev/null || true
    modprobe isofs 2>/dev/null || true
    modprobe loop 2>/dev/null || true
    modprobe vfat 2>/dev/null || true
    mkdir -p /mnt/data
    mount -t ntfs3 -o ro,noatime "$DATA_PATH" /mnt/data || stop 'cannot mount USOS_DATA read-only'
    [ -f "/mnt/data/$iso" ] || stop "the Windows ISO is not on DATA: $iso"
    floppy=''
    dos_iso=''
    nt4=''
    sp_exe=''
    case "$tag" in NT4|NT4S) nt4=yes ;; esac
    if [ -n "$nt4" ]; then
        for helper in nt4_csmwrap_target.sh nt4_qemu_install.sh w9x_phase1_qemu.sh; do
            [ -r "/usr/lib/usos/$helper" ] || stop "$helper is missing"
        done
        # SP6a (the user's SP6I386.EXE, a Microsoft file: never on the stick):
        # the X470 cannot start the RTM kernel, only an SP6a system.
        for sp_dir in "/mnt/data/Systems/Windows/$folder/ServicePack" '/mnt/data/Systems/Windows/Windows NT 4.0/ServicePack'; do
            [ -d "$sp_dir" ] || continue
            sp_exe=$(find "$sp_dir" -maxdepth 1 -type f -iname 'sp6i386.exe' 2>/dev/null | head -n 1)
            [ -z "$sp_exe" ] || break
        done
        [ -n "$sp_exe" ] || stop 'Windows NT 4.0 needs Service Pack 6a: put SP6I386.EXE into Systems\Windows\Windows NT 4.0\ServicePack on USOS_DATA'
        w9x_csmwrap_log "NT4 service pack: ${sp_exe#/mnt/data/}"
    fi
    win3_iso=''
    case "$tag" in
        DOS) dos_iso="/mnt/data/$iso" ;;
        W3)
            dos_iso='/mnt/data/Systems/DOS/MS-DOS/Images/MS-DOS 6.22.iso'
            [ -f "$dos_iso" ] || stop 'Windows 3.x needs the MS-DOS 6.22 ISO as Systems\DOS\MS-DOS\Images\MS-DOS 6.22.iso'
            win3_iso="/mnt/data/$iso" ;;
    esac
    if [ "$tag" = 95 ]; then
        # Windows 95 CDs do not boot: the startup disk image next to the ISO
        # folder (Systems\Windows\Windows 95\Boot\BOOTDISK.IMG, bridge).
        floppy="/mnt/data/Systems/Windows/$folder/Boot/BOOTDISK.IMG"
        [ -f "$floppy" ] || stop 'Windows 95 needs Systems\Windows\Windows 95\Boot\BOOTDISK.IMG (a 95 OSR2 or 98 startup disk image)'
    fi

    answer_inf=/run/w9x-msbatch.inf
    answer_kind=USOS
    time_zone=
    [ -z "$dos_iso" ] || answer=dos
    [ -z "$nt4" ] || answer_inf=/run/nt4-winnt.sif
    case "$nt4:$answer" in
        yes:none) stop 'Windows NT 4.0 needs a product key: choose an answer profile with the key or type it when the menu asks' ;;
        yes:profile)
            # Rendered by the UEFI menu (answer_profiles.stageWin9x: NT4.SIF /
            # NT4S.SIF, WINNT.SIF with the key): copied to RAM, staged copies go.
            cp "/mnt/esp/EFI/USOS/answer/$tag.SIF" "$answer_inf" || stop 'the answer profile could not be taken'
            rm -f /mnt/esp/EFI/USOS/answer/NT4.SIF /mnt/esp/EFI/USOS/answer/NT4S.SIF
            for staged in 98SE 98 ME 95; do rm -f "/mnt/esp/EFI/USOS/answer/$staged.INF"; done
            sync
            answer=nt4
            answer_kind=PROFILE ;;
    esac
    case "$answer" in
        nt4) ;;
        dos) : > "$answer_inf" ;;
        none)
            cp /mnt/esp/EFI/USOS/dos-native/win9x/MSBATCH.INF "$answer_inf" || stop 'the default MSBATCH.INF is missing'
            time_zone=$(w9x_csmwrap_value timezone "$request") || time_zone=
            time_zone=$(w9x_release_time_zone "$tag" "$time_zone")
            w9x_csmwrap_log "TIMEZONE ${time_zone:-none (request.ini has no timezone=)}"
            w9x_msbatch_time_zone "$time_zone" "$answer_inf" || stop 'the time zone could not be added to MSBATCH.INF'
            # Guard: a zone from the menu must end up in [Setup], else the
            # Date/Time page would wait for a click again.
            if [ -n "$time_zone" ] && ! grep -q 'TimeZone=' "$answer_inf"; then
                stop "MSBATCH.INF has no TimeZone after inserting \"$time_zone\"; see EFI/USOS/win9x/prepare.log"
            fi ;;
        profile)
            # Rendered by the UEFI menu (answer_profiles.stageWin9x); it may
            # hold a product key: copied to RAM, then every staged copy goes.
            cp "/mnt/esp/EFI/USOS/answer/$tag.INF" "$answer_inf" || stop 'the answer profile could not be taken'
            for staged in 98SE 98 ME 95; do rm -f "/mnt/esp/EFI/USOS/answer/$staged.INF"; done
            rm -f /mnt/esp/EFI/USOS/answer/NT4.SIF /mnt/esp/EFI/USOS/answer/NT4S.SIF
            sync
            answer_kind=PROFILE ;;
        file:*)
            name=${answer#file:}
            case "$name" in */*|'') stop 'request.ini has an unsafe answer file name' ;; esac
            cp "/mnt/data/Systems/Windows/$folder/Unattended/$name" "$answer_inf" || stop "the answer file is not on DATA: $name"
            answer_kind=USER ;;
        *) stop 'request.ini has an unknown answer kind' ;;
    esac

    ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_PATH" 2>/dev/null | head -n 1)
    [ -n "$ESP_PARENT" ] || stop 'cannot resolve the USOS disk'
    USOS_DISK_DEVICE="/dev/$ESP_PARENT"
    CANDIDATES=/run/w9x-candidates
    : > "$CANDIDATES"
    index=0
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        mdev -s 2>/dev/null || true
        lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }' | grep -qv "^$USOS_DISK_DEVICE\$" && break
        sleep 1
    done
    for candidate in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        ro=$(lsblk -dnro RO "$candidate" 2>/dev/null | head -n 1 || true)
        if [ "$candidate" = "$USOS_DISK_DEVICE" ]; then
            w9x_csmwrap_log "DISK $candidate REJECT USOS stick"
        elif [ "$ro" = 1 ]; then
            w9x_csmwrap_log "DISK $candidate REJECT read-only"
        else
            index=$((index + 1))
            printf '%s|%s\n' "$index" "$candidate" >> "$CANDIDATES"
            w9x_csmwrap_log "DISK $candidate ACCEPT index=$index model=$(usos_disk_model "$candidate" || true) size=$(usos_disk_size "$candidate" || true)"
        fi
    done
    [ "$index" -gt 0 ] || stop 'No target disk found (only the USOS stick). No disk was changed.'

    USOS_XP_DISK_NOTE="Without CSM, $folder starts through CSMWrap, so USOS prepares the target disk first."
    export USOS_XP_DISK_NOTE
    while :; do
        TARGET_DEVICE=''
        usos_xp_choose_disk
        model=$(usos_disk_model "$TARGET_DEVICE" || true)
        serial=$(usos_disk_serial "$TARGET_DEVICE" || true)
        size=$(usos_disk_size "$TARGET_DEVICE")
        overview=/run/w9x-disk-overview.txt
        screen=/run/w9x-disk-confirm.txt
        usos_ui_stage 3 5 'Inspecting disk' 'Reading partitions, free space and system files.' || true
        if ! TARGET_DEVICE=$TARGET_DEVICE sh /usr/lib/usos/xp_disk_overview.sh > "$overview" 2>> "$W9X_DIR/prepare.log"; then
            printf 'Disk: %s\nS/N: %s\nSize: %s GiB\n' "$model" "$serial" "$((size / 1073741824))" > "$overview"
        fi
        # The layout w9x_csmwrap_target.sh writes (same arithmetic).
        total=$((size / 512))
        esp_start=$(( (total - 133120 + 2047) / 2048 * 2048 ))
        part_gib=$size_gib
        [ $((2048 + part_gib * 2097152)) -le "$esp_start" ] || part_gib=$(( (esp_start - 2048) / 2097152 ))
        layout="one FAT32 partition of $part_gib GiB"
        [ -z "$dos_iso" ] || layout='one FAT16 partition of 256 MiB'
        [ -z "$nt4" ] || layout='one FAT16 partition of 2000 MiB at the disk start'
        {
            printf 'ERASE ALL DATA ON THIS DISK\n\n'
            cat "$overview"
            printf '\n'
            printf 'All partitions, systems and files on this disk will be erased.\n'
            printf 'New layout (MBR): %s (drive C:) for %s, then a 64 MiB CSMWrap partition at the end of the disk; the rest stays unallocated.\n' "$layout" "$folder"
            if [ -n "$nt4" ]; then
                printf 'After the restart the disk starts by itself into the installed %s.\n' "$folder"
            else
                printf 'After the restart the disk starts by itself and %s Setup continues on it.\n' "$folder"
            fi
        } > "$screen"
        w9x_csmwrap_log "CONFIRM $TARGET_DEVICE model=$model serial=$serial size=$size part_gib=$part_gib"
        usos_xp_confirm "$screen" 'FORMAT THE ENTIRE DISK?' 'Erase ALL partitions and data on the selected disk' && break
        w9x_csmwrap_log "CONFIRM $TARGET_DEVICE cancelled; no disk was changed"
    done
    [ "$TARGET_DEVICE" != "$USOS_DISK_DEVICE" ] || stop 'refusing the USOS disk'
    w9x_csmwrap_log "TARGET $TARGET_DEVICE model=$model serial=$serial size=$size confirmed"

    # Windows 98 / 98 SE / Me: Setup phase 1 in a VM on this machine
    # (qemu9x.cpio, tools/w9x_phase1_qemu.sh); 95 and machines without it keep
    # the native DOS Setup start.
    vm_phase1=no
    if [ -n "$nt4" ]; then
        . /usr/lib/usos/w9x_phase1_qemu.sh
        . /usr/lib/usos/nt4_qemu_install.sh
        vm_reason=$(w9x_vm_available "$tag") || stop "Windows NT 4.0 installs only in the VM on this PC, which is not available: $vm_reason"
        w9x_csmwrap_log "NT4 vm ($vm_reason)"
    elif [ -z "$dos_iso" ] && [ -r /usr/lib/usos/w9x_phase1_qemu.sh ]; then
        . /usr/lib/usos/w9x_phase1_qemu.sh
        if vm_reason=$(w9x_vm_available "$tag"); then vm_phase1=yes; fi
        # Windows 95: the COA page of phase 1 needs the key, typed into the VM
        # (w9x_phase1_run); never logged, only its length.
        W9X_VM_KEY=''
        if [ "$vm_phase1" = yes ] && [ "$tag" = 95 ]; then
            if W9X_VM_KEY=$(w9x_vm_key_digits "$answer_inf"); then
                vm_reason="$vm_reason; 95 key from the answer: ${#W9X_VM_KEY} digits for the COA page"
            else
                W9X_VM_KEY=''
                vm_phase1=no
                vm_reason='Windows 95 without a product key (ProductID) in the answer keeps the native Setup start'
            fi
        fi
        w9x_csmwrap_log "PHASE1 vm=$vm_phase1 ($vm_reason)"
    fi
    usos_ui_stage 4 5 'Preparing the disk' "Copying $folder Setup, the USOS helpers and CSMWrap to the selected disk." || true
    if [ -n "$nt4" ]; then
        set -- env TARGET_DEVICE="$TARGET_DEVICE" NT4_SOURCE_ISO="/mnt/data/$iso" NT4_ANSWER_SIF="$answer_inf"             NT4_ANSWER_KIND="$answer_kind" NT4_SP_EXE="$sp_exe" sh /usr/lib/usos/nt4_csmwrap_target.sh
    elif [ -n "$dos_iso" ]; then
        set -- env TARGET_DEVICE="$TARGET_DEVICE" W9X_SOURCE_ISO="$dos_iso" DOS_WIN3_ISO="$win3_iso" \
            DOS_PROGRAMS_DIR=/mnt/data/Systems/DOS/MS-DOS/Programs sh /usr/lib/usos/dos_csmwrap_target.sh
    else
        set -- env TARGET_DEVICE="$TARGET_DEVICE" W9X_SOURCE_ISO="/mnt/data/$iso" W9X_SETUP_FOLDER="$setup" W9X_TAG="$tag" \
            W9X_ANSWER_INF="$answer_inf" W9X_ANSWER_KIND="$answer_kind" W9X_BOOT_FLOPPY="$floppy" W9X_SIZE_GIB="$size_gib" \
            W9X_USB_DIR="/mnt/data/Drivers/$folder/USB" W9X_TIME_ZONE="${time_zone:-}" W9X_VM_PHASE1="$([ "$vm_phase1" = yes ] && echo 1 || echo 0)"             sh /usr/lib/usos/w9x_csmwrap_target.sh
    fi
    if ! "$@" >> "$W9X_DIR/prepare.log" 2>&1 < /dev/null; then
        rm -f "$answer_inf"
        tail -n 5 "$W9X_DIR/prepare.log" 2>/dev/null || true
        stop 'The Windows 9x preparation failed; see EFI/USOS/win9x/prepare.log'
    fi
    rm -f "$answer_inf"
    if [ -n "$nt4" ]; then
        nt4_vm_progress() {
            usos_ui_stage 5 5 "$folder installation in the background (start $1)"                 "Do not turn off the computer. Elapsed: $(printf '%d:%02d' $(($2 / 60)) $(($2 % 60))), written to disk: $3 MB." || true
        }
        accel=$(w9x_vm_accel)
        w9x_csmwrap_log "NT4 install start target=$TARGET_DEVICE accel=$accel guest_mb=$W9X_VM_GUEST_MB timeout=$W9X_VM_TIMEOUT boots=$NT4_VM_BOOTS"
        nt4_vm_install "$TARGET_DEVICE" "$W9X_DIR/nt4" "$accel"
        vm_rc=$?
        w9x_csmwrap_log "NT4 vm rc=$vm_rc elapsed=${NT4_VM_ELAPSED:-?}s"
        usos_ui_stage 5 5 'Checking the installed system' '' || true
        if [ "$vm_rc" != 0 ] || ! vm_check=$(nt4_vm_finish "$TARGET_DEVICE" "$W9X_DIR/nt4"); then
            w9x_csmwrap_log "NT4 FAILED rc=$vm_rc stalled=${NT4_VM_STALLED:-0}s ${vm_check:-}"
            umount /mnt/data 2>/dev/null || true
            sync
            if [ "$vm_rc" = 3 ] && [ "${NT4_VM_STALLED:-0}" -gt 0 ]; then
                stop "Windows NT 4.0 Setup stopped writing to the disk for $((NT4_VM_STALLED / 60)) minutes (start ${NT4_VM_BOOT:-?}): a Setup page is waiting for input. The computer was not restarted; the last screen and logs: EFI/USOS/win9x/nt4"
            fi
            case "${vm_check:-}" in *'high-encryption CD'*)
                # update.exe refuses the Standard Encryption SP6a on a CD with
                # 128-bit security files (QEMU 2026-10-07, English Enterprise
                # Server CD with the export SP6a). POST.CMD then switches the
                # system to standard encryption and retries; this stop means
                # that failed too (POST.LOG "crypto:" lines).
                stop "Service Pack 6a did not install on this 128-bit (High Encryption) CD, also not after switching it to standard encryption (POST.LOG). Check that SP6I386.EXE is SP6a in the CD's language, or use the 128-bit (High Encryption) SP6I386.EXE, in Systems\\Windows\\$folder\\ServicePack on USOS_DATA. Logs: EFI/USOS/win9x/nt4" ;;
            esac
            case "${vm_check:-}" in *'no Service Pack 6'*)
                # SP6a's update.exe refuses a CD of another language ("This
                # Service Pack is for a different language", QEMU 2026-10-07:
                # the Polish SP6a on the English Enterprise Server CD).
                stop "Service Pack 6a did not install. It must be the same language as the CD: put SP6I386.EXE of that language into Systems\\Windows\\$folder\\ServicePack on USOS_DATA (that folder is used before the Workstation one). Logs: EFI/USOS/win9x/nt4" ;;
            esac
            stop 'The Windows NT 4.0 installation did not finish. The computer was not restarted; logs: EFI/USOS/win9x/nt4'
        fi
        w9x_csmwrap_log "NT4 PASS $vm_check"
        if ! TARGET_DEVICE=$TARGET_DEVICE USOS_XP_ESP_TAIL_SECTORS=133120 sh /usr/lib/usos/xp_csmwrap_esp.sh >> "$W9X_DIR/prepare.log" 2>&1; then
            stop 'The CSMWrap partition could not be written; see EFI/USOS/win9x/prepare.log'
        fi
    fi
    if [ "$vm_phase1" = yes ]; then
        w9x_phase1_progress() {
            usos_ui_stage 5 5 "$folder installation - stage 1 in the background"                 "Do not turn off the computer. Elapsed: $(printf '%d:%02d' $(($1 / 60)) $(($1 % 60))), written to disk: $2 MB." || true
        }
        accel=$(w9x_vm_accel)
        w9x_csmwrap_log "PHASE1 start target=$TARGET_DEVICE accel=$accel guest_mb=$W9X_VM_GUEST_MB timeout=$W9X_VM_TIMEOUT"
        w9x_phase1_run "$TARGET_DEVICE" "$accel"
        vm_rc=$?
        W9X_VM_KEY=''
        w9x_csmwrap_log "PHASE1 vm rc=$vm_rc elapsed=${W9X_VM_ELAPSED:-?}s"
        w9x_phase1_keep_logs "$W9X_DIR/phase1"
        usos_ui_stage 5 5 'Checking the result of stage 1' '' || true
        if [ "$vm_rc" != 0 ] || ! vm_check=$(w9x_phase1_verify "$TARGET_DEVICE" "$W9X_DIR/phase1"); then
            w9x_csmwrap_log "PHASE1 FAILED rc=$vm_rc ${vm_check:-}"
            umount /mnt/data 2>/dev/null || true
            sync
            stop 'Windows Setup stage 1 did not finish. The computer was not restarted; logs: EFI/USOS/win9x/phase1'
        fi
        w9x_csmwrap_log "PHASE1 PASS $vm_check"
    fi
    mv "$request" "$W9X_DIR/request.done" 2>/dev/null || true
    umount /mnt/data 2>/dev/null || true
    sync
    w9x_csmwrap_log 'DONE; waiting for the restart'
    usos_ui_notice_continue "$folder: start the prepared disk" "After the restart the firmware starts this disk's UEFI entry (CSMWrap; CSM stays off) and the $folder installation continues on it. If the USOS stick starts instead, pick the disk in the firmware boot menu." 'Restart' || true
    if [ -r "${USOS_UI_TTY:-}" ]; then
        IFS= read -r _w9x_ack < "$USOS_UI_TTY" || true
    else
        IFS= read -r _w9x_ack || true
    fi
    sync
    blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true
    reboot -f 2>/dev/null || true
    sleep 3
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
    while :; do sleep 3600; done
}
