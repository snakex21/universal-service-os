#!/bin/sh
set -eu

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s

module_path() {
    suffix=$1
    find /usr/lib/modules -type f -path "*/$suffix" -print -quit 2>/dev/null
}

load_input_module() {
    suffix=$1
    path=$(module_path "$suffix")
    [ -n "$path" ] || return 1
    insmod "$path" 2>/dev/null || true
}

usos_hw_boot_progress() {
    [ "${USOS_HW_REQUESTED:-no}" = yes ] || return 0
    usos_perf_mark "Hardware stage $1: $2"
    usos_ui_render_state service "$1" 5 'HARDWARE & SMART' "$2" '' 0 0 0 0 || true
}

load_pci_storage_modules() {
    for device in /sys/bus/pci/devices/*; do
        [ -r "$device/class" ] || continue
        class=$(cat "$device/class" 2>/dev/null || true)
        case "$class" in
            0x01*)
                [ -r "$device/modalias" ] || continue
                alias=$(cat "$device/modalias" 2>/dev/null || true)
                [ -n "$alias" ] || continue
                printf '[MICRO-LINUX] storage PCI class=%s modalias=%s\n' "$class" "$alias"
                case "$class" in
                    0x0106*) usos_hw_boot_progress 2 'Detecting SATA controllers and disks.' ;;
                    0x0101*) usos_hw_boot_progress 2 'Detecting IDE / ATA controllers and disks.' ;;
                    0x0108*) usos_hw_boot_progress 2 'Detecting NVMe controllers and disks.' ;;
                    *) usos_hw_boot_progress 2 'Detecting storage controllers and disks.' ;;
                esac
                modprobe "$alias" 2>/dev/null || true
                driver=none
                if [ -L "$device/driver" ]; then
                    driver=$(basename "$(readlink -f "$device/driver")")
                fi
                printf '[MICRO-LINUX] storage PCI bound class=%s driver=%s modalias=%s\n' "$class" "$driver" "$alias"
                ;;
        esac
    done
}

enable_emergency_input() {
    # Normal preparation is fully automatic. Load the USB/HID stack only when
    # an emergency shell is actually needed so every successful boot avoids
    # the module churn and the old one-second input discovery delay.
    load_input_module 'kernel/drivers/usb/host/xhci-hcd.ko' || true
    load_input_module 'kernel/drivers/usb/host/xhci-pci.ko' || true
    load_input_module 'kernel/drivers/usb/host/ehci-hcd.ko' || true
    load_input_module 'kernel/drivers/usb/host/ehci-pci.ko' || true
    load_input_module 'kernel/drivers/usb/host/ohci-hcd.ko' || true
    load_input_module 'kernel/drivers/usb/host/ohci-pci.ko' || true
    load_input_module 'kernel/drivers/hid/hid.ko' || true
    load_input_module 'kernel/drivers/hid/usbhid/usbhid.ko' || true
    load_input_module 'kernel/drivers/hid/hid-generic.ko' || true
    load_input_module 'kernel/drivers/input/evdev.ko' || true
    modprobe psmouse 2>/dev/null || true
    # Gamepads and touchscreens for the framebuffer menus (usos-fb-ui):
    # xpad (Xbox-compatible pads, ROG Ally gamepad mode), USB/I2C HID
    # multitouch panels, and hid-asus (ROG Ally keys) on ASUS machines only.
    modprobe xpad 2>/dev/null || true
    modprobe hid_multitouch 2>/dev/null || true
    modprobe i2c_hid_acpi 2>/dev/null || true
    case "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null)" in
        *ASUS*) modprobe hid_asus 2>/dev/null || true ;;
    esac
    mdev -s 2>/dev/null || true
}

persist_legacy_xp_stop() {
    reason=$1
    case "${LEGACY_ACTION:-}" in xp-staging|windows2000-staging) ;; *) return 0 ;; esac
    [ -r /proc/mounts ] || return 0
    awk '$2 == "/mnt/esp" { found=1 } END { exit(found ? 0 : 1) }' /proc/mounts || return 0
    [ -d /mnt/esp/EFI/USOS ] || return 0
    error_file=/mnt/esp/EFI/USOS/legacy-xp-staging-last-error.txt
    tmp_file="$error_file.tmp"
    {
        printf '[LEGACY_XP_FAILURE]\n'
        printf 'phase=%s\n' "${XP_STAGE_STATE:-unknown}"
        printf 'reason=%s\n' "$reason"
        printf 'uptime=%s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || true)"
        printf 'kernel_cmdline=%s\n' "$(cat /proc/cmdline 2>/dev/null || true)"
        if [ -r /run/xp-target.snapshot ]; then
            printf '%s\n' '--- target snapshot ---'
            cat /run/xp-target.snapshot
        fi
        printf '%s\n' '--- block inventory ---'
        lsblk -bdnpo NAME,TYPE,MODEL,SERIAL,SIZE,PTTYPE,RM,RO 2>/dev/null || true
    } > "$tmp_file" 2>/dev/null || return 0
    mv "$tmp_file" "$error_file" 2>/dev/null || return 0
    sync
    printf '[MICRO-LINUX] persisted Legacy XP failure to EFI/USOS/legacy-xp-staging-last-error.txt\n'
}

stop() {
    persist_legacy_xp_stop "$1" || true
    if command -v usos_ui_fail >/dev/null 2>&1; then
        usos_ui_fail 'Preparation stopped' "$1"
    fi
    if command -v usos_ui_restore_cursor >/dev/null 2>&1; then
        usos_ui_restore_cursor
    fi
    printf '[MICRO-LINUX] STOP: %s\n' "$1"
    printf '[MICRO-LINUX] loading emergency keyboard support...\n'
    enable_emergency_input || true
    printf '[MICRO-LINUX] emergency shell available on console\n'
    exec /bin/sh
}

mkdir -p /proc /sys /dev
mount -t proc proc /proc || stop 'cannot mount proc'
mount -t sysfs sysfs /sys || stop 'cannot mount sysfs'
mount -t devtmpfs devtmpfs /dev || stop 'cannot mount devtmpfs'
exec </dev/console >/dev/console 2>&1
mkdir -p /dev/pts /dev/input /dev/usos-block /run /tmp /mnt/esp /mnt/data /mnt/source /mnt/work /dev/disk/by-partuuid
mount -t devpts devpts /dev/pts 2>/dev/null || true

[ -r /usr/lib/usos/partuuid.sh ] || stop 'partuuid.sh is missing'
. /usr/lib/usos/partuuid.sh
[ -r /usr/lib/usos/partuuid_diagnostics.sh ] || stop 'partuuid_diagnostics.sh is missing'
. /usr/lib/usos/partuuid_diagnostics.sh
[ -r /usr/lib/usos/micro_linux_ui.sh ] || stop 'micro_linux_ui.sh is missing'
. /usr/lib/usos/micro_linux_ui.sh
stty -echo < "$USOS_UI_TTY" 2>/dev/null || true
case "$(cat /proc/cmdline)" in *usos.legacy_action=xp-staging*|*usos.legacy_action=windows2000-staging*) USOS_XP_CHOOSING=yes ;; esac
# This marker is intentionally before simpledrm. It measures kernel/early
# userspace time while the last UEFI frame is still visible, not black time.
usos_perf_mark 'micro-Linux userspace before framebuffer init'
usos_ui_init || true
USOS_HW_REQUESTED=no
case " $(cat /proc/cmdline) " in *' usos.legacy_action=hardware '*) USOS_HW_REQUESTED=yes ;; esac
if [ "$USOS_HW_REQUESTED" = yes ]; then
    usos_hw_boot_progress 1 'Initializing hardware detection.'
else
    usos_ui_stage 1 5 'Preparation environment started' 'Initializing only the storage stack needed for preparation.'
fi
printf '[MICRO-LINUX] boot PASS kernel=%s\n' "$(uname -r)"

modprobe sd_mod 2>/dev/null || true
# Resolve physical ATA/SATA controllers from their PCI modalias. The LTS
# initramfs carries the complete libata driver family but loads only drivers
# matching hardware actually present (e.g. CK804 -> sata_nv).
load_pci_storage_modules
# The virtio PCI transport must be present before virtio_blk/virtio_scsi can
# see QEMU's virtio disks (its PCI alias also matches in the loop above).
modprobe virtio_pci 2>/dev/null || true
modprobe virtio_blk 2>/dev/null || true
modprobe virtio_scsi 2>/dev/null || true
modprobe loop 2>/dev/null || true
modprobe fuse 2>/dev/null || true
modprobe nls_ascii 2>/dev/null || true
modprobe nls_cp437 2>/dev/null || true
modprobe fat 2>/dev/null || true
modprobe vfat 2>/dev/null || true
# QEMU usually exposes the USOS disk as virtio, while physical media is USB.
# Load only the USB host/storage path here; HID remains deferred to the emergency shell.
usos_hw_boot_progress 3 'Detecting USB controllers and drives.'
modprobe xhci_pci 2>/dev/null || true
modprobe ehci_pci 2>/dev/null || true
modprobe ohci_pci 2>/dev/null || true
modprobe usb_storage 2>/dev/null || true
modprobe uas 2>/dev/null || true
mdev -s || stop 'mdev scan failed'
if [ "$USOS_HW_REQUESTED" != yes ]; then
    usos_ui_stage 1 5 'Detecting USOS partitions' 'Resolving ESP, DATA and WORK by PARTUUID.'
fi

ESP_PARTUUID=''
GUARD_TEST_BAD_PARTUUID=''
TEST_STOP_AFTER_PREPARED=''
LEGACY_ACTION=''
LEGACY_IMAGE_HEX=''
LEGACY_UNATTENDED_HEX=''
BIOS_BOOT_DRIVE=''
BIOS_DISKS=''
for argument in $(cat /proc/cmdline); do
    case "$argument" in
        usos.esp_partuuid=*) ESP_PARTUUID=${argument#*=} ;;
        usos.guard_test_bad_partuuid=*) GUARD_TEST_BAD_PARTUUID=${argument#*=} ;;
        usos.test_stop_after_prepared=*) TEST_STOP_AFTER_PREPARED=${argument#*=} ;;
        usos.legacy_action=*) LEGACY_ACTION=${argument#*=} ;;
        usos.legacy_image_hex=*) LEGACY_IMAGE_HEX=${argument#*=} ;;
        usos.legacy_unattended_hex=*) LEGACY_UNATTENDED_HEX=${argument#*=} ;;
        usos.bios_boot_drive=*) BIOS_BOOT_DRIVE=${argument#*=} ;;
        usos.bios_disks=*) BIOS_DISKS=${argument#*=} ;;
    esac
done

# Diagnostics branches before any ESP/DATA/WORK mount or installation action.
if [ "$LEGACY_ACTION" = hardware ]; then
    [ -r /usr/lib/usos/hardware_ui.sh ] || stop 'hardware_ui.sh is missing'
    . /usr/lib/usos/hardware_ui.sh
    usos_hardware_main
    stop 'Hardware session returned unexpectedly'
fi
[ -n "$ESP_PARTUUID" ] || stop 'kernel command line has no usos.esp_partuuid'

# Create the same stable PARTUUID namespace normally maintained by udev. USB
# storage enumeration is asynchronous on real hardware, so the target path is
# retried for a short bounded window instead of taking one instantaneous scan.
# PARTUUID is read from the kernel's partition uevent data. Do not use
# `blkid -p -s PARTUUID -o value` here: util-linux blkid 2.41 can return rc=0
# with an empty value for PARTUUID even though sysfs, lsblk and normal blkid
# all expose the correct GPT partition UUID on the same device.

wait_for_partuuid_path() {
    wanted_uuid=$1
    wanted_path=$(usos_partuuid_path "$wanted_uuid")
    attempt=0
    while [ "$attempt" -lt 50 ]; do
        refresh_partuuid_links
        if [ -e "$wanted_path" ]; then
            printf '%s' "$wanted_path"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.1
    done
    return 1
}

uptime_seconds() {
    awk '{ print $1; exit }' /proc/uptime 2>/dev/null || printf '0'
}

elapsed_seconds() {
    awk -v start="$1" -v finish="$2" 'BEGIN { printf "%.3f", finish - start }'
}

ESP_WAIT_START=$(uptime_seconds)
if ESP_PATH=$(wait_for_partuuid_path "$ESP_PARTUUID"); then
    :
else
    ESP_WAIT_END=$(uptime_seconds)
    ESP_WAIT_ELAPSED=$(elapsed_seconds "$ESP_WAIT_START" "$ESP_WAIT_END")
    diagnostic_file=$(usos_partuuid_diagnostics "$ESP_PARTUUID" "$ESP_WAIT_ELAPSED" 50)
    usos_ui_diagnostic "$diagnostic_file" || true
    printf '[MICRO-LINUX] PARTUUID DIAGNOSTIC saved to DATA as %s\n' "$USOS_PARTUUID_DIAG_DATA_FILE"
    printf '[MICRO-LINUX] PARTUUID DIAGNOSTIC FROZEN; power off after reading the summary\n'
    while true; do sleep 3600; done
fi
usos_ui_stage 1 5 'Opening USOS configuration' 'Mounting the verified EFI System Partition.'
mount -t vfat -o rw,noatime "$ESP_PATH" /mnt/esp || stop 'cannot mount ESP'

if [ -n "$LEGACY_ACTION" ]; then
    case "$LEGACY_ACTION" in
        windows7-iso|windows-vista-iso)
            . /usr/lib/usos/legacy_windows_request.sh
            legacy_windows_request
            ;;
        xp-resume)
            # Resume runs a single step; do not show four stages that never run.
            usos_ui_declare_stages 'Continuing Windows XP installation'
            usos_ui_stage 1 1 'Continuing Windows XP installation' 'Checking the prepared XP target.' || true
            sh /usr/lib/usos/legacy_xp_resume.sh || stop 'XP resume refused; see EFI/USOS/legacy-xp-resume.log'
            umount /mnt/esp || stop 'cannot unmount ESP after XP resume'
            sync
            enable_emergency_input || true
            usos_ui_done 'XP - KONTYNUACJA GOTOWA' 'REMOVE USOS USB, THEN PRESS ENTER TO POWER OFF.' || true
            printf '[XP_RESUME] Remove USOS USB, press ENTER, then start target disk.\n'
            if [ -r "$USOS_UI_TTY" ]; then IFS= read -r _resume_poweroff < "$USOS_UI_TTY" || true; else IFS= read -r _resume_poweroff || true; fi
            poweroff -f
            while true; do sleep 3600; done
            ;;
        xp-staging|windows2000-staging)
            NT5_SYSTEM=windows-xp
            [ "$LEGACY_ACTION" != windows2000-staging ] || NT5_SYSTEM=windows-2000
            export NT5_SYSTEM
            [ -r /usr/lib/usos/legacy_xp_staging.sh ] || stop 'legacy_xp_staging.sh is missing'
            . /usr/lib/usos/legacy_xp_staging.sh
            usos_legacy_xp_staging "$LEGACY_IMAGE_HEX" "$LEGACY_UNATTENDED_HEX"
            stop 'Legacy XP staging returned unexpectedly'
            ;;
        *) stop "unsupported Legacy action: $LEGACY_ACTION" ;;
    esac
fi

TARGET_GUARD_TEST_INI=/mnt/esp/EFI/USOS/target-guard-test.ini
if [ -f "$TARGET_GUARD_TEST_INI" ]; then
    [ -r /usr/lib/usos/target_disk_identity.sh ] || stop 'target_disk_identity.sh is missing'
    . /usr/lib/usos/target_disk_identity.sh
    [ -x /usr/lib/usos/target_disk_guard.sh ] || stop 'target_disk_guard.sh is missing'
    target_guard_value() {
        key=$1
        awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$TARGET_GUARD_TEST_INI"
    }
    TARGET_GUARD_TEST_MODE=$(target_guard_value mode) || stop 'target guard test mode missing'
    TARGET_GUARD_SERIAL=$(target_guard_value target_serial) || stop 'target guard test serial missing'
    ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_PATH" 2>/dev/null | head -n 1)
    [ -n "$ESP_PARENT" ] || stop 'cannot resolve USOS parent disk for target guard test'
    USOS_DISK_DEVICE="/dev/$ESP_PARENT"
    printf '[TARGET_GUARD_TEST] disk inventory begin\n'
    lsblk -bdnpo NAME,TYPE,MODEL,SERIAL,SIZE 2>/dev/null | sed 's/^/[TARGET_GUARD_TEST] disk /' || true
    for sysdev in /sys/class/block/*; do
        [ -e "$sysdev" ] || continue
        sysname=${sysdev##*/}
        if [ -r "$sysdev/device/serial" ]; then
            sysserial=$(cat "$sysdev/device/serial" 2>/dev/null || true)
            printf '[TARGET_GUARD_TEST] sysfs %s serial=%s\n' "$sysname" "$sysserial"
        fi
    done
    printf '[TARGET_GUARD_TEST] disk inventory end\n'
    TARGET_DEVICE=''
    for candidate in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        candidate_serial=$(usos_disk_serial "$candidate" || true)
        if [ "$candidate_serial" = "$TARGET_GUARD_SERIAL" ]; then
            [ -z "$TARGET_DEVICE" ] || stop 'target guard test serial matched multiple disks'
            TARGET_DEVICE=$candidate
        fi
    done
    [ -n "$TARGET_DEVICE" ] || stop "target guard test disk not found by serial=$TARGET_GUARD_SERIAL"
    TARGET_SNAPSHOT=/run/target-disk.snapshot
    export TARGET_DEVICE TARGET_SNAPSHOT USOS_DISK_DEVICE
    case "$TARGET_GUARD_TEST_MODE" in
        mbr-changed)
            printf '[TARGET_GUARD_TEST] mbr-changed snapshot begin device=%s\n' "$TARGET_DEVICE"
            sh /usr/lib/usos/target_disk_guard.sh snapshot || stop 'target guard MBR-change snapshot failed unexpectedly'
            GUARD_SLOT=$(awk -F= '$1 == "xpsetup_slot" { print $2; found=1; exit } END { if (!found) exit 1 }' "$TARGET_SNAPSHOT") || stop 'target guard snapshot has no XPSETUP slot'
            GUARD_START=$(awk -F= '$1 == "xpsetup_start_lba" { print $2; found=1; exit } END { if (!found) exit 1 }' "$TARGET_SNAPSHOT") || stop 'target guard snapshot has no XPSETUP start'
            printf '[TARGET_GUARD_TEST] injecting competing MBR partition slot=%s start=%s after snapshot\n' "$GUARD_SLOT" "$GUARD_START"
            printf 'start=%s, size=2048, type=83\n' "$GUARD_START" | sfdisk --no-reread --no-tell-kernel -N "$GUARD_SLOT" "$TARGET_DEVICE" >/tmp/usos-target-guard-mbr-change.log 2>&1 || {
                cat /tmp/usos-target-guard-mbr-change.log || true
                stop 'cannot inject MBR TOCTOU fixture'
            }
            TARGET_CONFIRMATION='CREATE XPSETUP invalid invalid'
            export TARGET_CONFIRMATION
            if sh /usr/lib/usos/target_disk_guard.sh pre-write; then
                stop 'TARGET GUARD NEGATIVE TEST FAIL: changed MBR was accepted'
            fi
            printf '[TARGET_GUARD_TEST] mbr-changed PASS: guard stopped changed MBR before XPSETUP write\n'
            ;;
        serial-mismatch)
            printf '[TARGET_GUARD_TEST] serial-mismatch snapshot begin device=%s\n' "$TARGET_DEVICE"
            sh /usr/lib/usos/target_disk_guard.sh snapshot || stop 'target guard serial-mismatch snapshot failed unexpectedly'
            sed 's/^serial=.*/serial=SERIAL-CHANGED-AFTER-SNAPSHOT/' "$TARGET_SNAPSHOT" > "$TARGET_SNAPSHOT.tmp"
            mv "$TARGET_SNAPSHOT.tmp" "$TARGET_SNAPSHOT"
            TARGET_CONFIRMATION='CREATE XPSETUP invalid invalid'
            export TARGET_CONFIRMATION
            if sh /usr/lib/usos/target_disk_guard.sh pre-write; then
                stop 'TARGET GUARD NEGATIVE TEST FAIL: changed serial snapshot was accepted'
            fi
            printf '[TARGET_GUARD_TEST] serial-mismatch PASS: guard stopped changed serial before write\n'
            ;;
        *) stop "unknown target guard test mode=$TARGET_GUARD_TEST_MODE" ;;
    esac
    umount /mnt/esp || true
    sync
    printf '[TARGET_GUARD_TEST] DONE\n'
    while true; do sleep 3600; done
