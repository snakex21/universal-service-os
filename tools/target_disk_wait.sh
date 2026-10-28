# Target disk wait and "no target disk" diagnostics (sourced by the disk
# pickers of steps 600 / 610 / 620: vista_disk_prepare.sh,
# vista_csmwrap_prepare.sh, w9x_csmwrap_prepare.sh).
#
# X470 2026-10-13 (B261013-184439): after a Windows 7 x86 run on the Micron
# NVMe stopped in WinPE, the next micro-Linux start (Vista x86) logged only
# "DISK /dev/sda REJECT USOS stick" and stopped with "no target disk", without
# saying whether the NVMe controller was on PCI at all. This file only adds
# diagnostics and a longer wait; it changes no disk and picks nothing:
#
#   usos_target_disk_wait STICK LOGFN STAGE TOTAL
#       waits until a disk other than STICK exists: 10 s as before; when an
#       NVMe controller (PCI class 0x0108) is present but no nvme block device
#       appeared yet, up to 60 s in all, with a countdown on the stage page
#       (unbound NVMe controllers get one modprobe of their modalias). LOGFN
#       is the flow's log function. Status 1 when no other disk appeared.
#   usos_target_disk_report
#       the inventory for the log (stdout): lsblk, PCI storage controllers
#       (class 0x0104 / 0x0106 / 0x0108) with the bound driver, and dmesg
#       lines about nvme / ahci / ata / PCI errors.
#   usos_target_disk_stop
#       the stop text for "no target disk": NVMe controller absent from PCI,
#       present without a disk, or the plain message (stdout).
command -v usos_stick_write >/dev/null 2>&1 || usos_stick_write() { "$@"; }
command -v usos_esp_append >/dev/null 2>&1 || usos_esp_append() { cat >> "$1"; }

USOS_DISK_WAIT_PCI=${USOS_DISK_WAIT_PCI:-/sys/bus/pci/devices}
USOS_DISK_WAIT_BLOCK=${USOS_DISK_WAIT_BLOCK:-/sys/class/block}

# Bus/device/function of every NVMe controller (class 0x0108xx), one per line.
usos_nvme_controllers() {
    for usos_tw_pci in "$USOS_DISK_WAIT_PCI"/*; do
        [ -r "$usos_tw_pci/class" ] || continue
        case "$(cat "$usos_tw_pci/class" 2>/dev/null)" in 0x0108*) printf '%s\n' "${usos_tw_pci##*/}" ;; esac
    done
}

# Number of NVMe namespaces (nvme<C>n<N>, not partitions) the kernel shows.
usos_nvme_block_count() {
    usos_tw_count=0
    for usos_tw_block in "$USOS_DISK_WAIT_BLOCK"/nvme*n*; do
        [ -e "$usos_tw_block" ] || continue
        case "${usos_tw_block##*/}" in *p[0-9]*) continue ;; esac
        usos_tw_count=$((usos_tw_count + 1))
    done
    printf '%s' "$usos_tw_count"
}

usos_other_disk_present() {
    lsblk -dnpo NAME,TYPE 2>/dev/null | awk '$2 == "disk" { print $1 }' | grep -qv "^$1\$"
}

