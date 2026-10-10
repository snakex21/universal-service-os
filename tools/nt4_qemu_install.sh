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
# No disk write for this long ends the run (rc 3): a Setup page waits for
# input that never comes (X470 2026-10-07: NT 4.0 Server sat on its Server
# Type / Licensing pages for 40 minutes at 15 MB). Under TCG the longest
# quiet stretch of a good install is a few minutes.
NT4_VM_STALL=${NT4_VM_STALL:-900}
# NT 4.0 Server GUI-mode Setup ends with "One or more minor errors occurred
# ... Would you like to view the log file now? Yes/No" (QEMU 2026-10-07,
# Enterprise Server CD: setuplog.txt only had the Information lines about the
# pagefile and "Crashdump was enabled"; no answer-file key turns it off).
# Alt+N answers No and Setup restarts; on a wizard page it is Next.
NT4_VM_ANSWER=${NT4_VM_ANSWER:-alt-n}
# Workstation: 2 processors (its licence; SP6a halmps on the X470's MP table
# from SeaBIOS); 1 GiB (NT 4.0 trouble reports with more memory).
NT4_BOOT_OPTIONS=${NT4_BOOT_OPTIONS:-/NUMPROC=2 /MAXMEM=1024}
# NT 3.5: with more than 128 MiB the kernel finds no boot disk through AHCINT
# (STOP 0x7B, C0000034 for the ARC name after one disk read; QEMU OVMF +
# CSMWrap 2026-10-09: 64 and 128 MiB boot, 256 MiB and more stop, 2 GiB with
# /MAXMEM=128 boots).
NT35_BOOT_OPTIONS=${NT35_BOOT_OPTIONS:-/NUMPROC=2 /MAXMEM=128}

# NT 3.1 (docs/nt31-2026-10-09.md): /NODEBUG (without it the 3.1 kernel
# runs its debugger on COM1, "Kernel Debugger Using: COM1" on a STOP), no
# RAM beyond 64 MiB until a larger size is proven; the 3.1 loader knows no
# /NUMPROC.
NT31_BOOT_OPTIONS=${NT31_BOOT_OPTIONS:-/NODEBUG /MAXMEM=64}

# NT 3.1 text-mode Setup (SETUPAPP.EXE, no answer file): the VGA text page
# (QEMU pmemsave of B8000h) decides the key. Every page of the express path
# takes ENTER (Welcome, Express Setup, the partition C:, keep the FAT file
# system, \winnt), the last one CTRL+ALT+DELETE (that restart ends the VM).
# A page still on screen 30 s after its key gets the key again.
nt31_vm_tick() {
    [ $(( $1 - ${NT31_TICK_AT:--10} )) -ge 4 ] || return 0
    NT31_TICK_AT=$1
    rm -f "$W9X_VM_RUN/vga.bin"
    w9x_vm_monitor "pmemsave 0xb8000 4000 $W9X_VM_RUN/vga.bin"
    sleep 1
    [ -s "$W9X_VM_RUN/vga.bin" ] || return 0
    screen=$(od -An -v -tu1 "$W9X_VM_RUN/vga.bin" | awk '{ for (i = 1; i <= NF; i++) if (++n % 2) printf "%s", ($i >= 32 && $i < 127) ? sprintf("%c", $i + 0) : " " }')
    case "$screen" in
        *'Press CTRL+ALT+DELETE to restart'*) page=restart key=ctrl-alt-delete ;;
        *'Welcome to Setup.'*) page=welcome key=ret ;;
        *'Express Setup (recommended)'*) page=express key=ret ;;
        *'select the partition where you would like to install'*) page=partition key=ret ;;
        *'select a file system option'*) page=filesystem key=ret ;;
        *'Choose the location'*) page=location key=ret ;;
        *) return 0 ;;
    esac
    [ "$page" != "${NT31_PAGE:-}" ] || [ $(( $1 - NT31_PAGE_AT )) -ge 30 ] || return 0
    NT31_PAGE=$page
    NT31_PAGE_AT=$1
    printf 'nt31 text page %s at %ss: %s\n' "$page" "$1" "$key" >> "$W9X_VM_RUN/command.txt"
    w9x_vm_monitor "sendkey $key"
}

