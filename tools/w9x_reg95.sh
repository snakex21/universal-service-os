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
# w9x_reg95_write <C:\USOS9X folder> <MSBATCH.INF> [usoslog] [vmd inf]
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
#   * vmd inf argument (C:\USOS9X\USOSVMD.INF: the mouse in MS-DOS boxes,
#     docs/dos-mouse-2026-10-18.md "Windows 95"), two values 98 / Me do not
#     need. (a) The machine RunOnce value USOSVmd that runs the INF (rundll
#     setupx InstallHinfSection, UpdateInis: SYSTEM.INI [386Enh]
#     device=*vmouse and device=C:\USOS9X\USOSVMD.VXD); INSTALL.BAT's
#     [USOS.CsmReg] line for it is lost on 95 like every AddReg. (b)
#     CSConfigFlags 6 (do not create, do not start) in hardware profile 0001
#     for Root\*PNP0F0E\0000, the PS/2 port mouse that 95 Setup's detection
#     adds with Class\Mouse DevLoader *vmouse, MouseType PS2. 98 SE has the
#     same devnode without a Driver value, so its VMOUSE never sees it. On
#     95, once device=*vmouse loads VMOUSE, CONFIGMG would start the devnode
#     and VMOUSE's PS/2 init (INT 15h C205h..C200h with its own C207h
#     callback, a V86 INT 15h hook, IRQ 12) would run whatever USOSVMD
#     claimed: the BIOS-mouse probing that hung the X470 with mouse=*vmouse,
#     and a hook that swallows USOSMOUS.DRV's own C2xx calls. 95 OSR2
#     CONFIGMG.VXD reads CSConfigFlags from Config\<CurrentConfig>\Enum\<id>:
#     bit 2 = devnode not created, bit 4 = problem 22 (disabled) before the
#     start. Overwrite only; without that devnode the profile key is unused.
#   * the LAN policy (an ICW "Completed" line present): the desktop
#     "Internet" icon opens Internet Explorer 3 instead of ICWCONN1.EXE
#     (95 OSR2's {FBF23B42-...} Shell\Open\Command until the wizard ran;
#     the wizard installs Dial-Up Networking and the Dial-Up Adapter).
#   * NoWelcome's replacement: Explorer\Tips Show = 0 (no Welcome window).
#   * IE start page: Internet Explorer 3 cannot open about:blank (X470,
#     2026-10-20: "cannot find"), so an about:blank Start Page / First Home
#     Page becomes the local C:\USOS9X\START.HTM (written here: USOS info and
#     the 68k.news link), as file://C:\USOS9X\START.HTM, the form IE 3's
#     SHDOCVW.DLL builds for local pages itself.
#   * Run value order: USOSLog first, then the self-removing helpers, USOSLan
#     last. The 95 shell starts each Run value inside its RegEnumValue(index)
#     loop, so a helper that deletes its own value at once moves the next
#     value onto its index and the shell skips that one (X470 2026-10-20:
#     USOSLan hid USOSDisplay, USOSRES never ran). The helpers also wait 15 s
#     before deleting (tools/windows_usos_lan.c, tools/windows_usos_res.c).

W9X_REG95_INTERNET_CLSID='{FBF23B42-E3F0-101B-8488-00AA003E56F8}'
W9X_REG95_START_PAGE='file://C:\USOS9X\START.HTM'

