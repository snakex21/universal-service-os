#!/bin/sh
set -eu

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
/bin/busybox --install -s

stop() {
    printf '[MICRO-LINUX] STOP: %s\n' "$1"
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

printf '[MICRO-LINUX] boot PASS\n'
mdev -s || stop 'mdev failed'
modprobe sd_mod 2>/dev/null || true
modprobe virtio_blk 2>/dev/null || true
modprobe loop 2>/dev/null || true
modprobe fuse 2>/dev/null || true
modprobe nls_ascii 2>/dev/null || true
modprobe nls_cp437 2>/dev/null || true
modprobe fat 2>/dev/null || true
modprobe vfat 2>/dev/null || true

module_path() {
    suffix=$1
    find /usr/lib/modules -type f -path "*/$suffix" -print -quit 2>/dev/null
}

load_input_module() {
    suffix=$1
    path=$(module_path "$suffix")
    if [ -z "$path" ]; then
        printf '[MICRO-LINUX] keyboard module unavailable: %s\n' "$suffix"
        return 1
    fi
    if insmod "$path" 2>/dev/null; then
        printf '[MICRO-LINUX] keyboard module loaded: %s\n' "$suffix"
        return 0
    fi
    # A built-in or already loaded dependency can make insmod report failure;
    # keep booting because the input-device probe below is authoritative.
    printf '[MICRO-LINUX] keyboard module already active or not needed: %s\n' "$suffix"
    return 0
}

# Firmware owns the keyboard while the UEFI bootmanager is running. Once the
# Linux kernel takes over, load the USB host/HID/input stack explicitly because
# this tiny initramfs does not mount Alpine's full modloop. PS/2 AT keyboard
# support is provided by the pinned virt kernel itself.
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

sleep 1
mdev -s || stop 'second mdev scan failed'
if [ -e /dev/input/event0 ]; then
    printf '[MICRO-LINUX] keyboard/input device discovery PASS\n'
else
    printf '[MICRO-LINUX] keyboard/input event node not present; console keyboard may still be PS/2/built-in\n'
fi

# Create the same stable PARTUUID namespace normally maintained by udev. The
# discovery side uses kernel major:minor nodes; all preparation code receives
# and uses only /dev/disk/by-partuuid paths.
for marker in /sys/class/block/*/partition; do
    [ -f "$marker" ] || continue
    block_dir=${marker%/partition}
    major_minor=$(cat "$block_dir/dev")
    major=${major_minor%:*}
    minor=${major_minor#*:}
    generic_name="${major}_${minor}"
    generic_path="/dev/usos-block/$generic_name"
    [ -e "$generic_path" ] || mknod "$generic_path" b "$major" "$minor"
    partuuid=$(blkid -p -s PARTUUID -o value "$generic_path" 2>/dev/null || true)
    [ -n "$partuuid" ] || continue
    ln -snf "../../usos-block/$generic_name" "/dev/disk/by-partuuid/$partuuid"
done

ESP_PARTUUID=''
GUARD_TEST_BAD_PARTUUID=''
for argument in $(cat /proc/cmdline); do
    case "$argument" in
        usos.esp_partuuid=*) ESP_PARTUUID=${argument#*=} ;;
        usos.guard_test_bad_partuuid=*) GUARD_TEST_BAD_PARTUUID=${argument#*=} ;;
    esac
done
[ -n "$ESP_PARTUUID" ] || stop 'kernel command line has no usos.esp_partuuid'
ESP_PATH="/dev/disk/by-partuuid/$ESP_PARTUUID"
[ -e "$ESP_PATH" ] || stop "ESP PARTUUID path missing: $ESP_PATH"
mount -t vfat -o rw,noatime "$ESP_PATH" /mnt/esp || stop 'cannot mount ESP'

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
[ "$CONFIG_ESP_PARTUUID" = "$ESP_PARTUUID" ] || stop 'ESP PARTUUID command line/config mismatch'

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

DATA_PATH="/dev/disk/by-partuuid/$DATA_PARTUUID"
[ -e "$DATA_PATH" ] || stop 'DATA PARTUUID path missing'
KERNEL_RELEASE=$(uname -r)
NTFS3_MODULE="/usr/lib/modules/$KERNEL_RELEASE/kernel/fs/ntfs3/ntfs3.ko"
[ -f "$NTFS3_MODULE" ] || stop 'ntfs3 module missing'
modprobe nls_utf8 2>/dev/null || true
insmod "$NTFS3_MODULE" 2>/dev/null || stop 'cannot load ntfs3 module'
mount -t ntfs3 -o ro,noatime "$DATA_PATH" /mnt/data || stop 'cannot mount DATA NTFS with ntfs3'
ISO_PATH="/mnt/data/$SELECTED_ISO"
[ -f "$ISO_PATH" ] || stop "selected ISO not found: $SELECTED_ISO"
SOURCE_LABEL=$(basename "$SELECTED_ISO")

CRC_MODULE="/usr/lib/modules/$KERNEL_RELEASE/kernel/lib/crc/crc-itu-t.ko"
UDF_MODULE="/usr/lib/modules/$KERNEL_RELEASE/kernel/fs/udf/udf.ko"
[ -f "$CRC_MODULE" ] || stop 'crc-itu-t module missing'
[ -f "$UDF_MODULE" ] || stop 'udf module missing'
insmod "$CRC_MODULE" 2>/dev/null || true
modprobe cdrom 2>/dev/null || stop 'cannot load cdrom module required by udf'
insmod "$UDF_MODULE" 2>/dev/null || stop 'cannot load udf module'
mount -t udf -o loop,ro "$ISO_PATH" /mnt/source || stop 'cannot mount selected Windows ISO'

UNATTEND_FILE=''
if [ -n "$SELECTED_UNATTEND" ] && [ "$SELECTED_UNATTEND" != none ]; then
    UNATTEND_FILE="/mnt/data/$SELECTED_UNATTEND"
    [ -f "$UNATTEND_FILE" ] || stop "selected unattended file not found: $SELECTED_UNATTEND"
fi

printf '[MICRO-LINUX] phase=prepare-requested PASS\n'
printf '[MICRO-LINUX] DATA mounted by PARTUUID=%s\n' "$DATA_PARTUUID"
printf '[MICRO-LINUX] WORK target PARTUUID=%s\n' "$WORK_PARTUUID"
printf '[MICRO-LINUX] ISO mounted path=%s\n' "$SELECTED_ISO"

export WORK_PARTUUID ESP_PARTUUID DATA_PARTUUID EXPECTED_DISK_PTUUID
export WORK_MOUNT=/mnt/work SOURCE_ROOT=/mnt/source STATE_FILE SOURCE_LABEL
export USOS_DEVICE_INI="$DEVICE_INI" UNATTEND_FILE WORK_FS_DRIVER=ntfs3

sh /usr/lib/usos/prepare_work.sh || stop 'prepare_work.sh failed'

umount /mnt/source || stop 'cannot unmount ISO source'
umount /mnt/data || stop 'cannot unmount DATA'
sync
printf '[MICRO-LINUX] full preparation PASS; rebooting to USOS\n'
umount /mnt/esp || stop 'cannot unmount ESP'
sync
reboot -f