fi

XP_TARGET_TEST_INI=/mnt/esp/EFI/USOS/xp-target-test.ini
if [ -f "$XP_TARGET_TEST_INI" ]; then
    [ -r /usr/lib/usos/target_disk_identity.sh ] || stop 'target_disk_identity.sh is missing'
    . /usr/lib/usos/target_disk_identity.sh
    [ -x /usr/lib/usos/target_disk_guard.sh ] || stop 'target_disk_guard.sh is missing'
    [ -x /usr/lib/usos/prepare_xp_target.sh ] || stop 'prepare_xp_target.sh is missing'
    XP_TARGET_SERIAL=$(awk -F= '$1 == "target_serial" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$XP_TARGET_TEST_INI") || stop 'XP target test serial missing'
    XP_SOURCE_SERIAL=$(awk -F= '$1 == "source_serial" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$XP_TARGET_TEST_INI") || stop 'XP source test serial missing'
    XP_BLANK_TARGET=$(awk -F= '$1 == "blank_target" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) print "no" }' "$XP_TARGET_TEST_INI")
    case "$XP_BLANK_TARGET" in yes|no) ;; *) stop "invalid XP blank_target value: $XP_BLANK_TARGET" ;; esac
    XP_LOCAL_SOURCE_TEST_MODE=$(awk -F= '$1 == "local_source_test_mode" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) print "" }' "$XP_TARGET_TEST_INI")
    case "$XP_LOCAL_SOURCE_TEST_MODE" in ''|bootfiles) ;; *) stop "invalid XP local_source_test_mode value: $XP_LOCAL_SOURCE_TEST_MODE" ;; esac
    if [ "$XP_BLANK_TARGET" = no ]; then
        command -v sha256sum >/dev/null 2>&1 || stop 'sha256sum is required for XP existing-data sentinel verification'
        XP_SENTINEL_PARTITION=$(awk -F= '$1 == "sentinel_partition" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$XP_TARGET_TEST_INI") || stop 'XP sentinel partition missing'
        XP_SENTINEL_PATH=$(awk -F= '$1 == "sentinel_path" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$XP_TARGET_TEST_INI") || stop 'XP sentinel path missing'
        XP_SENTINEL_SHA256=$(awk -F= '$1 == "sentinel_sha256" { sub(/^[^=]*=/, ""); gsub(/\r/, ""); print; found=1; exit } END { if (!found) exit 1 }' "$XP_TARGET_TEST_INI") || stop 'XP sentinel SHA256 missing'
        [ -n "$XP_SENTINEL_SHA256" ] || stop 'XP sentinel SHA256 is empty'
    fi

    ESP_PARENT=$(lsblk -dnro PKNAME "$ESP_PATH" 2>/dev/null | head -n 1)
    [ -n "$ESP_PARENT" ] || stop 'cannot resolve USOS parent disk for XP target test'
    USOS_DISK_DEVICE="/dev/$ESP_PARENT"
    TARGET_DEVICE=''
    for candidate in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        candidate_serial=$(usos_disk_serial "$candidate" || true)
        if [ "$candidate_serial" = "$XP_TARGET_SERIAL" ]; then
            [ -z "$TARGET_DEVICE" ] || stop 'XP target serial matched multiple disks'
            TARGET_DEVICE=$candidate
        fi
    done
    [ -n "$TARGET_DEVICE" ] || stop "XP target disk not found by serial=$XP_TARGET_SERIAL"

    # Strategy B makes target preparation independent of the BIOS CHS
    # translation that will be active after the USB is removed. The on-disk
    # XPSETUP metadata uses deterministic 255/63 LBA-assisted CHS; the custom
    # production MBR measures INT 13h AH=08 at boot and corrects only the
    # in-memory FAT32 BPB before handing off to Microsoft's VBR. Keep BIOS disk
    # inventory for diagnostics, but never gate staging on a size->CHS match.
    XP_TEST_TARGET_SIZE=$(usos_disk_size "$TARGET_DEVICE")
    printf '[XP_TARGET_TEST] TARGET READY device=%s size=%s staging_chs=255/63 runtime_fix=Strategy-B\n' "$TARGET_DEVICE" "$XP_TEST_TARGET_SIZE"

    mkdir -p /mnt/xpexisting /mnt/xpiso /mnt/xpsetup
    if [ "$XP_BLANK_TARGET" = yes ]; then
        printf '[XP_TARGET_TEST] BLANK TARGET BEFORE PASS serial=%s\n' "$XP_TARGET_SERIAL"
    else
        KERNEL_RELEASE=$(uname -r)
        NTFS3_MODULE=$(module_path 'kernel/fs/ntfs3/ntfs3.ko') || true
        [ -n "$NTFS3_MODULE" ] || stop 'ntfs3 module missing for XP existing-data verification'
        modprobe nls_utf8 2>/dev/null || true
        insmod "$NTFS3_MODULE" 2>/dev/null || true
        mdev -s 2>/dev/null || true
        SENTINEL_DEVICE=$(lsblk -nrpo NAME,TYPE,PARTN "$TARGET_DEVICE" 2>/dev/null | awk -v wanted="$XP_SENTINEL_PARTITION" '$2 == "part" && $3 == wanted { print $1; exit }')
        [ -b "$SENTINEL_DEVICE" ] || stop "XP sentinel partition node missing: partition $XP_SENTINEL_PARTITION"
        mount -t ntfs3 -o ro,noatime "$SENTINEL_DEVICE" /mnt/xpexisting || stop 'cannot mount existing XP test partition read-only'
        SENTINEL_BEFORE=$(sha256sum "/mnt/xpexisting$XP_SENTINEL_PATH" 2>/dev/null | awk '{print $1}') || stop 'cannot hash existing-data sentinel before XPSETUP preparation'
        umount /mnt/xpexisting || stop 'cannot unmount existing XP test partition before target snapshot'
        [ "$SENTINEL_BEFORE" = "$XP_SENTINEL_SHA256" ] || stop "existing-data sentinel SHA mismatch before preparation: $SENTINEL_BEFORE"
        printf '[XP_TARGET_TEST] EXISTING DATA BEFORE PASS sha256=%s partition=%s path=%s\n' "$SENTINEL_BEFORE" "$XP_SENTINEL_PARTITION" "$XP_SENTINEL_PATH"
    fi

    TARGET_SNAPSHOT=/run/xp-target.snapshot
    export TARGET_DEVICE TARGET_SNAPSHOT USOS_DISK_DEVICE
    printf '[XP_TARGET_TEST] snapshot begin device=%s serial=%s\n' "$TARGET_DEVICE" "$XP_TARGET_SERIAL"
    sh /usr/lib/usos/target_disk_guard.sh snapshot || stop 'XP target snapshot refused MBR disk/free extent'
    XP_TARGET_MODEL=$(usos_disk_model "$TARGET_DEVICE")
    TARGET_CONFIRMATION="CREATE XPSETUP $XP_TARGET_MODEL $XP_TARGET_SERIAL"
    export TARGET_CONFIRMATION

    CRC_MODULE=$(module_path 'kernel/lib/crc/crc-itu-t.ko') || true
    UDF_MODULE=$(module_path 'kernel/fs/udf/udf.ko') || true
    [ -n "$CRC_MODULE" ] || stop 'crc-itu-t module missing for XP ISO test'
    [ -n "$UDF_MODULE" ] || stop 'udf module missing for XP ISO test'
    insmod "$CRC_MODULE" 2>/dev/null || true
    modprobe cdrom 2>/dev/null || stop 'cannot load cdrom dependency required by udf'
    insmod "$UDF_MODULE" 2>/dev/null || stop 'cannot load udf module for XP ISO test'
    mdev -s 2>/dev/null || true
    XP_SOURCE_DEVICE=''
    for candidate in $(lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }'); do
        candidate_serial=$(usos_disk_serial "$candidate" || true)
        if [ "$candidate_serial" = "$XP_SOURCE_SERIAL" ]; then
            [ -z "$XP_SOURCE_DEVICE" ] || stop 'XP ISO source serial matched multiple block devices'
            XP_SOURCE_DEVICE=$candidate
        fi
    done
    [ -b "$XP_SOURCE_DEVICE" ] || stop "XP test ISO source block device not found by serial=$XP_SOURCE_SERIAL"
    mount -t iso9660 -o ro,map=off "$XP_SOURCE_DEVICE" /mnt/xpiso 2>/dev/null || mount -t udf -o ro "$XP_SOURCE_DEVICE" /mnt/xpiso || stop 'cannot mount XP test ISO from virtio source device'
    SOURCE_ROOT=/mnt/xpiso
    XP_READY_FILE=/mnt/esp/EFI/USOS/xp-target-ready.ini
    XPSETUP_MOUNT=/mnt/xpsetup
    export SOURCE_ROOT XP_READY_FILE XPSETUP_MOUNT XP_LOCAL_SOURCE_TEST_MODE
    printf '[XP_TARGET_TEST] source mounted from virtio-only %s serial=%s; creating XPSETUP only in unallocated space\n' "$XP_SOURCE_DEVICE" "$XP_SOURCE_SERIAL"
    sh /usr/lib/usos/prepare_xp_target.sh || stop 'prepare_xp_target.sh failed'

    if [ "$XP_BLANK_TARGET" = yes ]; then
        printf '[XP_TARGET_TEST] BLANK TARGET AFTER PASS xpsetup-created=yes\n'
    else
        mdev -s 2>/dev/null || true
        SENTINEL_DEVICE=$(lsblk -nrpo NAME,TYPE,PARTN "$TARGET_DEVICE" 2>/dev/null | awk -v wanted="$XP_SENTINEL_PARTITION" '$2 == "part" && $3 == wanted { print $1; exit }')
        [ -b "$SENTINEL_DEVICE" ] || stop 'existing partition disappeared after XPSETUP preparation'
        mount -t ntfs3 -o ro,noatime "$SENTINEL_DEVICE" /mnt/xpexisting || stop 'cannot remount existing XP test partition after XPSETUP preparation'
        SENTINEL_AFTER=$(sha256sum "/mnt/xpexisting$XP_SENTINEL_PATH" 2>/dev/null | awk '{print $1}') || stop 'cannot hash existing-data sentinel after XPSETUP preparation'
        umount /mnt/xpexisting || stop 'cannot unmount existing XP test partition after verification'
        [ "$SENTINEL_AFTER" = "$XP_SENTINEL_SHA256" ] || stop "existing-data sentinel SHA mismatch after preparation: $SENTINEL_AFTER"
        [ "$SENTINEL_AFTER" = "$SENTINEL_BEFORE" ] || stop 'existing-data sentinel changed while creating XPSETUP'
        printf '[XP_TARGET_TEST] EXISTING DATA AFTER PASS sha256=%s unchanged=yes\n' "$SENTINEL_AFTER"
    fi

    umount /mnt/xpiso || stop 'cannot unmount XP test ISO'
    printf '[XP_TARGET_TEST] PREPARED PASS; finalizing persistent state\n'
    umount /mnt/esp || stop 'cannot unmount ESP after XP target preparation'
    sync
    printf '[XP_TARGET_TEST] PREPARED SYNC PASS; rebooting for Legacy chainload\n'
    reboot -f
fi

DEVICE_INI=/mnt/esp/EFI/USOS/usos-device.ini
STATE_FILE=/mnt/esp/EFI/USOS/install-state.ini
[ -f "$DEVICE_INI" ] || stop 'usos-device.ini missing'
[ -f "$STATE_FILE" ] || stop 'install-state.ini missing'

ini_value() {
    key=$1
    file=$2
    awk -F= -v wanted="$key" '
        $1 == wanted { value=$0; sub(/^[^=]*=/, "", value); gsub(/\r/, "", value); print value; found=1; exit }
        END { if (!found) exit 1 }
    ' "$file"
}

phase=$(ini_value phase "$STATE_FILE") || stop 'persistent phase missing'
[ "$phase" = prepare-requested ] || stop "refusing preparation from phase=$phase"
WORK_PARTUUID=$(ini_value work_partuuid "$DEVICE_INI") || stop 'WORK PARTUUID missing'
DATA_PARTUUID=$(ini_value data_partuuid "$DEVICE_INI") || stop 'DATA PARTUUID missing'
CONFIG_ESP_PARTUUID=$(ini_value esp_partuuid "$DEVICE_INI") || stop 'ESP PARTUUID missing from config'
EXPECTED_DISK_PTUUID=$(ini_value disk_ptuuid "$DEVICE_INI") || stop 'disk PTUUID missing'
SELECTED_ISO=$(ini_value selected_iso "$STATE_FILE") || stop 'selected ISO missing'
SELECTED_UNATTEND=$(ini_value selected_unattend "$STATE_FILE" 2>/dev/null || true)
SELECTED_METHOD=$(ini_value selected_method "$STATE_FILE" 2>/dev/null || true)
[ -n "$SELECTED_METHOD" ] || SELECTED_METHOD=iso
case "$SELECTED_METHOD" in
    iso|chainload|wimboot|vhdboot) ;;
    *) stop "unsupported preparation method: $SELECTED_METHOD" ;;
