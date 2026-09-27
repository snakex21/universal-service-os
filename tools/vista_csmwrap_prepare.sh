# Vista SP2 x64 without firmware CSM (profile vista-x64-sp2-uefi-csmwrap,
# experimental; docs/design/csmwrap-integration.md section 10).
# Sourced by pipeline step 610. The UEFI menu already validated the Vista ISO
# and the PE10 donor (hash) and wrote EFI/USOS/vista-csmwrap/request.ini and
# usos-source.ini (the same DATA binding the wimboot start injects).
#
# The user picks the target disk (XP disk picker, the USOS stick and read-only
# disks are never offered) and confirms the wipe; tools/vista_csmwrap_target.sh
# then writes that disk only (MBR, PE10 staging partition, CSMWrap ESP). The
# USOS stick stays connected: PE10 opens the Vista ISO on DATA, as on UEFI.

vista_csmwrap_log() {
    printf '[VISTA_CSMWRAP] %s\n' "$*"
    printf '%s\n' "$*" >> "$VISTA_CSMWRAP_DIR/prepare.log" 2>/dev/null || true
}

vista_csmwrap_value() {
    awk -F= -v key="$1" '{ sub(/\r$/, "") } $1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$2"
}

usos_vista_csmwrap_prepare() {
    VISTA_CSMWRAP_DIR=/mnt/esp/EFI/USOS/vista-csmwrap
    request=$VISTA_CSMWRAP_DIR/request.ini
    [ -f "$request" ] || stop 'the Vista CSMWrap request is missing on the USOS ESP'
    : > "$VISTA_CSMWRAP_DIR/prepare.log" 2>/dev/null || true
    [ -d /sys/firmware/efi ] || stop 'the Vista CSMWrap preparation requires UEFI'
    for helper in target_disk_identity.sh xp_confirmation_ui.sh xp_menu_ui.sh vista_csmwrap_target.sh answer_plan.sh; do
        [ -r "/usr/lib/usos/$helper" ] || stop "$helper is missing"
    done
    . /usr/lib/usos/target_disk_identity.sh
    . /usr/lib/usos/xp_confirmation_ui.sh
    . /usr/lib/usos/answer_plan.sh
    NT5_TITLE='WINDOWS VISTA'
    NT5_NAME='Windows Vista'
    export NT5_TITLE NT5_NAME
    xp_stage_set() { :; }

    iso=$(vista_csmwrap_value iso "$request") || stop 'request.ini has no iso'
    donor=$(vista_csmwrap_value donor "$request") || stop 'request.ini has no donor'
    folder=$(vista_csmwrap_value folder "$request") || folder='Windows Vista'
    answer=$(vista_csmwrap_value answer "$request") || answer=none
    for value in "$iso" "$donor" "$folder" "$answer"; do
        case "$value" in *..*|/*) stop 'request.ini has an unsafe path' ;; esac
    done
    vista_csmwrap_log "REQUEST iso=$iso donor=$donor folder=$folder answer=${answer%%:*}"

    DEVICE_INI=/mnt/esp/EFI/USOS/usos-device.ini
    DATA_PARTUUID=$(awk -F= '$1 == "data_partuuid" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$DEVICE_INI") || stop 'DATA PARTUUID missing'
    DATA_PATH=$(wait_for_partuuid_path "$DATA_PARTUUID") || stop "DATA partition not found: $DATA_PARTUUID"
    modprobe ntfs3 2>/dev/null || true
    mkdir -p /mnt/data
    mount -t ntfs3 -o ro,noatime "$DATA_PATH" /mnt/data || stop 'cannot mount USOS_DATA read-only'
    [ -f "/mnt/data/$iso" ] || stop "the Vista ISO is not on DATA: $iso"
    [ -f "/mnt/data/$donor" ] || stop "the PE10 donor is not on DATA: $donor"

    answer_xml=''
    case "$answer" in
        none) ;;
        profile)
            answer_xml=/run/vista-answer.xml
            usos_answer_plan_take /mnt/esp/EFI/USOS/answer/usos-plan.ini autounattend_xml "$answer_xml" || stop 'the answer profile could not be taken'
            ;;
        file:*)
            name=${answer#file:}
            case "$name" in */*|'') stop 'request.ini has an unsafe answer file name' ;; esac
            answer_xml="/mnt/data/Systems/Windows/$folder/Unattended/$name"
            [ -f "$answer_xml" ] || stop "the answer file is not on DATA: $name"
            ;;
        *) stop 'request.ini has an unknown answer kind' ;;
    esac

    ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_PATH" 2>/dev/null | head -n 1)
    [ -n "$ESP_PARENT" ] || stop 'cannot resolve the USOS disk'
    USOS_DISK_DEVICE="/dev/$ESP_PARENT"
    CANDIDATES=/run/vista-candidates
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
            vista_csmwrap_log "DISK $candidate REJECT USOS stick"
        elif [ "$ro" = 1 ]; then
            vista_csmwrap_log "DISK $candidate REJECT read-only"
        else
            index=$((index + 1))
            printf '%s|%s\n' "$index" "$candidate" >> "$CANDIDATES"
            vista_csmwrap_log "DISK $candidate ACCEPT index=$index model=$(usos_disk_model "$candidate" || true) size=$(usos_disk_size "$candidate" || true)"
        fi
    done
    [ "$index" -gt 0 ] || stop 'No target disk found (only the USOS stick). No disk was changed.'

    while :; do
        TARGET_DEVICE=''
        usos_xp_choose_disk
        model=$(usos_disk_model "$TARGET_DEVICE" || true)
        serial=$(usos_disk_serial "$TARGET_DEVICE" || true)
        size=$(usos_disk_size "$TARGET_DEVICE")
        screen=/run/vista-disk-confirm.txt
        {
            printf 'Disk: %s\nS/N: %s\nSize: %s GiB\n\n' "$model" "$serial" "$((size / 1073741824))"
            printf 'All partitions, systems and files on this disk will be erased.\n'
            printf 'Vista without CSM: USOS writes the Windows PE helper and a small CSMWrap partition to the end of this disk. In Vista Setup select the unallocated space; do not delete the small partitions.\n'
        } > "$screen"
        usos_xp_confirm "$screen" 'WINDOWS VISTA - CONFIRM INSTALLATION' 'Erase this disk and prepare Windows Vista' && break
    done
    [ "$TARGET_DEVICE" != "$USOS_DISK_DEVICE" ] || stop 'refusing the USOS disk'
    vista_csmwrap_log "TARGET $TARGET_DEVICE model=$model serial=$serial size=$size confirmed"
    usos_ui_stage 4 5 'Preparing the disk' 'Copying the Windows PE helper and CSMWrap to the selected disk.' || true

    TARGET_DEVICE=$TARGET_DEVICE VISTA_DONOR_ISO="/mnt/data/$donor" VISTA_REQUEST_DIR=$VISTA_CSMWRAP_DIR VISTA_ANSWER_XML=$answer_xml \
        sh /usr/lib/usos/vista_csmwrap_target.sh >> "$VISTA_CSMWRAP_DIR/prepare.log" 2>&1 || {
        rm -f /run/vista-answer.xml
        tail -n 5 "$VISTA_CSMWRAP_DIR/prepare.log" 2>/dev/null || true
        stop 'The Vista CSMWrap preparation failed; see EFI/USOS/vista-csmwrap/prepare.log'
    }
    rm -f /run/vista-answer.xml
    mv "$request" "$VISTA_CSMWRAP_DIR/request.done" 2>/dev/null || true
    umount /mnt/data 2>/dev/null || true
    sync
    vista_csmwrap_log 'DONE; waiting for the restart'
    usos_ui_stage 5 5 'Disk prepared' 'Keep the USOS stick connected.' || true
    usos_ui_notice_continue 'Windows Vista: start the prepared disk' "Keep the USOS stick connected. After the restart open the firmware boot menu and start this disk's UEFI entry (not Legacy); CSM stays off. Vista Setup then starts from it through CSMWrap." 'Restart' || true
    if [ -r "${USOS_UI_TTY:-}" ]; then
        IFS= read -r _vista_ack < "$USOS_UI_TTY" || true
    else
        IFS= read -r _vista_ack || true
    fi
    sync
    reboot -f 2>/dev/null || true
    sleep 3
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
    while :; do sleep 3600; done
}
