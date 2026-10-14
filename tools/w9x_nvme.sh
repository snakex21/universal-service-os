# Windows 95 OSR2 / 98 / 98 SE / Me on an NVMe target: usosnvme.mpd, the
# USOS NVMe SCSI miniport for SCSIPORT.PDR (tools/nt/usosnvme, USOSNVME_W9X;
# docs/research/nvme-9x-2026-10-13.md). Without it Windows reaches the disk
# through CSMWrap's SeaBIOS INT 13h only (MS-DOS compatibility mode).
#
# Experimental until an X470 pass: only with DATA
# Systems\Windows\<9x folder>\Unattended\nvme-experimental.txt. The driver
# is refused (the disk stays in compatibility mode, the install goes on) when
# the namespace does not use 512-byte sectors or BAR0 lies above 4 GiB
# (Windows 9x VMM maps 32-bit physical addresses only).
#
# Sourced by tools/w9x_csmwrap_target.sh (check, INF lines, U9NVME=1 for
# INSTALL.BAT) and tools/w9x_csmwrap_prepare.sh (after the VM phase 1: the
# INF into C:\WINDOWS\INF and the MPD into C:\WINDOWS\SYSTEM\IOSUBSYS, so
# Windows' first start on the real PC installs the driver for the new PCI
# device without a disk prompt). Universal Service OS, GPL-3.0-or-later.

W9X_NVME_SYSFS=${W9X_NVME_SYSFS:-/sys}

# The PCI function directory (sysfs) of an NVMe namespace block device.
w9x_nvme_pci() {
    wn_blk=$W9X_NVME_SYSFS/class/block/${1##*/}
    for wn_cand in "$wn_blk/device/device" "$wn_blk"/device/nvme*/device; do
        [ -r "$wn_cand/class" ] || continue
        readlink -f "$wn_cand" 2>/dev/null || printf '%s\n' "$wn_cand"
        return 0
    done
    return 1
}

# w9x_nvme_check DEVICE: 0 when usosnvme.mpd can serve the disk, else 1 and
# the reason on stdout.
w9x_nvme_check() {
    wn_dev=${1##*/}
    case "$wn_dev" in nvme*n*) ;; *) echo "$1 is not an NVMe namespace"; return 1 ;; esac
    wn_lbs=$(cat "$W9X_NVME_SYSFS/class/block/$wn_dev/queue/logical_block_size" 2>/dev/null)
    [ "$wn_lbs" = 512 ] || { echo "the NVMe namespace uses ${wn_lbs:-?}-byte sectors (usosnvme.mpd supports 512 only)"; return 1; }
    wn_pci=$(w9x_nvme_pci "$wn_dev") || { echo "no PCI function found for $wn_dev"; return 1; }
    wn_class=$(cat "$wn_pci/class" 2>/dev/null)
    [ "$wn_class" = 0x010802 ] || { echo "PCI class ${wn_class:-?} is not NVMe (0x010802)"; return 1; }
    wn_start=$(awk 'NR == 1 { print $1 }' "$wn_pci/resource" 2>/dev/null)
    [ -n "$wn_start" ] || { echo "cannot read BAR0 of $wn_pci"; return 1; }
    # 0x + 16 hex digits: anything set above the low 8 digits = above 4 GiB
    wn_high=$(printf '%s' "${wn_start#0x}" | sed -e 's/........$//' -e 's/^0*//')
    if [ -n "$wn_high" ]; then
        echo "BAR0 $wn_start is above 4 GiB (Windows 9x maps 32-bit addresses only; firmware: Above 4G Decoding off)"
        return 1
    fi
    return 0
}

# "PCI\VEN_xxxx&DEV_yyyy" of the target's controller (upper case).
w9x_nvme_hwid() {
    wn_pci=$(w9x_nvme_pci "$1") || return 1
    wn_v=$(sed 's/^0x//' "$wn_pci/vendor" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    wn_d=$(sed 's/^0x//' "$wn_pci/device" 2>/dev/null | tr '[:lower:]' '[:upper:]')
    [ -n "$wn_v" ] && [ -n "$wn_d" ] || return 1
    printf 'PCI\\VEN_%s&DEV_%s\n' "$wn_v" "$wn_d"
}

# USOSNVME.INF (stdin -> stdout) with a line for the hardware ID $1 after
# the PCI\CC_010802 line of [USOS.Mfg].
w9x_nvme_inf_add_id() {
    # The ID through the environment: awk -v would eat its backslash.
    W9X_NVME_ID=$1 awk '{ print }
        /^%USOSNVME\.DeviceDesc%=USOSNVME, PCI\\CC_010802/ && ENVIRON["W9X_NVME_ID"] != "" {
            printf "%%USOSNVME.DeviceDesc%%=USOSNVME, %s\r\n", ENVIRON["W9X_NVME_ID"]
        }'
}

# w9x_nvme_inject PARTITION_DEVICE: after the VM phase 1, the INF and the MPD
# from C:\USOS9X into the installed Windows (mtools on the FAT32 partition).
# No-op without C:\USOS9X\USOSNVME.MPD (driver not chosen).
w9x_nvme_inject() {
    wn_img=$1
    wn_tmp=${TMPDIR:-/tmp}/w9x-nvme.$$
    rm -rf "$wn_tmp"; mkdir -p "$wn_tmp" || return 1
    if ! mcopy -n -i "$wn_img" ::/USOS9X/USOSNVME.MPD "$wn_tmp/USOSNVME.MPD" 2>/dev/null; then
        rm -rf "$wn_tmp"; echo 'no usosnvme.mpd on C: (driver not chosen)'; return 0
    fi
    mcopy -n -i "$wn_img" ::/USOS9X/USOSNVME.INF "$wn_tmp/USOSNVME.INF" 2>/dev/null || { rm -rf "$wn_tmp"; echo 'USOSNVME.INF missing on C:'; return 1; }
    mdir -i "$wn_img" ::/WINDOWS/SYSTEM/IOSUBSYS >/dev/null 2>&1 || { rm -rf "$wn_tmp"; echo 'C:\WINDOWS\SYSTEM\IOSUBSYS missing (phase 1 incomplete)'; return 1; }
    mcopy -o -i "$wn_img" "$wn_tmp/USOSNVME.MPD" ::/WINDOWS/SYSTEM/IOSUBSYS/USOSNVME.MPD &&
        mcopy -o -i "$wn_img" "$wn_tmp/USOSNVME.INF" ::/WINDOWS/INF/USOSNVME.INF || { rm -rf "$wn_tmp"; echo 'cannot copy usosnvme into C:\WINDOWS'; return 1; }
    rm -rf "$wn_tmp"
    echo 'usosnvme.mpd -> C:\WINDOWS\SYSTEM\IOSUBSYS, USOSNVME.INF -> C:\WINDOWS\INF'
    return 0
}
