# Windows 95 RTM / OSR1 (SETUP 4.0.0.950) only: two text fixes on the
# installed C:\WINDOWS after the VM phase 1 (Setup's file copy) and before
# the first GUI start on the PC. Sourced by tools/w9x_csmwrap_prepare.sh;
# OSR2 / OSR2.1 are never touched (their X470 runs PASS without them).
#
# 1. SETUP.INI [progman.only]: GRPCONV's Program Manager step (PMGroup3=the
#    "Main" group: Printers, Control Panel, Explorer, MS-DOS mode) talks to
#    Program Manager over DDE and hung the 950 first boot on the X470
#    (2026-10-25, w95rtm-micron3/4: the GUI stopped at "Setting up the Start
#    menu"). The Start menu entries come from the other [group*] sections; the
#    Program Manager group is a Windows 3.1 leftover. The section stays (as an
#    empty section), its lines go; [PMGroup3] itself stays unused.
# 2. MONITOR.INF [VESADDC.Install]: 950 installs the DDC monitor (*PNP09FF,
#    "Plug and Play Monitor (VESA DDC)") with MaxResolution=1600,1200 and,
#    unlike OSR2 (which writes MaxResolution from the EDID into the monitor
#    devnode, X470: 1920,1680), never raises it: the display mode list then
#    stops at 1400x1050 although the VESA driver lists 1920x1080 (X470 950
#    USOSRES.LOG 2026-10-25). The VESADDC install section gets its own
#    [USOS.MaxRes] (1920,1200 = the largest USOSVESA.INF mode) instead of the
#    shared [1600] section that named CRT models also use. USOSRES still picks
#    the native / below-native mode inside the 9x 1920x1080 cap.
# Both filters are byte-exact outside the changed lines (CRLF, code page).

# SETUP.INI on stdin -> stdout without the [progman.only] entries.
w9x_950_setupini_filter() {
    LC_ALL=C awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line) }
        line ~ /^[ \t]*\[/ { t = tolower(line); gsub(/[ \t]/, "", t); skip = (t == "[progman.only]"); print; next }
        skip && line !~ /^[ \t]*(;.*)?$/ { dropped++; next }
        { print }
        END { if (!dropped) exit 3 }'
}

# MONITOR.INF on stdin -> stdout, VESADDC.Install with [USOS.MaxRes].
w9x_950_monitorinf_filter() {
    LC_ALL=C awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); cr = ($0 ~ /\r$/) ? "\r" : "" }
        line ~ /^[ \t]*\[/ { t = tolower(line); gsub(/[ \t]/, "", t); vesa = (t == "[vesaddc.install]") }
        vesa && tolower(line) ~ /^addreg[ \t]*=/ {
            n = split(substr(line, index(line, "=") + 1), part, ",")
            out = ""
            for (i = 1; i <= n; i++) { p = part[i]; gsub(/^[ \t]+|[ \t]+$/, "", p)
                if (p == "1600") { p = "USOS.MaxRes"; done++ }
                out = out (i > 1 ? ", " : "") p }
            print "AddReg=" out cr; next }
        { print }
        END {
            if (done != 1) exit 3
            printf "\r\n; USOS (tools/w9x_950_post.sh): DDC monitors up to the largest VESA mode.\r\n"
            printf "[USOS.MaxRes]\r\nHKR,,MaxResolution,,\"1920,1200\"\r\nHKR,\"MODES\\1920,1200\"\r\n"
        }'
}

