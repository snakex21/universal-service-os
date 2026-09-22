#!/bin/sh
set -eu

MODE=${1:-pre-format}
WORK_PARTUUID=${WORK_PARTUUID:?WORK_PARTUUID is required}
ESP_PARTUUID=${ESP_PARTUUID:?ESP_PARTUUID is required}
DATA_PARTUUID=${DATA_PARTUUID:?DATA_PARTUUID is required}
EXPECTED_DISK_PTUUID=${EXPECTED_DISK_PTUUID:?EXPECTED_DISK_PTUUID is required}
USOS_DEVICE_INI=${USOS_DEVICE_INI:?USOS_DEVICE_INI is required}

BASIC_DATA_TYPE='EBD0A0A2-B9E5-4433-87C0-68B6B72699C7'
WORK_TYPE=$BASIC_DATA_TYPE
ESP_TYPE='C12A7328-F81F-11D2-BA4B-00A0C93EC93B'
DATA_TYPE=$BASIC_DATA_TYPE
WORK_LABEL='USOS_WORK'
MARKER='/.usos-work'
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
[ -r "$SCRIPT_DIR/partuuid.sh" ] || { printf '[DEVICE_GUARD] STOP: partuuid.sh is missing\n' >&2; exit 1; }
. "$SCRIPT_DIR/partuuid.sh"

fail() {
    printf '[DEVICE_GUARD] STOP: %s\n' "$1" >&2
    exit 1
}

read_ini_nonce() {
    awk -F= '
        /^[[:space:]]*nonce[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            found=1
            exit
        }
        END { if (!found) exit 1 }
    ' "$USOS_DEVICE_INI"
}

[ "$(id -u)" -eq 0 ] || fail 'root privileges are required for block-device inspection'
command -v lsblk >/dev/null 2>&1 || fail 'lsblk is required'
command -v findmnt >/dev/null 2>&1 || fail 'findmnt is required'
[ -f "$USOS_DEVICE_INI" ] || fail "missing usos-device.ini: $USOS_DEVICE_INI"
DEVICE_NONCE=$(read_ini_nonce) || fail 'usos-device.ini has no nonce'
[ -n "$DEVICE_NONCE" ] || fail 'usos-device.ini nonce is empty'

! usos_guid_equal "$WORK_PARTUUID" "$ESP_PARTUUID" || fail 'WORK equals ESP'
! usos_guid_equal "$WORK_PARTUUID" "$DATA_PARTUUID" || fail 'WORK equals DATA'
! usos_guid_equal "$ESP_PARTUUID" "$DATA_PARTUUID" || fail 'ESP equals DATA'

WORK_PATH=$(usos_partuuid_path "$WORK_PARTUUID")
ESP_PATH=$(usos_partuuid_path "$ESP_PARTUUID")
DATA_PATH=$(usos_partuuid_path "$DATA_PARTUUID")

for path in "$WORK_PATH" "$ESP_PATH" "$DATA_PATH"; do
    [ -e "$path" ] || fail "missing PARTUUID path: $path"
done

lsblk_value() {
    path=$1
    column=$2
    lsblk -b -dnro "$column" "$path" 2>/dev/null | head -n 1
}

[ "$(lsblk_value "$WORK_PATH" TYPE)" = part ] || fail 'WORK PARTUUID is not a partition'
[ "$(lsblk_value "$ESP_PATH" TYPE)" = part ] || fail 'ESP PARTUUID is not a partition'
[ "$(lsblk_value "$DATA_PATH" TYPE)" = part ] || fail 'DATA PARTUUID is not a partition'
usos_guid_equal "$(lsblk_value "$WORK_PATH" PARTUUID)" "$WORK_PARTUUID" || fail 'WORK PARTUUID lookup mismatch'
usos_guid_equal "$(lsblk_value "$ESP_PATH" PARTUUID)" "$ESP_PARTUUID" || fail 'ESP PARTUUID lookup mismatch'
usos_guid_equal "$(lsblk_value "$DATA_PATH" PARTUUID)" "$DATA_PARTUUID" || fail 'DATA PARTUUID lookup mismatch'

WORK_PARENT=$(lsblk_value "$WORK_PATH" PKNAME)
WORK_PARTTYPE=$(lsblk_value "$WORK_PATH" PARTTYPE)
WORK_SIZE=$(lsblk_value "$WORK_PATH" SIZE)
WORK_FSTYPE=$(lsblk_value "$WORK_PATH" FSTYPE)
WORK_CURRENT_LABEL=$(lsblk_value "$WORK_PATH" LABEL)
ESP_PARENT=$(lsblk_value "$ESP_PATH" PKNAME)
ESP_PARTTYPE=$(lsblk_value "$ESP_PATH" PARTTYPE)
DATA_PARENT=$(lsblk_value "$DATA_PATH" PKNAME)
DATA_PARTTYPE=$(lsblk_value "$DATA_PATH" PARTTYPE)

[ -n "$WORK_PARENT" ] || fail 'WORK parent disk is missing'
[ "$WORK_PARENT" = "$ESP_PARENT" ] || fail 'WORK and ESP have different parent disks'
[ "$WORK_PARENT" = "$DATA_PARENT" ] || fail 'WORK and DATA have different parent disks'

usos_guid_equal "$WORK_PARTTYPE" "$WORK_TYPE" || fail 'WORK GPT type mismatch'
usos_guid_equal "$ESP_PARTTYPE" "$ESP_TYPE" || fail 'ESP GPT type mismatch'
usos_guid_equal "$DATA_PARTTYPE" "$DATA_TYPE" || fail 'DATA GPT type mismatch'