esac
usos_guid_equal "$CONFIG_ESP_PARTUUID" "$ESP_PARTUUID" || stop 'ESP PARTUUID command line/config mismatch'
DATA_PATH=$(wait_for_partuuid_path "$DATA_PARTUUID") || stop "DATA PARTUUID path missing: $(usos_partuuid_path "$DATA_PARTUUID")"
WORK_PATH=$(wait_for_partuuid_path "$WORK_PARTUUID") || stop "WORK PARTUUID path missing: $(usos_partuuid_path "$WORK_PARTUUID")"
usos_ui_stage 1 5 'Validating preparation request' 'Checking selected image and device identity.'

if [ -n "$GUARD_TEST_BAD_PARTUUID" ]; then
    printf '[MICRO-LINUX] NEGATIVE GUARD TEST: intentionally supplied bad WORK PARTUUID=%s\n' "$GUARD_TEST_BAD_PARTUUID"
    WORK_PARTUUID=$GUARD_TEST_BAD_PARTUUID
    export WORK_PARTUUID ESP_PARTUUID DATA_PARTUUID EXPECTED_DISK_PTUUID
    export USOS_DEVICE_INI="$DEVICE_INI"
    printf '[MICRO-LINUX] invoking device_guard before any formatting operation\n'
    if sh /usr/lib/usos/device_guard.sh pre-format; then
        stop 'NEGATIVE GUARD TEST FAIL: invalid PARTUUID was accepted'
    fi
    printf '[MICRO-LINUX] NEGATIVE GUARD TEST PASS: device_guard stopped invalid PARTUUID\n'
    stop 'expected negative device_guard stop; mkfs.ntfs was not invoked'