# NT 3.1 GUI-mode Setup (INITIAL.INF, stdin -> stdout, CR LF) without its
# pages: no network, printer or application search; owner $1, organisation
# $2, computer name $3; blank Administrator password, no extra user account;
# no Emergency Repair Disk (the Date/Time applet stays: nt4_vm_install
# answers it with ENTER); at the end the USOS
# section (drivers and their Services keys) and the restart without the
# "Setup is done" page. 1 when an anchor is missing (another INITIAL.INF).
# $4 = net (Advanced Server, STF_PRODUCT LanmanNT): the network stays on.
# 3.1 AS is always a domain controller; without the network WinLogon refuses
# every logon ("Unable to log you on because the netlogon service is not
# running", QEMU 2026-10-10), so its Setup installs the MS Loopback Adapter
# (nt31_ntlanman_inf) and creates the domain.
nt31_initial_inf() {
    awk -v BINMODE=3 -v full="$1" -v org="$2" -v comp="$3" -v net="${4:-}" '
        function out(t) { printf "%s\r\n", t }
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low) }
        low ~ /^\[/ { sec = low }
        sec == "[uivars]" && net == "net" && low ~ /^donetwork=\$\(chosen\)$/ { hit["vars"]++; low = "" }
        sec == "[uivars]" && low ~ /^(donetwork|doprinter|doappsetup)=\$\(chosen\)$/ { sub(/\$\([Cc]hosen\)/, "$(NotChosen)", line); hit["vars"]++ }
        low ~ /^shell"repair\.inf""createrepairdiskette"$/ { out("; USOS: no Emergency Repair Disk"); hit["erd"]++; next }
        { out(line) }
        low == "[dolicense]" { out("    set !FullName = \"" full "\""); out("    set !OrgName = \"" org "\""); out("    Return STATUS_SUCCESSFUL"); hit["lic"]++ }
        low == "[docomputername]" { out("    Return STATUS_SUCCESSFUL \"" comp "\""); hit["comp"]++ }
        low == "[doadminaccountsetup]" { out("    Return STATUS_SUCCESSFUL \"\""); hit["admin"]++ }
        low == "[doaccountsetup]" { out("    Return STATUS_USERCANCEL \"\" \"\""); hit["acct"]++ }
        sec == "[shellcommands]" && low == "setupdone=+" { out("    shell \"\" UsosNt31Post"); out("    set Exit_Code = $(!SETUP_ERROR_SUCCESS)"); out("    goto rebootend"); hit["done"]++ }
        END {
            out("")
            out("; USOS NT 3.1 (docs/nt31-2026-10-09.md): the USOS drivers and their Services keys")
            out("[UsosNt31Post]")
            out("    OpenRegKey $(!REG_H_LOCAL) \"\" \"system\\CurrentControlSet\\services\" 33554432 UsosSvc")
            svc("ahcint", 1, 0, 1, "SCSI miniport")
            svc("usosrst", 1, 0, 0, "SCSI miniport")
            par("usosrst", "{HpetLegacyOff,0,$(!REG_VT_DWORD),1},{RtcFix,0,$(!REG_VT_DWORD),1}")
            # usosusb as a boot driver: as a system driver (Start 1) NT 3.1
            # never ran its DriverEntry (no Diag value, QEMU 2026-10-10).
            svc("usosusb", 1, 0, 0, "Keyboard Port")
            set("Scsidisk", "{Start,0,$(!REG_VT_DWORD),0}")
            par("Kbdclass", "{ConnectMultiplePorts,0,$(!REG_VT_DWORD),1}")
            par("Mouclass", "{ConnectMultiplePorts,0,$(!REG_VT_DWORD),1}")
            set("Atdisk", "{Start,0,$(!REG_VT_DWORD),4}")
            out("    CloseRegKey $(UsosSvc)")
            # No automatic logon in NT 3.1; the logon box offers Administrator.
            out("    OpenRegKey $(!REG_H_LOCAL) \"\" \"software\\Microsoft\\Windows NT\\CurrentVersion\" 33554432 UsosSvc")
            set("Winlogon", "{DefaultUserName,0,$(!REG_VT_SZ),\"Administrator\"}")
            out("    CloseRegKey $(UsosSvc)")
            out("    RunProgram STATUS \"\" \"\" $(!STF_WINDOWSSYSPATH)\"\\cmd.exe\" /c C:\\USOS\\NT3\\POST.CMD")
            out("    Return STATUS_SUCCESSFUL")
            n = split("vars erd lic comp admin acct done", need, " ")
            for (i = 1; i <= n; i++) if (!hit[need[i]]) { print "INITIAL.INF: no anchor " need[i] > "/dev/stderr"; bad = 1 }
            if (hit["vars"] != 3) { print "INITIAL.INF: UiVars " hit["vars"] "/3" > "/dev/stderr"; bad = 1 }
            exit bad
        }
        function key(name, values) {
            out("    shell \"registry.inf\" CreateKey $(UsosSvc) " name " " values)
            out("    ifstr(i) $($R0) == STATUS_SUCCESSFUL")
            out("        CloseRegKey $($R1)")
            out("    endif")
        }
        function set(name, values) { key("{{" name ",0,33554432}}", "{" values "}") }
        function par(name, values) { key("{{" name ",0,33554432},{Parameters,0,33554432}}", "{" values "}") }
        function svc(name, type, start, err, group) {
            set(name, "{Type,0,$(!REG_VT_DWORD)," type "},{Start,0,$(!REG_VT_DWORD)," start "},{ErrorControl,0,$(!REG_VT_DWORD)," err "},{Group,0,$(!REG_VT_SZ),\"" group "\"}")
        }'
}

