# Sourced by micro_linux_init.sh. It intentionally does not run on import.

xp_stage_set() {
    XP_STAGE_STATE=$1
    export XP_STAGE_STATE
    status_file=/mnt/esp/EFI/USOS/legacy-xp-staging-status.txt
    tmp_file="$status_file.tmp"
    {
        printf '[LEGACY_XP_STATUS]\n'
        printf 'phase=%s\n' "$XP_STAGE_STATE"
        printf 'image=%s\n' "${XP_IMAGE_NAME:-unknown}"
        printf 'target=%s\n' "${TARGET_DEVICE:-unselected}"
        printf 'uptime=%s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || true)"
    } > "$tmp_file" || stop 'cannot write Legacy XP staging status to ESP'
    mv "$tmp_file" "$status_file" || stop 'cannot publish Legacy XP staging status on ESP'
    sync
}

xp_run_logged() {
    log_name=$1
    shift
    tmp_log="/tmp/$log_name"
    rc_file="/tmp/$log_name.rc"
    rm -f "$tmp_log" "$rc_file"
    (
        if "$@"; then command_rc=0; else command_rc=$?; fi
        printf '%s\n' "$command_rc" > "$rc_file"
    ) 2>&1 | tee "$tmp_log"
    [ -r "$rc_file" ] || return 125
    command_rc=$(cat "$rc_file")
    cp "$tmp_log" "/mnt/esp/EFI/USOS/$log_name" 2>/dev/null || true
    sync
    return "$command_rc"
}