fi

KERNEL_RELEASE=$(uname -r)
NTFS3_MODULE="/usr/lib/modules/$KERNEL_RELEASE/kernel/fs/ntfs3/ntfs3.ko"
[ -f "$NTFS3_MODULE" ] || stop 'ntfs3 module missing'
modprobe nls_utf8 2>/dev/null || true
insmod "$NTFS3_MODULE" 2>/dev/null || stop 'cannot load ntfs3 module'
usos_ui_stage 1 5 'Opening DATA partition' 'Loading the selected boot image from NTFS.'
mount -t ntfs3 -o ro,noatime "$DATA_PATH" /mnt/data || stop 'cannot mount DATA NTFS with ntfs3'
IMAGE_PATH="/mnt/data/$SELECTED_ISO"
[ -f "$IMAGE_PATH" ] || stop "selected image not found: $SELECTED_ISO"
SOURCE_LABEL=$(basename "$SELECTED_ISO")
WIM_FILE=''
WIM_TEMPLATE=''
VHD_SHARED=''
VHD_BCD=''
SOURCE_MOUNTED=no

if [ "$SELECTED_METHOD" = wimboot ]; then
    WIM_FILE="$IMAGE_PATH"
    WIM_TEMPLATE=/mnt/data/Programs/USOS/WimBootTemplate
    [ -d "$WIM_TEMPLATE" ] || stop 'WIMBoot template is missing; run Aktualizuj USOS from Windows after adding the WIM file'
    usos_ui_stage 1 5 'Opening WIM boot environment' "$SELECTED_ISO"