w9x_reg95_convert() {
    # Values through the environment: awk -v would expand the backslashes.
    W9X_REG95_LOG=${2:-} W9X_REG95_VMD=${3:-} W9X_REG95_CLSID=$W9X_REG95_INTERNET_CLSID W9X_REG95_HOME=$W9X_REG95_START_PAGE awk '
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
    # HKLM Run values are held back and written in rank order at the end.
    function rank(name) {
        name = tolower(name)
        return name == "usoslog" ? 0 : name == "usosdisplay" ? 2 : name == "usosaddons" ? 3 : name == "usoslan" ? 4 : 1
    }
    function value(key, name, data) {
        if (tolower(key) == tolower(runkey)) { nrun++; runname[nrun] = name; rundata[nrun] = data; return }
        if (tolower(key) ~ /\\internet explorer\\main$/ && tolower(name) ~ /^(start page|first home page)$/ && tolower(data) == "\"about:blank\"")
            data = "\"" esc(home) "\""
        emit(key, name, data)
    }
    BEGIN {
        usoslog = ENVIRON["W9X_REG95_LOG"]; vmd = ENVIRON["W9X_REG95_VMD"]; clsid = ENVIRON["W9X_REG95_CLSID"]; home = ENVIRON["W9X_REG95_HOME"]
        runkey = "HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\Run"
    }
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
                if (fv == 0) value(key, f[3], "\"" esc(n >= 5 ? f[5] : "") "\"")
                else if (fv == 65537) {
                    v = hexval(n >= 5 ? f[5] : "0")
                    if (v < 0) { skip(line, "dword"); continue }
                    # 4 binary bytes, as the 9x readers take a DWORD (and as 95 itself
                    # stores EnableAutodial); real-mode REGEDIT "hex:" is proven on the
                    # X470 (USOSUSB.REG), "dword:" there is not.
                    value(key, f[3], sprintf("hex:%02x,%02x,%02x,%02x", v % 256, int(v / 256) % 256, int(v / 65536) % 256, int(v / 16777216) % 256))
                } else if (fv == 1) {
                    data = ""
                    for (i = 5; i <= n; i++) {
                        b = tolower(f[i]); sub(/^0x/, "", b)
                        if (b !~ /^[0-9a-f][0-9a-f]?$/) { data = "!"; break }
                        data = data (i > 5 ? "," : "") (length(b) == 1 ? "0" b : b)
                    }
                    if (data == "!") { skip(line, "binary"); continue }
                    value(key, f[3], "hex:" data)
                } else { skip(line, "flags " flag); continue }
                if (tolower(f[2]) ~ /internet connection wizard$/ && tolower(f[3]) == "completed") icw = 1
            }
        }
        if (usoslog != "") { nrun++; runname[nrun] = "USOSLog"; rundata[nrun] = "\"" esc(usoslog) "\"" }
        for (r = 0; r <= 4; r++)
            for (i = 1; i <= nrun; i++) if (rank(runname[i]) == r) emit(runkey, runname[i], rundata[i])
        if (icw) emit("HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\\" clsid "\\Shell\\Open\\Command", "", "\"" esc("\"C:\\Program Files\\Internet Explorer\\IEXPLORE.EXE\"") "\"")
        emit("HKEY_USERS\\.Default\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Tips", "Show", "hex:00,00,00,00")
        if (vmd != "") {
            emit("HKEY_LOCAL_MACHINE\\Software\\Microsoft\\Windows\\CurrentVersion\\RunOnce", "USOSVmd",
                 "\"" esc("rundll.exe setupx.dll,InstallHinfSection DefaultInstall 4 " vmd) "\"")
            emit("HKEY_LOCAL_MACHINE\\Config\\0001\\Enum\\Root\\*PNP0F0E\\0000", "CSConfigFlags", "hex:06,00,00,00")
        }
        printf "\r\n"
        for (i = 1; i <= nskip; i++) printf "; USOS: not converted (%s)\r\n", skipped[i]
    }' "$1"
}

# The local IE 3 start page (HTML 3.2, ASCII, CRLF; no script, no images).
w9x_reg95_start_page() {
    sed 's/$/\r/' <<'EOF'
<HTML>
<HEAD><TITLE>USOS - Windows 95</TITLE></HEAD>
<BODY>
<H2>Windows 95, installed by USOS</H2>
<P>Universal Service OS set up this computer. This page is a local file:
C:\USOS9X\START.HTM. Change the start page in View, Options, Navigation.</P>
<P>Without a Windows 95 driver for the network card the link below cannot
open.</P>
<UL>
<LI><A HREF="http://68k.news">68k.news</A> - news for old browsers</LI>
</UL>
<P>USOS logs: C:\USOS9X\LOGS</P>
</BODY>
</HTML>
EOF
}

w9x_reg95_write() {
    dir=$1 inf=$2 usoslog=${3:-} vmd=${4:-}
    [ -d "$dir" ] && [ -r "$inf" ] || return 1
    grep -qi '^\[install\]' "$inf" || return 1
    w9x_reg95_convert "$inf" "$usoslog" "$vmd" >"$dir/REG95.REG" || return 1
    grep -q '^\[HKEY_' "$dir/REG95.REG" || { rm -f "$dir/REG95.REG"; return 1; }
    if grep -q 'START\.HTM' "$dir/REG95.REG"; then w9x_reg95_start_page > "$dir/START.HTM" || return 1; fi
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
