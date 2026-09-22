#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
fail() { printf '[WINDOWS_BIOS] STOP: %s\n' "$1" >&2; exit 1; }
case "${USOS_WINDOWS_BIOS_HANDOFF:-direct}" in
native)
    # Use the firmware-initialized Core -> wimboot path proven on MS-7100.
    # Only the identified ESP receives a one-shot request; Setup chooses the
    # installation target after the restart.
    [ -s "$SCRIPT_DIR/wimboot" ] || fail 'Native Windows boot payload is missing'
    case "${1:-}" in
    preflight) exit 0 ;;
    start)
        base=/mnt/esp/EFI/USOS
        [ -s "$base/windows-bios/boot.cpio" ] || fail 'Prepared Windows PE archive is missing'
        guid=$(printf '%s' "${WORK_PARTUUID:-}" | tr A-F a-f)
        [ "${#guid}" = 36 ] || fail 'Invalid WORK identity'
        case "$guid" in *[!a-f0-9-]*) fail 'Invalid WORK identity' ;; esac
        marker="$base/windows-bios-ready.ini"
        dd if=/dev/zero of="$marker.tmp" bs=512 count=1 2>/dev/null
        printf 'ready=1\nwork_partuuid=%s\n' "$guid" | dd of="$marker.tmp" conv=notrunc 2>/dev/null
        [ "$(wc -c < "$marker.tmp")" = 512 ] || fail 'Invalid native boot request size'
        sync
        mv "$marker.tmp" "$marker"
        printf '[WINDOWS_BIOS] NATIVE HANDOFF READY; restarting to Windows Setup\n' >> "$base/windows-bios-preflight.log"
        sync
        umount /mnt/esp || fail 'Cannot close ESP before Windows boot'
        sync
        reboot -f
        fail 'Native restart returned unexpectedly'
        ;;
    *) fail 'Expected preflight or start' ;;
    esac
    ;;
direct) ;;
*) fail 'Unknown Windows handoff mode' ;;
esac
command -v kexec >/dev/null || fail 'kexec is missing; update USOS'
[ "$(cat /proc/sys/kernel/kexec_load_disabled)" = 0 ] || fail 'Direct Windows boot is disabled; update the BIOS loader'
[ -s "$SCRIPT_DIR/wimboot-kexec" ] || fail 'BIOS handoff payload is missing'
if [ "${USOS_WINDOWS_BIOS_ORDERED:-0}" = 1 ]; then
    [ -s "$SCRIPT_DIR/wimboot-kexec-ordered" ] || fail 'Ordered BIOS handoff payload is missing'
    boot_drive=''
    for argument in $(cat /proc/cmdline); do
        case "$argument" in usos.bios_boot_drive=*) boot_drive=${argument#*=} ;; esac
    done
    case "$boot_drive" in 8[0-9a-fA-F]) ;; *) fail 'Invalid BIOS USB drive identity' ;; esac
fi
case "${1:-}" in
preflight) exit 0 ;;
start)
    archive=/mnt/esp/EFI/USOS/windows-bios/boot.cpio
    [ -s "$archive" ] || fail 'Prepared Windows PE archive is missing'
    payload="$SCRIPT_DIR/wimboot-kexec"
    if [ "${USOS_WINDOWS_BIOS_ORDERED:-0}" = 1 ]; then
        mkdir -p /run/usos
        payload=/run/usos/wimboot-kexec
        cp "$SCRIPT_DIR/wimboot-kexec-ordered" "$payload"
        byte=$((0x$boot_drive))
        printf "\\$(printf '%03o' "$byte")" | dd of="$payload" bs=1 seek=1530 conv=notrunc 2>/dev/null
        [ "$(od -An -tu1 -j1530 -N1 "$payload" | tr -d ' ')" = "$byte" ] || fail 'Cannot set BIOS USB drive identity'
    fi
    boot_args='quiet linear'
    if [ -f /mnt/esp/EFI/USOS/windows-bios-debug.ini ]; then
        boot_args='linear'
        printf '[WINDOWS_BIOS] Diagnostic mode: showing wimboot details; continuing automatically without keyboard input\n'
    fi
    kexec -c -l "$payload" --type=bzImage --real-mode \
        --mem-min=0x3000 --mem-max=0x7fffffff --initrd="$archive" \
        --append="$boot_args" || fail 'Cannot load Windows PE into RAM'
    # A new direct start must never leave an automatic restart request behind.
    rm -f /mnt/esp/EFI/USOS/windows-bios-ready.ini
    printf '[WINDOWS_BIOS] wimboot arguments: %s\n' "$boot_args" >> /mnt/esp/EFI/USOS/windows-bios-preflight.log
    printf '[WINDOWS_BIOS] Windows PE loaded into RAM; next step is direct handoff\n' >> /mnt/esp/EFI/USOS/windows-bios-preflight.log
    sync
    umount /mnt/esp || fail 'Cannot close ESP before Windows boot'
    sync
    printf '[WINDOWS_BIOS] DIRECT HANDOFF PASS; starting Windows Setup without firmware reboot\n'
    kexec -e
    fail 'Direct handoff returned unexpectedly'
    ;;
*) fail 'Expected preflight or start' ;;
esac