usos_target_disk_wait() {
    usos_tw_stick=$1 usos_tw_log=${2:-:} usos_tw_stage=${3:-3} usos_tw_total=${4:-5}
    usos_tw_max=10 usos_tw_n=0
    while :; do
        mdev -s 2>/dev/null || true
        usos_other_disk_present "$usos_tw_stick" && { [ "$usos_tw_max" = 10 ] || "$usos_tw_log" "DISK WAIT another disk appeared after ${usos_tw_n} s"; return 0; }
        if [ "$usos_tw_n" = 10 ] && [ "$usos_tw_max" = 10 ] && [ -n "$(usos_nvme_controllers)" ] && [ "$(usos_nvme_block_count)" = 0 ]; then
            usos_tw_max=60
            "$usos_tw_log" "DISK WAIT NVMe controller(s) $(usos_nvme_controllers | tr '\n' ' ')present, no nvme block device after 10 s; waiting up to 60 s"
            for usos_tw_bdf in $(usos_nvme_controllers); do
                [ -L "$USOS_DISK_WAIT_PCI/$usos_tw_bdf/driver" ] && continue
                usos_tw_alias=$(cat "$USOS_DISK_WAIT_PCI/$usos_tw_bdf/modalias" 2>/dev/null || true)
                [ -n "$usos_tw_alias" ] || continue
                modprobe "$usos_tw_alias" 2>/dev/null
                "$usos_tw_log" "DISK WAIT $usos_tw_bdf had no driver; modprobe of its modalias exit=$?"
            done
        fi
        [ "$usos_tw_n" -lt "$usos_tw_max" ] || break
        if [ "$usos_tw_max" = 60 ]; then
            usos_ui_stage "$usos_tw_stage" "$usos_tw_total" 'Detecting disks' "Waiting for the NVMe disk to appear: $((usos_tw_max - usos_tw_n)) s left." 2>/dev/null || true
        fi
        sleep 1
        usos_tw_n=$((usos_tw_n + 1))
    done
    "$usos_tw_log" "DISK WAIT no disk other than $usos_tw_stick after ${usos_tw_n} s"
    return 1
}

usos_target_disk_report() {
    printf '%s\n' '--- no target disk: diagnostics ---'
    printf 'uptime=%s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null || true)"
    printf '%s\n' '--- lsblk -bdnpo NAME,TYPE,MODEL,SERIAL,SIZE,RO ---'
    lsblk -bdnpo NAME,TYPE,MODEL,SERIAL,SIZE,RO 2>&1 || true
    printf '%s\n' '--- PCI storage controllers (class 0x0104 / 0x0106 / 0x0108) ---'
    usos_tr_found=0
    for usos_tr_pci in "$USOS_DISK_WAIT_PCI"/*; do
        [ -r "$usos_tr_pci/class" ] || continue
        usos_tr_class=$(cat "$usos_tr_pci/class" 2>/dev/null || true)
        case "$usos_tr_class" in 0x0104*|0x0106*|0x0108*) ;; *) continue ;; esac
        usos_tr_found=$((usos_tr_found + 1))
        usos_tr_driver=none
        [ -L "$usos_tr_pci/driver" ] && usos_tr_driver=$(basename "$(readlink "$usos_tr_pci/driver")")
        printf 'PCI %s class=%s vendor=%s device=%s driver=%s enable=%s power=%s link=%s/x%s\n' "${usos_tr_pci##*/}" "$usos_tr_class" \
            "$(cat "$usos_tr_pci/vendor" 2>/dev/null)" "$(cat "$usos_tr_pci/device" 2>/dev/null)" "$usos_tr_driver" \
            "$(cat "$usos_tr_pci/enable" 2>/dev/null)" "$(cat "$usos_tr_pci/power_state" 2>/dev/null)" \
            "$(cat "$usos_tr_pci/current_link_speed" 2>/dev/null | tr ' ' '_')" "$(cat "$usos_tr_pci/current_link_width" 2>/dev/null)"
    done
    printf 'PCI storage controllers=%s nvme_controllers=%s nvme_block_devices=%s\n' "$usos_tr_found" "$(usos_nvme_controllers | grep -c .)" "$(usos_nvme_block_count)"
    printf '%s\n' '--- dmesg: nvme / ahci / ata / PCI errors ---'
    dmesg 2>/dev/null | grep -iE 'nvme|ahci|ata[0-9]|pcieport|aer|pci .*(error|fail|timeout|disabled|not ready)|BAR .*(fail|no space)' | tail -n 150 || true
    printf '%s\n' '--- end of diagnostics ---'
}

usos_target_disk_stop() {
    if [ -z "$(usos_nvme_controllers)" ]; then
        printf '%s' 'No target disk found (only the USOS stick), and no NVMe controller is visible on PCI. If an NVMe disk is installed, shut the computer down completely (power off, not restart), wait a few seconds and try again. No disk was changed.'
    elif [ "$(usos_nvme_block_count)" = 0 ]; then
        printf '%s' 'No target disk found: the NVMe controller is on PCI, but its disk did not appear within 60 s. Shut the computer down completely (power off, not restart) and try again. No disk was changed.'
    else
        printf '%s' 'No target disk found (only the USOS stick). No disk was changed.'
    fi
}
