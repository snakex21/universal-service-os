# Windows Embedded POSReady 2009: the install in a VM on the target machine
# (docs/posready-2009-2026-10-10.md). Sourced after tools/w9x_phase1_qemu.sh
# (QEMU from qemu9x.cpio, w9x_phase1_run, logs).
#
# tools/posready_csmwrap_target.sh has written the disk: partition 1 FAT16
# active with the PE and Setup files + Setup\unattended.xml + \USOS\POSR,
# partition 2 empty (Setup formats it NTFS, ModifyPartition ID 2). The VM
# boots THE SAME DISK (raw, IDE, SeaBIOS, ONE CPU: Setup's offline PnP then
# installs the ACPI uniprocessor HAL and kernel; with 2 CPUs it installed
# halmacpi + the MP kernel, untested past the first start). Every guest
# restart ends QEMU (-no-reboot):
#   run 1   PE -> SetupLauncher -> Setup /unattended; then
#           posready_after_setup (boot files, BOOT.INI /execute, USOS MBR);
#   run 2-4 the installed system: First Boot Agent (it restarts 3 times);
#   run 5   the logon dialog: Administrator typed (blank password); the
#           RunOnce starts \USOS\POSR\FIRST.CMD from partition 1: drivers,
#           DONE.TXT, shutdown.
# Partition 1 stays: the system partition (NTLDR, BOOT.INI) and the source.

POSR_VM_BOOTS=${POSR_VM_BOOTS:-8}
POSR_VM_STALL=${POSR_VM_STALL:-900}
POSR_VM_MB=${POSR_VM_MB:-1024}
# The disk the VM sees: the whole target up to 33 GiB (the target script
# ends the Windows partition at 32 GiB; the CSMWrap ESP comes after the VM).
POSR_VM_DISK_MAX=${POSR_VM_DISK_MAX:-35433480192}

posready_vm_args() {
    case "$2" in kvm) accel='kvm' ;; *) accel='tcg,tb-size=256' ;; esac
    bytes=$(blockdev --getsize64 "$1" 2>/dev/null || echo "$POSR_VM_DISK_MAX")
    [ "$bytes" -le "$POSR_VM_DISK_MAX" ] || bytes=$POSR_VM_DISK_MAX
    bytes=$((bytes / 512 * 512))
    printf '%s\n' -name usos-posready-install -nodefaults -L "$W9X_VM_DATADIR" \
        -machine pc -accel "$accel" -cpu "${POSR_VM_CPU:-pentium3}" -smp 1 -m "$POSR_VM_MB" \
        -rtc base=localtime -vga std -display none -nic none -no-reboot \
        -drive "file=$1,format=raw,size=$bytes,if=ide,index=0,media=disk,cache=none,file.locking=off" \
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

# Runs the VM until FIRST.CMD wrote \USOS\POSR\DONE.TXT on partition 1.
# Calls posready_vm_progress RUN ELAPSED WRITTEN_MB when the caller defines
# it. 0 = done, 2 = QEMU or the after-setup step failed, 3 = timeout or no
# disk write for POSR_VM_STALL seconds, 4 = no DONE.TXT after POSR_VM_BOOTS
# runs. Logs of every run in $2/run-N.
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
        POSR_VM_BOOT=$boot
        w9x_phase1_progress() { command -v posready_vm_progress >/dev/null 2>&1 && posready_vm_progress "$POSR_VM_BOOT" "$1" "$2"; return 0; }
        w9x_phase1_run "$target" "$accel"
        rc=$?
        w9x_phase1_keep_logs "$logs/run-$boot"
        printf 'run %s rc=%s elapsed=%s stalled=%s active1=%s\n' "$boot" "$rc" "${W9X_VM_ELAPSED:-0}" "${W9X_VM_STALLED:-0}" \
            "$(posready_mbr_byte "$target" 1 0)" >> "$logs/runs.txt"
        [ "$rc" = 0 ] || return "$rc"
        [ "$boot" != 1 ] || posready_after_setup "$target" "$logs" || return 2
        # After the First Boot Agent the classic logon dialog waits (POSReady
        # has no autologon answer; QEMU 2026-10-10): Administrator, blank
        # password, typed when the screen sat idle (W9X_VM_ANSWER_IDLE).
        W9X_VM_ANSWER=${POSR_VM_LOGON_KEYS:-shift-a d m i n i s t r a t o r ret}
        if posready_vm_marker "$target" DONE.TXT; then return 0; fi
    done
    return 4
}