# w9x_950_post_inject <FAT image or loop device of C:>: both fixes via mtools.
# Prints one log line. Returns 1 only when a file exists but cannot be
# rewritten; a missing file or an unexpected layout leaves it unchanged.
w9x_950_post_inject() {
    wp_img=$1
    wp_tmp=${TMPDIR:-/tmp}/w9x-950post.$$
    rm -rf "$wp_tmp"; mkdir -p "$wp_tmp" || return 1
    wp_msg='' wp_rc=0
    for wp_pair in 'SETUP.INI:setupini:progman.only removed' 'INF/MONITOR.INF:monitorinf:VESADDC MaxResolution 1920,1200'; do
        wp_file=${wp_pair%%:*} wp_rest=${wp_pair#*:}
        wp_kind=${wp_rest%%:*} wp_done=${wp_rest#*:}
        if ! mcopy -n -i "$wp_img" "::/WINDOWS/$wp_file" "$wp_tmp/in" 2>/dev/null; then
            wp_msg="$wp_msg; $wp_file missing (unchanged)"; continue
        fi
        if grep -q 'USOS (tools/w9x_950_post.sh)' "$wp_tmp/in"; then
            wp_msg="$wp_msg; $wp_file already done"; continue
        fi
        if ! "w9x_950_${wp_kind}_filter" < "$wp_tmp/in" > "$wp_tmp/out"; then
            wp_msg="$wp_msg; $wp_file nothing to change (unchanged)"; continue
        fi
        if mcopy -o -i "$wp_img" "$wp_tmp/out" "::/WINDOWS/$wp_file"; then
            wp_msg="$wp_msg; $wp_file: $wp_done"
        else
            wp_msg="$wp_msg; $wp_file: write FAILED"; wp_rc=1
        fi
    done
    rm -rf "$wp_tmp"
    printf '950 post-phase1:%s\n' "${wp_msg#;}"
    return $wp_rc
}

# Native phase 1 (no VM; EFI/USOS/win9x/phase1-native.flag or no VM on this
# PC): no prep system runs between Setup's file copy and the first GUI start,
# so tools/w9x_csmwrap_target.sh stages this DOS twin of w9x_950_post_inject
# instead. AUTOEXEC.BAT (INSTALL.BAT, src/platform/bios/dos_startup.cmd)
# calls it before FIRSTBT.BAT; once Setup's files are on C: (WIN.COM and
# SYSTEM.DAT, i.e. the first start after phase 1) it runs VESBIND PMDROP /
# MAXRES (the same bytes as the awk filters above), checks each result by
# running the filter again, logs to C:\USOS9X\W950POST.LOG and writes
# PHASE1.OK, the marker the VM path writes and FIRSTBT.BAT waits for. The
# originals stay as C:\USOS9X\SETUPINI.ORG / MONINF.ORG. A Product ID staged
# for Setup's own page (USOSPID.KEY, tools/w9x_pid95.sh) is deleted here at
# the latest, once Setup's files are on C: (USOSPID.DRV deletes it earlier).
# Display binding (VESA95 / VESALATE) is left alone: the native run ends
# with one adapter.
# w9x_950_post_dos_write <C:\USOS9X staging dir> [osr2]
# osr2: 95 OSR2 under the first-desktop coordinator (tools/w9x_firstboot.sh):
# only the marker (PHASE1.OK, which FIRSTBT.BAT waits for) and the Product
# ID file, at the same point; OSR2 needs neither text fix (its X470 runs:
# no GRPCONV hang, MaxResolution from the EDID).
w9x_950_post_dos_write() {
    if [ "${2:-}" = osr2 ]; then
        sed 's/$/\r/' > "$1/W950POST.BAT" <<'EOF'
@ECHO OFF
REM USOS (tools/w9x_950_post.sh): 95 OSR2 after a native phase 1, marker only.
IF EXIST C:\USOS9X\PHASE1.OK GOTO END
IF NOT EXIST C:\WINDOWS\WIN.COM GOTO END
IF EXIST C:\USOS9X\USOSPID.KEY DEL C:\USOS9X\USOSPID.KEY
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
ECHO OSR2: no 950 text fixes, PHASE1.OK only>> C:\USOS9X\W950POST.LOG
ECHO phase1=native-osr2> C:\USOS9X\PHASE1.OK
:END
EOF
        return
    fi
    [ -f "$1/VESBIND.EXE" ] || return 1
    sed 's/$/\r/' > "$1/W950POST.BAT" <<'EOF'
@ECHO OFF
REM USOS (tools/w9x_950_post.sh): SETUP 4.0.0.950 after a native phase 1.
IF EXIST C:\USOS9X\PHASE1.OK GOTO END
IF NOT EXIST C:\WINDOWS\WIN.COM GOTO END
IF EXIST C:\USOS9X\USOSPID.KEY DEL C:\USOS9X\USOSPID.KEY
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST C:\USOS9X\VESBIND.EXE GOTO NOVB
IF NOT EXIST C:\WINDOWS\SETUP.INI GOTO PMMISS
C:\USOS9X\VESBIND.EXE PMDROP C:\WINDOWS\SETUP.INI C:\USOS9X\SETUPINI.NEW
IF ERRORLEVEL 2 GOTO PMBAD
IF ERRORLEVEL 1 GOTO PMNONE
COPY /Y C:\WINDOWS\SETUP.INI C:\USOS9X\SETUPINI.ORG > NUL
COPY /Y C:\USOS9X\SETUPINI.NEW C:\WINDOWS\SETUP.INI > NUL
C:\USOS9X\VESBIND.EXE PMDROP C:\WINDOWS\SETUP.INI C:\USOS9X\SETUPINI.CHK
IF ERRORLEVEL 2 GOTO PMBAD
IF NOT ERRORLEVEL 1 GOTO PMBAD
ECHO SETUP.INI: progman.only removed>> C:\USOS9X\W950POST.LOG
GOTO MON
:PMMISS
ECHO SETUP.INI missing (unchanged)>> C:\USOS9X\W950POST.LOG
GOTO MON
:PMNONE
ECHO SETUP.INI nothing to change (unchanged)>> C:\USOS9X\W950POST.LOG
GOTO MON
:PMBAD
ECHO SETUP.INI: FAILED>> C:\USOS9X\W950POST.LOG
:MON
IF NOT EXIST C:\WINDOWS\INF\MONITOR.INF GOTO MNMISS
C:\USOS9X\VESBIND.EXE MAXRES C:\WINDOWS\INF\MONITOR.INF C:\USOS9X\MONINF.NEW
IF ERRORLEVEL 2 GOTO MNBAD
IF ERRORLEVEL 1 GOTO MNNONE
COPY /Y C:\WINDOWS\INF\MONITOR.INF C:\USOS9X\MONINF.ORG > NUL
COPY /Y C:\USOS9X\MONINF.NEW C:\WINDOWS\INF\MONITOR.INF > NUL
C:\USOS9X\VESBIND.EXE MAXRES C:\WINDOWS\INF\MONITOR.INF C:\USOS9X\MONINF.CHK
IF ERRORLEVEL 2 GOTO MNBAD
IF NOT ERRORLEVEL 1 GOTO MNBAD
ECHO INF\MONITOR.INF: VESADDC MaxResolution 1920,1200>> C:\USOS9X\W950POST.LOG
GOTO MARK
:MNMISS
ECHO INF\MONITOR.INF missing (unchanged)>> C:\USOS9X\W950POST.LOG
GOTO MARK
:MNNONE
ECHO INF\MONITOR.INF nothing to change (unchanged)>> C:\USOS9X\W950POST.LOG
GOTO MARK
:MNBAD
ECHO INF\MONITOR.INF: FAILED>> C:\USOS9X\W950POST.LOG
GOTO MARK
:NOVB
ECHO VESBIND.EXE missing: no 950 post fixes>> C:\USOS9X\W950POST.LOG
:MARK
ECHO phase1=native> C:\USOS9X\PHASE1.OK
:END
EOF
}
