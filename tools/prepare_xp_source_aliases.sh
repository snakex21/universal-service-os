#!/bin/sh
set -eu
SOURCE_ROOT=${SOURCE_ROOT:?}
MTOOLS_IMAGE=${MTOOLS_IMAGE:?}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/xp_source_io.sh"
. "$SCRIPT_DIR/nt5_profile.sh"
usos_nt5_profile
SRC=$NT5_SOURCE_DIR
work=$(mktemp -d)
trap 'rm -f "$work/manifest" "$work/readback"; rmdir "$work"' EXIT HUP INT TERM
awk -v nt5_system="${NT5_SYSTEM:-windows-xp}" -v src_dir="$SRC" -f "$SCRIPT_DIR/xp_dosnet_aliases.awk" "$SOURCE_ROOT/$SRC/DOSNET.INF" > "$work/manifest"
printf '[XP_SOURCE_ALIASES] Preparing DOSNET destinations\n'
count=0
while IFS='|' read -r source target; do
    physical="$SOURCE_ROOT/$SRC/$source"
    [ -f "$physical" ] || physical="${physical%?}_"
    # The full ISO can already supply a destination (notably SYSTEM32's
    # uncompressed boot files). Preserve and verify that original file.
    [ ! -f "$SOURCE_ROOT/$SRC/$target" ] || physical="$SOURCE_ROOT/$SRC/$target"
    if [ ! -f "$physical" ]; then
        printf '[XP_SOURCE_ALIASES] Missing source: %s\n' "$source" >&2
        exit 1
    fi
    destination="::/\$WIN_NT\$.~LS/$SRC/$target"
    printf '[XP_SOURCE_ALIASES] %s -> %s\n' "$source" "$target"
    # Refuse to overwrite a different existing source under an alias name.
    if mcopy -o -i "$MTOOLS_IMAGE" "$destination" "$work/readback" 2>/dev/null; then
        cmp -s "$physical" "$work/readback" || { printf '[XP_SOURCE_ALIASES] Conflicting destination: %s\n' "$target" >&2; exit 1; }
    else
        mcopy -o -i "$MTOOLS_IMAGE" "$physical" "$destination"
        mcopy -o -i "$MTOOLS_IMAGE" "$destination" "$work/readback"
        cmp -s "$physical" "$work/readback" || { printf '[XP_SOURCE_ALIASES] Readback mismatch: %s\n' "$target" >&2; exit 1; }
    fi
    rm -f "$work/readback"
    count=$((count+1))
done < "$work/manifest"
printf '[XP_SOURCE_ALIASES] PASS aliases=%s byte-for-byte readback verified\n' "$count"
