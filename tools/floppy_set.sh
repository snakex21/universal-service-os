# Floppy disk sets as installation media (2026-10-23): a folder in a system's
# DATA Images folder holding diskette images (disk1.img ... disk10.img, any
# names) instead of one ISO. Sourced by tools/dos_csmwrap_target.sh; the UEFI
# menu lists such a folder as one media entry (src/catalog/floppy_set.zig has
# the same rules: extensions, sizes, natural order).
#
# floppy_set_images DIR       the diskette images of DIR, one path per line,
#                             in disk order (natural sort of the names)
# floppy_set_merge DIR DEST   every file of every diskette into DEST (one flat
#                             folder, as tools/prepare_windows3_media.py built
#                             the ISOs from the same diskettes); directories on
#                             a diskette are kept, names upper case. The same
#                             file on several diskettes: the first copy wins;
#                             an identical copy is skipped silently, a
#                             different one is logged as a conflict.
# The images are only read (mtools, no loop device). Logs through `log` when
# the caller has one (stdout otherwise).

# Diskette sizes in bytes: 160/180/320/360 KiB (5.25"), 720 KiB, 1.2 MiB,
# 1.44 MiB, 2.88 MiB.
floppy_set_size_ok() {
    case "$1" in 163840|184320|327680|368640|737280|1228800|1474560|2949120) return 0 ;; esac
    return 1
}

floppy_set_log() {
    if command -v log >/dev/null 2>&1; then log "$*"; else printf '%s\n' "$*"; fi
}

floppy_set_images() {
    local image
    for image in "$1"/*; do
        [ -f "$image" ] || continue
        case "$(basename "$image" | tr '[:upper:]' '[:lower:]')" in *.img|*.ima|*.vfd|*.flp) ;; *) continue ;; esac
        floppy_set_size_ok "$(wc -c < "$image" | tr -d ' ')" || continue
        printf '%s\n' "$image"
    done | awk '{
        # natural order: case and separators ignored ("Disk 3 of 10",
        # DISK_3, disk03), every digit run compared as a number
        n = $0; sub(/.*\//, "", n); s = tolower(n); gsub(/[^a-z0-9]/, "", s); key = ""
        while (match(s, /[0-9]+/)) {
            digits = substr(s, RSTART, RLENGTH); sub(/^0+/, "", digits)
            key = key substr(s, 1, RSTART - 1) substr("00000000000000000000", 1, 20 - length(digits)) digits
            s = substr(s, RSTART + RLENGTH)
        }
        printf "%s%s\t%s\n", key, s, $0
    }' | LC_ALL=C sort | cut -f2-
}

floppy_set_merge() {
    local src=$1 dest=$2 disks=0 files=0 same=0 conflicts=0 unpack images origin old_ifs image disk count list rel name first
    mkdir -p "$dest" || return 1
    unpack="$dest.disk"
    images=$(floppy_set_images "$src")
    [ -n "$images" ] || { floppy_set_log "floppy set: no diskette images in $src"; return 1; }
    # One line per merged file: NAME<TAB>DISK (where the kept copy came from).
    origin="$dest.origin"
    : > "$origin"
    old_ifs=$IFS
    IFS='
'
    for image in $images; do
        IFS=$old_ifs
        disk=$(basename "$image")
        disks=$((disks + 1))
        rm -rf "$unpack"
        mkdir -p "$unpack"
        if ! MTOOLS_SKIP_CHECK=1 mcopy -s -n -m -i "$image" '::*' "$unpack/" >/dev/null 2>&1; then
            # An empty diskette has nothing to match; anything else is an error.
            if MTOOLS_SKIP_CHECK=1 mdir -a -i "$image" ::/ >/dev/null 2>&1 &&
                [ -z "$(find "$unpack" -type f | head -n 1)" ]; then
                floppy_set_log "floppy set: $disk has no files"
                continue
            fi
            floppy_set_log "floppy set: cannot read $disk (not a FAT diskette?)"
            rm -rf "$unpack"
            return 1
        fi
        count=0
        list=$(cd "$unpack" && find . -type f | sed 's|^\./||' | LC_ALL=C sort)
        IFS='
'
        for rel in $list; do
            IFS=$old_ifs
            name=$(printf '%s' "$rel" | tr '[:lower:]' '[:upper:]')
            count=$((count + 1))
            if [ -e "$dest/$name" ]; then
                if cmp -s "$unpack/$rel" "$dest/$name"; then
                    same=$((same + 1))
                else
                    first=$(awk -F '\t' -v n="$name" '$1 == n { print $2; exit }' "$origin")
                    floppy_set_log "floppy set: conflict $name: $disk differs from ${first:-an earlier diskette}, the copy from ${first:-the earlier diskette} is kept"
                    conflicts=$((conflicts + 1))
                fi
                continue
            fi
            case "$name" in */*) mkdir -p "$dest/${name%/*}" || return 1 ;; esac
            mv "$unpack/$rel" "$dest/$name" || { floppy_set_log "floppy set: cannot copy $name from $disk"; return 1; }
            printf '%s\t%s\n' "$name" "$disk" >> "$origin"
            files=$((files + 1))
        done
        IFS=$old_ifs
        floppy_set_log "floppy set: $disk: $count files"
    done
    IFS=$old_ifs
    rm -rf "$unpack" "$origin"
    floppy_set_log "floppy set: $disks diskettes merged, $files files, $same identical duplicates, $conflicts conflicts (first copy kept)"
    [ "$files" -gt 0 ]
}