# After a VM run of an NT 3.1 install: once text mode has written
# \WINNT\SYSTEM32\INITIAL.INF (plain text there), it gets nt31_initial_inf
# with the names of \USOS\NT3\NAMES.TXT (nt4_csmwrap_target.sh); Advanced
# Server (NT31_NET = net) also its network INFs. 1 = the file is there but
# cannot be patched.
nt31_vm_patch_initial() {
    img="$1@@$NT4_PART_OFFSET"
    inf=$W9X_VM_RUN/../nt31-initial.inf
    MTOOLS_SKIP_CHECK=1 mtype -i "$img" ::/WINNT/SYSTEM32/INITIAL.INF > "$inf" 2>/dev/null && [ -s "$inf" ] || { rm -f "$inf"; return 0; }
    NT31_NET=''
    ! grep -qi '^[[:space:]]*STF_PRODUCT[[:space:]]*=[[:space:]]*LanmanNT' "$inf" || NT31_NET=net
    if ! grep -q '^\[UsosNt31Post\]' "$inf"; then
        names=$(MTOOLS_SKIP_CHECK=1 mtype -i "$img" ::/USOS/NT3/NAMES.TXT 2>/dev/null | tr -d '\r')
        value() { printf '%s\n' "$names" | awk -v k="$1" -F= '$1 == k { sub(/^[^=]*=/, ""); print; exit }'; }
        if [ -n "$NT31_NET" ]; then
            nt31_vm_patch_file "$img" NTLANMAN.INF nt31_ntlanman_inf &&
                nt31_vm_patch_file "$img" OEMNADLB.INF nt31_oemnadlb_inf || { rm -f "$inf"; return 1; }
        fi
        nt31_initial_inf "$(value fullname)" "$(value org)" "$(value computer)" "$NT31_NET" < "$inf" > "$inf.new" || { rm -f "$inf" "$inf.new"; return 1; }
        MTOOLS_SKIP_CHECK=1 mcopy -o -i "$img" "$inf.new" ::/WINNT/SYSTEM32/INITIAL.INF || { rm -f "$inf" "$inf.new"; return 1; }
    fi
    rm -f "$inf" "$inf.new"
    # HARDWARE.INF: the Language (Locale) page keeps the CD's default.
    nt31_vm_patch_file "$img" HARDWARE.INF nt31_hardware_inf
}

# Filters \WINNT\SYSTEM32\$2 of the C: image $1 (mtools "image@@offset")
# through $3 (stdin -> stdout) unless it already has a "; USOS" line.
# 1 = the file is missing or cannot be patched.
nt31_vm_patch_file() {
    pf=$W9X_VM_RUN/../nt31-patch.inf
    MTOOLS_SKIP_CHECK=1 mtype -i "$1" "::/WINNT/SYSTEM32/$2" > "$pf" 2>/dev/null && [ -s "$pf" ] || { rm -f "$pf"; return 1; }
    if ! grep -q '^; USOS' "$pf"; then
        "$3" < "$pf" > "$pf.new" && MTOOLS_SKIP_CHECK=1 mcopy -o -i "$1" "$pf.new" "::/WINNT/SYSTEM32/$2" || { rm -f "$pf" "$pf.new"; return 1; }
    fi
    rm -f "$pf" "$pf.new"
    return 0
}