elif [ "$SELECTED_METHOD" = vhdboot ]; then
    VHD_SHARED=/mnt/data/Programs/USOS/VHDBoot/Shared
    VHD_BCD="/mnt/data/Programs/USOS/VHDBoot/Entries/$SELECTED_ISO/BCD"
    [ -d "$VHD_SHARED" ] || stop 'VHDBoot shared files are missing; run Aktualizuj USOS from Windows after adding the VHD/VHDX file'
    [ -f "$VHD_BCD" ] || stop "VHDBoot BCD is missing for selected image: $SELECTED_ISO"
    usos_ui_stage 1 5 'Opening VHD boot environment' "$SELECTED_ISO"
else
    CRC_MODULE="/usr/lib/modules/$KERNEL_RELEASE/kernel/lib/crc/crc-itu-t.ko"
    UDF_MODULE="/usr/lib/modules/$KERNEL_RELEASE/kernel/fs/udf/udf.ko"
    [ -f "$CRC_MODULE" ] || stop 'crc-itu-t module missing'
    [ -f "$UDF_MODULE" ] || stop 'udf module missing'
    insmod "$CRC_MODULE" 2>/dev/null || true
    modprobe cdrom 2>/dev/null || stop 'cannot load cdrom module required by udf'
    insmod "$UDF_MODULE" 2>/dev/null || stop 'cannot load udf module'
    usos_ui_stage 1 5 'Mounting boot ISO' "$SELECTED_ISO"
    mount -t udf -o loop,ro "$IMAGE_PATH" /mnt/source || stop 'cannot mount selected ISO'
    SOURCE_MOUNTED=yes
