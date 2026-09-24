#!/bin/sh
# Keep the removable-media boot path (\EFI\BOOT\BOOT{X64,IA32,AA64,ARM}.EFI)
# off the prepared WORK partition.
#
# AMI Aptio (and most other UEFI firmware) lists every partition that carries
# \EFI\BOOT\BOOTX64.EFI as its own "UEFI: <disk>, Partition N" boot option.
# Only the USOS ESP may offer that path, so WORK keeps its boot chain under
# \EFI\USOS-WORK\ and USOS chainloads it from there (src/platform/uefi/
# work_boot_path.zig; the old \EFI\BOOT path is a one-release fallback).
#
#   sh work_boot_relocate.sh relocate <root>
#       Move \EFI\BOOT to \EFI\USOS-WORK. When the directory holds only boot
#       entry binaries, or the USOS Windows 7 chain (win7.original.efi), it is
#       moved as a whole. Otherwise (e.g. Linux shim/GRUB) everything is copied
#       to \EFI\USOS-WORK and only the entry binaries are removed from
#       \EFI\BOOT, so loaders that hard-code /EFI/BOOT for their config keep
#       working. Idempotent; lookups are case-insensitive.
#   sh work_boot_relocate.sh assert <root> [--require-entry]
#       Fail if <root> has a removable-media entry binary. With
#       --require-entry, also require \EFI\USOS-WORK\BOOTX64.EFI.
#   sh work_boot_relocate.sh check <root>
#       Like assert, but only prints a WARNING (for volumes USOS never writes).
#   sh work_boot_relocate.sh source-check <source root> [x64|ia32|aa64]
#       Before anything is copied: the mounted source (ISO) must carry the
#       removable-media loader of this firmware (default x64) in EFI/BOOT, any
#       case. Otherwise stop with what the media has instead (e.g. only
#       BOOTIA32.EFI: 32-bit Windows, which x64 UEFI cannot start).
set -eu

say() { printf '[WORK_BOOT] %s\n' "$1"; }
die() { printf '[WORK_BOOT] STOP: %s\n' "$1" >&2; exit 1; }

# Prints the child of $1 whose lower-cased name is $2 (type $3: d or f).
child_ci() {
    find "$1" -mindepth 1 -maxdepth 1 -type "$3" 2>/dev/null |
        awk -v want="$2" '{ n = $0; sub(/.*\//, "", n); if (tolower(n) == want) { print; exit } }'
}

is_entry_name() {
    case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
        bootx64.efi|bootia32.efi|bootaa64.efi|bootarm.efi) return 0 ;;
    esac
    return 1
}

# Lists removable-media entry binaries directly inside $1.
entries_in() {
    find "$1" -mindepth 1 -maxdepth 1 -type f 2>/dev/null |
        awk '{ n = $0; sub(/.*\//, "", n); n = tolower(n); if (n == "bootx64.efi" || n == "bootia32.efi" || n == "bootaa64.efi" || n == "bootarm.efi") print }'
}

# 0 when the whole directory can move: only files, and either all of them are
# entry binaries (Windows media) or it is the USOS Windows 7 chain.
whole_move() {
    dir=$1
    [ -z "$(find "$dir" -mindepth 1 -maxdepth 1 ! -type f 2>/dev/null)" ] || return 1
    [ -n "$(child_ci "$dir" win7.original.efi f)" ] && return 0
    for file in "$dir"/* "$dir"/.[!.]*; do
        [ -e "$file" ] || continue
        is_entry_name "${file##*/}" || return 1
    done
    return 0
}