# NT 3.1 Advanced Server network pages (NTLANMAN.INF, stdin -> stdout, CR
# LF): during Setup (NTN_Origination install) the adapter is the MS Loopback
# Adapter (LOOP, the CD's OEMNADLB.INF and LOOP.SYS; no hardware, so the
# installed system runs the same on the X470 without the VM network card),
# without the detection and the adapter list. Control Panel runs
# (NTN_Origination ncpa) keep the CD behaviour.
nt31_ntlanman_inf() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low) }
        low ~ /^\[/ { sec = low }
        { printf "%s\r\n", line }
        sec == "[initialadapterinstall]" && low == "set!stf_ncdetinfo={}" && !hit++ {
            printf "; USOS: the MS Loopback Adapter during Setup (docs/nt31-2026-10-09.md)\r\n"
            printf "    Ifstr(i) $(!NTN_Origination) == \"install\"\r\n"
            printf "        Set !STF_NCOPTION = LOOP\r\n"
            printf "        Goto detectbypass\r\n"
            printf "    Endif\r\n"
        }
        END { if (hit != 1) { print "NTLANMAN.INF: no [InitialAdapterInstall] STF_NCDETINFO line" > "/dev/stderr"; exit 1 } }'
}

# OEMNADLB.INF (MS Loopback Adapter, stdin -> stdout, CR LF): during Setup
# no media type page (the INF default 802.3 stays).
nt31_oemnadlb_inf() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low) }
        { printf "%s\r\n", line }
        low == "adapteroptions=+" && !hit++ {
            printf "; USOS: no media type page during Setup (docs/nt31-2026-10-09.md)\r\n"
            printf "    Ifstr(i) $(!NTN_Origination) == \"install\"\r\n"
            printf "        goto skipoptions\r\n"
            printf "    Endif\r\n"
        }
        END { if (hit != 1) { print "OEMNADLB.INF: no adapteroptions label" > "/dev/stderr"; exit 1 } }'
}

# NT 3.1 HARDWARE.INF (stdin -> stdout, CR LF): [InitialHardwareInstall]
# installs the detected default language (locale) without its page.
nt31_hardware_inf() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low) }
        low ~ /^\[/ { sec = low }
        { printf "%s\r\n", line }
        sec == "[initialhardwareinstall]" && low == "system=+" { printf "; USOS: the default language (locale), no page\r\n    goto install_system\r\n"; hit++ }
        sec == "[initialhardwareinstall]" && low == "install_system=+" { lab++ }
        END { if (hit != 1 || lab != 1) { print "HARDWARE.INF: no [InitialHardwareInstall] system / install_system label" > "/dev/stderr"; exit 1 } }'
}

# The QEMU argument list (W9X_VM_ARGS_FN for w9x_phase1_run): the w9x rules
# (no network, -no-reboot, cache=none) with the disk view limited to the
# first NT4_VM_DISK_BYTES (FAT16 C: is in the first 2 GiB; NT 4.0 atapi has
# no 48-bit LBA) and the hard disk as the only boot device.
# The target disk: IDE for NT 4.0; NT 3.51 on an AMD Am53c974 SCSI adapter
# (NT4_VM_HBA, in-box miniport amsint.sys; SeaBIOS boots from it): NT 3.51's
# IDE driver atdisk.sys overflows a kernel stack in QEMU (nested per-sector
# IRQ 14, STOP 0x7F 8, 2026-10-08). The real disk keeps its own controller
# after the install (AHCINT). One argument per line.
nt4_vm_disk_args() {
    if [ -n "${NT4_VM_HBA:-}" ]; then
        printf '%s\n' -drive "file=$1,format=raw,size=$NT4_VM_DISK_BYTES,if=none,id=target,cache=none,file.locking=off" \
            -device "$NT4_VM_HBA,id=hba" -device scsi-hd,drive=target,bus=hba.0,bootindex=0
    else
        printf '%s\n' -drive "file=$1,format=raw,size=$NT4_VM_DISK_BYTES,if=ide,index=0,media=disk,cache=none,file.locking=off"
    fi
}

