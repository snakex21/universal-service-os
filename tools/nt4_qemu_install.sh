# Windows NT 4.0: the whole install in a VM on the target machine
# (docs/nt4-2026-10-07.md). Sourced by tools/w9x_csmwrap_prepare.sh after
# tools/w9x_phase1_qemu.sh (QEMU from qemu9x.cpio, w9x_phase1_run, logs).
#
# tools/nt4_csmwrap_target.sh has written C: (winnt /b layout, syslinux ->
# chain.c32 -> $LDR$). The VM boots THE SAME DISK (raw block device, only its
# first NT4_VM_DISK_BYTES visible, IDE, SeaBIOS, -cpu pentium3: the RTM
# text-mode kernel triple-faults on a Zen 3 CPUID) and runs text mode, GUI
# mode and the first logon (POST.CMD: AHCINT + usosrst, SP6a). Every guest
# restart ends QEMU (-no-reboot); the next run starts until POST.CMD wrote
# C:\USOS\NT4\DONE.TXT. Then nt4_vm_finish checks C:, adds /NUMPROC and
# /MAXMEM to BOOT.INI and removes the Setup leftovers; the CSMWrap ESP is
# written after it (the VM never sees it).

NT4_VM_BOOTS=${NT4_VM_BOOTS:-6}
NT4_VM_DISK_BYTES=${NT4_VM_DISK_BYTES:-4294967296}
NT4_PART_OFFSET=32256
# Workstation: 2 processors (its licence; SP6a halmps on the X470's MP table
# from SeaBIOS); 1 GiB (NT 4.0 trouble reports with more memory).
NT4_BOOT_OPTIONS=${NT4_BOOT_OPTIONS:-/NUMPROC=2 /MAXMEM=1024}

# The QEMU argument list (W9X_VM_ARGS_FN for w9x_phase1_run): the w9x rules
# (no network, -no-reboot, cache=none) with the disk view limited to the
# first NT4_VM_DISK_BYTES (FAT16 C: is in the first 2 GiB; NT 4.0 atapi has
# no 48-bit LBA) and the hard disk as the only boot device.
nt4_vm_args() {
    case "$2" in kvm) accel='kvm' ;; *) accel='tcg,tb-size=128' ;; esac
    printf '%s\n' -name usos-nt4-install -nodefaults -L "$W9X_VM_DATADIR" \
        -machine pc -accel "$accel" -cpu pentium3 -smp 1 -m "$W9X_VM_GUEST_MB" \
        -rtc base=localtime -vga std -display none -nic none -no-reboot \
        -drive "file=$1,format=raw,size=$NT4_VM_DISK_BYTES,if=ide,index=0,media=disk,cache=none,file.locking=off" \
        -boot order=c \
        -serial "file:$W9X_VM_RUN/serial.log" \
        -chardev "file,id=seabios,path=$W9X_VM_RUN/seabios.log" -device isa-debugcon,iobase=0x402,chardev=seabios \
        -monitor "pipe:$W9X_VM_RUN/mon" \
        -monitor "pipe:$W9X_VM_RUN/key"
}

# 0 when C: of the target $1 holds \USOS\NT4\$2 (mtools, read only).
nt4_vm_marker() {
    MTOOLS_SKIP_CHECK=1 mdir -i "$1@@$NT4_PART_OFFSET" "::/USOS/NT4/$2" >/dev/null 2>&1
}

# Runs the VM until the install is done. Calls nt4_vm_progress BOOT ELAPSED
# WRITTEN_MB when the caller defines it. 0 = DONE.TXT written, 2 = QEMU
# failed, 3 = timeout, 4 = no DONE.TXT after NT4_VM_BOOTS runs. Logs of every
# run in $1/run-N.
nt4_vm_install() {
    target=$1
    logs=$2
    accel=${3:-tcg}
    NT4_VM_ELAPSED=0
    W9X_VM_ARGS_FN=nt4_vm_args
    W9X_VM_KEY=''
    boot=0
    while [ "$boot" -lt "$NT4_VM_BOOTS" ]; do
        boot=$((boot + 1))
        NT4_VM_BOOT=$boot
        w9x_phase1_progress() { command -v nt4_vm_progress >/dev/null 2>&1 && nt4_vm_progress "$NT4_VM_BOOT" "$1" "$2"; return 0; }
        w9x_phase1_run "$target" "$accel"
        rc=$?
        NT4_VM_ELAPSED=$((NT4_VM_ELAPSED + ${W9X_VM_ELAPSED:-0}))
        w9x_phase1_keep_logs "$logs/run-$boot"
        printf 'run %s rc=%s elapsed=%s\n' "$boot" "$rc" "${W9X_VM_ELAPSED:-0}" >> "$logs/runs.txt"
        [ "$rc" = 0 ] || return "$rc"
        if nt4_vm_marker "$target" DONE.TXT; then return 0; fi
    done
    return 4
}

