# Windows 98 / 98 SE / Me Setup phase 1 in a VM on the target machine
# (docs/win9x-modern-2026-09-30.md section 4d; design option a1).
# Sourced by tools/w9x_csmwrap_prepare.sh. Nothing here is copied from
# Windows 9x QuickInstall.
#
# tools/w9x_csmwrap_target.sh has written the target disk (bootable:
# syslinux -> MEMDISK -> the CD's boot floppy -> INSTALL.BAT -> SETUP). On
# X470-class PCs Setup's DOS stage hangs under CSMWrap, so this boots THE SAME
# DISK in QEMU (raw block device, SeaBIOS, i440FX, ACPI off, no network).
# Setup's first restart ends the VM (-no-reboot); the files on C: are checked
# and the real machine then restarts into the disk's CSMWrap entry, where
# Windows' first start and hardware detection run on the real hardware.
#
# QEMU, SeaBIOS and the KVM modules come from the optional second initrd
# EFI/USOS/micro-linux/qemu9x.cpio (only on the w9x command line). Without it,
# with less than ~1 GiB RAM, or with the flag file
# EFI/USOS/win9x/phase1-native.flag, the old path is kept (Setup's DOS stage
# on the real machine). KVM only with EFI/USOS/win9x/phase1-kvm.flag and a
# working /dev/kvm; the default is TCG.
#
# Windows 95 (2026-10-06): its OEM Setup asks for the Certificate of
# Authenticity number in phase 1 (SUWIN's COA page; for ProductType 9 it does
# not take MSBATCH.INF ProductID) and nobody can type in the VM. The caller
# passes the answer's key as digits (W9X_VM_KEY, never logged); when the guest
# writes nothing for W9X_VM_IDLE seconds early in phase 1 (a page waits),
# w9x_phase1_run types those digits and Enter through a second QEMU monitor
# whose output is discarded (the edit fields move on by themselves at 5 / 7
# digits; Enter is the wizard's Next). The licence page is skipped by Setup's
# own /IW switch (INSTALL.BAT).

W9X_VM_QEMU=${W9X_VM_QEMU:-/usr/bin/qemu-system-i386}
W9X_VM_DATADIR=${W9X_VM_DATADIR:-/usr/share/qemu}
W9X_VM_MEMINFO=${W9X_VM_MEMINFO:-/proc/meminfo}
W9X_VM_KVM_DEV=${W9X_VM_KVM_DEV:-/dev/kvm}
W9X_VM_FLAGS=${W9X_VM_FLAGS:-/mnt/esp/EFI/USOS/win9x}
W9X_VM_RUN=${W9X_VM_RUN:-/run/w9x-vm}
# Guest RAM (MiB) and the least RAM (KiB, MemTotal) the target needs: guest,
# QEMU's TCG cache and the unpacked initramfs + qemu9x.cpio.
W9X_VM_GUEST_MB=${W9X_VM_GUEST_MB:-512}
W9X_VM_MIN_KB=${W9X_VM_MIN_KB:-900000}
# Phase 1 under TCG takes minutes; a Setup that waits for input (or INSTALL.BAT
# stopped on an error) never restarts, so the VM is stopped after this.
W9X_VM_TIMEOUT=${W9X_VM_TIMEOUT:-5400}
W9X_VM_SCREEN_EVERY=${W9X_VM_SCREEN_EVERY:-60}
# Windows 95 key typing (see above): seconds without a disk write that count
# as "a page waits", at most this many attempts, and only while the guest has
# written less than this many MB (the COA page comes before the file copy).
W9X_VM_IDLE=${W9X_VM_IDLE:-60}
W9X_VM_KEY_TRIES=${W9X_VM_KEY_TRIES:-5}
W9X_VM_KEY_MAX_MB=${W9X_VM_KEY_MAX_MB:-64}
# With key typing, or with W9X_VM_STALL_ANY=1 (NT 4.0: no key to type), no
# disk write for this long ends the VM (rc 3, W9X_VM_STALLED = the idle
# seconds) instead of waiting for the full timeout on a page nobody answers.
W9X_VM_STALL=${W9X_VM_STALL:-1800}
# A message box that needs one known key (W9X_VM_ANSWER, a QEMU sendkey name;
# NT 4.0: alt-n): typed when a graphics screen got no disk write for
# W9X_VM_ANSWER_IDLE seconds, at most W9X_VM_ANSWER_TRIES times per run, the
# screen before it kept as answer-N.ppm. Off when empty. Several answers:
# "keys;keys;..." (attempt N types list N, later attempts the last list),
# each list one or more sendkey names separated by spaces (NT 3.1 Advanced
# Server: its Domain Settings page first, then the Date/Time applet).
W9X_VM_ANSWER=${W9X_VM_ANSWER:-}
W9X_VM_ANSWER_IDLE=${W9X_VM_ANSWER_IDLE:-180}
W9X_VM_ANSWER_TRIES=${W9X_VM_ANSWER_TRIES:-3}
# The same for a text-mode screen (W9X_VM_TEXT_ANSWER; NT 3.51: ret for
# text-mode Setup's "Setup was unable to verify your C: drive ... Press ENTER
# to continue", QEMU 2026-10-08), after W9X_VM_TEXT_ANSWER_IDLE seconds
# without a disk write, at most W9X_VM_ANSWER_TRIES times per run. Off when
# empty.
W9X_VM_TEXT_ANSWER=${W9X_VM_TEXT_ANSWER:-}
W9X_VM_TEXT_ANSWER_IDLE=${W9X_VM_TEXT_ANSWER_IDLE:-90}