nt4_vm_args() {
    case "$2" in kvm) accel='kvm' ;; *) accel='tcg,tb-size=128' ;; esac
    printf '%s\n' -name usos-nt4-install -nodefaults -L "$W9X_VM_DATADIR" \
        -machine pc -accel "$accel" -cpu "${NT4_VM_CPU:-pentium3}" -smp 1 -m "${NT4_VM_MB:-$W9X_VM_GUEST_MB}" \
        -rtc base=localtime -vga std -display none -nic none -no-reboot \
        $(nt4_vm_disk_args "$1") \
        -boot order=c \
        -serial "file:$W9X_VM_RUN/serial.log" \
        -chardev "file,id=seabios,path=$W9X_VM_RUN/seabios.log" -device isa-debugcon,iobase=0x402,chardev=seabios \
        -monitor "pipe:$W9X_VM_RUN/mon" \
        -monitor "pipe:$W9X_VM_RUN/key"
}

# 0 when C: of the target $1 holds \USOS\NT4\$2 or (NT 3.51) \USOS\NT3\$2
# (mtools, read only).
nt4_vm_marker() {
    MTOOLS_SKIP_CHECK=1 mdir -i "$1@@$NT4_PART_OFFSET" "::/USOS/NT4/$2" >/dev/null 2>&1 ||
        MTOOLS_SKIP_CHECK=1 mdir -i "$1@@$NT4_PART_OFFSET" "::/USOS/NT3/$2" >/dev/null 2>&1
}

