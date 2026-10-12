#!/bin/sh
# Firmware boot entry for a disk USOS just prepared (Custom OS, step 620;
# docs/custom-os-2026-10-11.md 5). Haiku written to the X470 disk started
# only through the firmware's removable-media scan and had no entry of its
# own in the boot menu (user report 2026-10-12).
#
#   uefi_boot_entry.sh add       TARGET_DEVICE, ENTRY_NAME: finds the EFI
#                                system partition of TARGET_DEVICE, writes a
#                                Boot#### "ENTRY_NAME" = HD(ESP)/\EFI\BOOT\BOOTX64.EFI,
#                                puts it first in BootOrder (ENTRY_ORDER=last:
#                                appended; every other entry, the USOS stick
#                                too, stays in its order) and sets BootNext to
#                                it, so the restart starts the new disk and it
#                                stays the default and in the boot menu.
#   uefi_boot_entry.sh option    print the load option (hex) for the ESP of
#                                TARGET_DEVICE (tests)
#   uefi_boot_entry.sh esp       print "number start size mbrtype sigtype signature" (tests)
#
# The device path is the short form HD(...)/File(...) (UEFI 2.x 3.1.2; what
# bcdedit writes): the firmware finds the partition on whatever port the disk
# sits. Variables go through efivarfs only (EFIVARS_DIR, default
# /sys/firmware/efi/efivars; efivarfs.ko is in the micro-Linux), never the
# USOS stick. Each variable is written with one write() (attributes + data),
# then read back. Exit 0 = entry written, 1 = error, 2 = no UEFI variables
# (BIOS boot / efivarfs missing): the caller goes on either way, the disk
# still starts through the removable path.
set -eu

TARGET_DEVICE=${TARGET_DEVICE:?TARGET_DEVICE is required}
EFIVARS=${EFIVARS_DIR:-/sys/firmware/efi/efivars}
LOADER=${ENTRY_LOADER:-'\EFI\BOOT\BOOTX64.EFI'}
# Where the entry goes in BootOrder: "first" (default; the written system
# stays the default after BootNext is used up, X470 2026-10-12) or "last".
ORDER=${ENTRY_ORDER:-first}
case "$ORDER" in first|last) ;; *) printf '[BOOT_ENTRY] FAIL: ENTRY_ORDER must be first or last\n' >&2; exit 1 ;; esac
GLOBAL=8be4df61-93ca-11d2-aa0d-00e098032b8c
# EFI_VARIABLE_NON_VOLATILE | BOOTSERVICE_ACCESS | RUNTIME_ACCESS
ATTR=07000000

log() { printf '[BOOT_ENTRY] %s\n' "$*"; }
fail() { printf '[BOOT_ENTRY] FAIL: %s\n' "$1" >&2; exit "${2:-1}"; }

SS=${SECTOR_SIZE:-}
if [ -z "$SS" ]; then
    SS=$(blockdev --getss "$TARGET_DEVICE" 2>/dev/null) || SS=512
fi

hexdump_bytes() { dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | od -An -v -tx1 | tr -d ' \n'; }
u32_at() { od -An -tu4 -j"$2" -N4 "$1" | tr -d ' \n'; }
u8_at() { od -An -tu1 -j"$2" -N1 "$1" | tr -d ' \n'; }
le16() { printf '%02x%02x' $(($1 & 255)) $(($1 >> 8 & 255)); }
le32() { printf '%02x%02x%02x%02x' $(($1 & 255)) $(($1 >> 8 & 255)) $(($1 >> 16 & 255)) $(($1 >> 24 & 255)); }
le64() { le32 $(($1 & 4294967295)); le32 $(($1 >> 32 & 4294967295)); }
# UCS-2LE with the terminating NUL (ASCII only; other bytes become '_').
ucs2() {
    printf '%s' "$1" | od -An -v -tx1 | tr -s ' \n' '\n\n' | awk 'NF { if ($1 >= "80" || $1 < "20") $1 = "5f"; printf "%s00", $1 } END { printf "0000" }'
}
# Hex string -> bytes (one printf with octal escapes; busybox and Git sh).
hex2bin() {
    printf "$(printf '%s' "$1" | awk '{
        h = "0123456789abcdef"; s = tolower($0); out = ""
        for (i = 1; i < length(s); i += 2)
            out = out sprintf("\\%03o", (index(h, substr(s, i, 1)) - 1) * 16 + index(h, substr(s, i + 1, 1)) - 1)
        printf "%s", out }')"
}

