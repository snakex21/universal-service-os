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