# Runs the VM until the install is done. Calls nt4_vm_progress BOOT ELAPSED
# WRITTEN_MB when the caller defines it. 0 = DONE.TXT written, 2 = QEMU
# failed, 3 = timeout or no disk write for NT4_VM_STALL seconds
# (NT4_VM_STALLED = those seconds, 0 for the overall timeout), 4 = no
# DONE.TXT after NT4_VM_BOOTS runs. Logs of every run in $1/run-N (the last
# screen as screen.ppm).
nt4_vm_install() {
    target=$1
    logs=$2
    accel=${3:-tcg}
    NT4_VM_ELAPSED=0
    W9X_VM_ARGS_FN=nt4_vm_args
    W9X_VM_KEY=''
    W9X_VM_STALL_ANY=1
    W9X_VM_STALL=$NT4_VM_STALL
    W9X_VM_ANSWER=$NT4_VM_ANSWER
    # NT 3.51 text-mode Setup stops at "Setup was unable to verify your C:
    # drive ... Press ENTER to continue" (its autochk on the USOS FAT16 C:,
    # QEMU 2026-10-08); ENTER goes on and the install completes.
    W9X_VM_TEXT_ANSWER=''
    NT4_VM_HBA=''
    NT4_VM_CPU=''
    NT4_VM_MB=''
    W9X_VM_TICK_FN=''
    nt3=''
    nt31=''
    NT31_NET=''
    if MTOOLS_SKIP_CHECK=1 mdir -i "$target@@$NT4_PART_OFFSET" ::/USOS/NT3 >/dev/null 2>&1; then
        nt3=yes
        W9X_VM_TEXT_ANSWER=${NT3_VM_TEXT_ANSWER:-ret}
        NT4_VM_HBA=${NT3_VM_HBA:-am53c974}
        # NT 3.5 (SOURCE.TXT version=3.50, nt4_csmwrap_target.sh): its GUI
        # Setup (INITIAL.INF GetProcessor) knows no CPU newer than a Pentium
        # and its CD has no amsint.sys; its atdisk.sys runs text mode on QEMU
        # IDE without the NT 3.51 interrupt nesting (QEMU 2026-10-09).
        if MTOOLS_SKIP_CHECK=1 mtype -i "$target@@$NT4_PART_OFFSET" ::/USOS/NT3/SOURCE.TXT 2>/dev/null | grep -q '^version=3\.50'; then
            NT4_VM_CPU=${NT35_VM_CPU:-pentium}
            NT4_VM_HBA=${NT35_VM_HBA:-}
        fi
        # NT 3.1 (version=3.10): text mode answered page by page
        # (nt31_vm_tick), GUI Setup runs from the patched INITIAL.INF
        # (nt31_vm_patch_initial after each run); Pentium, IDE, 64 MiB.
        if MTOOLS_SKIP_CHECK=1 mtype -i "$target@@$NT4_PART_OFFSET" ::/USOS/NT3/SOURCE.TXT 2>/dev/null | grep -q '^version=3\.10'; then
            nt31=yes
            NT4_VM_CPU=${NT31_VM_CPU:-pentium}
            NT4_VM_HBA=''
            NT4_VM_MB=${NT31_VM_MB:-64}
            W9X_VM_TEXT_ANSWER=''
            # The Date/Time applet GUI Setup opens (it writes the time zone;
            # without it WinLogon refused Administrator: "time restrictions",
            # QEMU 2026-10-10) is accepted with ENTER after the idle time.
            W9X_VM_ANSWER=${NT31_VM_ANSWER:-ret}
            W9X_VM_TICK_FN=nt31_vm_tick
            NT31_PAGE=''
            NT31_TICK_AT=-10
        fi
    fi
    NT4_VM_STALLED=0
    boot=0
    boots=$NT4_VM_BOOTS
    # NT 3.51 restarts a few times after GUI Setup before the usosnt3 service
    # runs (QEMU 2026-10-08: DONE.TXT at the 5th and at the 7th VM start).
    [ -z "$nt3" ] || boots=${NT3_VM_BOOTS:-12}
    while [ "$boot" -lt "$boots" ]; do
        boot=$((boot + 1))
        NT4_VM_BOOT=$boot
        w9x_phase1_progress() { command -v nt4_vm_progress >/dev/null 2>&1 && nt4_vm_progress "$NT4_VM_BOOT" "$1" "$2"; return 0; }
        w9x_phase1_run "$target" "$accel"
        rc=$?
        NT4_VM_ELAPSED=$((NT4_VM_ELAPSED + ${W9X_VM_ELAPSED:-0}))
        w9x_phase1_keep_logs "$logs/run-$boot"
        NT4_VM_STALLED=${W9X_VM_STALLED:-0}
        printf 'run %s rc=%s elapsed=%s stalled=%s\n' "$boot" "$rc" "${W9X_VM_ELAPSED:-0}" "$NT4_VM_STALLED" >> "$logs/runs.txt"
        [ "$rc" = 0 ] || { W9X_VM_TICK_FN=''; return "$rc"; }
        if [ -n "$nt31" ] && ! nt31_vm_patch_initial "$target"; then
            printf 'run %s: cannot patch INITIAL.INF\n' "$boot" >> "$logs/runs.txt"
            W9X_VM_TICK_FN=''
            return 2
        fi
        # NT 3.1 Advanced Server: GUI Setup stops first at Domain Settings
        # (3.1 has no unattended form of it, QEMU 2026-10-10): controller of
        # the new domain USOSDOMAIN (NT31_DOMAIN_KEYS), then the Date/Time
        # applet takes ENTER.
        [ -z "$nt31" ] || [ "$NT31_NET" != net ] ||
            W9X_VM_ANSWER=${NT31_AS_VM_ANSWER:-alt-c tab ${NT31_DOMAIN_KEYS:-shift-u shift-s shift-o shift-s shift-d shift-o shift-m shift-a shift-i shift-n} ret;ret}
        if nt4_vm_marker "$target" DONE.TXT; then W9X_VM_TICK_FN=''; return 0; fi
    done
    W9X_VM_TICK_FN=''
    return 4
}

