# Vista SP2 x64 on UEFI: USOS prepares the target disk (docs/windows-vista-existing-esp-2026-09-26.md).
# Sourced by pipeline step 600. Reuses the XP disk picker and confirmation
# (xp_menu_ui.sh / xp_confirmation_ui.sh) and the disk identity helpers.
#
# After the user picked a non-USOS disk and confirmed the wipe:
#   - the old partition table is erased (first and last MiB, both GPT copies);
#   - a fresh GPT gets an EFI system partition (300 MiB, FAT32) and a
#     Microsoft reserved partition (128 MiB, what Vista/7 Setup creates on GPT);
#   - the rest stays unallocated: in Vista Setup the user picks that space;
#   - the table and the ESP are read back, buffers flushed;
#   - EFI/USOS/vista-target.ini on the USOS ESP records the disk GUID, the ESP
#     PARTUUID and the disk size; the Vista installer in WinPE pins the ESP
#     from it and consumes the file.
# No other disk is written. The USOS stick (ESP parent) is never offered.

VISTA_ESP_MIB=300
VISTA_MSR_MIB=128

vista_prepare_log() {
    printf '[VISTA_DISK] %s\n' "$*"
    printf '%s\n' "$*" >> /mnt/esp/EFI/USOS/vista-disk-prepare.log 2>/dev/null || true
}

