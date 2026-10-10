# Windows Embedded POSReady 2009: the install in a VM on the target machine
# (docs/posready-2009-2026-10-10.md). Sourced after tools/w9x_phase1_qemu.sh
# (QEMU from qemu9x.cpio, w9x_phase1_run, logs).
#
# STATUS: draft, not run end to end (no POSReady product key for the test;
# QEMU 2026-10-10 stopped at Setup's "Invalid product key"). Not wired into
# the micro-Linux payload yet.
#
# tools/posready_csmwrap_target.sh has written the disk: partition 1 FAT16
# active with the PE and Setup files + Setup\unattended.xml, partition 2
# empty (Setup formats it NTFS, ModifyPartition ID 2). The VM boots THE SAME DISK (raw, IDE,
# SeaBIOS, 2 CPUs: Setup's offline PnP then picks the ACPI multiprocessor
# HAL, which the X470 needs too). Every guest restart ends QEMU (-no-reboot):
#   run 1  PE -> SetupLauncher -> Setup /unattended -> postsetup.cmd;
#   run 2+ the installed system: First Boot Agent, then the first logon,
#          whose RunOnce writes C:\USOS\POSR\DONE.TXT and shuts down.
# Partition 1 stays (FBA reads the Setup files on the first boot).

POSR_VM_BOOTS=${POSR_VM_BOOTS:-5}
POSR_VM_STALL=${POSR_VM_STALL:-900}
POSR_VM_MB=${POSR_VM_MB:-1024}
POSR_VM_DISK_BYTES=${POSR_VM_DISK_BYTES:-34359738368}

posready_vm_args() {
    case "$2" in kvm) accel='kvm' ;; *) accel='tcg,tb-size=256' ;; esac
    printf '%s\n' -name usos-posready-install -nodefaults -L "$W9X_VM_DATADIR" \
        -machine pc -accel "$accel" -cpu "${POSR_VM_CPU:-pentium3}" -smp 2 -m "$POSR_VM_MB" \
        -rtc base=localtime -vga std -display none -nic none -no-reboot \
        -drive "file=$1,format=raw,size=$POSR_VM_DISK_BYTES,if=ide,index=0,media=disk,cache=none,file.locking=off" \
        -boot order=c \
        -serial "file:$W9X_VM_RUN/serial.log" \
        -chardev "file,id=seabios,path=$W9X_VM_RUN/seabios.log" -device isa-debugcon,iobase=0x402,chardev=seabios \
        -monitor "pipe:$W9X_VM_RUN/mon" \
        -monitor "pipe:$W9X_VM_RUN/key"
}

# MBR byte of partition $2 (1..4) at offset $3 inside its 16-byte entry.
posready_mbr_byte() {
    od -An -tu1 -j $((446 + ($2 - 1) * 16 + $3)) -N1 "$1" 2>/dev/null | tr -d ' \n'
}

# Active flag on partition $2 only.
posready_set_active() {
    for i in 1 2 3 4; do
        flag='\000'; [ "$i" = "$2" ] && flag='\200'
        printf "$flag" | dd of="$1" bs=1 seek=$((446 + (i - 1) * 16)) count=1 conv=notrunc 2>/dev/null || return 1
    done
    sync
}

posready_vm_install() {
    target=$1
    logs=$2
    accel=${3:-tcg}
    W9X_VM_ARGS_FN=posready_vm_args
    W9X_VM_KEY=''
    W9X_VM_STALL_ANY=1
    W9X_VM_STALL=$POSR_VM_STALL
    W9X_VM_ANSWER=''
    W9X_VM_TEXT_ANSWER=''
    W9X_VM_TICK_FN=''
    mkdir -p "$logs"
    boot=0
    while [ "$boot" -lt "$POSR_VM_BOOTS" ]; do
        boot=$((boot + 1))
        w9x_phase1_run "$target" "$accel"
        rc=$?
        w9x_phase1_keep_logs "$logs/run-$boot"
        printf 'run %s rc=%s elapsed=%s stalled=%s active2=%s\n' "$boot" "$rc" "${W9X_VM_ELAPSED:-0}" "${W9X_VM_STALLED:-0}" \
            "$(posready_mbr_byte "$target" 2 0)" >> "$logs/runs.txt"
        [ "$rc" = 0 ] || return "$rc"
        # After run 1 the Windows partition (2) boots; unverified whether
        # Setup's BootPreparation already makes it active.
        [ "$boot" != 1 ] || posready_set_active "$target" 2 || return 2
        if posready_vm_marker "$target" DONE.TXT; then return 0; fi
    done
    return 4
}

# 0 when \USOS\POSR\$2 exists on partition 2 (NTFS, read only: kernel ntfs3
# or ntfs-3g).
posready_vm_marker() {
    m=/run/posready-marker
    mkdir -p "$m"
    start=$(od -An -tu4 -j 470 -N4 "$1" | tr -d ' \n')
    loop=$(losetup -f) || return 1
    losetup -r -o $((start * 512)) "$loop" "$1" || return 1
    found=1
    if mount -t ntfs3 -o ro "$loop" "$m" 2>/dev/null || ntfs-3g -o ro "$loop" "$m" 2>/dev/null; then
        [ -f "$m/USOS/POSR/$2" ] && found=0
        umount "$m"
    fi
    losetup -d "$loop"
    return "$found"
}