# 0 when \USOS\POSR\$2 exists on partition 1 (FAT16, mtools, read only).
posready_vm_marker() {
    off=$(( $(od -An -tu4 -j 454 -N4 "$1" | tr -d ' \n') * 512 ))
    MTOOLS_SKIP_CHECK=1 mdir -i "$1@@$off" "::/USOS/POSR/$2" >/dev/null 2>&1
}

# After the VM: FIRST.LOG of the first logon (the community ACPI check) and
# the installed system checked read-only. Prints a one-line summary; rc 1
# when something is missing.
posready_vm_finish() {
    t=$1
    l=$2
    off=$(( $(od -An -tu4 -j 454 -N4 "$t" | tr -d ' \n') * 512 ))
    MTOOLS_SKIP_CHECK=1 mtype -i "$t@@$off" ::/USOS/POSR/FIRST.LOG > "$l/FIRST.LOG" 2>/dev/null || { echo 'no FIRST.LOG'; return 1; }
    MTOOLS_SKIP_CHECK=1 mtype -i "$t@@$off" ::/BOOT.INI > "$l/BOOT.INI" 2>/dev/null || { echo 'no BOOT.INI on partition 1'; return 1; }
    w=/run/posready-finish
    mkdir -p "$w"
    p2=$(od -An -tu4 -j 470 -N4 "$t" | tr -d ' \n')
    lp=$(losetup -f) && losetup -r -o $((p2 * 512)) "$lp" "$t" || { echo 'no loop device'; return 1; }
    rc=0
    if mount -t ntfs3 -o ro "$lp" "$w"; then
        win=$w/Windows; [ -d "$win" ] || win=$w/WINDOWS
        acpi=$(sha256sum "$win/system32/drivers/acpi.sys" 2>/dev/null | cut -c1-64)
        want=$(sha256sum /usr/lib/usos/posready/DRV/acpi.sys 2>/dev/null | cut -c1-64)
        [ -n "$acpi" ] && [ "$acpi" = "$want" ] || { echo 'acpi.sys on the system is not the community ACPI'; rc=1; }
        [ -f "$win/system32/drivers/genahci.sys" ] || { echo 'genahci.sys missing'; rc=1; }
        [ -f "$win/system32/drivers/usbxhci.sys" ] || { echo 'usbxhci.sys missing'; rc=1; }
        umount "$w"
    else
        echo 'cannot mount the Windows partition'; rc=1
    fi
    losetup -d "$lp"
    [ "$rc" = 0 ] && echo "POSReady installed; community ACPI, GenAHCI, USB3 in place"
    return "$rc"
}

