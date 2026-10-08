#!/bin/sh
set -eu

SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}

fail() {
    printf '[XP_SOURCE] STOP: %s\n' "$1" >&2
    exit 1
}

# XP x64 media uses AMD64 instead of I386. Reject it explicitly before the
# generic missing-I386 checks so the operator gets an actionable reason.
if [ ! -d "$SOURCE_ROOT/I386" ] && [ -d "$SOURCE_ROOT/AMD64" ]; then
    fail 'Windows XP x64/AMD64 source is not supported; USOS XP staging requires the 32-bit I386 tree'
fi

[ -f "$SOURCE_ROOT/WIN51" ] || fail 'XP source missing base marker: WIN51'
[ -d "$SOURCE_ROOT/I386" ] || fail 'XP source missing 32-bit I386 directory'

for required in \
    I386/DOSNET.INF I386/SETUPLDR.BIN I386/NTLDR I386/NTDETECT.COM \
    I386/TXTSETUP.SIF I386/USETUP.EXE I386/SETUPDD.SY_ \
    I386/NTOSKRNL.EX_ I386/NTKRNLMP.EX_ I386/BOOTVID.DL_; do
    [ -f "$SOURCE_ROOT/$required" ] || fail "XP source missing required file: $required"
done

# Edition/channel marker is deliberately flexible. Professional commonly uses
# WIN51IP, Home uses WIN51IC, and other 32-bit XP editions may use another
# WIN51I* marker. Service-pack suffixes are optional so RTM media is valid.
markers=''
service_pack_markers=''
for candidate in "$SOURCE_ROOT"/WIN51I*; do
    [ -f "$candidate" ] || continue
    name=${candidate##*/}
    if [ -z "$markers" ]; then
        markers=$name
    else
        markers="$markers,$name"
    fi
    case "$name" in
        *.SP[0-9])
            if [ -z "$service_pack_markers" ]; then
                service_pack_markers=$name
            else
                service_pack_markers="$service_pack_markers,$name"
            fi
            ;;
    esac
done
[ -n "$markers" ] || fail 'XP source missing edition marker matching WIN51I*'

# XP Media Center Edition 2005 (menu entry windows-xp-mce, nt5_profile.sh
# USOS_XP_EDITION=mce): GUI Setup installs Media Center from CD2's
# CMPNENTS\MEDIACTR\I386\MEDIACTR.CAB; only a disc with that folder merged in
# can run without asking for CD2.
media_center=no
mce_cab=$(find "$SOURCE_ROOT" -maxdepth 4 -type f -ipath '*/cmpnents/mediactr/i386/mediactr.cab' 2>/dev/null | head -n 1)
[ -z "$mce_cab" ] || media_center=yes
if [ "${USOS_XP_EDITION:-}" = mce ] && [ "$media_center" != yes ]; then
    fail 'XP Media Center Edition entry: CMPNENTS\MEDIACTR\I386\MEDIACTR.CAB is missing (only disc 1 of the two-CD set?); use a disc with CD2'"'"'s CMPNENTS folder merged in'
fi
[ -n "$service_pack_markers" ] || service_pack_markers=RTM

printf 'markers=%s\n' "$markers"
printf 'service_pack_markers=%s\n' "$service_pack_markers"
printf 'media_center=%s\n' "$media_center"