# 0 when this system's Setup phase 1 runs in the VM (reason on stdout).
w9x_vm_available() {
    # Me (2026-10-06): the same DOS-stage SETUP.EXE as 98 (/P I valid), so the
    # same VM path. 95 (2026-10-06) too, but only with its key: the caller
    # (w9x_csmwrap_prepare.sh) keeps the native start for 95 without one.
    # NT4 / NT4S (2026-10-07), NT351 / NT351S (2026-10-08), NT35 / NT35S, NT31 / NT31S (2026-10-09): the whole install runs in the VM (tools/nt4_qemu_install.sh).
    case "$1" in 98SE|98|ME|95|NT4|NT4S|NT351|NT351S|NT35|NT35S|NT31|NT31S) ;; *) echo "release $1 keeps the native Setup start"; return 1 ;; esac
    if [ -e "$W9X_VM_FLAGS/phase1-native.flag" ]; then echo 'phase1-native.flag present'; return 1; fi
    if [ ! -x "$W9X_VM_QEMU" ]; then echo 'qemu9x.cpio not loaded (no QEMU)'; return 1; fi
    for firmware in bios-256k.bin vgabios-stdvga.bin; do
        [ -r "$W9X_VM_DATADIR/$firmware" ] || { echo "QEMU firmware missing: $firmware"; return 1; }
    done
    total=$(awk '$1 == "MemTotal:" { print $2; exit }' "$W9X_VM_MEMINFO" 2>/dev/null)
    case "$total" in ''|*[!0-9]*) echo 'cannot read MemTotal'; return 1 ;; esac
    if [ "$total" -lt "$W9X_VM_MIN_KB" ]; then echo "RAM ${total} KiB < ${W9X_VM_MIN_KB} KiB"; return 1; fi
    echo "vm ok (MemTotal ${total} KiB)"
}

# kvm or tcg. KVM needs the flag file and a /dev/kvm that opens.
w9x_vm_accel() {
    [ -e "$W9X_VM_FLAGS/phase1-kvm.flag" ] || { echo tcg; return 0; }
    if [ ! -e "$W9X_VM_KVM_DEV" ] && command -v modprobe >/dev/null 2>&1; then
        if grep -qw svm /proc/cpuinfo 2>/dev/null; then modprobe kvm-amd 2>/dev/null || true
        elif grep -qw vmx /proc/cpuinfo 2>/dev/null; then modprobe kvm-intel 2>/dev/null || true; fi
        command -v mdev >/dev/null 2>&1 && mdev -s 2>/dev/null || true
    fi
    if [ -c "$W9X_VM_KVM_DEV" ] && { : < "$W9X_VM_KVM_DEV"; } 2>/dev/null; then echo kvm; else echo tcg; fi
}

