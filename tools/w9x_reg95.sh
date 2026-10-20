# Windows 95: the answer's registry values after Setup (sourced by
# tools/w9x_csmwrap_target.sh).
#
# Why 95 needs this: 98 / 98 SE / Me Setup copies MSBATCH.INF into
# C:\WINDOWS and applies its [Install] AddReg sections (SETUPLOG.TXT
# "MSBATCH.INF=10,..."). Windows 95 OSR2 Setup reads MSBATCH.INF for its
# own [Setup] / [NameAndOrg] / [Network] answers only and ignores [Install]
# (X470 fresh install, 95 OSR2.1 PL, B261020-111448-1F997795: none of
# USOS.Lan, USOS.Display, USOS.CsmReg, USOS.RunOnce reached SYSTEM.DAT or
# USER.DAT, no MSBATCH.INF line in SETUPLOG.TXT). So USOSRES (display mode),
# USOSLAN, USOSLOG never started and the IE / ICW defaults were missing.
#
# w9x_reg95_write <C:\USOS9X folder> <MSBATCH.INF> [usoslog]
# converts the AddReg sections named in [Install] into REG95.REG (REGEDIT4,
# real-mode REGEDIT syntax: HKCU -> HKEY_USERS\.Default, which is HKCU on 95
# without user profiles and the template of a new profile; HKCR ->
# HKLM\SOFTWARE\Classes) and writes REG95.BAT. AUTOEXEC.BAT
# (src/platform/bios/dos_startup.cmd) calls REG95.BAT before every Windows
# start; it imports REG95.REG once, after the VM phase 1 created the
# registry and after VESA95.BAT (whose failure path restores its backup),
# i.e. before the first desktop on the real PC.
#
# Lines the conversion cannot express are left out and listed as REG95.REG
# comments: an LDID (%10%, %25%: USOS.RunOnce's NoWelcome command, whose INF
# 95 never copies), HKR, noclobber / multi-string / expand flags.
# Windows 95 additions (no AddReg line on 98 does these):
#   * usoslog argument: the USOSLOG.EXE Run value (INSTALL.BAT appends it as
#     [USOS.CsmReg] at DOS time, after this conversion).
#   * the LAN policy (an ICW "Completed" line present): the desktop
#     "Internet" icon opens Internet Explorer 3 instead of ICWCONN1.EXE
#     (95 OSR2's {FBF23B42-...} Shell\Open\Command until the wizard ran;
#     the wizard installs Dial-Up Networking and the Dial-Up Adapter).
#   * NoWelcome's replacement: Explorer\Tips Show = 0 (no Welcome window).

W9X_REG95_INTERNET_CLSID='{FBF23B42-E3F0-101B-8488-00AA003E56F8}'