# After run 1 (QEMU 2026-10-10): POSReady Setup treats the ACTIVE partition
# (1, FAT16) as the system partition: BOOT.INI there points at
# partition(2)\Windows, but its NTLDR is still the PE's SETUPLDR and Setup
# wrote a Microsoft MBR ("Error loading operating system" on the restart).
# NTLDR / NTDETECT.COM in the root of partition 2 with partition 2 active
# stopped NTLDR with TRAP 6 (whpx) or hung (TCG). So partition 1 stays the
# system partition: its NTLDR / NTDETECT.COM become the disc's Setup\NTLdr /
# Setup\NTDetect.com (SYSLINUX keeps chaining /NTLDR), BOOT.INI gets a short
# timeout, and the USOS MBR code goes back (it boots the active partition by
# LBA). Partition 2 is only checked (ro). Logs to $2.
posready_after_setup() {
    t=$1
    l=$2
    lib=${USOS_LIB_DIR:-/usr/lib/usos}
    w=/run/posready-after
    mkdir -p "$w/pe" "$w/win"
    p1=$(od -An -tu4 -j 454 -N4 "$t" | tr -d ' \n')
    p2=$(od -An -tu4 -j 470 -N4 "$t" | tr -d ' \n')
    l1=$(losetup -f) && losetup -o $((p1 * 512)) "$l1" "$t" || return 1
    l2=$(losetup -f) && losetup -r -o $((p2 * 512)) "$l2" "$t" || { losetup -d "$l1"; return 1; }
    rc=0
    if mount -t vfat -o utf8=0,shortname=mixed "$l1" "$w/pe" && mount -t ntfs3 -o ro "$l2" "$w/win"; then
        if [ ! -f "$w/win/WINDOWS/system32/ntoskrnl.exe" ] && [ ! -f "$w/win/Windows/system32/ntoskrnl.exe" ]; then
            echo 'after-setup: no Windows\system32\ntoskrnl.exe on partition 2' >> "$l/runs.txt"; rc=1
        elif [ ! -f "$w/pe/BOOT.INI" ] && [ ! -f "$w/pe/boot.ini" ]; then
            echo 'after-setup: Setup wrote no BOOT.INI on partition 1' >> "$l/runs.txt"; rc=1
        else
            cp "$w/pe/Setup/NTLdr" "$w/pe/NTLDR" && cp "$w/pe/Setup/NTDetect.com" "$w/pe/NTDETECT.COM" || {
                echo 'after-setup: cannot copy Setup\NTLdr / Setup\NTDetect.com' >> "$l/runs.txt"; rc=1; }
            ini=$w/pe/BOOT.INI; [ -f "$ini" ] || ini=$w/pe/boot.ini
            cp "$ini" "$l/setup-boot.ini" 2>/dev/null || true
            # /execute (DEP off, no PAE): Setup installs no ntkrnlpa.exe ("could
            # not be found by setup"), and on an NX CPU NTLDR would load the
            # PAE kernel (QEMU 2026-10-10, whpx: "hal.dll missing or corrupt").
            awk '{ sub(/\r$/, "") } /^timeout=/ { $0 = "timeout=3" }
                /^multi\(/ && /=/ && !/\/execute/ { $0 = $0 " /execute" } { printf "%s\r\n", $0 }' "$ini" > "$w/boot.ini" &&
                cat "$w/boot.ini" > "$ini" || rc=1
        fi
    else
        echo 'after-setup: cannot mount partition 1 (FAT) or 2 (NTFS)' >> "$l/runs.txt"; rc=1
    fi
    sync
    umount "$w/win" 2>/dev/null; umount "$w/pe" 2>/dev/null
    losetup -d "$l2"; losetup -d "$l1"
    [ "$rc" = 0 ] || return 1
    dd if="$lib/xp-geometry-fix-mbr-440.bin" of="$t" bs=440 count=1 conv=notrunc 2>/dev/null || return 1
    posready_set_active "$t" 1 || return 1
    echo 'after-setup: partition 1 NTLDR = Setup\NTLdr, BOOT.INI from Setup, USOS MBR' >> "$l/runs.txt"
}

# unattended.xml (stdout) from the template $1 and the menu's POSR.SIF $2
# (src/flow/answer/posready.zig: FullName, Organization, ComputerName,
# AdminPassword, ProductKey; values without quotes or angle brackets). Never
# logs the key. rc 1 without a ProductKey.
posready_answer_xml() {
    awk -v sif="$2" '
        BEGIN {
            while ((getline line < sif) > 0) {
                sub(/\r$/, "", line)
                if (line ~ /^;/ || line !~ /=/) continue
                k = line; sub(/=.*/, "", k); v = line; sub(/^[^=]*=/, "", v)
                gsub(/["<>&]/, "", v)
                val[k] = v
            }
            if (val["ProductKey"] == "") exit 3
            if (val["FullName"] == "") val["FullName"] = "USOS"
            if (val["ComputerName"] == "") val["ComputerName"] = "USOS-POSREADY"
            n = split("PRODUCT_KEY=ProductKey FULL_NAME=FullName ORGANIZATION=Organization COMPUTER_NAME=ComputerName ADMIN_PASSWORD=AdminPassword", pairs, " ")
            for (i = 1; i <= n; i++) { split(pairs[i], kv, "="); ph["@" kv[1] "@"] = val[kv[2]] }
        }
        {
            for (p in ph) {
                out = ""
                while ((at = index($0, p)) > 0) { out = out substr($0, 1, at - 1) ph[p]; $0 = substr($0, at + length(p)) }
                $0 = out $0
            }
            print
        }' "$1"
}
