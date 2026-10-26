# Windows 95 Setup and the MSBATCH.INF [Setup] ProductID (native phase 1).
# Sourced by tools/w9x_csmwrap_target.sh. Own code; the layout below was
# read from the user's 95 RTM PL OEM CD (SUWIN.EXE, SETUPX.DLL, WINSETUP.BIN
# 4.00.950) for compatibility, see docs/win95-rtm-osr1-2026-10-23.md (PID).
#
# SUWIN reads [Setup] ProductID (up to 23 characters) with lstrcpy into a
# field 6 bytes into its 24-byte product ID buffer; the 18 bytes left end
# where the batch file path starts. A full OEM ID ddddd-OEM-ddddddd-ddddd
# (23 characters) overwrites the first 6 bytes of that path with its last 5
# digits: the batch file is no longer found and Setup runs on defaults
# (no "Batchfile=" in SETUPLOG.TXT, every page, startup disk, floppy and
# restart prompts). Retail keys ddd-ddddddd (11) fit. The buffer's first 6
# bytes come from WINSETUP's appended /U: template (17 x's). The OEM check
# (SETUPX PIDValidate, ProductType 9) wants the full 23-character ID there.
#
# w9x_pid95_prepare MSBATCH.INF: prints what it did.
#   kept       no ProductID, or one that fits (at most 17 characters)
#   dropped    any ID of 18 or more characters (every OEM ID): the line
#              goes, the batch file stays readable, Setup asks for the key
# An OEM ID is never split into WINSETUP.BIN's /U: template any more (the
# former oem-split mode for 950): the batch ProductID never filled the
# Product ID page anyway (SUWIN reads only the page's edit field), and the
# patched template put 5 key digits into SETUPLOG.TXT's CmdLine (X470 95
# RTM PL native, 2026-10-26). WINSETUP.BIN stays as on the CD.
# The MSBATCH.INF stays CR LF. rc 1 only on a file error.

# The [Setup] ProductID value of $1, quotes removed (empty without one).
w9x_pid95_value() {
    tr -d '\r' < "$1" | awk '
        /^[ \t]*\[/ { setup = (tolower($0) ~ /^[ \t]*\[setup\][ \t]*$/); next }
        setup && tolower($0) ~ /^[ \t]*productid[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); gsub(/"/, "", v); print v; exit }'
}

# $1 with [Setup] ProductID set to $2 (empty: the line goes). CR LF out.
w9x_pid95_rewrite() {
    tr -d '\r' < "$1" | awk -v new="$2" '
        /^[ \t]*\[/ { setup = (tolower($0) ~ /^[ \t]*\[setup\][ \t]*$/) }
        setup && tolower($0) ~ /^[ \t]*productid[ \t]*=/ {
            if (new != "") print "ProductID=\"" new "\""
            next }
        { print }' | sed 's/$/\r/' > "$1.pid" && mv "$1.pid" "$1"
}

w9x_pid95_prepare() {
    pid_inf=$1
    [ -f "$pid_inf" ] || return 1
    pid_value=$(w9x_pid95_value "$pid_inf")
    if [ "${#pid_value}" -le 17 ]; then
        echo kept
        return 0
    fi
    w9x_pid95_rewrite "$pid_inf" '' || return 1
    echo dropped
}