# The EFI system partition: GPT type C12A7328-F81F-11D2-BA4B-00A0C93EC93B
# first, else an MBR slot of type EF. Prints number start size mbrtype
# sigtype signature(32 hex digits).
find_esp() {
    head=/tmp/usos-boot-entry.$$
    dd if="$TARGET_DEVICE" of="$head" bs="$SS" count=34 2>/dev/null || fail 'cannot read the disk start'
    if [ "$(dd if="$head" bs=1 skip="$SS" count=8 2>/dev/null)" = 'EFI PART' ]; then
        entries=$(u32_at "$head" $((SS + 72)))
        count=$(u32_at "$head" $((SS + 80)))
        esize=$(u32_at "$head" $((SS + 84)))
        [ "$count" -le 128 ] || count=128
        if [ "$((entries * SS + count * esize))" -gt "$((34 * SS))" ]; then
            dd if="$TARGET_DEVICE" of="$head" bs="$SS" count=$((entries + (count * esize + SS - 1) / SS)) 2>/dev/null || fail 'cannot read the GPT entries'
        fi
        i=0
        while [ "$i" -lt "$count" ]; do
            off=$((entries * SS + i * esize))
            if [ "$(hexdump_bytes "$head" "$off" 16)" = 28732ac11ff8d211ba4b00a0c93ec93b ]; then
                first=$(( $(u32_at "$head" $((off + 32))) + $(u32_at "$head" $((off + 36))) * 4294967296 ))
                last=$(( $(u32_at "$head" $((off + 40))) + $(u32_at "$head" $((off + 44))) * 4294967296 ))
                printf '%s %s %s 2 2 %s\n' $((i + 1)) "$first" $((last - first + 1)) "$(hexdump_bytes "$head" $((off + 16)) 16)"
                rm -f "$head"
                return 0
            fi
            i=$((i + 1))
        done
    fi
    if [ "$(hexdump_bytes "$head" 510 2)" = 55aa ]; then
        for slot in 0 1 2 3; do
            [ "$(u8_at "$head" $((446 + 16 * slot + 4)))" = 239 ] || continue
            printf '%s %s %s 1 1 %s000000000000000000000000\n' $((slot + 1)) \
                "$(u32_at "$head" $((446 + 16 * slot + 8)))" "$(u32_at "$head" $((446 + 16 * slot + 12)))" "$(hexdump_bytes "$head" 440 4)"
            rm -f "$head"
            return 0
        done
    fi
    rm -f "$head"
    return 1
}

# EFI_LOAD_OPTION: Attributes (LOAD_OPTION_ACTIVE), FilePathListLength,
# Description, HD(number,start,size,signature,mbrtype,sigtype) node (4/1, 42
# bytes), File(LOADER) node (4/4), End (7F/FF).
load_option() {
    set -- $(find_esp) || return 1
    [ "$#" = 6 ] || return 1
    hd="0401$(le16 42)$(le32 "$1")$(le64 "$2")$(le64 "$3")$6$(printf '%02x%02x' "$4" "$5")"
    file=$(ucs2 "$LOADER")
    file="0404$(le16 $((4 + ${#file} / 2)))$file"
    path="$hd${file}7fff0400"
    printf '01000000%s%s%s\n' "$(le16 $((${#path} / 2)))" "$(ucs2 "$NAME")" "$path"
}

var_hex() { [ -f "$EFIVARS/$1-$GLOBAL" ] && od -An -v -tx1 "$EFIVARS/$1-$GLOBAL" | tr -d ' \n'; }