w9x_reg95_convert() {
    # Values through the environment: awk -v would expand the backslashes.
    W9X_REG95_LOG=${2:-} W9X_REG95_CLSID=$W9X_REG95_INTERNET_CLSID awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    # INF fields: comma separated, "..." quoted ("" inside = one quote).
    function fields(line, out,    n, i, c, q, cur) {
        n = 1; cur = ""; q = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "\"") {
                if (q && substr(line, i + 1, 1) == "\"") { cur = cur "\""; i++ }
                else q = !q
            } else if (c == "," && !q) { out[n++] = trim(cur); cur = "" }
            else if (c == ";" && !q) break
            else cur = cur c
        }
        out[n] = trim(cur)
        return n
    }
    function strings(s,    out, a, b, k) {
        out = ""
        while ((a = index(s, "%")) > 0) {
            b = index(substr(s, a + 1), "%")
            if (b == 0) break
            k = tolower(substr(s, a + 1, b - 1))
            if (k in str) out = out substr(s, 1, a - 1) str[k]
            else out = out substr(s, 1, a + b)
            s = substr(s, a + b + 1)
        }
        return out s
    }
    function hexval(s,    i, c, v) {
        s = tolower(s); v = 0
        if (substr(s, 1, 2) != "0x") return s + 0
        for (i = 3; i <= length(s); i++) {
            c = index("0123456789abcdef", substr(s, i, 1))
            if (c == 0) return -1
            v = v * 16 + c - 1
        }
        return v
    }
    function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); return s }
    function emit(key, name, data) {
        if (key != last) { printf "\r\n[%s]\r\n", key; last = key }
        printf "%s=%s\r\n", (name == "" ? "@" : "\"" esc(name) "\""), data
    }
    function skip(line, why) { skipped[++nskip] = why ": " line }
    BEGIN { usoslog = ENVIRON["W9X_REG95_LOG"]; clsid = ENVIRON["W9X_REG95_CLSID"] }
    { sub(/\r$/, "") }
    /^[ \t]*\[/ {
        sec = tolower(trim($0)); gsub(/^\[|\]$/, "", sec); order[++nsec] = sec; next
    }
    /^[ \t]*(;|$)/ { next }
    {
        body[sec] = body[sec] $0 "\n"
        if (sec == "strings") {
            eq = index($0, "=")
            if (eq) { v = trim(substr($0, eq + 1)); gsub(/^"|"$/, "", v); str[tolower(trim(substr($0, 1, eq - 1)))] = v }
        } else if (sec == "install" && tolower($0) ~ /^[ \t]*addreg[ \t]*=/) {
            list = substr($0, index($0, "=") + 1)
        }
    }
    END {
        printf "REGEDIT4\r\n"
        nlist = split(list, names, ",")
        icw = 0
        for (s = 1; s <= nlist; s++) {
            name = tolower(trim(names[s]))
            nl = split(body[name], lines, "\n")
            for (l = 1; l <= nl; l++) {
                line = lines[l]
                if (trim(line) == "") continue
                n = fields(line, f)
                for (i = 1; i <= n; i++) f[i] = strings(f[i])
                root = toupper(f[1])
                if (root == "HKLM") key = "HKEY_LOCAL_MACHINE"
                else if (root == "HKCU") key = "HKEY_USERS\\.Default"
                else if (root == "HKCR") key = "HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes"
                else if (root == "HKU") key = "HKEY_USERS"
                else { skip(line, "root"); continue }
                if (f[2] != "") key = key "\\" f[2]
                bad = 0
                for (i = 2; i <= n; i++) if (f[i] ~ /%[0-9]+%/) bad = 1
                if (bad) { skip(line, "ldid"); continue }
                flag = (n >= 4 ? f[4] : "")
                fv = (flag == "" ? 0 : hexval(flag))
                if (n < 4 && f[3] == "") { if (!(key in made)) { made[key] = 1; if (key != last) { printf "\r\n[%s]\r\n", key; last = key } } continue }
                if (fv == 0) emit(key, f[3], "\"" esc(n >= 5 ? f[5] : "") "\"")
                else if (fv == 65537) {
                    v = hexval(n >= 5 ? f[5] : "0")
                    if (v < 0) { skip(line, "dword"); continue }
                    # 4 binary bytes, as the 9x readers take a DWORD (and as 95 itself
                    # stores EnableAutodial); real-mode REGEDIT "hex:" is proven on the
                    # X470 (USOSUSB.REG), "dword:" there is not.
                    emit(key, f[3], sprintf("hex:%02x,%02x,%02x,%02x", v % 256, int(v / 256) % 256, int(v / 65536) % 256, int(v / 16777216) % 256))
                } else if (fv == 1) {
                    data = ""
                    for (i = 5; i <= n; i++) {
                        b = tolower(f[i]); sub(/^0x/, "", b)
                        if (b !~ /^[0-9a-f][0-9a-f]?$/) { data = "!"; break }
                        data = data (i > 5 ? "," : "") (length(b) == 1 ? "0" b : b)
                    }
                    if (data == "!") { skip(line, "binary"); continue }
                    emit(key, f[3], "hex:" data)
                } else { skip(line, "flags " flag); continue }
                if (tolower(f[2]) ~ /internet connection wizard$/ && tolower(f[3]) == "completed") icw = 1
            }
        }
        if (usoslog != "") emit("HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Run", "USOSLog", "\"" esc(usoslog) "\"")
        if (icw) emit("HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\\" clsid "\\Shell\\Open\\Command", "", "\"" esc("\"C:\\Program Files\\Internet Explorer\\IEXPLORE.EXE\"") "\"")
        emit("HKEY_USERS\\.Default\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Tips", "Show", "hex:00,00,00,00")
        printf "\r\n"
        for (i = 1; i <= nskip; i++) printf "; USOS: not converted (%s)\r\n", skipped[i]
    }' "$1"
}

w9x_reg95_write() {
    dir=$1 inf=$2 usoslog=${3:-}
    [ -d "$dir" ] && [ -r "$inf" ] || return 1
    grep -qi '^\[install\]' "$inf" || return 1
    w9x_reg95_convert "$inf" "$usoslog" > "$dir/REG95.REG" || return 1
    grep -q '^\[HKEY_' "$dir/REG95.REG" || { rm -f "$dir/REG95.REG"; return 1; }
    U='C:\USOS9X\'
    A='C:\WINDOWS\COMMAND\ATTRIB.EXE'
    R='REGEDIT /L:SYSTEM.DAT /R:USER.DAT'
    run='HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run'
    sed 's/$/\r/' > "$dir/REG95.BAT" <<EOF || return 1
@ECHO OFF
REM USOS: Windows 95 answer registry (tools/w9x_reg95.sh): 95 Setup ignores
REM MSBATCH.INF [Install] AddReg. Runs from AUTOEXEC.BAT, imports once.
IF EXIST ${U}REG95.OK GOTO END
IF EXIST ${U}REG95.RUN GOTO END
IF NOT EXIST ${U}REG95.REG GOTO END
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST C:\WINDOWS\USER.DAT GOTO END
IF NOT EXIST $A GOTO END
ECHO run> ${U}REG95.RUN
C:
CD \WINDOWS
$A -S -R -H SYSTEM.DAT
$A -S -R -H USER.DAT
$R ${U}REG95.REG
$R /E ${U}REG95CHK.REG $run
$A +S +R +H SYSTEM.DAT
$A +S +R +H USER.DAT
ECHO ok> ${U}REG95.OK
CD \\
:END
EOF
}
