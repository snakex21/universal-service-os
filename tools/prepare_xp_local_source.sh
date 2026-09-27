#!/bin/sh
set -eu

SOURCE_ROOT=${SOURCE_ROOT:?SOURCE_ROOT is required}
MTOOLS_IMAGE=${MTOOLS_IMAGE:?MTOOLS_IMAGE is required}
. "$(dirname -- "$0")/xp_source_io.sh"
# Setup source directory: I386, or AMD64 for XP x64 (its I386 holds the
# loader, NTDETECT and the WOW64 files and is copied as well).
. "$(dirname -- "$0")/nt5_profile.sh"
usos_nt5_profile
SRC=$NT5_SOURCE_DIR

fail() {
    printf '[XP_LOCAL_SOURCE] STOP: %s\n' "$1" >&2
    exit 1
}

for tool in awk cp mkdir mcopy mdir mmd mktemp tr; do
    command -v "$tool" >/dev/null 2>&1 || fail "$tool is required"
done

DOSNET="$SOURCE_ROOT/$SRC/DOSNET.INF"
for required in \
    "$DOSNET" \
    "$SOURCE_ROOT/I386/SETUPLDR.BIN" \
    "$SOURCE_ROOT/I386/NTDETECT.COM" \
    "$SOURCE_ROOT/$SRC/TXTSETUP.SIF" \
    "$SOURCE_ROOT/$SRC/USETUP.EXE"; do
    [ -f "$required" ] || fail "XP source missing required file: $required"
done

BT_DIR='$WIN_NT$.~BT'
LS_DIR='$WIN_NT$.~LS'
manifest=$(mktemp)
winnt_sif=$(mktemp)
bt_stage=$(mktemp -d)
trap 'rm -f "$manifest" "$winnt_sif"; rm -rf "$bt_stage"' EXIT HUP INT TERM

