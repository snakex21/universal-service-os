#!/bin/sh
# Read hardware descriptions without mounting filesystems.

usos_hw_text() {
    LC_ALL=C tr '\t\r\n|' '    ' | LC_ALL=C tr -cd ' -~' | cut -c 1-160
}

usos_hw_field() {
    local file=$1 value=''
    if [ -r "$file" ]; then value=$(cat "$file" | usos_hw_text); fi
    printf '%s' "${value:-Unavailable}"
}

usos_hw_system_report() {
    printf 'CPU: '
    awk -F': ' '/^model name[[:space:]]*:/ {print $2; exit}' /proc/cpuinfo | usos_hw_text
    printf '\nLogical CPUs: %s\n' "$(grep -c '^processor[[:space:]]*:' /proc/cpuinfo)"
    awk '/^MemTotal:/ {printf "Usable RAM: %.0f MiB\n", $2 / 1024}' /proc/meminfo
    printf '\nSystem: %s %s\n' "$(usos_hw_field /sys/class/dmi/id/sys_vendor)" "$(usos_hw_field /sys/class/dmi/id/product_name)"
    printf 'Board: %s %s\n' "$(usos_hw_field /sys/class/dmi/id/board_vendor)" "$(usos_hw_field /sys/class/dmi/id/board_name)"
    printf 'BIOS: %s %s (%s)\n' "$(usos_hw_field /sys/class/dmi/id/bios_vendor)" "$(usos_hw_field /sys/class/dmi/id/bios_version)" "$(usos_hw_field /sys/class/dmi/id/bios_date)"
    printf '\nMEMORY SLOTS (firmware-reported)\n'
    timeout 10 dmidecode -t 17 2>/dev/null | awk '
        /^[[:space:]]*(Size|Locator|Type|Speed|Configured Memory Speed|Manufacturer|Part Number):/ {sub(/^[[:space:]]*/, ""); print}
    ' || true
    printf '\nPCI DEVICES\n'
    timeout 10 lspci -nn 2>/dev/null || printf 'PCI inventory unavailable\n'
}

usos_hw_disks() {
    # Only whole physical/virtual disks; never partitions, loops or optical media.
    lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" && $1 ~ /^\/dev\/[A-Za-z0-9]+$/ {print $1}' | head -n 60
}

usos_hw_disk_field() {
    # Raw lsblk output hex-escapes spaces in model/serial names. List mode
    # keeps display text; trim column padding before using numeric values.
    lsblk -bdnlo "$2" -- "$1" 2>/dev/null | head -n 1 | usos_hw_text | sed 's/^ *//; s/ *$//'
}

usos_hw_size() {
    awk -v bytes="$1" 'BEGIN {if (bytes < 1073741824) printf "%.0f MiB", bytes/1048576; else printf "%.2f GiB", bytes/1073741824}'
}
