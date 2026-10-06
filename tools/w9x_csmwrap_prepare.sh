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
    [ -z "$dos_iso" ] || answer=dos
    case "$answer" in
        dos) : > "$answer_inf" ;;
        none)
            cp /mnt/esp/EFI/USOS/dos-native/win9x/MSBATCH.INF "$answer_inf" || stop 'the default MSBATCH.INF is missing'
            time_zone=$(w9x_csmwrap_value timezone "$request") || time_zone=
            w9x_msbatch_time_zone "$time_zone" "$answer_inf" || stop 'the time zone could not be added to MSBATCH.INF'
            [ -z "$time_zone" ] || w9x_csmwrap_log "TIMEZONE $time_zone" ;;
        profile)
            # Rendered by the UEFI menu (answer_profiles.stageWin9x); it may
            # hold a product key: copied to RAM, then every staged copy goes.
            cp "/mnt/esp/EFI/USOS/answer/$tag.INF" "$answer_inf" || stop 'the answer profile could not be taken'
            for staged in 98SE 98 ME 95; do rm -f "/mnt/esp/EFI/USOS/answer/$staged.INF"; done
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
        {
            printf 'ERASE ALL DATA ON THIS DISK\n\n'
            cat "$overview"
            printf '\n'
            printf 'All partitions, systems and files on this disk will be erased.\n'
            printf 'New layout (MBR): %s (drive C:) for %s, then a 64 MiB CSMWrap partition at the end of the disk; the rest stays unallocated.\n' "$layout" "$folder"
            printf 'After the restart the disk starts by itself and %s Setup continues on it.\n' "$folder"
        } > "$screen"
        w9x_csmwrap_log "CONFIRM $TARGET_DEVICE model=$model serial=$serial size=$size part_gib=$part_gib"
        usos_xp_confirm "$screen" 'FORMAT THE ENTIRE DISK?' 'Erase ALL partitions and data on the selected disk' && break
        w9x_csmwrap_log "CONFIRM $TARGET_DEVICE cancelled; no disk was changed"
    done
    [ "$TARGET_DEVICE" != "$USOS_DISK_DEVICE" ] || stop 'refusing the USOS disk'
    w9x_csmwrap_log "TARGET $TARGET_DEVICE model=$model serial=$serial size=$size confirmed"

    # Windows 98 / 98 SE: Setup phase 1 in a VM on this machine (qemu9x.cpio,
    # tools/w9x_phase1_qemu.sh); 95, Me and machines without it keep the
    # native DOS Setup start.
    vm_phase1=no
    if [ -z "$dos_iso" ] && [ -r /usr/lib/usos/w9x_phase1_qemu.sh ]; then
        . /usr/lib/usos/w9x_phase1_qemu.sh
        if vm_reason=$(w9x_vm_available "$tag"); then vm_phase1=yes; fi
        w9x_csmwrap_log "PHASE1 vm=$vm_phase1 ($vm_reason)"
    fi
    usos_ui_stage 4 5 'Preparing the disk' "Copying $folder Setup, the USOS helpers and CSMWrap to the selected disk." || true
    if [ -n "$dos_iso" ]; then
        set -- env TARGET_DEVICE="$TARGET_DEVICE" W9X_SOURCE_ISO="$dos_iso" DOS_WIN3_ISO="$win3_iso" \
            DOS_PROGRAMS_DIR=/mnt/data/Systems/DOS/MS-DOS/Programs sh /usr/lib/usos/dos_csmwrap_target.sh
    else
        set -- env TARGET_DEVICE="$TARGET_DEVICE" W9X_SOURCE_ISO="/mnt/data/$iso" W9X_SETUP_FOLDER="$setup" W9X_TAG="$tag" \
            W9X_ANSWER_INF="$answer_inf" W9X_ANSWER_KIND="$answer_kind" W9X_BOOT_FLOPPY="$floppy" W9X_SIZE_GIB="$size_gib" \
            W9X_USB_DIR="/mnt/data/Drivers/$folder/USB" W9X_VM_PHASE1="$([ "$vm_phase1" = yes ] && echo 1 || echo 0)"             sh /usr/lib/usos/w9x_csmwrap_target.sh
    fi
    if ! "$@" >> "$W9X_DIR/prepare.log" 2>&1 < /dev/null; then
        rm -f "$answer_inf"
        tail -n 5 "$W9X_DIR/prepare.log" 2>/dev/null || true
        stop 'The Windows 9x preparation failed; see EFI/USOS/win9x/prepare.log'
    fi
    rm -f "$answer_inf"
    if [ "$vm_phase1" = yes ]; then
        w9x_phase1_progress() {
            usos_ui_stage 5 5 "$folder installation - stage 1 in the background"                 "Do not turn off the computer. Elapsed: $(printf '%d:%02d' $(($1 / 60)) $(($1 % 60))), written to disk: $2 MB." || true
        }
        accel=$(w9x_vm_accel)
        w9x_csmwrap_log "PHASE1 start target=$TARGET_DEVICE accel=$accel guest_mb=$W9X_VM_GUEST_MB timeout=$W9X_VM_TIMEOUT"
        w9x_phase1_run "$TARGET_DEVICE" "$accel"
        vm_rc=$?
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
