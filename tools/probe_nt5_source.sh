#!/bin/sh
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
. "$SCRIPT_DIR/nt5_profile.sh"
usos_nt5_profile
if [ "$NT5_SYSTEM" = windows-xp ]; then
    exec sh "$SCRIPT_DIR/probe_xp_source.sh"
fi
SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
fail() { printf '[NT5_SOURCE] STOP: %s\n' "$1" >&2; exit 1; }
[ -f "$SOURCE_ROOT/CDROM_NT.5" ] && [ -f "$SOURCE_ROOT/CDROM_IP.5" ] || fail 'Windows 2000 Professional CD markers are missing'
[ ! -e "$SOURCE_ROOT/WIN51" ] || fail 'XP source selected as Windows 2000'
[ -f "$SOURCE_ROOT/CDROMSP4.TST" ] || [ -f "$SOURCE_ROOT/cdromsp4.tst" ] || fail 'Windows 2000 SP4 source is required'
for required in \
    I386/DOSNET.INF I386/SETUPLDR.BIN I386/NTLDR I386/NTDETECT.COM \
    I386/TXTSETUP.SIF I386/USETUP.EXE I386/SETUPDD.SY_ \
    I386/NTOSKRNL.EX_ I386/NTKRNLMP.EX_ I386/BOOTVID.DL_ I386/SP4.CAB; do
    [ -f "$SOURCE_ROOT/$required" ] || fail "Windows 2000 source missing required file: $required"
done
awk '
function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
{
    line=$0; sub(/;.*/, "", line); line=trim(line)
    if (line ~ /^\[/) { active=(tolower(line)=="[setupdata]"); next }
    if (!active) next
    n=split(line, field, "="); if(n!=2) next
    key=tolower(trim(field[1])); value=trim(field[2]); gsub(/"/, "", value)
    if(key=="majorversion") { major=value; majors++ }
    if(key=="minorversion") { minor=value; minors++ }
    if(key=="producttype") { product=value; products++ }
}
END { exit !(majors==1 && minors==1 && products==1 && major==5 && minor==0 && product==0) }
' "$SOURCE_ROOT/I386/TXTSETUP.SIF" || fail 'Expected Windows 2000 Professional SetupData version 5.0'
printf 'markers=CDROM_NT.5,CDROM_IP.5\nservice_pack_markers=CDROMSP4.TST\n'