# BOOT.INI (stdin -> stdout, CR LF): NT4_BOOT_OPTIONS on every ARC line
# that lacks /NUMPROC, timeout=5, no C:\ entry (Setup saved the syslinux
# boot sector as BOOTSECT.DOS; LDLINUX.SYS is removed below). A /MAXMEM
# Setup wrote is dropped first (the Enterprise Server CD's TXTSETUP.SIF has
# OsLoadOptions "/maxmem=256", QEMU 2026-10-07).
# Diagnostics: after the first normal entry (the default stays first) an
# "[USOS /SOS]" entry (driver list on screen, photographable on a crash) and,
# when Setup wrote none, a "[VGA mode]" /basevideo /sos entry.
nt4_boot_ini() {
    awk -v BINMODE=3 -v opts="$NT4_BOOT_OPTIONS" '
        function entry(arc, desc, sw) { return arc "=\"" desc "\" " sw (opts == "" ? "" : " " opts) }
        { line = $0; sub(/\r$/, "", line); low = tolower(line) }
        low ~ /^[ \t]*timeout[ \t]*=/ { line = "timeout=5" }
        low ~ /^[ \t]*c:\\[ \t]*=/ { next }
        low ~ /^[ \t]*multi\(/ {
            if (low ~ /\/basevideo/) vga = 1
            else if (low ~ /\/sos/) sos = 1
            else if (first == "" && (p = index(line, "=\"")) > 0) {
                rest = substr(line, p + 2); q = index(rest, "\"")
                if (q > 0) { first = n + 1; arc = substr(line, 1, p - 1); desc = substr(rest, 1, q - 1) }
            }
            if (low !~ /\/numproc/) {
                gsub(/[ \t]+\/[Mm][Aa][Xx][Mm][Ee][Mm]=[0-9]+/, "", line)
                line = line (opts == "" ? "" : " " opts)
            }
        }
        { out[++n] = line }
        END {
            for (i = 1; i <= n; i++) {
                printf "%s\r\n", out[i]
                if (i != first) continue
                if (!sos) printf "%s\r\n", entry(arc, desc " [USOS /SOS]", "/SOS")
                if (!vga) printf "%s\r\n", entry(arc, desc " [VGA mode]", "/basevideo /sos")
            }
        }'
}

# The real path of C:-relative $2 under the mount point $1, any letter case
# (NT 4.0 stores lower-case 8.3 names, e.g. boot.ini, ntoskrnl.exe, with the
# NT case flags; shortname=winnt shows them lower case and the micro-Linux
# vfat lookup is case-sensitive: QEMU e2e 2026-10-07 found "missing NTLDR").
# 1 when a component does not exist.
nt4_ci_path() {
    found=$1
    rest=$2
    while [ -n "$rest" ]; do
        part=${rest%%/*}
        case "$rest" in */*) rest=${rest#*/} ;; *) rest='' ;; esac
        [ -n "$part" ] || continue
        match=$(ls -a "$found" 2>/dev/null | awk -v p="$part" 'tolower($0) == tolower(p) { print; exit }')
        [ -n "$match" ] || return 1
        found=$found/$match
    done
    printf '%s\n' "$found"
}

# 0 when the last fsck.fat -n run in the log $2 only found the dirty bit
# (NT 3.51 leaves it set when the USOS service restarts the VM, QEMU
# 2026-10-08); then fsck.fat -a clears it and a new -n run must be clean.
nt4_vm_dirty_only() {
    last=$(awk '/^== fsck.fat -n:/ { s = "" } { s = s $0 "\n" } END { printf "%s", s }' "$2")
    printf '%s' "$last" | grep -q 'Dirty bit is set' || return 1
    printf '%s' "$last" | grep -v -e '^== ' -e '^fsck.fat ' -e 'Dirty bit is set' -e 'Automatically removing dirty bit' \
        -e '^Leaving filesystem unchanged' -e ': [0-9]* files, [0-9]*/[0-9]* clusters$' -e '^ *$' | grep -q . && return 1
    printf '== fsck.fat -a: dirty bit only\n' >> "$2"
    fsck.fat -a "$1" >> "$2" 2>&1
    w9x_phase1_fsck "$1" "$2" 'C: after clearing the dirty bit'
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
    if ! w9x_phase1_fsck "$loop" "$logs/fsck.txt" 'C: after the NT 4.0 install' && ! nt4_vm_dirty_only "$loop" "$logs/fsck.txt"; then
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
    # NT 3.51 keeps its USOS files in \USOS\NT3 (USOSNT3.EXE writes POST.LOG
    # and the key dumps as .TXT; nt4_csmwrap_target.sh).
    sub=NT4
    nt4_ci_path "$c" USOS/NT3 >/dev/null && sub=NT3
    for file in POST.LOG VERSION.REG CSD.REG USOSRST.REG USOSVBE.REG VERSION.TXT DRIVERS.TXT SETUP.LOG DONE.TXT SOURCE.TXT; do
        src=$(nt4_ci_path "$c" "USOS/$sub/$file") && cp "$src" "$logs/$file" 2>/dev/null
    done
    status=0
    reason=''
    [ "$sub" = NT4 ] || reason='NT 3.x;'
    for path in WINNT/SYSTEM32/NTOSKRNL.EXE WINNT/SYSTEM32/DRIVERS/AHCINT.SYS WINNT/SYSTEM32/DRIVERS/USOSRST.SYS BOOT.INI NTLDR USOS/$sub/DONE.TXT; do
        nt4_ci_path "$c" "$path" >/dev/null || { reason="$reason missing $path;"; status=1; }
    done
    if nt4_ci_path "$c" USOS/NT4/SP6I386.EXE >/dev/null; then
        # SP6a: Control\Windows CSDVersion = 0x600 right after update.exe (the
        # CurrentVersion string keeps the CD's service pack until a restart).
        if grep -aiq 'CSDVersion"=dword:0000060' "$logs/CSD.REG" 2>/dev/null ||
            grep -aq 'Service Pack 6' "$logs/VERSION.REG" 2>/dev/null; then reason="$reason SP6a installed;"
        elif grep -aq 'crypto=high' "$logs/SOURCE.TXT" 2>/dev/null; then
            # update.exe -u exits without a word when a Standard Encryption
            # SP6a meets the 128-bit files of a US/Canada CD, and POST.CMD's
            # switch to standard encryption did not help either.
            reason="$reason no Service Pack 6 in CSDVersion (high-encryption CD);"; status=1
        else reason="$reason no Service Pack 6 in CSDVersion;"; status=1; fi
    fi
    if [ "$status" = 0 ] && [ "$sub" = NT3 ]; then
        # nt4_csmwrap_target.sh kept AUTOCHK.EXE out of text-mode Setup.
        # Setup copied the stand-in (usosachk) as system32\autochk.exe.
        if src=$(nt4_ci_path "$c" USOS/NT3/AUTOCHK.EXE); then
            sys32=$(nt4_ci_path "$c" WINNT/SYSTEM32) &&
                { old=$(nt4_ci_path "$c" WINNT/SYSTEM32/AUTOCHK.EXE) || old=$sys32/autochk.exe; } &&
                cp "$src" "$old" && reason="$reason autochk.exe restored;" ||
                { reason="$reason cannot restore autochk.exe;"; status=1; }
        fi
    fi
    if [ "$status" = 0 ] && [ "$sub" = NT3 ] && src=$(nt4_ci_path "$c" USOS/NT3/SOURCE.TXT) &&
        grep -aq '^version=3\.50' "$src"; then
        NT4_BOOT_OPTIONS=$NT35_BOOT_OPTIONS
    fi
    if [ "$status" = 0 ] && [ "$sub" = NT3 ] && src=$(nt4_ci_path "$c" USOS/NT3/SOURCE.TXT) &&
        grep -aq '^version=3\.10' "$src"; then
        NT4_BOOT_OPTIONS=$NT31_BOOT_OPTIONS
        # NT 3.1: the Setup boot floppy files on the root of C:
        # (nt4_csmwrap_target.sh nt31_layout, ROOTLIST.TXT).
        if list=$(nt4_ci_path "$c" USOS/NT3/ROOTLIST.TXT); then
            for leftover in $(tr -d '\r' < "$list") TXTSETUP.INF; do
                file=$(nt4_ci_path "$c" "$leftover") || continue
                chmod u+w "$file" 2>/dev/null || true
                rm -f "$file"
            done
        fi
    fi
    if [ "$status" = 0 ]; then
        ini=$(nt4_ci_path "$c" BOOT.INI) || ini=$c/BOOT.INI
        chmod u+w "$ini" 2>/dev/null || true
        nt4_boot_ini < "$ini" > "$W9X_VM_RUN/boot.ini" && cat "$W9X_VM_RUN/boot.ini" > "$ini" ||
            { reason="$reason cannot write BOOT.INI;"; status=1; }
        cp "$ini" "$logs/BOOT.INI" 2>/dev/null
        # chmod clears the read-only bit (vfat), so rm can remove LDLINUX.SYS.
        for leftover in LDLINUX.SYS LDLINUX.C32 SYSLINUX.CFG CHAIN.C32 LIBCOM32.C32 LIBUTIL.C32 BOOTSECT.DOS '$LDR$' TXTSETUP.SIF WINNT.SIF \
            USOS/NT4/SP6I386.EXE; do
            file=$(nt4_ci_path "$c" "$leftover") || continue
            chmod u+w "$file" 2>/dev/null || true
            rm -f "$file"
        done
        for leftover in '$WIN_NT$.~BT' '$WIN_NT$.~LS' USOS/NT4/SP6X; do
            file=$(nt4_ci_path "$c" "$leftover") && rm -rf "$file"
        done
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
