# Vista SP2 x64 without firmware CSM (profile vista-x64-sp2-uefi-csmwrap,
# experimental; docs/design/csmwrap-integration.md section 10).
# Sourced by pipeline step 610. The UEFI menu already validated the Vista ISO
# and the PE10 donor (hash) and wrote EFI/USOS/vista-csmwrap/request.ini and
# usos-source.ini (the same DATA binding the wimboot start injects).
#
# The user picks the target disk (XP disk picker, the USOS stick and read-only
# disks are never offered, nothing is picked automatically) and confirms the
# erase on the XP "FORMAT THE ENTIRE DISK?" screen; tools/vista_csmwrap_target.sh
# then writes that disk only (MBR, PE10 staging partition, CSMWrap ESP). The
# USOS stick stays connected: PE10 opens the Vista ISO on DATA, as on UEFI.
#
# Screens: the UEFI menu's progress page continues here (stages 3-5 of
# VistaCsmwrapStage, tools/micro_linux_ui.sh); /dev/console is the serial
# port (vista_preparation.formatCommand), every tool writes to prepare.log.
#
# profile=win-x86-uefi-csmwrap in request.ini (32-bit Windows 8.1 / 10,
# design doc section 11): no donor (donor= is the Windows ISO itself), the
# target script runs with X86_SELF=1 and prepares the Windows partition too.

vista_csmwrap_log() {
    printf '[VISTA_CSMWRAP] %s\n' "$*"
    printf '%s\n' "$*" >> "$VISTA_CSMWRAP_DIR/prepare.log" 2>/dev/null || true
}

vista_csmwrap_value() {
    awk -F= -v key="$1" '{ sub(/\r$/, "") } $1 == key { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$2"
}

# First 8.1/10 trial only: scoped DATA opt-in. Older x86 paths are unchanged.
# x64 hook: codex/nvme-vista-x64 adds vista_nvme64_enabled (profile
# vista-x64-sp2-uefi-csmwrap, same flag file) next to this; keep both scoped
# by profile so one flag never opens the other architecture.
vista_modern_nvme_enabled() {
    [ "$1" = win-x86-uefi-csmwrap ] || return 1
    case "$3" in 'Windows 10'|'Windows 8.1'|'Windows Embedded 8.1 Industry') ;; *) return 1 ;; esac
    [ -f "$2/Systems/Windows/$3/Unattended/nvme-experimental.txt" ]
}

# External PE10 is accepted only for the same opted-in 8.1 experiment.
vista_modern_external_donor_enabled() {
    case "$3" in 'Windows 8.1'|'Windows Embedded 8.1 Industry') ;; *) return 1 ;; esac
    vista_modern_nvme_enabled "$@"
}