relocate() {
    root=$1
    [ -d "$root" ] || die "root is not a directory: $root"
    efi=$(child_ci "$root" efi d)
    [ -n "$efi" ] || { say 'no EFI directory; nothing to relocate'; return 0; }
    boot=$(child_ci "$efi" boot d)
    [ -n "$boot" ] || { say 'no EFI/BOOT directory; nothing to relocate'; return 0; }
    if [ -z "$(entries_in "$boot")" ]; then
        say "EFI/BOOT has no removable-media entry; left as is: $boot"
        return 0
    fi
    target=$(child_ci "$efi" usos-work d)
    if whole_move "$boot" && [ -z "$target" ]; then
        mv "$boot" "$efi/USOS-WORK" || die "cannot rename $boot to $efi/USOS-WORK"
        say "moved $boot -> $efi/USOS-WORK"
        return 0
    fi
    [ -n "$target" ] || { target="$efi/USOS-WORK"; mkdir "$target" || die "cannot create $target"; }
    # Copy without replacing files already published in USOS-WORK.
    (cd "$boot" && find . -type d) | while IFS= read -r rel; do
        mkdir -p "$target/$rel" || exit 1
    done || die "cannot create directories below $target"
    (cd "$boot" && find . -type f) | while IFS= read -r rel; do
        [ -e "$target/$rel" ] && continue
        cp -p "$boot/$rel" "$target/$rel" || exit 1
        cmp -s "$boot/$rel" "$target/$rel" || exit 1
    done || die "cannot copy $boot to $target"
    if whole_move "$boot"; then
        rm -rf "$boot" || die "cannot remove $boot after copy"
        say "merged $boot into $target"
        return 0
    fi
    entries_in "$boot" | while IFS= read -r entry; do
        name=${entry##*/}
        copy=$(child_ci "$target" "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" f)
        [ -n "$copy" ] && [ -s "$copy" ] || exit 1
        rm -f "$entry" || exit 1
    done || die "cannot remove removable-media entries from $boot"
    say "copied $boot to $target and removed its entry binaries (other files kept for loaders that read /EFI/BOOT)"
}

# Prints removable-media entries at <root>/EFI/BOOT (any case).
removable_entries() {
    # The root is passed through the environment: awk -v would expand backslashes.
    find "$1" -mindepth 3 -maxdepth 3 -type f 2>/dev/null |
        USOS_WORK_BOOT_ROOT=$1 awk '{ rel = substr($0, length(ENVIRON["USOS_WORK_BOOT_ROOT"]) + 2); r = tolower(rel); if (r ~ /^efi\/boot\/boot(x64|ia32|aa64|arm)\.efi$/) print }'
}

assert_clean() {
    root=$1
    mode=$2
    found=$(removable_entries "$root")
    if [ -n "$found" ]; then
        if [ "$mode" = warn ]; then
            say "WARNING: removable-media boot entry outside the ESP (firmware will list this partition): $(printf '%s' "$found" | tr '\n' ' ')"
            return 0
        fi
        die "removable-media boot entry left outside the ESP: $(printf '%s' "$found" | tr '\n' ' ')"
    fi
    if [ "$mode" = require ]; then
        efi=$(child_ci "$root" efi d)
        dir=''
        [ -z "$efi" ] || dir=$(child_ci "$efi" usos-work d)
        entry=''
        [ -z "$dir" ] || entry=$(child_ci "$dir" bootx64.efi f)
        [ -n "$entry" ] && [ -s "$entry" ] || die 'EFI/USOS-WORK/BOOTX64.EFI is missing'
        say "boot entry PASS path=$entry"
    fi
    say "no removable-media entry outside the ESP PASS root=$root"
}

# Before copying: the source must have EFI/BOOT/BOOT<arch>.EFI (any case).
source_check() {
    root=$1
    want=$(printf '%s' "${2:-x64}" | tr 'A-Z' 'a-z')
    case "$want" in x64|ia32|aa64) ;; *) die "unknown firmware architecture: $want" ;; esac
    found=''
    efi=$(child_ci "$root" efi d)
    boot=''
    [ -z "$efi" ] || boot=$(child_ci "$efi" boot d)
    [ -z "$boot" ] || found=$(entries_in "$boot" | awk '{ n = $0; sub(/.*\//, "", n); printf "%s%s", sep, toupper(n); sep = " " }')
    if [ -n "$boot" ] && [ -n "$(child_ci "$boot" "boot$want.efi" f)" ]; then
        say "source loader PASS BOOT$(printf '%s' "$want" | tr 'a-z' 'A-Z').EFI (media has: $found)"
        return 0
    fi
    case "$want:$found" in
        x64:*BOOTIA32.EFI*) die "the image is 32-bit (x86): its EFI/BOOT has only $found; 64-bit UEFI cannot start it. Use 32-bit UEFI or BIOS mode (CSM), or a 64-bit ISO. Nothing was copied." ;;
        x64:*BOOTAA64.EFI*) die "the image is for ARM64 (EFI/BOOT: $found); it cannot start on this PC. Nothing was copied." ;;
        *:) die "the image has no UEFI loader (no EFI/BOOT/BOOT*.EFI); it cannot start in UEFI mode. Nothing was copied." ;;
        *) die "the image has no BOOT$(printf '%s' "$want" | tr 'a-z' 'A-Z').EFI for this firmware (EFI/BOOT: $found). Nothing was copied." ;;
    esac
}

command=${1:-}
case "$command" in
    relocate) [ "$#" -eq 2 ] || die 'usage: relocate <root>'; relocate "$2" ;;
    assert)
        [ "$#" -ge 2 ] || die 'usage: assert <root> [--require-entry]'
        mode=plain
        [ "${3:-}" != --require-entry ] || mode=require
        assert_clean "$2" "$mode"
        ;;
    check) [ "$#" -eq 2 ] || die 'usage: check <root>'; assert_clean "$2" warn ;;
    source-check) [ "$#" -ge 2 ] || die 'usage: source-check <root> [x64|ia32|aa64]'; source_check "$2" "${3:-x64}" ;;
    *) die "unknown command: $command" ;;
esac
