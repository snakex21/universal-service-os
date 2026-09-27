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
# NT 5.2: Server 2003 x86 (I386, ProductType 1-3) and XP x64 (AMD64 source,
# I386 loader, ProductType 0). SetupData from the source directory's TXTSETUP.SIF.
usos_nt52_setupdata() {
    awk -v want_arch="$1" -v want_server="$2" '
    function trim(s) { gsub(/^[ \t]+|[ \t\r]+$/, "", s); return s }
    {
        line=$0; sub(/;.*/, "", line); line=trim(line)
        if (line ~ /^\[/) { active=(tolower(line)=="[setupdata]"); next }
        if (!active) next
        n=split(line, field, "="); if(n!=2) next
        key=tolower(trim(field[1])); value=tolower(trim(field[2])); gsub(/"/, "", value)
        if(key=="majorversion") { major=value; majors++ }
        if(key=="minorversion") { minor=value; minors++ }
        if(key=="producttype") { product=value; products++ }
        if(key=="architecture") { arch=value; archs++ }
    }
    END {
        server=(product+0>=1 && product+0<=3)
        exit !(majors==1 && minors==1 && products==1 && archs==1 && major==5 && minor==2 && arch==want_arch && server==want_server+0)
    }' "$3"
}
case "$NT5_SYSTEM" in
    windows-server-2003)
        [ -f "$SOURCE_ROOT/WIN51" ] || fail 'Windows Server 2003 WIN51 marker is missing'
        markers=$(cd "$SOURCE_ROOT" && ls -d WIN51I? 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        [ -n "$markers" ] || fail 'Windows Server 2003 WIN51I* edition marker is missing (CD2 or a client disc selected?)'
        for required in I386/DOSNET.INF I386/SETUPLDR.BIN I386/NTLDR I386/NTDETECT.COM I386/TXTSETUP.SIF I386/USETUP.EXE I386/SETUPDD.SY_ I386/NTOSKRNL.EX_; do
            [ -f "$SOURCE_ROOT/$required" ] || fail "Windows Server 2003 source missing required file: $required"
        done
        usos_nt52_setupdata i386 1 "$SOURCE_ROOT/I386/TXTSETUP.SIF" || fail 'Expected a Windows Server 2003 x86 source (SetupData 5.2, i386, server ProductType)'
        sp=$(cd "$SOURCE_ROOT" && ls -d WIN51I?.SP? 2>/dev/null | tr '\n' ',' | sed 's/,$//')
        printf 'markers=WIN51,%s\nservice_pack_markers=%s\n' "$markers" "${sp:-none}"
        exit 0 ;;
    windows-xp-x64)
        [ -f "$SOURCE_ROOT/WIN51" ] && [ -f "$SOURCE_ROOT/WIN51AP" ] || fail 'Windows XP x64 markers (WIN51, WIN51AP) are missing'
        for required in AMD64/DOSNET.INF AMD64/TXTSETUP.SIF AMD64/USETUP.EXE AMD64/SETUPDD.SY_ AMD64/NTOSKRNL.EX_ I386/SETUPLDR.BIN I386/NTLDR I386/NTDETECT.COM; do
            [ -f "$SOURCE_ROOT/$required" ] || fail "Windows XP x64 source missing required file: $required"
        done
        usos_nt52_setupdata amd64 0 "$SOURCE_ROOT/AMD64/TXTSETUP.SIF" || fail 'Expected a Windows XP Professional x64 source (SetupData 5.2, amd64, workstation)'
        sp=''; [ ! -f "$SOURCE_ROOT/WIN51AP.SP2" ] || sp=WIN51AP.SP2
        printf 'markers=WIN51,WIN51AP\nservice_pack_markers=%s\n' "${sp:-none}"
        exit 0 ;;
esac
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
