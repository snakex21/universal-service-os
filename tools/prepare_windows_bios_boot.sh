#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/partuuid.sh"
fail() { printf '[WINDOWS_BIOS] STOP: %s\n' "$1" >&2; exit 1; }
bootdir=/mnt/esp/EFI/USOS/windows-bios
source_file() { find "$SOURCE_ROOT" -type f | awk -v pattern="$1" 'tolower($0) ~ pattern {print;exit}'; }
case "${1:-}" in
preflight)
    [ -s "$SCRIPT_DIR/wimboot" ] || fail 'wimboot payload missing'
    boot_bytes=2097152
    for pattern in '/bootmgr$' '/boot/bcd$' '/boot/boot.sdi$' '/sources/boot.wim$'; do
        file=$(source_file "$pattern")
        [ -n "$file" ] && [ -s "$file" ] || fail "Source lacks $pattern"
        boot_bytes=$((boot_bytes+$(stat -c %s "$file")))
    done
    file=$(source_file '/sources/install\.(wim|esd)$')
    [ -n "$file" ] && [ -s "$file" ] || fail 'Source lacks install.wim or install.esd'
    if [ "${USOS_WINDOWS_SETUP_FROM_SOURCE:-0}" = 1 ]; then
        file=$(source_file '/sources/setup\.exe$')
        [ -n "$file" ] && [ -s "$file" ] || fail 'Vista source lacks sources/setup.exe'
    fi
    bytes=$(du -sb "$SOURCE_ROOT" | awk '{print $1}')
    size=$(lsblk -bdnro SIZE "$(usos_partuuid_path "$WORK_PARTUUID")")
    [ "$size" -gt "$((bytes+268435456))" ] || fail 'WORK is too small for this installer'
    # The consumed cache can be replaced; no boot request references it now.
    rm -f "$bootdir/boot.cpio" "$bootdir/boot.cpio.tmp"
    free_kb=$(df -Pk /mnt/esp | awk 'NR==2 {print $4}')
    [ "$((free_kb*1024))" -gt "$boot_bytes" ] || fail 'ESP has insufficient room for Windows PE boot files'
    printf '[WINDOWS_BIOS] SOURCE PASS bootmgr BCD boot.sdi boot.wim installation-image\n'
    ;;
install)
    sh "$SCRIPT_DIR/device_guard.sh" pre-format || fail 'WORK identity changed'
    stage=$(mktemp -d)
    trap 'rm -f "$stage/"*; rmdir "$stage"' EXIT HUP INT TERM
    ln -s "$(source_file '/bootmgr$')" "$stage/bootmgr"
    # Physical-only diagnostic override.  A locally generated bootmgr.exe on
    # our own ESP can prove whether bootmgr's PE entry point executes after
    # the wimboot handoff without relying on any BIOS interrupt.  Production
    # media ignores the file unless windows-bios-debug.ini is present.
    probe=/mnt/esp/EFI/USOS/windows-bios-bootmgr-probe.exe
    if [ -f /mnt/esp/EFI/USOS/windows-bios-debug.ini ] && [ -s "$probe" ]; then
        ln -s "$probe" "$stage/bootmgr.exe"
        printf '[WINDOWS_BIOS] DEBUG bootmgr entry probe enabled\n'
    fi
    ln -s "$(source_file '/boot/bcd$')" "$stage/BCD"
    ln -s "$(source_file '/boot/boot.sdi$')" "$stage/boot.sdi"
    ln -s "$(source_file '/sources/boot.wim$')" "$stage/boot.wim"
    nonce=$(awk -F= '$1=="nonce" {gsub(/\r/, "", $2);print $2;exit}' "$USOS_DEVICE_INI")
    case "$nonce" in ''|*[!a-zA-Z0-9_-]*) fail 'Invalid WORK ownership nonce' ;; esac
    setup_from_source=0
    [ "${USOS_WINDOWS_SETUP_FROM_SOURCE:-0}" != 1 ] || setup_from_source=1
    sed -e "s/@USOS_NONCE@/$nonce/g" -e "s/@USOS_SETUP_FROM_SOURCE@/$setup_from_source/g" "$SCRIPT_DIR/windows_bios_startup.cmd" | sed 's/$/\r/' > "$stage/usos-start.cmd"
    [ "${#WORK_PARTUUID}" = 36 ] || fail 'Invalid WORK partition identity'
    case "$WORK_PARTUUID" in *[!a-fA-F0-9-]*) fail 'Invalid WORK partition identity' ;; esac
    printf 'work_partuuid=%s\r\n' "$WORK_PARTUUID" > "$stage/usos-source.ini"
    for arch in x86 x86_64; do
        cp "$SCRIPT_DIR/usos-source-$arch.exe" "$stage/"
        for ext in exe cpl sys; do cp "$SCRIPT_DIR/imdisk-$arch.$ext" "$stage/"; done
    done
    cp "$SCRIPT_DIR/usos-launch-x86.exe" "$stage/usos-launch-x86.exe"
    cp "$SCRIPT_DIR/usos-launch-x86_64.exe" "$stage/usos-launch-AMD64.exe"
    for name in usos-imdisk-README.txt usos-imdisk-LICENSE.txt usos-imdisk-source.zip; do cp "$SCRIPT_DIR/$name" "$stage/"; done
    # Native GUI launcher hides the preparation console and exposes diagnostics
    # only on failure. Winpeshl expands the architecture from the booted WinPE.
    printf '[LaunchApp]\r\nAppPath=%%SYSTEMROOT%%\\System32\\usos-launch-%%PROCESSOR_ARCHITECTURE%%.exe\r\n' > "$stage/winpeshl.ini"
    mkdir -p "$bootdir"
    cp "$SCRIPT_DIR/wimboot" "$bootdir/wimboot"
    (cd "$stage"; printf '%s\n' * | cpio -o -L -H newc) > "$bootdir/boot.cpio.tmp" || fail 'Cannot construct Windows PE archive'
    [ "$(dd if="$bootdir/boot.cpio.tmp" bs=1 count=6 2>/dev/null)" = 070701 ] || fail 'Invalid Windows PE archive'
    sync
    mv "$bootdir/boot.cpio.tmp" "$bootdir/boot.cpio"
    rm -f /mnt/esp/EFI/USOS/windows-bios-ready.ini
    sync
    printf '[WINDOWS_BIOS] PREPARED PASS wimboot direct-handoff-ready\n'
    ;;
*) fail 'Expected preflight or install' ;;
esac