PARENT_ROW=$(lsblk -dnro NAME,TYPE,PTTYPE,PTUUID | awk -v parent="$WORK_PARENT" '$1 == parent && $2 == "disk" { print; found=1 } END { if (!found) exit 1 }') || fail 'parent disk record not found'
set -- $PARENT_ROW
PARENT_PTTYPE=$3
PARENT_PTUUID=$4

[ "$(usos_lower_ascii "$PARENT_PTTYPE")" = 'gpt' ] || fail 'parent partition table is not GPT'
usos_guid_equal "$PARENT_PTUUID" "$EXPECTED_DISK_PTUUID" || fail 'parent GPT disk UUID mismatch'

WORK_MAJMIN=$(lsblk -dn -o MAJ:MIN "$WORK_PATH") || fail 'cannot identify WORK device number'
[ -n "$WORK_MAJMIN" ] || fail 'WORK device number is empty'
ROOT_MAJMIN=$(findmnt -rn -T / -o MAJ:MIN | head -n 1)
[ "$WORK_MAJMIN" != "$ROOT_MAJMIN" ] || fail 'WORK is rootfs'
if findmnt -rn -o MAJ:MIN | grep -Fxq "$WORK_MAJMIN"; then
    fail 'WORK is mounted'
fi

marker_exists() {
    command -v ntfsls >/dev/null 2>&1 || fail 'ntfsls is required to inspect existing NTFS WORK identity'
    ntfsls -a -l -p / "$WORK_PATH" 2>/dev/null | awk '$NF == ".usos-work" { found=1 } END { exit(found ? 0 : 1) }'
}

read_marker_nonce() {
    command -v ntfscat >/dev/null 2>&1 || fail 'ntfscat is required to read existing NTFS WORK identity'
    ntfscat "$WORK_PATH" "$MARKER" 2>/dev/null | awk -F= '
        /^[[:space:]]*nonce[[:space:]]*=/ {
            value=$0
            sub(/^[^=]*=/, "", value)
            gsub(/\r/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
            found=1
            exit
        }
        END { if (!found) exit 1 }
    '
}

confirm_fresh_work() {
    current_label=${WORK_CURRENT_LABEL:--}
    expected="FORMAT ${WORK_PARTUUID} ${WORK_SIZE} ${current_label} AS ${WORK_LABEL}"
    printf '[DEVICE_GUARD] FRESH WORK CONFIRMATION REQUIRED\n' >&2
    printf 'PARTUUID=%s\nSIZE_BYTES=%s\nCURRENT_LABEL=%s\nPLANNED_LABEL=%s\n' \
        "$WORK_PARTUUID" "$WORK_SIZE" "$current_label" "$WORK_LABEL" >&2
    printf 'Type exactly: %s\n> ' "$expected" >&2
    if [ -n "${WORK_FIRST_RUN_CONFIRMATION:-}" ]; then
        answer=$WORK_FIRST_RUN_CONFIRMATION
        printf '%s\n' "$answer" >&2
    else
        IFS= read -r answer || fail 'first-run confirmation not provided'
    fi
    [ "$answer" = "$expected" ] || fail 'first-run confirmation mismatch'
}

case "$MODE" in
    pre-format)
        marker_nonce=''
        marker_status=1
        if [ "$(usos_lower_ascii "$WORK_FSTYPE")" = 'ntfs' ]; then
            if marker_exists; then
                marker_nonce=$(read_marker_nonce) || fail 'existing .usos-work cannot be read or has no nonce'
                marker_status=0
            fi
        fi

        if [ "$marker_status" -eq 0 ]; then
            [ "$WORK_CURRENT_LABEL" = "$WORK_LABEL" ] || fail "WORK label mismatch: expected $WORK_LABEL, got ${WORK_CURRENT_LABEL:--}"
            [ "$marker_nonce" = "$DEVICE_NONCE" ] || fail '.usos-work nonce does not match usos-device.ini'
            printf '[DEVICE_GUARD] PASS existing WORK identity\n'
        else
            confirm_fresh_work
            printf '[DEVICE_GUARD] PASS fresh WORK confirmation\n'
        fi
        ;;
    restore-marker)
        [ "$(usos_lower_ascii "$WORK_FSTYPE")" = 'ntfs' ] || fail 'WORK is not NTFS after format'
        [ "$WORK_CURRENT_LABEL" = "$WORK_LABEL" ] || fail "WORK label mismatch after format: expected $WORK_LABEL, got ${WORK_CURRENT_LABEL:--}"
        command -v ntfscp >/dev/null 2>&1 || fail 'ntfscp is required to restore .usos-work without mounting WORK'
        command -v ntfscat >/dev/null 2>&1 || fail 'ntfscat is required to verify restored .usos-work'
        tmp=$(mktemp)
        trap 'rm -f "$tmp"' EXIT HUP INT TERM
        printf 'nonce=%s\n' "$DEVICE_NONCE" > "$tmp"
        ntfscp "$WORK_PATH" "$tmp" "$MARKER" >/dev/null 2>&1 || fail 'failed to write .usos-work'
        restored=$(read_marker_nonce) || fail 'failed to read restored .usos-work'
        [ "$restored" = "$DEVICE_NONCE" ] || fail 'restored .usos-work nonce mismatch'
        printf '[DEVICE_GUARD] PASS marker restored\n'
        ;;
    *)
        fail "unknown mode: $MODE (expected pre-format or restore-marker)"
        ;;
esac

printf 'WORK=%s\nESP=%s\nDATA=%s\nDISK_PTUUID=%s\nWORK_SIZE_BYTES=%s\nWORK_LABEL=%s\n' \
    "$WORK_PATH" "$ESP_PATH" "$DATA_PATH" "$EXPECTED_DISK_PTUUID" "$WORK_SIZE" "${WORK_CURRENT_LABEL:--}"