fi

UNATTEND_FILE=''
if [ -n "$SELECTED_UNATTEND" ] && [ "$SELECTED_UNATTEND" != none ]; then
    UNATTEND_FILE="/mnt/data/$SELECTED_UNATTEND"
    [ -f "$UNATTEND_FILE" ] || stop "selected unattended file not found: $SELECTED_UNATTEND"
fi

printf '[MICRO-LINUX] phase=prepare-requested PASS\n'
printf '[MICRO-LINUX] DATA mounted by PARTUUID=%s\n' "$DATA_PARTUUID"
printf '[MICRO-LINUX] WORK target PARTUUID=%s\n' "$WORK_PARTUUID"
printf '[MICRO-LINUX] selected image path=%s method=%s\n' "$SELECTED_ISO" "$SELECTED_METHOD"

export WORK_PARTUUID ESP_PARTUUID DATA_PARTUUID EXPECTED_DISK_PTUUID
export WORK_MOUNT=/mnt/work SOURCE_ROOT=/mnt/source STATE_FILE SOURCE_LABEL SELECTED_METHOD SELECTED_ISO WIM_FILE WIM_TEMPLATE VHD_SHARED VHD_BCD
export USOS_DEVICE_INI="$DEVICE_INI" UNATTEND_FILE WORK_FS_DRIVER=ntfs3