# One write() of attributes + data (efivarfs replaces the whole variable),
# then the read-back.
var_write() {
    file="$EFIVARS/$1-$GLOBAL"
    tmp=/tmp/usos-boot-var.$$
    hex2bin "$ATTR$2" > "$tmp"
    bytes=$(wc -c < "$tmp" | tr -d ' ')
    [ "$bytes" = $(( (${#ATTR} + ${#2}) / 2 )) ] || { rm -f "$tmp"; fail "internal error: $1 encodes to $bytes bytes"; }
    # efivarfs marks existing variables immutable.
    [ ! -e "$file" ] || ! command -v chattr >/dev/null 2>&1 || chattr -i "$file" 2>/dev/null || true
    dd if="$tmp" of="$file" bs="$bytes" count=1 conv=notrunc 2>/dev/null || { rm -f "$tmp"; fail "cannot write $1 (the firmware refused the variable)"; }
    rm -f "$tmp"
    [ "$(var_hex "$1")" = "$ATTR$2" ] || fail "read-back: $1 differs"
}

case "${1:-add}" in
    esp)
        find_esp || fail 'no EFI system partition on the disk'
        exit 0 ;;
    option)
        NAME=${ENTRY_NAME:?ENTRY_NAME is required}
        load_option || fail 'no EFI system partition on the disk'
        exit 0 ;;
    add) ;;
    *) fail "unknown command: $1" ;;
esac

NAME=${ENTRY_NAME:?ENTRY_NAME is required}
if [ -z "${EFIVARS_DIR:-}" ]; then
    [ -d /sys/firmware/efi ] || fail 'not started through UEFI: no boot entry' 2
    if [ -z "$(ls "$EFIVARS" 2>/dev/null)" ]; then
        modprobe efivarfs 2>/dev/null || true
        mkdir -p "$EFIVARS" 2>/dev/null || true
        mount -t efivarfs efivarfs "$EFIVARS" 2>/dev/null || true
    fi
    [ -n "$(ls "$EFIVARS" 2>/dev/null)" ] || fail 'UEFI variables are not available (efivarfs)' 2
fi
[ -d "$EFIVARS" ] || fail 'UEFI variables are not available (efivarfs)' 2
option=$(load_option) || fail 'no EFI system partition on the disk'
set -- $(find_esp)
log "ESP partition $1 start=$2 size=$3 $([ "$4" = 2 ] && echo "GPT PARTUUID=$6" || echo "MBR signature=$(printf '%s' "$6" | cut -c1-8)") loader=$LOADER"

# The same entry already there (the same image written again): reuse it.
number=''
for f in "$EFIVARS"/Boot[0-9A-F][0-9A-F][0-9A-F][0-9A-F]-$GLOBAL; do
    [ -f "$f" ] || continue
    n=${f##*/Boot}
    n=${n%%-*}
    if [ "$(od -An -v -tx1 "$f" | tr -d ' \n' | cut -c9-)" = "$option" ]; then
        number=$n
        break
    fi
done
if [ -z "$number" ]; then
    i=1
    while [ "$i" -le 65535 ]; do
        n=$(printf '%04X' "$i")
        [ -e "$EFIVARS/Boot$n-$GLOBAL" ] || { number=$n; break; }
        i=$((i + 1))
    done
    [ -n "$number" ] || fail 'no free Boot#### number'
    var_write "Boot$number" "$option"
    log "Boot$number \"$NAME\" written"
else
    log "Boot$number \"$NAME\" already present"
fi
le_number=$(le16 $((0x$number)))

order=$(var_hex BootOrder | cut -c9- || true)
# Every other entry (the USOS stick, other systems) stays, in its order.
others=''
rest=$order
while [ -n "$rest" ]; do
    item=$(printf '%s' "$rest" | cut -c1-4)
    [ "$item" = "$le_number" ] || others="$others$item"
    rest=$(printf '%s' "$rest" | cut -c5-)
done
case "$ORDER" in
    first) new_order="$le_number$others" ;;
    *) if [ "$others" = "$order" ]; then new_order="$order$le_number"; else new_order=$order; fi ;;
esac
if [ "$new_order" != "$order" ]; then
    var_write BootOrder "$new_order"
    log "BootOrder: Boot$number $([ "$ORDER" = first ] && echo 'first (the default from now on; the other entries keep their order)' || echo appended)"
else
    log "BootOrder: Boot$number already $([ "$ORDER" = first ] && echo first || echo present)"
fi
var_write BootNext "$le_number"
log "BootNext=Boot$number: the restart starts \"$NAME\""
printf 'boot_entry=Boot%s\n' "$number"
