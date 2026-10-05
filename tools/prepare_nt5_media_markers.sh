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
# CDROM_NT.5 plus the edition marker (probe_nt5_source.sh): CDROM_IP.5
# Professional, CDROM_IS.5 Server, CDROM_IA.5 Advanced Server; and the SP4
# marker when the source has one (Professional requires it, Server may be RTM).
[ -f "$SOURCE_ROOT/CDROM_NT.5" ] || fail 'missing source marker: CDROM_NT.5'
markers=CDROM_NT.5
for marker in CDROM_IP.5 CDROM_IS.5 CDROM_IA.5; do
    [ ! -f "$SOURCE_ROOT/$marker" ] || markers="$markers $marker"
done
[ "$markers" != CDROM_NT.5 ] || fail 'missing Windows 2000 edition marker (CDROM_IP.5, CDROM_IS.5 or CDROM_IA.5)'
sp4="$SOURCE_ROOT/CDROMSP4.TST"
[ -f "$sp4" ] || sp4="$SOURCE_ROOT/cdromsp4.tst"
if [ -f "$sp4" ]; then
    markers="$markers CDROMSP4.TST"
else
    case "$markers" in *CDROM_IP.5*) fail 'missing SP4 marker' ;; esac
fi
readback=$(mktemp)
trap 'rm -f "$readback"' EXIT HUP INT TERM
for marker in $markers; do
    source="$SOURCE_ROOT/$marker"
    [ "$marker" != CDROMSP4.TST ] || source=$sp4
    for directory in '::/' '::/$WIN_NT$.~LS/'; do
        mcopy -o -i "$MTOOLS_IMAGE" "$source" "$directory$marker" || fail "cannot copy $marker"
        mcopy -o -i "$MTOOLS_IMAGE" "$directory$marker" "$readback" || fail "cannot read back $marker"
        cmp -s "$source" "$readback" || fail "marker readback mismatch: $marker"
    done
done
case "$markers" in
    *CDROM_IP.5*) printf '[NT5_MARKERS] Windows 2000 SP4 local media markers verified\n' ;;
    *) printf '[NT5_MARKERS] Windows 2000 Server local media markers verified (%s)\n' "$markers" ;;
esac
