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
# w9x_pid95_prepare MSBATCH.INF WINSETUP.BIN [split]: prints what it did.
#   kept       no ProductID, or one that fits (at most 17 characters)
#   oem-split  (only with "split") an OEM ID: WINSETUP.BIN's template gets the
#              6-character prefix ddddd- in place (17 x's -> ddddd-xxxxxxxxxxx,
#              same length), ProductID becomes the 17-character rest
#              OEM-ddddddd-ddddd, so SUWIN assembles the full ID
#   dropped    any other ID of 18 or more characters (or no unique template):
#              the line goes, the batch file stays readable, Setup asks
# The MSBATCH.INF stays CR LF. rc 1 only on a file error.

W9X_PID95_TEMPLATE='15 20 2f 55 3a 78 78 78 78 78 78 78 78 78 78 78 78 78 78 78 78 78'

# The [Setup] ProductID value of $1, quotes removed (empty without one).
w9x_pid95_value() {
    tr -d '\r' < "$1" | awk '
        /^[ \t]*\[/ { setup = (tolower($0) ~ /^[ \t]*\[setup\][ \t]*$/); next }
        setup && tolower($0) ~ /^[ \t]*productid[ \t]*=/ {
            v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]+$/, "", v); gsub(/"/, "", v); print v; exit }'
}

# Byte offset of the 17 x's of the " /U:" template in $1 (one match only).
w9x_pid95_template_offset() {
    od -An -v -tx1 "$1" | awk -v pat="$W9X_PID95_TEMPLATE" '
        BEGIN { n = split(pat, p, " ") }
        { for (i = 1; i <= NF; i++) b[pos++] = $i }
        END {
            hits = 0
            for (s = 0; s + n <= pos; s++) {
                if (b[s] != p[1]) continue
                for (k = 2; k <= n && b[s + k - 1] == p[k]; k++) ;
                if (k > n) { hits++; at = s + 5 }
            }
            if (hits != 1) exit 1
            print at }'
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
    pid_inf=$1 pid_bin=$2 pid_mode=${3:-}
    [ -f "$pid_inf" ] || return 1
    pid_value=$(w9x_pid95_value "$pid_inf")
    if [ "${#pid_value}" -le 17 ]; then
        echo kept
        return 0
    fi
    if [ "$pid_mode" = split ] && [ -f "$pid_bin" ] &&
       printf '%s\n' "$pid_value" | grep -Eqi '^[0-9]{5}-OEM-[0-9]{7}-[0-9]{5}$' &&
       pid_at=$(w9x_pid95_template_offset "$pid_bin"); then
        pid_head=$(printf '%s' "$pid_value" | cut -c1-6)
        pid_tail=$(printf '%s' "$pid_value" | cut -c7- | tr '[:lower:]' '[:upper:]')
        printf '%s' "$pid_head" | dd of="$pid_bin" bs=1 seek="$pid_at" conv=notrunc 2>/dev/null || return 1
        [ "$(dd if="$pid_bin" bs=1 skip="$pid_at" count=6 2>/dev/null)" = "$pid_head" ] || return 1
        w9x_pid95_rewrite "$pid_inf" "$pid_tail" || return 1
        echo oem-split
        return 0
    fi
    w9x_pid95_rewrite "$pid_inf" '' || return 1
    echo dropped
}