usos_hex_to_ascii() {
    hex=$1
    case "$hex" in
        ''|*[!0-9A-Fa-f]*) return 1 ;;
    esac
    [ $(( ${#hex} % 2 )) -eq 0 ] || return 1
    decoded=''
    while [ -n "$hex" ]; do
        pair=$(printf '%s' "$hex" | cut -c1-2)
        hex=$(printf '%s' "$hex" | cut -c3-)
        value=$((0x$pair))
        [ "$value" -ne 0 ] || return 1
        octal=$(printf '%03o' "$value")
        decoded=$decoded$(printf "\\$octal")
    done
    printf '%s' "$decoded"
}

usos_legacy_xp_staging() {
    . /usr/lib/usos/nt5_profile.sh
    usos_nt5_profile || stop 'Unsupported NT5 source profile'
    image_hex=$1
    unattended_hex=${2:-}
    [ -n "$image_hex" ] || stop 'Legacy XP request has no image name'
    XP_IMAGE_NAME=$(usos_hex_to_ascii "$image_hex") || stop 'Legacy XP image name hex is invalid'
    case "$XP_IMAGE_NAME" in
        */*|*\\*) stop 'Legacy XP image request must contain a file name only' ;;
        *.iso|*.ISO) ;;
        *) stop "Legacy XP image is not an ISO: $XP_IMAGE_NAME" ;;
    esac

    printf '[LEGACY_XP] REQUEST backend=xp-staging image=%s\n' "$XP_IMAGE_NAME"
    printf '[LEGACY_XP] BACKEND prepare_xp_target.sh\n'
    xp_stage_set source-discovery

    DEVICE_INI=/mnt/esp/EFI/USOS/usos-device.ini
    [ -f "$DEVICE_INI" ] || stop 'usos-device.ini missing for Legacy XP staging'
    DATA_PARTUUID=$(awk -F= '$1 == "data_partuuid" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$DEVICE_INI") || stop 'DATA PARTUUID missing for Legacy XP staging'
    DATA_PATH=$(wait_for_partuuid_path "$DATA_PARTUUID") || stop "DATA PARTUUID path missing for Legacy XP staging: $DATA_PARTUUID"

    NTFS3_MODULE=$(module_path 'kernel/fs/ntfs3/ntfs3.ko') || true
    [ -n "$NTFS3_MODULE" ] || stop 'ntfs3 module missing for Legacy XP staging'
    modprobe nls_utf8 2>/dev/null || true
    insmod "$NTFS3_MODULE" 2>/dev/null || true
    mkdir -p /mnt/data /mnt/source /mnt/xpsetup
    mount -t ntfs3 -o ro,noatime "$DATA_PATH" /mnt/data || stop 'cannot mount USOS_DATA read-only for Legacy XP staging'
    XP_IMAGE_PATH="/mnt/data/Systems/Windows/$NT5_NAME/Images/$XP_IMAGE_NAME"
    [ -f "$XP_IMAGE_PATH" ] || stop "selected XP ISO not found on DATA: $XP_IMAGE_NAME"
    printf '[LEGACY_XP] SOURCE PASS path=Systems/Windows/%s/Images/%s\n' "$NT5_NAME" "$XP_IMAGE_NAME"

    XP_WINNT_SIF=''
    if [ -n "$unattended_hex" ]; then
        XP_UNATTENDED_NAME=$(usos_hex_to_ascii "$unattended_hex") || stop 'Legacy XP unattended name hex is invalid'
        case "$XP_UNATTENDED_NAME" in
            */*|*\\*) stop 'Legacy XP unattended request must contain a file name only' ;;
        esac
        XP_UNATTENDED_LOWER=$(printf '%s' "$XP_UNATTENDED_NAME" | tr '[:upper:]' '[:lower:]')
        case "$XP_UNATTENDED_LOWER" in
            *.sif) ;;
            *) stop "Legacy XP unattended file is not .sif: $XP_UNATTENDED_NAME" ;;
        esac
        XP_WINNT_SIF="/mnt/data/Systems/Windows/$NT5_NAME/Unattended/$XP_UNATTENDED_NAME"
        [ -f "$XP_WINNT_SIF" ] || stop "selected XP WINNT.SIF not found on DATA: $XP_UNATTENDED_NAME"
        [ -r /usr/lib/usos/xp_unattended_policy.sh ] || stop 'xp_unattended_policy.sh is missing'
        . /usr/lib/usos/xp_unattended_policy.sh
        XP_SIF_RISKS=$(usos_xp_sif_risks "$XP_WINNT_SIF") || stop 'cannot inspect selected XP WINNT.SIF'
        if [ -n "$XP_SIF_RISKS" ]; then
            printf '[LEGACY_XP] UNATTENDED WARNING selected=%s contains partition automation directives:\n' "$XP_UNATTENDED_NAME"
            printf '%s\n' "$XP_SIF_RISKS" | sed 's/^/[LEGACY_XP] UNATTENDED WARNING   /'
            printf '[LEGACY_XP] UNATTENDED WARNING Setup could select XPSETUP or another partition without asking.\n'
            stop 'unsafe WINNT.SIF refused; remove AutoPartition=1/Repartition=Yes so partition selection remains manual'
        fi
        printf '[LEGACY_XP] UNATTENDED PASS selected=%s partition_selection=manual product_key=user-controlled\n' "$XP_UNATTENDED_NAME"
    else
        printf '[LEGACY_XP] UNATTENDED none; minimal WINNT.SIF will be generated without ProductKey\n'
    fi
    export XP_WINNT_SIF

    xp_stage_set disk-enumeration
    usos_ui_stage 2 5 'Verifying target device' "Enumerating disks and validating the selected $NT5_NAME target." || true
    [ -r /usr/lib/usos/target_disk_identity.sh ] || stop 'target_disk_identity.sh is missing'
    . /usr/lib/usos/target_disk_identity.sh
    [ -x /usr/lib/usos/target_disk_guard.sh ] || stop 'target_disk_guard.sh is missing'
    [ -x /usr/lib/usos/prepare_xp_target.sh ] || stop 'prepare_xp_target.sh is missing'

    ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_PATH" 2>/dev/null | head -n 1)
    [ -n "$ESP_PARENT" ] || stop 'cannot resolve USOS parent disk for Legacy XP staging'
    USOS_DISK_DEVICE="/dev/$ESP_PARENT"

    XP_DISK_DIAG=/run/legacy-xp-disk-enumeration.txt
    : > "$XP_DISK_DIAG"
    xp_disk_log() {
        printf '%s\n' "$1" | tee -a "$XP_DISK_DIAG"
    }

    xp_storage_hardware_diag() {
        xp_disk_log '[LEGACY_XP] SYSFS BLOCK INVENTORY BEGIN'
        for block in /sys/class/block/*; do
            [ -e "$block" ] || continue
            name=${block##*/}
            dev=$(cat "$block/dev" 2>/dev/null || true)
            size=$(cat "$block/size" 2>/dev/null || true)
            removable=$(cat "$block/removable" 2>/dev/null || true)
            xp_disk_log "[LEGACY_XP] SYSFS BLOCK name=$name dev=$dev sectors=$size removable=$removable"
        done
        xp_disk_log '[LEGACY_XP] SYSFS BLOCK INVENTORY END'

        xp_disk_log '[LEGACY_XP] PCI STORAGE INVENTORY BEGIN'
        pci_storage_count=0
        for pci in /sys/bus/pci/devices/*; do
            [ -d "$pci" ] || continue
            class=$(cat "$pci/class" 2>/dev/null || true)
            case "$class" in
                0x01*) ;;
                *) continue ;;
            esac
            pci_storage_count=$((pci_storage_count + 1))
            vendor=$(cat "$pci/vendor" 2>/dev/null || true)
            device=$(cat "$pci/device" 2>/dev/null || true)
            subsystem_vendor=$(cat "$pci/subsystem_vendor" 2>/dev/null || true)
            subsystem_device=$(cat "$pci/subsystem_device" 2>/dev/null || true)
            modalias=$(cat "$pci/modalias" 2>/dev/null || true)
            driver='none'
            if [ -L "$pci/driver" ]; then driver=$(basename "$(readlink "$pci/driver")"); fi
            xp_disk_log "[LEGACY_XP] PCI STORAGE bdf=${pci##*/} class=$class vendor=$vendor device=$device subsystem_vendor=$subsystem_vendor subsystem_device=$subsystem_device driver=$driver modalias=$modalias"
        done
        xp_disk_log "[LEGACY_XP] PCI STORAGE INVENTORY END detected=$pci_storage_count"

        xp_disk_log '[LEGACY_XP] STORAGE MODULE FILES BEGIN'
        module_matches=$(find /usr/lib/modules -type f -name '*.ko' 2>/dev/null | grep -Ei '/(ata|sata|pata|ahci|ide|scsi|nvme)[^/]*\.ko$' || true)
        if [ -n "$module_matches" ]; then
            printf '%s\n' "$module_matches" | sed 's/^/[LEGACY_XP] MODULE FILE /' | tee -a "$XP_DISK_DIAG" || true
        else
            xp_disk_log '[LEGACY_XP] MODULE FILE none matching ata/sata/pata/ahci/ide/scsi/nvme'
        fi
        xp_disk_log '[LEGACY_XP] STORAGE MODULE FILES END'

        xp_disk_log '[LEGACY_XP] LOADED MODULES BEGIN'
        if [ -r /proc/modules ]; then sed 's/^/[LEGACY_XP] MODULE LOADED /' /proc/modules | tee -a "$XP_DISK_DIAG" || true; fi
        xp_disk_log '[LEGACY_XP] LOADED MODULES END'

        xp_disk_log '[LEGACY_XP] DMESG BEGIN'
        dmesg 2>/dev/null | sed 's/^/[LEGACY_XP] DMESG /' | tee -a "$XP_DISK_DIAG" || true
        xp_disk_log '[LEGACY_XP] DMESG END'
    }

    xp_disk_log 'LEGACY XP DISK ENUMERATION'
    BIOS_GEOMETRY=/run/legacy-xp-bios-geometry
    : > "$BIOS_GEOMETRY"
    bios_detected=0
    bios_non_usos=0
    if [ -z "${BIOS_DISKS:-}" ]; then
        xp_disk_log '[LEGACY_XP] BIOS INVENTORY unavailable: kernel command line has no usos.bios_disks'
    else
        old_ifs=$IFS
        IFS=,
        for bios_record in $BIOS_DISKS; do
            drive_hex=$(printf '%s' "$bios_record" | cut -d: -f1)
            status_hex=$(printf '%s' "$bios_record" | cut -d: -f2)
            sectors_hex=$(printf '%s' "$bios_record" | cut -d: -f3)
            bps_hex=$(printf '%s' "$bios_record" | cut -d: -f4)
            cylinders_hex=$(printf '%s' "$bios_record" | cut -d: -f5)
            heads_hex=$(printf '%s' "$bios_record" | cut -d: -f6)
            spt_hex=$(printf '%s' "$bios_record" | cut -d: -f7)
            bios_detected=$((bios_detected + 1))
            if [ "$drive_hex" = "${BIOS_BOOT_DRIVE:-}" ]; then
                bios_decision='REJECT reason=USOS-boot-drive'
            else
                bios_decision='ACCEPT reason=non-USOS-BIOS-drive'
                bios_non_usos=$((bios_non_usos + 1))
            fi
            case "$status_hex" in
                0)
                    sectors_dec=$((0x$sectors_hex))
                    bps_dec=$((0x$bps_hex))
                    bytes_dec=$((sectors_dec * bps_dec))
                    cylinders_dec=0
                    heads_dec=0
                    spt_dec=0
                    if [ -n "$cylinders_hex" ] && [ -n "$heads_hex" ] && [ -n "$spt_hex" ]; then
                        cylinders_dec=$((0x$cylinders_hex))
                        heads_dec=$((0x$heads_hex))
                        spt_dec=$((0x$spt_hex))
                    fi
                    if [ "$cylinders_dec" -gt 0 ] && [ "$heads_dec" -gt 0 ] && [ "$spt_dec" -gt 0 ]; then
                        xp_disk_log "[LEGACY_XP] BIOS DISK drive=0x$drive_hex sectors=$sectors_dec bps=$bps_dec bytes=$bytes_dec chs=$cylinders_dec/$heads_dec/$spt_dec $bios_decision"
                        printf '%s|%s|%s|%s|%s\n' "$bytes_dec" "$drive_hex" "$cylinders_dec" "$heads_dec" "$spt_dec" >> "$BIOS_GEOMETRY"
                    else
                        xp_disk_log "[LEGACY_XP] BIOS DISK drive=0x$drive_hex sectors=$sectors_dec bps=$bps_dec bytes=$bytes_dec chs=unavailable $bios_decision"
                    fi
                    ;;
                2)
                    xp_disk_log "[LEGACY_XP] BIOS DISK drive=0x$drive_hex size=unknown edd=no $bios_decision"
                    ;;
                *)
                    xp_disk_log "[LEGACY_XP] BIOS DISK drive=0x$drive_hex size=unknown edd-parameters=FAIL $bios_decision"
                    ;;
            esac
        done
        IFS=$old_ifs
    fi
    xp_disk_log "[LEGACY_XP] BIOS INVENTORY END detected=$bios_detected non_usos=$bios_non_usos boot=0x${BIOS_BOOT_DRIVE:-unknown}"

    CANDIDATES=/run/legacy-xp-candidates
    : > "$CANDIDATES"
    candidate_index=0
    linux_disk_count=0
    xp_disk_log '[LEGACY_XP] LINUX BLOCK INVENTORY BEGIN'
    for candidate in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        linux_disk_count=$((linux_disk_count + 1))
        model=$(usos_disk_model "$candidate" || true)
        serial=$(usos_disk_serial "$candidate" || true)
        size=$(usos_disk_size "$candidate" || true)
        pttype=$(lsblk -dnro PTTYPE "$candidate" 2>/dev/null | head -n 1 || true)
        ro=$(lsblk -dnro RO "$candidate" 2>/dev/null | head -n 1 || true)
        rm=$(lsblk -dnro RM "$candidate" 2>/dev/null | head -n 1 || true)
        if [ "$candidate" = "$USOS_DISK_DEVICE" ]; then
            decision='REJECT reason=USOS-parent-disk'
        else
            candidate_index=$((candidate_index + 1))
            printf '%s|%s\n' "$candidate_index" "$candidate" >> "$CANDIDATES"
            decision="ACCEPT reason=non-USOS-block-disk target_index=$candidate_index"
        fi
        xp_disk_log "[LEGACY_XP] LINUX DISK device=$candidate model=$model serial=$serial size=$size pttype=$pttype rm=$rm ro=$ro $decision"
        lsblk -bnpo NAME,TYPE,SIZE,FSTYPE,LABEL "$candidate" 2>/dev/null | sed 's/^/[LEGACY_XP]   /' | tee -a "$XP_DISK_DIAG" || true
    done
    xp_disk_log "[LEGACY_XP] LINUX BLOCK INVENTORY END detected=$linux_disk_count candidates=$candidate_index usos=$USOS_DISK_DEVICE"
    XP_DISK_DIAG_PERSIST=/mnt/esp/EFI/USOS/legacy-xp-disk-enumeration.txt

    STORAGE_PROBE_INI=/mnt/esp/EFI/USOS/lts-storage-probe.ini
    if [ -f "$STORAGE_PROBE_INI" ]; then
        expected_vendor=$(awk -F= '$1 == "vendor" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }' "$STORAGE_PROBE_INI" 2>/dev/null || true)
        expected_device=$(awk -F= '$1 == "device" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }' "$STORAGE_PROBE_INI" 2>/dev/null || true)
        expected_driver=$(awk -F= '$1 == "driver" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }' "$STORAGE_PROBE_INI" 2>/dev/null || true)
        expected_candidates=$(awk -F= '$1 == "candidates" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }' "$STORAGE_PROBE_INI" 2>/dev/null || true)
        [ -n "$expected_vendor" ] || stop 'LTS storage probe vendor missing'
        [ -n "$expected_device" ] || stop 'LTS storage probe device missing'
        [ -n "$expected_driver" ] || stop 'LTS storage probe driver missing'
        [ -n "$expected_candidates" ] || stop 'LTS storage probe candidates missing'

        xp_storage_hardware_diag
        probe_modalias_ok=0
        probe_driver_ok=0
        probe_bdf=''
        probe_modalias=''
        probe_driver='none'
        for pci in /sys/bus/pci/devices/*; do
            [ -d "$pci" ] || continue
            vendor=$(cat "$pci/vendor" 2>/dev/null || true)
            device=$(cat "$pci/device" 2>/dev/null || true)
            [ "$vendor" = "$expected_vendor" ] || continue
            [ "$device" = "$expected_device" ] || continue
            probe_bdf=${pci##*/}
            probe_modalias=$(cat "$pci/modalias" 2>/dev/null || true)
            if [ -L "$pci/driver" ]; then probe_driver=$(basename "$(readlink "$pci/driver")"); fi
            expected_vendor_hex=$(printf '%s' "$expected_vendor" | sed 's/^0x//' | tr '[:lower:]' '[:upper:]')
            expected_device_hex=$(printf '%s' "$expected_device" | sed 's/^0x//' | tr '[:lower:]' '[:upper:]')
            case "$probe_modalias" in
                pci:v0000${expected_vendor_hex}d0000${expected_device_hex}*) probe_modalias_ok=1 ;;
            esac
            [ "$probe_driver" = "$expected_driver" ] && probe_driver_ok=1
            break
        done

        probe_candidate_ok=0
        probe_candidate_device='none'
        if [ "$candidate_index" -eq "$expected_candidates" ] && [ "$candidate_index" -eq 1 ]; then
            probe_candidate_device=$(cut -d'|' -f2 "$CANDIDATES" | head -n 1)
            case "$probe_candidate_device" in /dev/sd[a-z]|/dev/sd[a-z][a-z]) probe_candidate_ok=1 ;; esac
        fi

        probe_result=FAIL
        if [ "$probe_modalias_ok" -eq 1 ] && [ "$probe_driver_ok" -eq 1 ] && [ "$probe_candidate_ok" -eq 1 ]; then
            probe_result=PASS
        fi
        xp_disk_log "[LTS_PROBE] CHECK1 modalias=$probe_modalias_ok bdf=$probe_bdf value=$probe_modalias"
        xp_disk_log "[LTS_PROBE] CHECK2 driver=$probe_driver_ok value=$probe_driver expected=$expected_driver"
        xp_disk_log "[LTS_PROBE] CHECK3 candidate=$probe_candidate_ok candidates=$candidate_index device=$probe_candidate_device"
        xp_disk_log "[LTS_PROBE] RESULT=$probe_result"
        cp "$XP_DISK_DIAG" "$XP_DISK_DIAG_PERSIST" || stop 'cannot persist Legacy XP disk enumeration diagnostic to ESP'
        cp "$XP_DISK_DIAG" /mnt/esp/EFI/USOS/lts-storage-probe.txt || stop 'cannot persist LTS storage probe result to ESP'
        sync
        usos_ui_diagnostic "$XP_DISK_DIAG" || true
        printf '[LTS_PROBE] AUTOMATIC STORAGE PROBE %s - NO TARGET WRITE OR STAGING OCCURRED\n' "$probe_result"
        while :; do sleep 3600; done
    fi

    if [ "$candidate_index" -eq 0 ]; then
        xp_storage_hardware_diag
        if [ "$bios_non_usos" -gt 0 ]; then
            xp_disk_log '[LEGACY_XP] ENUMERATION RESULT: BIOS sees a non-USOS disk, but micro-Linux exposes no non-USOS block disk.'
        elif [ "$bios_detected" -gt 0 ]; then
            xp_disk_log '[LEGACY_XP] ENUMERATION RESULT: BIOS reports only the USOS boot disk; no non-USOS BIOS drive was detected.'
        else
            xp_disk_log '[LEGACY_XP] ENUMERATION RESULT: BIOS inventory unavailable/empty and micro-Linux exposes no non-USOS block disk.'
        fi
        xp_disk_log "[LEGACY_XP] DIAGNOSTIC PERSIST path=EFI/USOS/legacy-xp-disk-enumeration.txt"
        cp "$XP_DISK_DIAG" "$XP_DISK_DIAG_PERSIST" || stop 'cannot persist Legacy XP disk enumeration diagnostic to ESP'
        sync
        usos_ui_diagnostic "$XP_DISK_DIAG" || true
        printf '[LEGACY_XP] DISK ENUMERATION DIAGNOSTIC FROZEN; no target write has occurred\n'
        enable_emergency_input || true
        exec /bin/sh
    fi

    xp_disk_log "[LEGACY_XP] DIAGNOSTIC PERSIST path=EFI/USOS/legacy-xp-disk-enumeration.txt"
    cp "$XP_DISK_DIAG" "$XP_DISK_DIAG_PERSIST" || stop 'cannot persist Legacy XP disk enumeration diagnostic to ESP'
    sync

    TEST_INI=/mnt/esp/EFI/USOS/legacy-xp-menu-test.ini
    TARGET_DEVICE=''
    TEST_STOP_AFTER_PREPARE='no'
    . /usr/lib/usos/xp_menu_ui.sh
    XP_SOURCE_OPEN=no
    while :; do
    XP_FORMAT_CONFIRMED=no
    if [ -f "$TEST_INI" ]; then
        test_serial=$(awk -F= '$1 == "target_serial" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$TEST_INI") || stop 'Legacy XP menu test target_serial missing'
        TEST_STOP_AFTER_PREPARE=$(awk -F= '$1 == "stop_after_prepare" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; exit }' "$TEST_INI" 2>/dev/null || true)
        [ -n "$TEST_STOP_AFTER_PREPARE" ] || TEST_STOP_AFTER_PREPARE=no
        for candidate in $(cut -d'|' -f2 "$CANDIDATES"); do
            candidate_serial=$(usos_disk_serial "$candidate" || true)
            if [ "$candidate_serial" = "$test_serial" ]; then
                [ -z "$TARGET_DEVICE" ] || stop 'Legacy XP menu test serial matched multiple disks'
                TARGET_DEVICE=$candidate
            fi
        done
        [ -n "$TARGET_DEVICE" ] || stop "Legacy XP menu test target not found by serial=$test_serial"
        printf '[LEGACY_XP] TEST AUTO-SELECT device=%s serial=%s\n' "$TARGET_DEVICE" "$test_serial"
    else
        printf '[LEGACY_XP] PAUSE 1/2 - choose target disk; no disk write has occurred\n'
        usos_xp_choose_disk
    fi

    TARGET_SIZE_FOR_BIOS=$(usos_disk_size "$TARGET_DEVICE")
    bios_geometry_matches=$(awk -F'|' -v wanted="$TARGET_SIZE_FOR_BIOS" '$1 == wanted { count++ } END { print count + 0 }' "$BIOS_GEOMETRY")
    [ "$bios_geometry_matches" -eq 1 ] || stop "selected XP target size maps to $bios_geometry_matches BIOS geometry records; refusing guessed CHS"
    bios_geometry_line=$(awk -F'|' -v wanted="$TARGET_SIZE_FOR_BIOS" '$1 == wanted { print; exit }' "$BIOS_GEOMETRY")
    XP_BIOS_DRIVE=$(printf '%s' "$bios_geometry_line" | cut -d'|' -f2)
    XP_BIOS_CYLINDERS=$(printf '%s' "$bios_geometry_line" | cut -d'|' -f3)
    XP_BIOS_HEADS=$(printf '%s' "$bios_geometry_line" | cut -d'|' -f4)
    XP_BIOS_SPT=$(printf '%s' "$bios_geometry_line" | cut -d'|' -f5)
    [ "$XP_BIOS_HEADS" -ge 1 ] && [ "$XP_BIOS_HEADS" -le 256 ] || stop "invalid BIOS head count for selected XP target: $XP_BIOS_HEADS"
    [ "$XP_BIOS_SPT" -ge 1 ] && [ "$XP_BIOS_SPT" -le 63 ] || stop "invalid BIOS sectors/track for selected XP target: $XP_BIOS_SPT"
    [ "$XP_BIOS_CYLINDERS" -ge 1 ] && [ "$XP_BIOS_CYLINDERS" -le 1024 ] || stop "invalid BIOS cylinder count for selected XP target: $XP_BIOS_CYLINDERS"
    printf '[LEGACY_XP] BIOS TARGET MATCH device=%s drive=0x%s size=%s chs=%s/%s/%s source=INT13-AH08\n' "$TARGET_DEVICE" "$XP_BIOS_DRIVE" "$TARGET_SIZE_FOR_BIOS" "$XP_BIOS_CYLINDERS" "$XP_BIOS_HEADS" "$XP_BIOS_SPT"

    # Validate and mount the selected source before offering a destructive reset.
    if [ "$XP_SOURCE_OPEN" = no ]; then
    xp_stage_set source-mount
    CRC_MODULE=$(module_path 'kernel/lib/crc/crc-itu-t.ko') || true
    UDF_MODULE=$(module_path 'kernel/fs/udf/udf.ko') || true
    [ -n "$CRC_MODULE" ] || stop 'crc-itu-t module missing for XP ISO'
    [ -n "$UDF_MODULE" ] || stop 'udf module missing for XP ISO'
    insmod "$CRC_MODULE" 2>/dev/null || true
    modprobe cdrom 2>/dev/null || stop 'cannot load cdrom dependency required by udf'
    insmod "$UDF_MODULE" 2>/dev/null || stop 'cannot load udf module for XP ISO'
    modprobe loop 2>/dev/null || true
    mdev -s 2>/dev/null || true
    LOOP_DEVICE=$(losetup -f 2>/dev/null) || stop 'no free loop device for selected XP ISO'
    losetup "$LOOP_DEVICE" "$XP_IMAGE_PATH" || stop 'cannot attach selected XP ISO to loop device'
    if mount -t iso9660 -o ro,map=off "$LOOP_DEVICE" /mnt/source 2>/dev/null; then
        :
    elif mount -t udf -o ro "$LOOP_DEVICE" /mnt/source; then
        :
    else
        losetup -d "$LOOP_DEVICE" 2>/dev/null || true
        stop 'cannot mount selected XP ISO as ISO9660 or UDF'
    fi
    SOURCE_ROOT=/mnt/source
    export SOURCE_ROOT TARGET_DEVICE USOS_DISK_DEVICE
    sh /usr/lib/usos/probe_nt5_source.sh || stop 'Invalid NT5 source; no target write occurred'
    XP_SOURCE_OPEN=yes
    fi
    export TARGET_DEVICE
    . /usr/lib/usos/xp_disk_reset_ui.sh
    usos_xp_disk_mode || continue

    TARGET_SNAPSHOT=/run/xp-target.snapshot
    XP_ALLOW_EMPTY=no
    [ -n "$XP_WINNT_SIF" ] || XP_ALLOW_EMPTY=yes
    export XP_ALLOW_EMPTY
    export TARGET_DEVICE TARGET_SNAPSHOT USOS_DISK_DEVICE XP_BIOS_DRIVE XP_BIOS_CYLINDERS XP_BIOS_HEADS XP_BIOS_SPT
    xp_stage_set target-snapshot
    usos_ui_stage 3 5 'Preparing workspace' 'Validating free space, MBR state and the XPSETUP reservation.' || true
    printf '[LEGACY_XP] SNAPSHOT begin device=%s\n' "$TARGET_DEVICE"
    xp_run_logged legacy-xp-target-snapshot.log sh /usr/lib/usos/target_disk_guard.sh snapshot || stop 'XP target snapshot refused selected MBR disk/free extent'
    xp_stage_set target-snapshot-pass
    XP_TARGET_MODEL=$(usos_disk_model "$TARGET_DEVICE")
    XP_TARGET_SERIAL=$(usos_disk_serial "$TARGET_DEVICE")
    PREVIOUS_ACTIVE_SLOTS=$(awk -F= '$1 == "active_slots" { sub(/^[^=]*=/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$TARGET_SNAPSHOT") || stop 'XP target snapshot has no active partition state'
    XPSETUP_REUSE=$(awk -F= '$1 == "xpsetup_reuse" { print $2; found=1; exit } END { if (!found) exit 1 }' "$TARGET_SNAPSHOT") || stop 'XP target snapshot has no XPSETUP reuse state'
    case "$XPSETUP_REUSE" in yes|no) ;; *) stop "invalid XPSETUP reuse state in snapshot: $XPSETUP_REUSE" ;; esac
    XP_WINDOWS_PLAN=''
    if [ -z "$XP_WINNT_SIF" ]; then
        XP_WINDOWS_PLAN=/run/xp-windows.plan
        awk -f /usr/lib/usos/xp_windows_partition_plan.awk "$TARGET_SNAPSHOT" > "$XP_WINDOWS_PLAN" || stop 'Automatic XP needs at least 8 GiB contiguous space at the staging reservation. No target write occurred.'
        cat "$XP_WINDOWS_PLAN"
    fi
    export XP_WINDOWS_PLAN
    if [ -n "$PREVIOUS_ACTIVE_SLOTS" ]; then
        old_ifs=$IFS
        IFS=,
        for active_slot in $PREVIOUS_ACTIVE_SLOTS; do
            printf '[LEGACY_XP] WARNING: Partition %s is currently active. After preparation, the computer will boot XP Setup.\n' "$active_slot"
        done
        IFS=$old_ifs
    fi
    if [ "$XPSETUP_REUSE" = yes ]; then
        REQUIRED_CONFIRMATION="REUSE XPSETUP $XP_TARGET_MODEL $XP_TARGET_SERIAL"
        printf '[LEGACY_XP] REUSE existing XPSETUP approved by strict guard; no second MBR slot will be created\n'
    else
        REQUIRED_CONFIRMATION="CREATE XPSETUP $XP_TARGET_MODEL $XP_TARGET_SERIAL"
    fi
    printf '[LEGACY_XP] PAUSE 2/2 - installation confirmation\n'
    if [ "${XP_FORMAT_CONFIRMED:-no}" = yes ]; then
        TARGET_CONFIRMATION=$REQUIRED_CONFIRMATION
        printf '[LEGACY_XP] Installation authorised by whole-disk confirmation\n'
    elif [ -f "$TEST_INI" ]; then
        TARGET_CONFIRMATION=$REQUIRED_CONFIRMATION
        printf '[LEGACY_XP] TEST AUTO-CONFIRM exact phrase\n'
    else
        confirmation_screen=/run/xp-disk-confirm.txt
        {
            printf '%s - CONFIRM INSTALLATION\n\nDisk: %s\nS/N: %s\nSize: %s GiB\n\n' "$NT5_TITLE" "$XP_TARGET_MODEL" "$XP_TARGET_SERIAL" "$((TARGET_SIZE_FOR_BIOS / 1073741824))"
            if [ -n "$XP_WINDOWS_PLAN" ]; then
                windows_sectors=$(awk -F= '$1=="windows_sectors" {print $2}' "$XP_WINDOWS_PLAN")
                printf 'Windows C: %s GiB NTFS.\nOne partition for Windows and automatic setup.\nNo separate XPSETUP partition will remain.\n' "$((windows_sectors / 2097152))"
            else
                printf 'Custom SIF: select a partition in XP Setup.\n'
            fi
            if [ "$XPSETUP_REUSE" = yes ]; then
                printf 'The existing XPSETUP partition will be formatted.\n'
            elif [ -z "$XP_WINDOWS_PLAN" ]; then
                printf 'New XPSETUP installer partition: 2 GiB.\n'
            fi
            printf 'The computer will continue installation from this disk.\nOther partitions will be preserved.\n'
        } > "$confirmation_screen"
        usos_xp_confirm "$confirmation_screen" "$NT5_TITLE - CONFIRMATION" "Prepare $NT5_NAME installation" || continue
        TARGET_CONFIRMATION=$REQUIRED_CONFIRMATION
    fi
    export TARGET_CONFIRMATION
    USOS_XP_CHOOSING=no
    break
    done

    SOURCE_ROOT=/mnt/source
    XP_READY_FILE=/mnt/esp/EFI/USOS/xp-target-ready.ini
    XPSETUP_MOUNT=/mnt/xpsetup
    export SOURCE_ROOT XP_READY_FILE XPSETUP_MOUNT
    xp_stage_set prepare-xpsetup
    usos_ui_stage 4 5 'Copying files' 'Preparing the Windows partition and installation files.' || true
    printf '[LEGACY_XP] PREPARE_XP_TARGET BEGIN target=%s source=%s\n' "$TARGET_DEVICE" "$XP_IMAGE_NAME"
    xp_run_logged legacy-xp-prepare.log sh /usr/lib/usos/prepare_xp_target.sh || stop 'prepare_xp_target.sh failed'
    printf '[LEGACY_XP] PREPARE_XP_TARGET PASS\n'
    xp_stage_set prepare-xpsetup-pass
    usos_ui_stage 5 5 'Verification and finalization' 'Verifying the staged source, unmounting media and flushing writes.' || true

    if [ -n "$XP_WINNT_SIF" ]; then
        XPSETUP_START=$(awk -F= '$1 == "xpsetup_start_lba" { print $2; found=1; exit } END { if (!found) exit 1 }' "$TARGET_SNAPSHOT") || stop 'XP target snapshot has no XPSETUP start for WINNT.SIF readback'
        XP_SIF_READBACK=/tmp/usos-xp-winnt-readback.sif
        rm -f "$XP_SIF_READBACK"
        mcopy -o -i "$TARGET_DEVICE@@$((XPSETUP_START * 512))" '::/$WIN_NT$.~BT/WINNT.SIF' "$XP_SIF_READBACK" || stop 'cannot read back staged user WINNT.SIF'
        cmp -s "$XP_WINNT_SIF" "$XP_SIF_READBACK" || stop 'staged user WINNT.SIF differs from selected DATA file'
        XP_SIF_SHA256=$(sha256sum "$XP_SIF_READBACK" | awk '{print $1}') || stop 'cannot hash staged user WINNT.SIF readback'
        rm -f "$XP_SIF_READBACK"
        printf '[LEGACY_XP] UNATTENDED READBACK PASS selected=%s sha256=%s exact=yes\n' "$XP_UNATTENDED_NAME" "$XP_SIF_SHA256"
    fi

    umount /mnt/source || stop 'cannot unmount selected XP ISO after preparation'
    losetup -d "$LOOP_DEVICE" || stop 'cannot detach selected XP ISO loop device'
    umount /mnt/data || stop 'cannot unmount USOS_DATA after XP preparation'
    printf '[LEGACY_XP] PREPARED PASS backend=xp-staging\n'
    xp_stage_set handoff-finalize

    # Variant (b): there is deliberately no Core 0x80->0x81 handoff after
    # staging. The target will boot naturally as BIOS 0x80 after the user
    # removes USOS. Delete the old auto-chainload marker so plugging USOS back
    # in later cannot trigger the known-bad second-disk chainload path.
    [ -f "$XP_READY_FILE" ] || stop 'XP target ready marker missing after successful preparation'
    if [ -n "$XP_WINDOWS_PLAN" ]; then
        mv "$XP_READY_FILE" /mnt/esp/EFI/USOS/xp-install-record.ini || stop 'cannot persist XP installation identity'
        rm -f /mnt/esp/EFI/USOS/xp-resume.ini
    else
        mv "$XP_READY_FILE" /mnt/esp/EFI/USOS/xp-resume.ini || stop 'cannot persist XP resume identity'
    fi
    [ ! -e "$XP_READY_FILE" ] || stop 'obsolete XP auto-chainload marker still exists after removal'
    printf '[LEGACY_XP] REMOVE-USOS HANDOFF PASS auto_chainload_marker=cleared target_boot=BIOS-0x80\n'

    if [ "$TEST_STOP_AFTER_PREPARE" = yes ]; then
        printf '[LEGACY_XP] TEST STOP AFTER PREPARE - NO CHAINLOAD ATTEMPTED\n'
        while true; do sleep 3600; done
    fi

    xp_stage_set waiting-remove-usos
    umount /mnt/esp || stop 'cannot unmount ESP after XP target preparation'
    sync
    printf '[LEGACY_XP] PREPARED SYNC PASS; USOS media may now be removed safely\n'
    enable_emergency_input || true
    if [ -n "$XP_WINDOWS_PLAN" ]; then
        printf '[LEGACY_XP] Target boot runs Text Mode on NTFS automatically, then restarts into GUI Setup on C:.\n'
        # Text Mode needs no input here (partition preselected via the local
        # source, EULA and format skipped). Say so before the restart: the only
        # live keys are SETUPLDR's F2/F5/F6/F7 hints in its first seconds.
        usos_ui_notice_continue "$NT5_NAME will now install on its own" "After the restart, $NT5_NAME Setup runs on its own up to the graphical setup wizard. Until then do not press any keys: the disk has already been chosen here." 'Proceed' || true
        printf '[LEGACY_XP] WAITING FOR USER: automatic-install notice, ENTER to continue\n'
        if [ -r "$USOS_UI_TTY" ]; then
            IFS= read -r _notice_ack < "$USOS_UI_TTY" || true
        else
            IFS= read -r _notice_ack || true
        fi
    else
        printf '[LEGACY_XP] After Text Mode copies files, boot USOS again and choose CONTINUE XP.\n'
    fi
    printf '\n%s READY TO INSTALL.\nRemove the USOS USB drive, then press ENTER to power off.\n' "$NT5_TITLE"
    usos_ui_done "$NT5_TITLE READY TO INSTALL" 'REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF.' || true
    printf '[LEGACY_XP] WAITING FOR USER: remove USOS USB, then press ENTER to power off; target will boot XPSETUP as BIOS 0x80 on next power-on\n'
    # /dev/console follows the last console= kernel argument (ttyS0 here), so
    # reading inherited stdin would wait for a serial-port newline while the
    # visible physical keyboard types into VT1. Read from the exact UI TTY.
    if [ -r "$USOS_UI_TTY" ]; then
        IFS= read -r _poweroff_request < "$USOS_UI_TTY" || true
    else
        IFS= read -r _poweroff_request || true
    fi
    printf '[LEGACY_XP] POWER OFF REQUESTED input=%s\n' "$USOS_UI_TTY"
    poweroff -f 2>/dev/null || true
    sleep 2
    halt -f 2>/dev/null || true
    while true; do sleep 3600; done
}