usos_ui_stage 2 5 'Starting device verification' 'device_guard runs before the first destructive operation.'
if [ "${USOS_WINDOWS_BIOS:-no}" = yes ]; then
    cpu_log=/mnt/esp/EFI/USOS/windows-bios-preflight.log
    {
        printf '[WINDOWS_BIOS] source=%s\n' "$SELECTED_ISO"
        cat /proc/cpuinfo
    } > "$cpu_log"
    boot_wim=$(find /mnt/source -type f | awk 'tolower($0) ~ /\/sources\/boot.wim$/ {print;exit}')
    [ -n "$boot_wim" ] || stop 'Source lacks sources/boot.wim'
    if sh /usr/lib/usos/windows_bios_cpu_check.sh "$boot_wim" > /tmp/windows-bios-cpu-check.txt 2>&1; then
        cat /tmp/windows-bios-cpu-check.txt >> "$cpu_log"
        cat /tmp/windows-bios-cpu-check.txt
        sync
    else
        cat /tmp/windows-bios-cpu-check.txt >> "$cpu_log"
        cat /tmp/windows-bios-cpu-check.txt
        sync
        stop "$(tail -n 1 /tmp/windows-bios-cpu-check.txt)"
    fi
    sh /usr/lib/usos/windows_bios_handoff.sh preflight || stop 'Windows BIOS direct boot preflight failed'
    sh /usr/lib/usos/prepare_windows_bios_boot.sh preflight || stop 'Windows BIOS source preflight failed'