# The QEMU argument list (one per line) for the target disk $1, accel $2.
# Hard rules: ACPI off (Setup also gets /P I through U9VM=1), no network,
# -no-reboot (Setup's first restart ends the VM), the whole disk with
# cache=none: O_DIRECT, so none of the guest's writes sit in this kernel's
# page cache next to the later loop mount, and QEMU's flush on exit reaches
# the disk.
w9x_vm_args() {
    case "$2" in kvm) accel='kvm' ;; *) accel='tcg,tb-size=128' ;; esac
    printf '%s\n' -name usos-w9x-phase1 -nodefaults -L "$W9X_VM_DATADIR" \
        -machine pc,acpi=off -accel "$accel" -cpu pentium3 -smp 1 -m "$W9X_VM_GUEST_MB" \
        -rtc base=localtime -vga std -display none -nic none -no-reboot \
        -drive "file=$1,format=raw,if=ide,index=0,media=disk,cache=none,file.locking=off" \
        -boot order=c \
        -serial "file:$W9X_VM_RUN/serial.log" \
        -chardev "file,id=seabios,path=$W9X_VM_RUN/seabios.log" -device isa-debugcon,iobase=0x402,chardev=seabios \
        -monitor "pipe:$W9X_VM_RUN/mon" \
        -monitor "pipe:$W9X_VM_RUN/key"
}

w9x_vm_monitor() {
    # Read-write open: never blocks, also when QEMU is gone.
    printf '%s\n' "$1" 1<> "$W9X_VM_RUN/mon.in" 2>/dev/null || true
}

# The Windows 95 key of the MSBATCH.INF $1 ([Setup] ProductID, as
# tools/../msbatch.zig renders it) as the digits typed into Setup's COA page:
# OEM ddddd-OEM-ddddddd-ddddd -> 17 digits (the page has three fields and no
# "OEM" field), retail ddd-ddddddd -> 10 digits. Nothing (rc 1) otherwise.
w9x_vm_key_digits() {
    awk '
        { sub(/\r$/, "") }
        /^[ \t]*\[/ { setup = (tolower($0) ~ /^[ \t]*\[setup\][ \t]*$/); next }
        setup && tolower($0) ~ /^[ \t]*productid[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/"/, "", v); sub(/[ \t]+$/, "", v); v = toupper(v)
            if (v ~ /^[0-9][0-9][0-9][0-9][0-9]-OEM-[0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9]$/ ||
                v ~ /^[0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9][0-9]$/) { gsub(/[^0-9]/, "", v); print v; found = 1 }
            exit
        }
        END { exit(found ? 0 : 1) }' "$1" 2>/dev/null
}

# 0 when the guest shows a graphics screen (Setup's mini-Windows runs at
# 640x480; QEMU dumps a text-mode screen 720 pixels wide: 720x400, NT 3.51
# text-mode Setup 720x396, QEMU 2026-10-08). The dump stays in
# $W9X_VM_RUN only for its header and is deleted at once (it may show a page
# with the digits after a rejected attempt).
w9x_vm_graphics_screen() {
    rm -f "$W9X_VM_RUN/mode.ppm"
    w9x_vm_monitor "screendump $W9X_VM_RUN/mode.ppm"
    for _ in 1 2 3 4 5; do
        [ -s "$W9X_VM_RUN/mode.ppm" ] && break
        sleep 1
    done
    size=$(head -c 20 "$W9X_VM_RUN/mode.ppm" 2>/dev/null | tr '\n' ' ' | awk '{ print $2 "x" $3 }')
    rm -f "$W9X_VM_RUN/mode.ppm"
    case "$size" in 720x*|x|'') return 1 ;; esac
    return 0
}

