#!/bin/sh
# Read-only preflight: boot.wim may be newer than the Windows being installed.
set -eu
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
wim=${1:?Expected boot.wim path}
cpuinfo=${2:-/proc/cpuinfo}
unknown() { printf '[WINDOWS_BIOS] CPU CHECK UNKNOWN: %s\n' "$1"; exit 0; }
[ "$(dd if="$wim" bs=1 count=5 2>/dev/null)" = MSWIM ] || unknown 'WIM signature'
# WIM header: XML resource at 0x48, boot index at 0x78 (little endian).
set -- $(od -An -tu4 -j72 -N24 "$wim")
[ "$#" = 6 ] || unknown 'truncated WIM header'
xml_bytes=$1; size_flags_hi=$2; xml_offset=$3; offset_hi=$4; raw_bytes=$5; raw_hi=$6
[ "$offset_hi" = 0 ] && [ "$raw_hi" = 0 ] || unknown 'large XML resource'
case "$size_flags_hi" in 0|33554432) ;; *) unknown 'compressed XML resource' ;; esac
[ "$xml_bytes" = "$raw_bytes" ] && [ "$xml_bytes" -ge 2 ] && [ "$xml_bytes" -le 1048576 ] || unknown 'invalid XML length'
[ "$xml_offset" -ge 208 ] && [ "$((xml_offset+xml_bytes))" -le "$(stat -c %s "$wim")" ] || unknown 'XML outside file'
boot_index=$(od -An -tu4 -j120 -N4 "$wim" | tr -d ' \n')
case "$boot_index" in ''|*[!0-9]*|0) unknown 'no boot image' ;; esac
# Read at most 1 MiB and decode UTF-16 code units without interpreting non-ASCII
# low bytes as XML delimiters. Non-ASCII display names are irrelevant here.
metadata=$(dd if="$wim" bs=4096 skip="$((xml_offset/4096))" count="$(((xml_offset%4096+xml_bytes+4095)/4096))" 2>/dev/null |
    dd bs=1 skip="$((xml_offset%4096))" count="$xml_bytes" 2>/dev/null |
    od -An -v -tu2 | awk '{for(i=1;i<=NF;i++) if($i>0 && $i<128) printf "%c",$i; else printf "?"}' |
    awk -v boot_index="$boot_index" -f "$SCRIPT_DIR/windows_wim_version.awk") || unknown 'Windows version metadata unavailable'
set -- $metadata
[ "$#" = 3 ] || unknown 'Windows version metadata incomplete'
arch=$1; major=$2; minor=$3
printf '[WINDOWS_BIOS] boot.wim image=%s architecture=%s Windows=%s.%s\n' "$boot_index" "$arch" "$major" "$minor"
if [ "$arch" = 9 ] && { [ "$major" -gt 6 ] || { [ "$major" = 6 ] && [ "$minor" -ge 3 ]; }; }; then
    if ! awk '/^flags[ \t]*:/ {seen=1; found=0; for(i=3;i<=NF;i++) if($i=="cx16") found=1; if(!found) missing=1} END {exit !(seen && !missing)}' "$cpuinfo"; then
        printf '[WINDOWS_BIOS] CPU CHECK STOP: x64 Windows 8.1+ boot environment requires cx16\n'
        printf 'This ISO needs CMPXCHG16B. Use Windows 7 SP1 with original Setup.\n'
        exit 1
    fi
fi
printf '[WINDOWS_BIOS] CPU CHECK PASS (CMPXCHG16B requirement)\n'
