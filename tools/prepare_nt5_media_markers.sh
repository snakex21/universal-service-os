#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/nt5_profile.sh"
usos_nt5_profile
[ "$NT5_SYSTEM" = windows-2000 ] || exit 0
SOURCE_ROOT=${SOURCE_ROOT:?}
MTOOLS_IMAGE=${MTOOLS_IMAGE:?}
. "$SCRIPT_DIR/xp_source_io.sh"
fail() { printf '[NT5_MARKERS] STOP: %s\n' "$1" >&2; exit 1; }
for marker in CDROM_NT.5 CDROM_IP.5; do
    [ -f "$SOURCE_ROOT/$marker" ] || fail "missing source marker: $marker"
done
sp4="$SOURCE_ROOT/CDROMSP4.TST"
[ -f "$sp4" ] || sp4="$SOURCE_ROOT/cdromsp4.tst"
[ -f "$sp4" ] || fail 'missing SP4 marker'
readback=$(mktemp)
trap 'rm -f "$readback"' EXIT HUP INT TERM
for marker in CDROM_NT.5 CDROM_IP.5 CDROMSP4.TST; do
    source="$SOURCE_ROOT/$marker"
    [ "$marker" != CDROMSP4.TST ] || source=$sp4
    for directory in '::/' '::/$WIN_NT$.~LS/'; do
        mcopy -o -i "$MTOOLS_IMAGE" "$source" "$directory$marker" || fail "cannot copy $marker"
        mcopy -o -i "$MTOOLS_IMAGE" "$directory$marker" "$readback" || fail "cannot read back $marker"
        cmp -s "$source" "$readback" || fail "marker readback mismatch: $marker"
    done
done
printf '[NT5_MARKERS] Windows 2000 SP4 local media markers verified\n'