fi
sh /usr/lib/usos/prepare_work.sh || stop 'prepare_work.sh failed'
if [ "${USOS_WINDOWS_BIOS:-no}" = yes ]; then
    sh /usr/lib/usos/prepare_windows_bios_boot.sh install || stop 'Windows BIOS bootstrap preparation failed'
fi
if [ "${USOS_WINDOWS_BIOS_HANDOFF:-direct}" = native ]; then
    usos_ui_stage 5 5 'RESTARTING TO WINDOWS SETUP' 'Keep the USOS USB drive connected. Setup will start automatically.'
else
    usos_ui_stage 5 5 'STARTING INSTALLER' 'Please wait. Keep the USOS USB drive connected.'
fi

if [ "$SOURCE_MOUNTED" = yes ]; then
    umount /mnt/source || stop 'cannot unmount ISO source'
fi
umount /mnt/data || stop 'cannot unmount DATA'
sync
if [ "$TEST_STOP_AFTER_PREPARED" = 1 ]; then
    printf '[MICRO-LINUX] TEST STOP AFTER PREPARED PASS; host may stop QEMU now\n'
    umount /mnt/esp || stop 'cannot unmount ESP'
    sync
    while true; do sleep 3600; done
fi
if [ "${USOS_WINDOWS_BIOS:-no}" = yes ]; then
    sh /usr/lib/usos/windows_bios_handoff.sh start || stop 'Windows BIOS direct boot failed'
    stop 'Windows BIOS direct boot unexpectedly returned'
fi
printf '[MICRO-LINUX] full preparation PASS; rebooting to USOS\n'
umount /mnt/esp || stop 'cannot unmount ESP'
sync
reboot -f