usos_vista_disk_prepare() {
    : > /mnt/esp/EFI/USOS/vista-disk-prepare.log 2>/dev/null || true
    for tool in sfdisk mkfs.fat lsblk dd blockdev sync awk; do
        command -v "$tool" >/dev/null 2>&1 || stop "$tool is required for the Vista disk preparation"
    done
    [ -d /sys/firmware/efi ] || stop 'Vista disk preparation requires UEFI'
    [ -r /usr/lib/usos/target_disk_identity.sh ] || stop 'target_disk_identity.sh is missing'
    . /usr/lib/usos/target_disk_identity.sh
    [ -r /usr/lib/usos/xp_confirmation_ui.sh ] || stop 'xp_confirmation_ui.sh is missing'
    . /usr/lib/usos/xp_confirmation_ui.sh
    NT5_TITLE='WINDOWS VISTA'
    NT5_NAME='Windows Vista'
    export NT5_TITLE NT5_NAME
    xp_stage_set() { :; }

    ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_PATH" 2>/dev/null | head -n 1)
    [ -n "$ESP_PARENT" ] || stop 'cannot resolve the USOS disk'
    USOS_DISK_DEVICE="/dev/$ESP_PARENT"
    CANDIDATES=/run/vista-candidates
    : > "$CANDIDATES"
    index=0
    # Storage drivers may still be probing: wait briefly for a non-USOS disk.
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        mdev -s 2>/dev/null || true
        lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }' | grep -qv "^$USOS_DISK_DEVICE\$" && break
        sleep 1
    done
    for candidate in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        ro=$(lsblk -dnro RO "$candidate" 2>/dev/null | head -n 1 || true)
        if [ "$candidate" = "$USOS_DISK_DEVICE" ]; then
            vista_prepare_log "DISK $candidate REJECT USOS stick"
        elif [ "$ro" = 1 ]; then
            vista_prepare_log "DISK $candidate REJECT read-only"
        else
            index=$((index + 1))
            printf '%s|%s\n' "$index" "$candidate" >> "$CANDIDATES"
            vista_prepare_log "DISK $candidate ACCEPT index=$index model=$(usos_disk_model "$candidate" || true) size=$(usos_disk_size "$candidate" || true)"
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
            printf 'USOS creates an EFI partition and leaves the rest free. In Vista Setup select the unallocated space.\n'
        } > "$screen"
        usos_xp_confirm "$screen" 'WINDOWS VISTA - CONFIRM INSTALLATION' 'Erase this disk and prepare Windows Vista' && break
    done
    [ "$TARGET_DEVICE" != "$USOS_DISK_DEVICE" ] || stop 'refusing the USOS disk'
    vista_prepare_log "TARGET $TARGET_DEVICE model=$model serial=$serial size=$size confirmed"
    usos_ui_stage 4 5 'Preparing the disk' 'Erasing the partition table and creating the EFI partition.' || true

    # Nothing of the target may be mounted.
    if awk -v d="$TARGET_DEVICE" 'index($1, d) == 1 { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts; then
        stop 'a partition of the selected disk is mounted; no disk was changed'
    fi
    sectors=$((size / 512))
    [ "$sectors" -gt 16777216 ] || stop 'the selected disk is smaller than 8 GiB; no disk was changed'
    dd if=/dev/zero of="$TARGET_DEVICE" bs=1048576 count=1 conv=fsync 2>/dev/null || stop 'cannot erase the partition table'
    dd if=/dev/zero of="$TARGET_DEVICE" bs=512 seek=$((sectors - 2048)) count=2048 conv=fsync 2>/dev/null || stop 'cannot erase the backup partition table'
    blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true
    {
        printf 'label: gpt\n'
        printf 'start=2048, size=%s, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, name="EFI system partition"\n' "$((VISTA_ESP_MIB * 2048))"
        printf 'size=%s, type=E3C9E316-0B5C-4DB8-817D-F92DF00215AE, name="Microsoft reserved partition"\n' "$((VISTA_MSR_MIB * 2048))"
    } | sfdisk --no-reread --no-tell-kernel -q "$TARGET_DEVICE" >> /mnt/esp/EFI/USOS/vista-disk-prepare.log 2>&1 || stop 'sfdisk could not write the new GPT'
    blockdev --rereadpt "$TARGET_DEVICE" 2>/dev/null || true
    mdev -s 2>/dev/null || true
    sleep 1
    esp_part=$(lsblk -lnpo NAME,TYPE "$TARGET_DEVICE" 2>/dev/null | awk '$2 == "part" { print $1; exit }')
    [ -n "$esp_part" ] && [ -b "$esp_part" ] || stop 'the new EFI partition did not appear'
    mkfs.fat -F 32 -n SYSTEM "$esp_part" >> /mnt/esp/EFI/USOS/vista-disk-prepare.log 2>&1 || stop 'cannot format the new EFI partition'
    sync; blockdev --flushbufs "$TARGET_DEVICE" 2>/dev/null || true

    # Read back: exactly ESP + MSR, the ESP holds FAT32.
    dump=$(sfdisk --dump "$TARGET_DEVICE" 2>/dev/null) || stop 'cannot read back the new GPT'
    printf '%s\n' "$dump" >> /mnt/esp/EFI/USOS/vista-disk-prepare.log
    disk_guid=$(printf '%s\n' "$dump" | awk -F': ' '$1 == "label-id" { print $2; exit }')
    parts=$(printf '%s\n' "$dump" | grep -c '^/dev/')
    esp_uuid=$(printf '%s\n' "$dump" | awk '/^\/dev\// && /C12A7328-F81F-11D2-BA4B-00A0C93EC93B/ { for (i = 1; i <= NF; i++) if ($i ~ /^uuid=/) { u=$i; sub(/^uuid=/, "", u); sub(/,$/, "", u); print u; exit } }')
    [ "$parts" = 2 ] || stop "read-back: expected 2 partitions, found $parts"
    [ -n "$disk_guid" ] && [ -n "$esp_uuid" ] || stop 'read-back: disk GUID or ESP PARTUUID missing'
    fat=$(dd if="$esp_part" bs=1 skip=82 count=5 2>/dev/null)
    [ "$fat" = FAT32 ] || stop 'read-back: the EFI partition is not FAT32'
    vista_prepare_log "READBACK PASS disk_guid=$disk_guid esp_partuuid=$esp_uuid size=$size"

    tmp=/mnt/esp/EFI/USOS/vista-target.ini.tmp
    printf 'state=prepared\ndisk_guid=%s\nesp_partuuid=%s\ndisk_size=%s\nmodel=%s\nserial=%s\n' \
        "$disk_guid" "$esp_uuid" "$size" "$model" "$serial" > "$tmp" || stop 'cannot record the prepared disk on the USOS ESP'
    mv "$tmp" /mnt/esp/EFI/USOS/vista-target.ini || stop 'cannot record the prepared disk on the USOS ESP'
    sync
    usos_ui_stage 5 5 'Disk prepared' 'Restarting into USOS: choose Windows Vista again to start Setup.' || true
    vista_prepare_log 'DONE; restarting into USOS'
    # No unmounts here (an unmount of DATA hung in QEMU); the record is
    # already renamed into place and synced. Restart through the kernel.
    sync
    sleep 3
    reboot -f 2>/dev/null || true
    sleep 3
    echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
    echo b > /proc/sysrq-trigger 2>/dev/null || true
    while :; do sleep 3600; done
}