# DOSNET.INF is the authoritative list used by WINNT32 for the text-mode boot
# set. Preserve compressed source names from I386; only explicit third-column
# destinations are renamed. NTLDR is deliberately excluded: WINNT32 leaves the
# installed OS loader at the partition root and boots SETUPLDR separately.
awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
{
    line=$0
    sub(/\r$/, "", line)
    if (line ~ /^\[/) {
        upper=toupper(line)
        in_floppy=(upper ~ /^\[FLOPPYFILES\./)
        next
    }
    if (!in_floppy) next
    sub(/;.*/, "", line)
    line=trim(line)
    if (line == "") next
    n=split(line, field, ",")
    if (n < 2) next
    disk=trim(field[1])
    source=trim(field[2])
    dest=(n >= 3 ? trim(field[3]) : "")
    if (toupper(source) == "NTLDR") next
    print disk "|" source "|" dest
}
' "$DOSNET" > "$manifest"
[ -s "$manifest" ] || fail 'DOSNET.INF produced an empty FloppyFiles manifest'

mmd -i "$MTOOLS_IMAGE" "::/$BT_DIR" >/dev/null 2>&1 || fail "cannot create $BT_DIR"
mmd -i "$MTOOLS_IMAGE" "::/$LS_DIR" >/dev/null 2>&1 || fail "cannot create $LS_DIR"

# Production keeps the complete I386 tree. The focused boot-files regression
# may request a tiny ~LS subset so it can exercise XP's own system-partition
# free-space check without spending minutes copying ~545 MiB through TCG/IDE.
# This test mode is never enabled by the production staging path.
XP_LOCAL_SOURCE_TEST_MODE=${XP_LOCAL_SOURCE_TEST_MODE:-}
case "$XP_LOCAL_SOURCE_TEST_MODE" in
    '')
        printf '[XP_LOCAL_SOURCE] copying complete I386 to %s\n' "$LS_DIR"
        mcopy -s -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386" "::/$LS_DIR/" || fail 'cannot copy complete I386 into local source'
        printf '[XP_LOCAL_SOURCE] complete I386 copy PASS\n'
        if [ "$SRC" != I386 ]; then
            printf '[XP_LOCAL_SOURCE] copying complete %s to %s\n' "$SRC" "$LS_DIR"
            mcopy -s -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/$SRC" "::/$LS_DIR/" || fail "cannot copy complete $SRC into local source"
            printf '[XP_LOCAL_SOURCE] complete %s copy PASS\n' "$SRC"
        fi
        sh "$(dirname -- "$0")/prepare_xp_source_aliases.sh" || fail 'cannot prepare DOSNET local-source aliases'
        sh "$(dirname -- "$0")/prepare_nt5_media_markers.sh" || fail 'cannot prepare NT5 media markers'
        LS_MODE=complete
        ;;
    bootfiles)
        printf '[XP_LOCAL_SOURCE] TEST MODE bootfiles: preparing minimal ~LS for post-partition regression\n'
        mmd -i "$MTOOLS_IMAGE" "::/$LS_DIR/I386" >/dev/null 2>&1 || fail 'cannot create minimal ~LS/I386'
        mmd -i "$MTOOLS_IMAGE" "::/$LS_DIR/I386/SYSTEM32" >/dev/null 2>&1 || fail 'cannot create minimal ~LS/I386/SYSTEM32'
        for name in SETUPLDR.BIN NTLDR NTDETECT.COM TXTSETUP.SIF USETUP.EXE DOSNET.INF; do
            [ -f "$SOURCE_ROOT/I386/$name" ] || fail "bootfiles regression source missing I386/$name"
            mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386/$name" "::/$LS_DIR/I386/$name" || fail "cannot copy bootfiles regression I386/$name"
        done
        # Text-mode formatting loads these from the local source after the
        # partition target is accepted. Keep their original compressed source
        # names when the ISO stores them as *.EX_/*.DL_/*.SY_.
        for logical in AUTOCHK.EXE AUTOFMT.EXE FASTFAT.SYS NTFS.SYS UFAT.DLL ULIB.DLL UNTFS.DLL FORMAT.COM; do
            physical=$logical
            if [ ! -f "$SOURCE_ROOT/I386/$physical" ]; then
                physical="${logical%?}_"
            fi
            [ -f "$SOURCE_ROOT/I386/$physical" ] || fail "bootfiles regression formatter source missing I386/$logical"
            mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386/$physical" "::/$LS_DIR/I386/$physical" || fail "cannot copy bootfiles regression formatter I386/$physical"
        done
        [ -f "$SOURCE_ROOT/I386/SYSTEM32/SMSS.EXE" ] || fail 'bootfiles regression source missing I386/SYSTEM32/SMSS.EXE'
        mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386/SYSTEM32/SMSS.EXE" "::/$LS_DIR/I386/SYSTEM32/SMSS.EXE" || fail 'cannot copy bootfiles regression SYSTEM32/SMSS.EXE'
        printf '[XP_LOCAL_SOURCE] bootfiles ~LS copy PASS\n'
        LS_MODE=bootfiles-test
        ;;
    *) fail "invalid XP_LOCAL_SOURCE_TEST_MODE: $XP_LOCAL_SOURCE_TEST_MODE" ;;
esac

# The complete-I386 superset deliberately keeps the stock I386\SYSTEM32\SMSS.EXE.
# A control boot with that exact superset reached Setup without ISO, so there is
# no reason to rewrite the large FAT tree after the recursive copy. USETUP.EXE
# is still placed as SYSTEM32\SMSS.EXE in ~BT where DOSNET.INF explicitly asks
# for that rename.

