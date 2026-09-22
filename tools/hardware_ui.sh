#!/bin/sh
# A self-contained, read-only service session using the common USOS GUI.

usos_hw_info_lines() {
    LC_ALL=C awk '{gsub(/\t/, "    "); gsub(/[^ -~]/, "?");
        gsub(/\/dev\/[A-Za-z0-9_.\/-]+/, "selected disk");
        if (NR <= 108) print "info=" substr($0,1,190);
        if (NR == 109) print "info=Further details omitted from this view."}' "$1"
}

usos_hw_menu() {
    if USOS_HW_CHOICE=$("$USOS_FB_UI" --menu "$1"); then return 0; fi
    USOS_HW_CHOICE=''
    return 1
}

usos_hw_notice() {
    printf 'mode=service\ncurrent=1\ntotal=1\ntitle=%s\ndetail=%s\nimage=%s\n' "$1" "$2" "${3:-}" | "$USOS_FB_UI" >/dev/null 2>&1 || true
}

usos_hw_system_screen() {
    usos_hw_notice 'HARDWARE INFORMATION' 'Reading CPU, memory, firmware and PCI devices.'
    usos_hw_system_report > "$USOS_HW_DIR/system.txt"
    {
        printf 'title=SYSTEM INFORMATION\nsubtitle=Descriptions reported by the CPU and firmware.\nitem=Back|Return to Hardware & SMART\n'
        usos_hw_info_lines "$USOS_HW_DIR/system.txt"
    } > "$USOS_HW_DIR/system.state"
    usos_hw_menu "$USOS_HW_DIR/system.state" || true
}

usos_hw_smart_screen() {
    local disk=$1 label=$2 summary serial
    [ -b "$disk" ] || return 0
    usos_hw_notice 'READING SMART' 'Reading drive identity and SMART.' "$label | Timeout: 20 seconds"
    if usos_smart_read "$disk" "$USOS_HW_DIR/smart.txt"; then
        summary=$(usos_smart_summary "$USOS_SMART_EXIT" "$USOS_HW_DIR/smart.txt")
    else
        summary='Invalid disk path'
        printf '%s\n' "$summary" > "$USOS_HW_DIR/smart.txt"
    fi
    serial=$(awk -F': *' '/^Serial [Nn]umber:/ {print $2; exit}' "$USOS_HW_DIR/smart.txt" | usos_hw_text)
    printf '[HARDWARE] SMART %s exit=%s status=%s\n' "$disk" "${USOS_SMART_EXIT:-unknown}" "$summary" > /dev/console
    {
        printf 'title=%s\nsubtitle=%s\n' "$label" "$summary"
        printf 'item=Refresh SMART|Read the current values again\nitem=Full report|Identity, attributes and error history; no additional disk query\nitem=Back|Return to the disk list\nselected=2\n'
        printf 'info=Serial number: %s\n' "${serial:-Unavailable}"
        usos_smart_table "$USOS_HW_DIR/smart.txt"
    } > "$USOS_HW_DIR/smart.state"
    while usos_hw_menu "$USOS_HW_DIR/smart.state"; do
        case "$USOS_HW_CHOICE" in
            1) return 10 ;;
            2)
                {
                    printf 'title=%s\nsubtitle=Full SMART report\nitem=Back|Return to the SMART table\n' "$label"
                    usos_hw_info_lines "$USOS_HW_DIR/smart.txt"
                } > "$USOS_HW_DIR/smart-full.state"
                usos_hw_menu "$USOS_HW_DIR/smart-full.state" || true
                ;;
            *) return 0 ;;
        esac
    done
}

usos_hw_disk_screen() {
    local disk model serial bytes transport count result selected label number
    while :; do
        usos_hw_notice 'DISKS & SMART' 'Reading detected disk identities.'
        mdev -s 2>/dev/null || true
        usos_hw_disks > "$USOS_HW_DIR/disks.txt"
        count=$(wc -l < "$USOS_HW_DIR/disks.txt")
        : > "$USOS_HW_DIR/disk-labels.txt"
        number=0
        {
            printf 'title=DISKS & SMART\nsubtitle=Select a disk to read its identity and health information.\n'
            while IFS= read -r disk; do
                number=$((number + 1))
                model=$(usos_hw_disk_field "$disk" MODEL)
                serial=$(usos_hw_disk_field "$disk" SERIAL)
                bytes=$(usos_hw_disk_field "$disk" SIZE)
                transport=$(usos_hw_disk_field "$disk" TRAN)
                case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac
                label="Disk $number - ${model:-Unknown model} - $(usos_hw_size "$bytes")"
                printf '%s\n' "$label" >> "$USOS_HW_DIR/disk-labels.txt"
                printf 'item=%s|%s | S/N: %s\n' "$label" "${transport:-Unknown interface}" "${serial:-Unavailable}"
            done < "$USOS_HW_DIR/disks.txt"
            printf 'item=Refresh disk list|Detect newly connected devices\nitem=Back|Return to Hardware & SMART\n'
            [ "$count" -gt 0 ] || printf 'info=No disks detected.\n'
            printf 'info=Some USB bridges and virtual disks do not expose SMART.\n'
            printf 'info=SMART is not enabled or changed automatically.\n'
        } > "$USOS_HW_DIR/disks.state"
        usos_hw_menu "$USOS_HW_DIR/disks.state" || return 0
        selected=$USOS_HW_CHOICE
        [ "$selected" -le "$((count + 1))" ] || return 0
        [ "$selected" -le "$count" ] || continue
        disk=$(sed -n "${selected}p" "$USOS_HW_DIR/disks.txt")
        label=$(sed -n "${selected}p" "$USOS_HW_DIR/disk-labels.txt")
        while :; do
            result=0
            usos_hw_smart_screen "$disk" "$label" || result=$?
            [ "$result" = 10 ] || break
        done
    done
}

usos_hardware_main() {
    USOS_HW_DIR=/run/usos-hardware
    mkdir -p "$USOS_HW_DIR"
    . /usr/lib/usos/hardware_inventory.sh
    . /usr/lib/usos/hardware_smart.sh
    usos_hw_boot_progress 4 'Initializing keyboard and mouse.'
    enable_emergency_input || true
    # Storage discovery can finish asynchronously. Refresh remains available.
    sleep 1
    mdev -s 2>/dev/null || true
    usos_hw_boot_progress 5 'Opening the hardware panel.'
    printf '[HARDWARE] READ-ONLY SESSION READY; no disk filesystems mounted\n'
    {
        printf 'title=HARDWARE & SMART\nsubtitle=Computer information and disk health.\n'
        printf 'item=System information|CPU, memory, motherboard, BIOS and PCI devices\n'
        printf 'item=Disks & SMART|Models, serial numbers, capacity and health reports\n'
        printf 'item=Return to USOS|Restart the computer\n'
    } > "$USOS_HW_DIR/main.state"
    while usos_hw_menu "$USOS_HW_DIR/main.state"; do
        case "$USOS_HW_CHOICE" in
            1) usos_hw_system_screen ;;
            2) usos_hw_disk_screen ;;
            *) break ;;
        esac
    done
    reboot -f
    while :; do sleep 3600; done
}