# Types the digits $1 and Enter into the guest (second monitor; its output,
# which echoes the commands, goes nowhere).
w9x_vm_type_key() {
    keys=$1
    while [ -n "$keys" ]; do
        digit=${keys%"${keys#?}"}
        keys=${keys#?}
        printf 'sendkey %s\n' "$digit" 1<> "$W9X_VM_RUN/key.in" 2>/dev/null || return 1
        sleep 1
    done
    printf 'sendkey ret\n' 1<> "$W9X_VM_RUN/key.in" 2>/dev/null || return 1
}

# Sectors written to block device $1 so far (/sys/block/<name>/stat field 7).
w9x_vm_written() {
    awk '{ print $7; exit }' "/sys/block/${1##*/}/stat" 2>/dev/null || echo 0
}

# Runs the VM on $1 (the confirmed target, nothing else is passed; the
# argument list comes from W9X_VM_ARGS_FN, default w9x_vm_args). Calls
# w9x_phase1_progress ELAPSED_SECONDS WRITTEN_MB every few seconds when the
# caller defines it. 0 = the guest restarted (Setup phase 1 ended), 2 = QEMU
# failed, 3 = timeout. Logs in $W9X_VM_RUN.
w9x_phase1_run() {
    target=$1
    accel=${2:-tcg}
    rm -rf "$W9X_VM_RUN"
    mkdir -p "$W9X_VM_RUN"
    # The target writer's buffered writes on the disk, its cached pages dropped.
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    mkfifo "$W9X_VM_RUN/mon.in" "$W9X_VM_RUN/mon.out" "$W9X_VM_RUN/key.in" "$W9X_VM_RUN/key.out" || return 2
    # Read-write open: never blocks, with or without QEMU on the other end.
    cat 0<> "$W9X_VM_RUN/mon.out" > "$W9X_VM_RUN/monitor.log" 2>/dev/null &
    drain=$!
    # The key monitor's echo would hold the key: discarded, never logged.
    cat 0<> "$W9X_VM_RUN/key.out" > /dev/null 2>&1 &
    drain_key=$!
    key=${W9X_VM_KEY:-}
    key_tries=0
    key_on_screen=0
    last_written=-1
    idle_since=0
    W9X_VM_STALLED=0
    answer_tries=0
    text_tries=0
    set --
    while IFS= read -r arg; do set -- "$@" "$arg"; done <<EOF
$("${W9X_VM_ARGS_FN:-w9x_vm_args}" "$target" "$accel")
EOF
    printf '%s\n' "$W9X_VM_QEMU $*" > "$W9X_VM_RUN/command.txt"
    start=$(date +%s)
    written0=$(w9x_vm_written "$target")
    "$W9X_VM_QEMU" "$@" > "$W9X_VM_RUN/qemu.log" 2>&1 < /dev/null &
    vm=$!
    last_shot=$start
    result=''
    while kill -0 "$vm" 2>/dev/null; do
        now=$(date +%s)
        elapsed=$((now - start))
        sectors=$(w9x_vm_written "$target")
        written=$(( (sectors - written0) / 2048 ))
        command -v w9x_phase1_progress >/dev/null 2>&1 && w9x_phase1_progress "$elapsed" "$written"
        # A caller-defined step on every round (NT 3.1: its text-mode Setup
        # pages answered by their text, nt4_qemu_install.sh).
        [ -z "${W9X_VM_TICK_FN:-}" ] || "$W9X_VM_TICK_FN" "$elapsed" || true
        if [ "$sectors" != "$last_written" ]; then
            last_written=$sectors
            idle_since=$now
            key_on_screen=0
        elif [ -n "$key" ] || [ "${W9X_VM_STALL_ANY:-0}" = 1 ]; then
            idle=$((now - idle_since))
            if [ -n "$key" ] && [ "$idle" -ge "$W9X_VM_IDLE" ] && [ "$key_tries" -lt "$W9X_VM_KEY_TRIES" ] && [ "$written" -lt "$W9X_VM_KEY_MAX_MB" ] &&
                ! w9x_vm_graphics_screen; then
                # Text mode (DOS: INSTALL.BAT, Patcher9x, Setup's DOS stage):
                # no page of Setup's mini-Windows waits; look again later.
                idle_since=$(date +%s)
            elif [ -n "$key" ] && [ "$idle" -ge "$W9X_VM_IDLE" ] && [ "$key_tries" -lt "$W9X_VM_KEY_TRIES" ] && [ "$written" -lt "$W9X_VM_KEY_MAX_MB" ]; then
                key_tries=$((key_tries + 1))
                printf 'key typed: attempt %s at %ss, idle %ss, written %s MB\n' "$key_tries" "$elapsed" "$idle" "$written" >> "$W9X_VM_RUN/command.txt"
                # Until the guest writes again the page may still show the
                # digits: no screendump of it (the logs go to the USOS ESP).
                key_on_screen=1
                w9x_vm_type_key "$key"
                idle_since=$(date +%s)
            elif [ -n "$W9X_VM_ANSWER" ] && [ "$idle" -ge "$W9X_VM_ANSWER_IDLE" ] && [ "$answer_tries" -lt "$W9X_VM_ANSWER_TRIES" ] &&
                w9x_vm_graphics_screen; then
                answer_tries=$((answer_tries + 1))
                w9x_vm_monitor "screendump $W9X_VM_RUN/answer-$answer_tries.ppm"
                sleep 3
                keys=$(printf '%s\n' "$W9X_VM_ANSWER" | awk -F';' -v n="$answer_tries" '{ print (n <= NF) ? $n : $NF }')
                printf 'answer typed: %s attempt %s at %ss, idle %ss, written %s MB\n' "$keys" "$answer_tries" "$elapsed" "$idle" "$written" >> "$W9X_VM_RUN/command.txt"
                for k in $keys; do w9x_vm_monitor "sendkey $k"; sleep 1; done
                idle_since=$(date +%s)
            elif [ -n "$W9X_VM_TEXT_ANSWER" ] && [ "$idle" -ge "$W9X_VM_TEXT_ANSWER_IDLE" ] && [ "$text_tries" -lt "$W9X_VM_ANSWER_TRIES" ] &&
                ! w9x_vm_graphics_screen; then
                text_tries=$((text_tries + 1))
                w9x_vm_monitor "screendump $W9X_VM_RUN/text-answer-$text_tries.ppm"
                sleep 3
                printf 'text answer typed: %s attempt %s at %ss, idle %ss, written %s MB
' "$W9X_VM_TEXT_ANSWER" "$text_tries" "$elapsed" "$idle" "$written" >> "$W9X_VM_RUN/command.txt"
                w9x_vm_monitor "sendkey $W9X_VM_TEXT_ANSWER"
                idle_since=$(date +%s)
            elif [ "$idle" -ge "$W9X_VM_STALL" ]; then
                printf 'stalled: no disk write for %ss\n' "$idle" >> "$W9X_VM_RUN/command.txt"
                W9X_VM_STALLED=$idle
                result=3
                [ "$key_on_screen" = 1 ] || w9x_vm_monitor "screendump $W9X_VM_RUN/screen.ppm"
                sleep 3
                w9x_vm_monitor quit
                sleep 5
                kill "$vm" 2>/dev/null || true
                break
            fi
        fi
        if [ $((now - last_shot)) -ge "$W9X_VM_SCREEN_EVERY" ] && [ "$key_on_screen" = 0 ]; then
            w9x_vm_monitor "screendump $W9X_VM_RUN/screen.ppm"
            last_shot=$now
        fi
        if [ "$elapsed" -ge "$W9X_VM_TIMEOUT" ]; then
            result=3
            [ "$key_on_screen" = 1 ] || w9x_vm_monitor "screendump $W9X_VM_RUN/screen.ppm"
            sleep 3
            w9x_vm_monitor quit
            sleep 5
            kill "$vm" 2>/dev/null || true
            break
        fi
        sleep 5
    done
    wait "$vm"
    rc=$?
    kill "$drain" "$drain_key" 2>/dev/null || true
    W9X_VM_ELAPSED=$(( $(date +%s) - start ))
    printf 'rc=%s elapsed=%s accel=%s\n' "$rc" "$W9X_VM_ELAPSED" "$accel" >> "$W9X_VM_RUN/command.txt"
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    [ -z "$result" ] || return "$result"
    [ "$rc" = 0 ] || return 2
    return 0
}

# 0 when the mounted C: at $1 holds what Setup phase 1 leaves behind.
w9x_phase1_tree_ok() {
    for path in WINDOWS/WIN.COM WINDOWS/SYSTEM WINDOWS/SYSTEM.INI SETUPLOG.TXT; do
        [ -e "$1/$path" ] || { echo "missing $path"; return 1; }
    done
    [ -d "$1/WINDOWS/SYSTEM" ] || { echo 'WINDOWS/SYSTEM is not a folder'; return 1; }
    echo 'phase 1 files present'
}

# What the real machine must not inherit from the VM, on the mounted C: at $1
# (CR LF kept; a file is replaced through a temporary next to it, and only
# when a line goes):
#  - WINDOWS\SYSTEM.INI [386Enh] mouse=: Setup detected QEMU's i8042 mouse
#    (mouse=*vmouse, msmouse.vxd); under CSMWrap SeaBIOS reports the USB
#    mouse as a BIOS PS/2 mouse and VPICD_Phys_EOI stopped the X470 with a
#    zero IRQ handle. U9FIX /CSM drops a *vmouse line at every start too.
#  - CONFIG.SYS: a second HIMEM.SYS line (INSTALL.BAT's fallback line, which
#    Setup turns into a copy of the first; the VM path no longer writes it).
#  - MSDOS.SYS without a Logo= line (Me): Logo=0 is added (see below).
# One output line per removed line; 1 when a file cannot be replaced.
w9x_phase1_patch_c() {
    for patch_file in WINDOWS/SYSTEM.INI CONFIG.SYS; do
        patch_path="$1/$patch_file"
        [ -f "$patch_path" ] || continue
        # BINMODE=3: gawk on Windows keeps the CRs too (busybox awk always does).
        awk -v BINMODE=3 -v file="${patch_file##*/}" '
            { line = $0; sub(/\r$/, "", line); low = tolower(line) }
            file == "SYSTEM.INI" && low ~ /^[ \t]*\[/ { in386 = (low ~ /^[ \t]*\[386enh\]/) }
            file == "SYSTEM.INI" && in386 && low ~ /^[ \t]*mouse[ \t]*=/ { print file ": removed " line > "/dev/stderr"; next }
            file == "CONFIG.SYS" && low ~ /^[ \t]*device(high)?[ \t]*=.*himem\.sys/ {
                if (seen) { print file ": removed " line > "/dev/stderr"; next }
                seen = 1
            }
            { print }' "$patch_path" > "$patch_path.u9p" 2> "$W9X_VM_RUN/patch.txt" ||
            { rm -f "$patch_path.u9p"; echo "cannot patch $patch_file"; return 1; }
        if [ -s "$W9X_VM_RUN/patch.txt" ]; then
            mv -f "$patch_path.u9p" "$patch_path" || { echo "cannot replace $patch_file"; return 1; }
            cat "$W9X_VM_RUN/patch.txt"
        else
            rm -f "$patch_path.u9p"
        fi
    done
    # Me writes its own MSDOS.SYS in the VM (INSTALL.BAT's Logo=0 is 95/98
    # only): Logo=0 under [Options] for the text start (start messages
    # visible; the animated logo never got past itself under QEMU OVMF +
    # CSMWrap, 2026-10-06). Rewritten in place (cat >), so the directory
    # entry keeps its hidden/system/read-only bits.
    msdos="$1/MSDOS.SYS"
    if [ -f "$msdos" ] && grep -qi '^\[options\]' "$msdos" && ! grep -qi '^[ 	]*logo[ 	]*=' "$msdos"; then
        awk -v BINMODE=3 '{ print } !done && tolower($0) ~ /^\[options\]/ { printf "Logo=0\r\n"; done = 1 }' "$msdos" > "$msdos.u9p" &&
            cat "$msdos.u9p" > "$msdos" || { rm -f "$msdos.u9p"; echo 'cannot patch MSDOS.SYS'; return 1; }
        rm -f "$msdos.u9p"
        echo 'MSDOS.SYS: added Logo=0'
    fi
    return 0
}

# Read-only FAT check (fsck.fat -n) of the partition $1, output appended to
# $2 under the heading $3. 0 = no errors found.
w9x_phase1_fsck() {
    printf '== fsck.fat -n: %s\n' "$3" >> "$2"
    if ! command -v fsck.fat >/dev/null 2>&1; then
        echo 'fsck.fat missing' >> "$2"
        return 1
    fi
    fsck.fat -n "$1" >> "$2" 2>&1
    fsck_rc=$?
    printf '== rc=%s\n' "$fsck_rc" >> "$2"
    return "$fsck_rc"
}

# Checks C: on $1 (partition at LBA 2048, as w9x_csmwrap_target.sh writes it),
# copies Setup's logs to $2, removes what the VM left for the real machine
# (w9x_phase1_patch_c, patch.txt) and marks C:\USOS9X\PHASE1.OK. fsck.fat -n
# before the mount and after the USOS changes (fsck.txt): any error fails.
# 0 = phase 1 done.
w9x_phase1_verify() {
    target=$1
    logs=$2
    mkdir -p "$logs" "$W9X_VM_RUN/c"
    rm -f "$logs/fsck.txt" "$logs/patch.txt"
    # All writes on the disk and no stale cached block under the loop device.
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    loop=$(losetup -f) || return 1
    losetup -o 1048576 "$loop" "$target" || return 1
    if ! w9x_phase1_fsck "$loop" "$logs/fsck.txt" 'C: after Setup phase 1'; then
        losetup -d "$loop" 2>/dev/null || true
        echo 'fsck.fat found errors on C: after Setup phase 1 (fsck.txt)'
        return 1
    fi
    if ! mount -t vfat -o shortname=winnt,utf8=0 "$loop" "$W9X_VM_RUN/c"; then
        losetup -d "$loop" 2>/dev/null || true
        echo 'cannot mount C:'
        return 1
    fi
    for file in USOS9X/INSTALL.LOG SETUPLOG.TXT DETLOG.TXT BOOTLOG.TXT; do
        [ -f "$W9X_VM_RUN/c/$file" ] && cp "$W9X_VM_RUN/c/$file" "$logs/${file##*/}" 2>/dev/null
    done
    status=0
    reason=$(w9x_phase1_tree_ok "$W9X_VM_RUN/c") || status=1
    if [ "$status" = 0 ]; then
        if patched=$(w9x_phase1_patch_c "$W9X_VM_RUN/c"); then
            printf '%s\n' "$patched" > "$logs/patch.txt"
            [ -z "$patched" ] || reason="$reason; $(printf '%s' "$patched" | tr '\n' ';')"
        else
            reason="$reason; $patched"
            status=1
        fi
    fi
    if [ "$status" = 0 ]; then
        printf 'phase1=qemu elapsed=%s\r\n' "${W9X_VM_ELAPSED:-0}" > "$W9X_VM_RUN/c/USOS9X/PHASE1.OK" || status=1
    fi
    sync
    umount "$W9X_VM_RUN/c" || status=1
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    if ! w9x_phase1_fsck "$loop" "$logs/fsck.txt" 'C: after the USOS changes'; then
        reason="$reason; fsck.fat found errors on C: after the USOS changes (fsck.txt)"
        status=1
    fi
    losetup -d "$loop" 2>/dev/null || true
    sync
    blockdev --flushbufs "$target" 2>/dev/null || true
    echo "$reason"
    return "$status"
}

# The VM's logs (and the last screen) next to prepare.log on the USOS ESP.
w9x_phase1_keep_logs() {
    mkdir -p "$1"
    for file in command.txt qemu.log serial.log seabios.log monitor.log screen.ppm answer-1.ppm answer-2.ppm answer-3.ppm; do
        [ -f "$W9X_VM_RUN/$file" ] && cp "$W9X_VM_RUN/$file" "$1/$file" 2>/dev/null
    done
    sync
}