usos_vista_csmwrap_prepare() {
    VISTA_CSMWRAP_DIR=/mnt/esp/EFI/USOS/vista-csmwrap
    request=$VISTA_CSMWRAP_DIR/request.ini
    [ -f "$request" ] || stop 'the Vista CSMWrap request is missing on the USOS ESP'
    # The previous run's log stays as prepare.log.previous (X470 2026-10-13:
    # a retry after a failed run overwrote the first diagnosis).
    mv -f "$VISTA_CSMWRAP_DIR/prepare.log" "$VISTA_CSMWRAP_DIR/prepare.log.previous" 2>/dev/null || true
    : > "$VISTA_CSMWRAP_DIR/prepare.log" 2>/dev/null || true
    [ -d /sys/firmware/efi ] || stop 'the Vista CSMWrap preparation requires UEFI'
    for helper in target_disk_identity.sh xp_confirmation_ui.sh xp_menu_ui.sh xp_disk_overview.sh xp_detect_system.sh vista_csmwrap_target.sh answer_plan.sh target_disk_wait.sh; do
        [ -r "/usr/lib/usos/$helper" ] || stop "$helper is missing"
    done
    . /usr/lib/usos/target_disk_identity.sh
    . /usr/lib/usos/target_disk_wait.sh
    . /usr/lib/usos/xp_confirmation_ui.sh
    . /usr/lib/usos/answer_plan.sh
    xp_stage_set() { :; }

    iso=$(vista_csmwrap_value iso "$request") || stop 'request.ini has no iso'
    donor=$(vista_csmwrap_value donor "$request") || stop 'request.ini has no donor'
    folder=$(vista_csmwrap_value folder "$request") || folder='Windows Vista'
    answer=$(vista_csmwrap_value answer "$request") || answer=none
    profile=$(vista_csmwrap_value profile "$request") || profile=vista-x64-sp2-uefi-csmwrap
    case "$profile" in
        vista-x64-sp2-uefi-csmwrap) x86_self=0 ;;
        win-x86-uefi-csmwrap) x86_self=1 ;;
        # 32-bit Windows 7 / Vista / Server 2008 (design doc section 12): the
        # same layout, the x86 PE10 donor is the staged WinPE.
        win-nt6-x86-uefi-csmwrap) x86_self=1; [ "$donor" != "$iso" ] || stop 'request.ini: the 32-bit Windows 7 / Vista path needs an x86 PE10 donor' ;;
        *) stop 'request.ini has an unknown profile' ;;
    esac
    for value in "$iso" "$donor" "$folder" "$answer"; do
        case "$value" in *..*|/*) stop 'request.ini has an unsafe path' ;; esac
    done
    vista_csmwrap_log "REQUEST profile=$profile iso=$iso donor=$donor folder=$folder answer=${answer%%:*}"
    # "Windows Vista" or "Windows Server 2008": the heading of the UEFI page too.
    # x86: the DATA folder ("Windows 10", "Windows 8.1", ...).
    if [ "$x86_self" = 1 ]; then NT5_NAME=$folder
    else case "$folder" in 'Windows Server 2008') NT5_NAME=$folder ;; *) NT5_NAME='Windows Vista' ;; esac
    fi
    NT5_TITLE=$(printf '%s' "$NT5_NAME" | tr '[:lower:]' '[:upper:]')
    USOS_UI_HEADING=$NT5_NAME
    export NT5_TITLE NT5_NAME USOS_UI_HEADING
    usos_ui_stage 3 5 'Detecting disks' 'The disk will only be changed after your confirmation.' || true

    DEVICE_INI=/mnt/esp/EFI/USOS/usos-device.ini
    DATA_PARTUUID=$(awk -F= '$1 == "data_partuuid" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$DEVICE_INI") || stop 'DATA PARTUUID missing'
    DATA_PATH=$(wait_for_partuuid_path "$DATA_PARTUUID") || stop "DATA partition not found: $DATA_PARTUUID"
    modprobe ntfs3 2>/dev/null || true
    mkdir -p /mnt/data
    mount -t ntfs3 -o ro,noatime "$DATA_PATH" /mnt/data || stop 'cannot mount USOS_DATA read-only'
    [ -f "/mnt/data/$iso" ] || stop "the Windows ISO is not on DATA: $iso"
    [ -f "/mnt/data/$donor" ] || stop "the PE10 donor is not on DATA: $donor"
    if [ "$profile" = win-x86-uefi-csmwrap ] && [ "$donor" != "$iso" ]; then
        vista_modern_external_donor_enabled "$profile" /mnt/data "$folder" || stop 'request.ini: external x86 PE10 requires the opted-in Windows 8.1 NVMe experiment'
    fi

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
    # Storage drivers may still be probing: wait for a non-USOS disk (10 s; up
    # to 60 s while an NVMe controller has no disk yet, tools/target_disk_wait.sh).
    usos_target_disk_wait "$USOS_DISK_DEVICE" vista_csmwrap_log 3 5 || true
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
    if [ "$index" -eq 0 ]; then
        # X470 2026-10-13: the log said only "REJECT USOS stick"; keep the
        # disks, PCI storage controllers and kernel messages for the report.
        usos_target_disk_report | usos_stick_write usos_esp_append "$VISTA_CSMWRAP_DIR/prepare.log" || true
        stop "$(usos_target_disk_stop)"
    fi
    [ "$index" -gt 0 ] || stop 'No target disk found (only the USOS stick). No disk was changed.'

    # Why the disk is chosen now (on the picker itself), then the XP erase
    # confirmation with the disk's model, size and partitions.
    if [ "$x86_self" = 1 ]; then
        USOS_XP_DISK_NOTE="Without CSM, $NT5_NAME starts through CSMWrap, so USOS prepares the target disk first."
    else
        USOS_XP_DISK_NOTE='Without CSM, Vista starts through CSMWrap, so USOS must first prepare the target disk.'
    fi
    export USOS_XP_DISK_NOTE
    while :; do
        TARGET_DEVICE=''
        pe_nvme=''
        usos_xp_choose_disk
        # NVMe target gate (docs/nvme-nt6-2026-10-12.md sections 12, 15, 17),
        # before the erase confirmation. Windows 7 / Vista / Server 2008 x86
        # (win-nt6-x86-uefi-csmwrap): the polled usosnvme replaces stornvme in
        # the PE10 donor image (USOS_PE_NVME=usosnvme for
        # vista_csmwrap_target.sh) and serves the installed system; X470
        # Micron 3400 PASS 2026-10-14 for Windows 7 SP1 x86 and Vista SP2 x86
        # (B261014-195920), Server 2008 x86 shares the Vista path. No
        # nvme-experimental.txt is needed any more. 8.1 / 10 x86 run
        # Microsoft's stornvme in Setup itself, which failed on the X470
        # under CSMWrap (2026-10-13, section 12), so they still stop here.
        # 64-bit Vista / 2008 would need a signed x64 driver. The 512-byte
        # LBA check applies.
        case "$TARGET_DEVICE" in /dev/nvme*)
            nvme_lbs=$(cat "/sys/class/block/${TARGET_DEVICE##*/}/queue/logical_block_size" 2>/dev/null || echo unknown)
            vista_csmwrap_log "NVME $TARGET_DEVICE logical_block=$nvme_lbs profile=$profile folder=$folder"
            [ "$x86_self" = 1 ] || stop "No NVMe driver for 64-bit $NT5_NAME yet (it would need a signed x64 driver). Pick a SATA disk. No disk was changed."
            case "$profile" in
                win-nt6-x86-uefi-csmwrap)
                    vista_csmwrap_log "NVME $folder x86: usosnvme in the WinPE and the installed system, WinPE lowmem"
                    pe_nvme=usosnvme ;;
                win-x86-uefi-csmwrap)
                    vista_modern_nvme_enabled "$profile" /mnt/data "$folder" || stop '32-bit Windows 8.1/10 on NVMe is not supported yet on this path. No disk was changed.'
                    pe_nvme=usosnvme-modern
                    vista_csmwrap_log 'NVME x86 modern: experimental PE, installed system and WinRE path' ;;
            esac
            [ "$nvme_lbs" = 512 ] || stop "The NVMe disk uses $nvme_lbs-byte sectors; $NT5_NAME through CSMWrap needs 512-byte sectors (switch the namespace to a 512-byte LBA format first). No disk was changed." ;;
        esac
        model=$(usos_disk_model "$TARGET_DEVICE" || true)
        serial=$(usos_disk_serial "$TARGET_DEVICE" || true)
        size=$(usos_disk_size "$TARGET_DEVICE")
        overview=/run/vista-disk-overview.txt
        screen=/run/vista-disk-confirm.txt
        usos_ui_stage 3 5 'Inspecting disk' 'Reading partitions, free space and system files.' || true
        # Read-only (loop devices, ro mounts); failure only means "unknown".
        if ! TARGET_DEVICE=$TARGET_DEVICE sh /usr/lib/usos/xp_disk_overview.sh > "$overview" 2>> "$VISTA_CSMWRAP_DIR/prepare.log"; then
            { printf 'Disk: %s\n' "$model"; usos_disk_type_line "$TARGET_DEVICE"; printf 'S/N: %s\nSize: %s GiB\n' "$serial" "$((size / 1073741824))"; } > "$overview"
        fi
        # The layout vista_csmwrap_target.sh writes (same arithmetic): the
        # whole partition table is replaced (both GPT copies and the MBR are
        # cleared), the staging and CSMWrap partitions sit at the end and the
        # rest is left unallocated for Setup.
        total=$((size / 512))
        esp_start=$(( (total - 133120 + 2047) / 2048 * 2048 ))
        staging_start=$(( (esp_start - 2097152) / 2048 * 2048 ))
        free_gib=$(( (staging_start - 2048) / 2097152 ))
        [ "$free_gib" -ge 0 ] 2>/dev/null || free_gib=0
        {
            printf 'ERASE ALL DATA ON THIS DISK\n\n'
            cat "$overview"
            printf '\n'
            printf 'All partitions, systems and files on this disk will be erased.\n'
            # Every path (Vista x64 too since 2026-10-11): the Windows
            # partition is made here and Setup installs to it (InstallTo), so
            # this is the only disk question. The 1 GiB helper partition
            # before the ESP is removed after Setup.
            printf 'New layout (MBR): %s (drive C:) for %s, then a 64 MiB CSMWrap partition at the end of the disk; the rest stays unallocated.\n' "$free_gib GiB NTFS" "$NT5_NAME"
        } > "$screen"
        vista_csmwrap_log "CONFIRM $TARGET_DEVICE model=$model serial=$serial size=$size free_gib=$free_gib"
        usos_xp_confirm "$screen" 'FORMAT THE ENTIRE DISK?' 'Erase ALL partitions and data on the selected disk' && break
        vista_csmwrap_log "CONFIRM $TARGET_DEVICE cancelled; no disk was changed"
    done
    [ "$TARGET_DEVICE" != "$USOS_DISK_DEVICE" ] || stop 'refusing the USOS disk'
    vista_csmwrap_log "TARGET $TARGET_DEVICE model=$model serial=$serial size=$size confirmed"

    # Every tool's output goes to prepare.log (none reaches the screen); the
    # stage-4 page stays up until the script ends.
    usos_ui_stage 4 5 'Preparing the disk' 'Copying the Windows PE helper and CSMWrap to the selected disk.' || true
    if ! TARGET_DEVICE=$TARGET_DEVICE VISTA_DONOR_ISO="/mnt/data/$donor" VISTA_REQUEST_DIR=$VISTA_CSMWRAP_DIR VISTA_ANSWER_XML=$answer_xml X86_SELF=$x86_self USOS_PE_NVME=$pe_nvme \
        sh /usr/lib/usos/vista_csmwrap_target.sh >> "$VISTA_CSMWRAP_DIR/prepare.log" 2>&1 < /dev/null; then
        rm -f /run/vista-answer.xml
        tail -n 5 "$VISTA_CSMWRAP_DIR/prepare.log" 2>/dev/null || true
        stop "The $NT5_NAME CSMWrap preparation failed; see EFI/USOS/vista-csmwrap/prepare.log"
    fi
    rm -f /run/vista-answer.xml
    mv "$request" "$VISTA_CSMWRAP_DIR/request.done" 2>/dev/null || true
    # How to log on afterwards (logon.ini from the menu, docs/logon-after-install.md).
    usos_logon_take /mnt/esp || true
    usos_logon_save /mnt/data "$(usos_logon_dir_of "$iso")" || true
    umount /mnt/data 2>/dev/null || true
    sync
    vista_csmwrap_log 'DONE; waiting for the restart'
    # Stage 5 (restart into Windows Setup): the notice page, every stage done.
    if [ "$x86_self" = 1 ]; then
        usos_ui_notice_continue "$NT5_NAME: start the prepared disk" "After the restart the firmware starts this disk's UEFI entry (CSMWrap; CSM stays off) and the $NT5_NAME installation continues on it. If the USOS stick starts instead, pick the disk in the firmware boot menu." 'Restart' || true
    else
        usos_ui_notice_continue 'Windows Vista: start the prepared disk' "Keep the USOS stick connected. After the restart open the firmware boot menu and start this disk's UEFI entry (not Legacy); CSM stays off. Vista Setup then starts from it through CSMWrap." 'Restart' || true
    fi
    # The notice waits for the user: the stick volumes read-only meanwhile
    # (a power-off here leaves the ESP clean).
    sh /usr/lib/usos/stick_release.sh ro
    if [ -r "${USOS_UI_TTY:-}" ]; then
        IFS= read -r _vista_ack < "$USOS_UI_TTY" || true
    else
        IFS= read -r _vista_ack || true
    fi
    sync
    sh /usr/lib/usos/stick_release.sh reboot
    while :; do sleep 3600; done
}