# BOOT.INI (stdin -> stdout, CR LF): NT4_BOOT_OPTIONS on every ARC line
# that lacks /NUMPROC, timeout=5.
nt4_boot_ini() {
    awk -v BINMODE=3 -v opts="$NT4_BOOT_OPTIONS" '
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*timeout[ \t]*=/ { line = "timeout=5" }
        low ~ /^[ \t]*multi\(/ && low !~ /\/numproc/ { line = line " " opts }
        { printf "%s\r\n", line }'
}

# After the VM: checks C: on $1 (fsck.fat -n before and after), copies the
# USOS logs to $2, writes BOOT.INI's options, removes the Setup leftovers
# (syslinux, $LDR$, the local source, the answer copies, the service pack).
# 0 = the install is complete; the reason on stdout.
nt4_vm_finish() {
    target=$1
    logs=$2
    mkdir -p "$logs" "$W9X_VM_RUN/c"
    rm -f "$logs/fsck.txt"
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    loop=$(losetup -f) || return 1
    losetup -o "$NT4_PART_OFFSET" "$loop" "$target" || return 1
    if ! w9x_phase1_fsck "$loop" "$logs/fsck.txt" 'C: after the NT 4.0 install'; then
        losetup -d "$loop" 2>/dev/null || true
        echo 'fsck.fat found errors on C: after the install (fsck.txt)'
        return 1
    fi
    if ! mount -t vfat -o shortname=winnt,utf8=0 "$loop" "$W9X_VM_RUN/c"; then
        losetup -d "$loop" 2>/dev/null || true
        echo 'cannot mount C:'
        return 1
    fi
    c=$W9X_VM_RUN/c
    for file in POST.LOG VERSION.REG USOSRST.REG DONE.TXT; do
        [ -f "$c/USOS/NT4/$file" ] && cp "$c/USOS/NT4/$file" "$logs/$file" 2>/dev/null
    done
    status=0
    reason=''
    for path in WINNT/SYSTEM32/NTOSKRNL.EXE WINNT/SYSTEM32/DRIVERS/AHCINT.SYS WINNT/SYSTEM32/DRIVERS/USOSRST.SYS BOOT.INI NTLDR USOS/NT4/DONE.TXT; do
        [ -e "$c/$path" ] || { reason="$reason missing $path;"; status=1; }
    done
    if [ -f "$c/USOS/NT4/SP6I386.EXE" ]; then
        if grep -aq 'Service Pack 6' "$c/USOS/NT4/VERSION.REG" 2>/dev/null; then reason="$reason SP6a installed;"
        else reason="$reason no Service Pack 6 in CSDVersion;"; status=1; fi
    fi
    if [ "$status" = 0 ]; then
        nt4_boot_ini < "$c/BOOT.INI" > "$W9X_VM_RUN/boot.ini" && cat "$W9X_VM_RUN/boot.ini" > "$c/BOOT.INI" ||
            { reason="$reason cannot write BOOT.INI;"; status=1; }
        cp "$c/BOOT.INI" "$logs/BOOT.INI" 2>/dev/null
        # chmod clears the read-only bit (vfat), so rm can remove LDLINUX.SYS.
        for leftover in LDLINUX.SYS LDLINUX.C32 SYSLINUX.CFG CHAIN.C32 LIBCOM32.C32 LIBUTIL.C32 '$LDR$' TXTSETUP.SIF WINNT.SIF \
            USOS/NT4/SP6I386.EXE; do
            [ -e "$c/$leftover" ] || continue
            chmod u+w "$c/$leftover" 2>/dev/null || true
            rm -f "$c/$leftover"
        done
        rm -rf "$c/\$WIN_NT\$.~BT" "$c/\$WIN_NT\$.~LS"
        reason="$reason BOOT.INI: $NT4_BOOT_OPTIONS;"
    fi
    sync
    umount "$c" || status=1
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    if ! w9x_phase1_fsck "$loop" "$logs/fsck.txt" 'C: after the USOS changes'; then
        reason="$reason fsck.fat found errors after the USOS changes;"
        status=1
    fi
    losetup -d "$loop" 2>/dev/null || true
    sync
    echo "${reason# }"
    return "$status"
}