bt_rows=0
while IFS='|' read -r disk logical explicit_dest; do
    # d1 = the Setup source directory; d2 = I386 on AMD64 media (loader).
    case "$SRC:$disk" in
        *:d1|*:D1) disk_dir=$SRC ;;
        AMD64:d2|AMD64:D2) disk_dir=I386 ;;
        *) fail "unsupported FloppyFiles source directory: $disk" ;;
    esac
    logical_upper=$(printf '%s' "$logical" | tr '[:lower:]' '[:upper:]')
    source_path="$SOURCE_ROOT/$disk_dir/$logical_upper"
    physical_name=$logical_upper
    if [ ! -f "$source_path" ]; then
        [ -n "$logical_upper" ] || fail 'empty DOSNET source filename'
        physical_name="${logical_upper%?}_"
        source_path="$SOURCE_ROOT/$disk_dir/$physical_name"
    fi
    [ -f "$source_path" ] || fail "DOSNET FloppyFiles source missing: $logical (tried $logical_upper and $physical_name)"

    if [ -n "$explicit_dest" ]; then
        dest=$(printf '%s' "$explicit_dest" | tr '\\' '/' | tr '[:lower:]' '[:upper:]')
    else
        dest=$physical_name
    fi
    case "$dest" in
        */*)
            parent=${dest%/*}
            mkdir -p "$bt_stage/$parent" || fail "cannot create BT staging directory: $parent"
            ;;
    esac
    cp "$source_path" "$bt_stage/$dest" || fail "cannot stage BT file: $logical -> $dest"
    bt_rows=$((bt_rows + 1))
done < "$manifest"
[ "$bt_rows" -gt 0 ] || fail 'no BT files staged from DOSNET.INF'
# One recursive mcopy avoids re-scanning a FAT32 tree with thousands of entries
# for every one of the ~118 text-mode files under TCG.
mcopy -s -o -i "$MTOOLS_IMAGE" "$bt_stage"/* "::/$BT_DIR/" || fail 'cannot copy staged BT tree'
printf '[XP_LOCAL_SOURCE] BT copy PASS rows=%s\n' "$bt_rows"

XP_WINNT_SIF=${XP_WINNT_SIF:-}
if [ -n "$XP_WINNT_SIF" ]; then
    [ -f "$XP_WINNT_SIF" ] || fail 'selected user WINNT.SIF is missing'
    mcopy -o -i "$MTOOLS_IMAGE" "$XP_WINNT_SIF" "::/$BT_DIR/WINNT.SIF" || fail 'cannot install selected user WINNT.SIF'
    printf '[XP_LOCAL_SOURCE] WINNT.SIF source=user bytes=%s\n' "$(wc -c < "$XP_WINNT_SIF" | tr -d '[:space:]')"
else
    cat > "$winnt_sif" <<'EOF'
[Data]
msdosinitiated="1"
floppyless="1"
AutoPartition="0"
UseSignatures="yes"
InstallDir="\WINDOWS"
EulaComplete="1"
winntupgrade="no"
win9xupgrade="no"
OriSrc="D:\"
OriTyp="5"
EOF
    mcopy -o -i "$MTOOLS_IMAGE" "$winnt_sif" "::/$BT_DIR/WINNT.SIF" || fail 'cannot install minimal WINNT.SIF'
    printf '[XP_LOCAL_SOURCE] WINNT.SIF source=minimal product_key=omitted\n'
fi

# Root handoff files. The custom FAT32 stage2 loads NTLDR, which is SETUPLDR
# under that name. $LDR$ is installed as well so the prepared partition also
# matches the proven NT52 local-source convention.
mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386/SETUPLDR.BIN" ::/NTLDR || fail 'cannot install root NTLDR=SETUPLDR.BIN'
mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386/SETUPLDR.BIN" '::/$LDR$' || fail 'cannot install root $LDR$'
mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/I386/NTDETECT.COM" ::/NTDETECT.COM || fail 'cannot install root NTDETECT.COM'
mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/$SRC/TXTSETUP.SIF" ::/TXTSETUP.SIF || fail 'cannot install root TXTSETUP.SIF'
if [ -f "$SOURCE_ROOT/BOOTFONT.BIN" ]; then
    mcopy -o -i "$MTOOLS_IMAGE" "$SOURCE_ROOT/BOOTFONT.BIN" ::/BOOTFONT.BIN || fail 'cannot install root BOOTFONT.BIN'
fi

for required in \
    "::/$BT_DIR/SETUPLDR.BIN" \
    "::/$BT_DIR/TXTSETUP.SIF" \
    "::/$BT_DIR/WINNT.SIF" \
    "::/$LS_DIR/I386/SETUPLDR.BIN" \
    "::/$LS_DIR/$SRC/TXTSETUP.SIF" \
    "::/$LS_DIR/$SRC/SYSTEM32/SMSS.EXE" \
    ::/NTLDR ::/NTDETECT.COM ::/TXTSETUP.SIF '::/$LDR$'; do
    mdir -i "$MTOOLS_IMAGE" "$required" >/dev/null 2>&1 || fail "prepared local source missing: $required"
done

rm -f "$manifest" "$winnt_sif"
rm -rf "$bt_stage"
trap - EXIT HUP INT TERM
if [ -n "$XP_WINNT_SIF" ]; then
    printf '[XP_LOCAL_SOURCE] PASS bt_rows=%s ls_i386=%s migrate_inf=omitted answer_file=user product_key=user-controlled\n' "$bt_rows" "$LS_MODE"
else
    printf '[XP_LOCAL_SOURCE] PASS bt_rows=%s ls_i386=%s migrate_inf=omitted answer_file=minimal product_key=omitted\n' "$bt_rows" "$LS_MODE"
fi
