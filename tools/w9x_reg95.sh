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
    W9X_REG95_LOG=${2:-} W9X_REG95_VMD=${3:-} W9X_REG95_NET_IDENTITY=${4:-} W9X_REG95_CLSID=$W9X_REG95_INTERNET_CLSID W9X_REG95_HOME=$W9X_REG95_START_PAGE awk '
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
        if (tolower(key) ~ /\\currentversion\\winlogon$/ && tolower(name) == "defaultusername" && data != "\"\"") logon_user = data
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
        # Original RTM PnP asks for these again if only [Network] in the
        # answer carries them. Seed the actual 95 VNETSUP identity fields.
        # Enabled only by the 950 static-NET95 writer, using answer values.
        if (ENVIRON["W9X_REG95_NET_IDENTITY"] == "1") {
            nl = split(body["network"], lines, "\n")
            for (l = 1; l <= nl; l++) {
                eq = index(lines[l], "=")
                if (!eq) continue
                id = tolower(trim(substr(lines[l], 1, eq - 1)))
                if (id != "computername" && id != "workgroup" && id != "description") continue
                if (fields(substr(lines[l], eq + 1), f) != 1) continue
                identity[id] = strings(f[1])
            }
            idkey = "HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\VxD\\VNETSUP"
            if (identity["computername"] != "") emit(idkey, "ComputerName", "\"" esc(identity["computername"]) "\"")
            if (identity["workgroup"] != "") emit(idkey, "Workgroup", "\"" esc(identity["workgroup"]) "\"")
            if ("description" in identity) emit(idkey, "Comment", "\"" esc(identity["description"]) "\"")
        }
        if (usoslog != "") { nrun++; runname[nrun] = "USOSLog"; rundata[nrun] = "\"" esc(usoslog) "\"" }
        for (r = 0; r <= 4; r++)
            for (i = 1; i <= nrun; i++) if (rank(runname[i]) == r) emit(runkey, runname[i], rundata[i])
        if (icw) emit("HKEY_LOCAL_MACHINE\\SOFTWARE\\Classes\\CLSID\\" clsid "\\Shell\\Open\\Command", "", "\"" esc("\"C:\\Program Files\\Internet Explorer\\IEXPLORE.EXE\"") "\"")
        # Windows Logon as the primary logon (REG95.BAT deletes Network\Logon
        # first: 95 Setup leaves PrimaryProvider "Microsoft Network" there
        # although MSBATCH says PrimaryLogon=Windows), with the Winlogon
        # DefaultUserName of the answer as the preset name.
        emit("HKEY_LOCAL_MACHINE\\Network\\Logon", "ProcessLoginScript", "hex:01")
        emit("HKEY_LOCAL_MACHINE\\Network\\Logon", "LMLogon", "hex:00,00,00,00")
        if (logon_user != "") emit("HKEY_LOCAL_MACHINE\\Network\\Logon", "username", logon_user)
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

# Original RTM/OSR1 NETCLI.INF VREDIR.Install and NETTRANS.INF MSTCP.Install
# copy groups. NETAPI.DLL is in PRECOPY, the other files in WIN95_*.CAB.
# Use this target's original EXTRACT and cabinets; keep existing inbox
# files (including patched ones). Copy the selected own driver separately.
w9x_reg95_netfiles_write() {
    nfdir=$1
    [ -d "$nfdir/NET" ] || return 1
    {
        cat <<'EOF'
@ECHO OFF
REM USOS: original 950 network files before the NET95 registry import.
IF EXIST C:\USOS9X\NET\NFILES.RUN GOTO FAIL
ECHO run> C:\USOS9X\NET\NFILES.RUN
IF EXIST C:\USOS9X\NET\NFILES.OK DEL C:\USOS9X\NET\NFILES.OK > NUL
IF EXIST C:\USOS9X\NET\NFILES.ERR DEL C:\USOS9X\NET\NFILES.ERR > NUL
ECHO begin> C:\USOS9X\NET\NFILES.LOG
IF NOT EXIST C:\WIN95\EXTRACT.EXE GOTO FAIL
IF NOT EXIST C:\WIN95\PRECOPY1.CAB GOTO FAIL
IF NOT EXIST C:\WIN95\WIN95_02.CAB GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\NUL GOTO FAIL
IF NOT EXIST C:\WINDOWS\INF\NUL GOTO FAIL
IF NOT EXIST C:\USOS9X\NET\USOSNET.SYS GOTO FAIL
IF NOT EXIST C:\USOS9X\NET\USOSNET.INF GOTO FAIL
COPY /Y C:\USOS9X\NET\USOSNET.SYS C:\WINDOWS\SYSTEM\USOSNET.SYS > NUL
IF ERRORLEVEL 1 GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\USOSNET.SYS GOTO FAIL
COPY /Y C:\USOS9X\NET\USOSNET.INF C:\WINDOWS\INF\USOSNET.INF > NUL
IF ERRORLEVEL 1 GOTO FAIL
IF NOT EXIST C:\WINDOWS\INF\USOSNET.INF GOTO FAIL
IF NOT EXIST C:\WINDOWS\HELP\NUL MD C:\WINDOWS\HELP
IF NOT EXIST C:\WINDOWS\HELP\NUL GOTO FAIL
EOF
        n=0
        while read -r dest cab names; do
            for name in $names; do
                n=$((n + 1))
                printf 'IF EXIST %s\\%s GOTO F%02d\n' "$dest" "$name" "$n"
                printf 'C:\\WIN95\\EXTRACT.EXE /A /Y /L %s C:\\WIN95\\%s %s >> C:\\USOS9X\\NET\\NFILES.LOG\n' "$dest" "$cab" "$name"
                printf 'IF ERRORLEVEL 1 GOTO FAIL\nIF NOT EXIST %s\\%s GOTO FAIL\n:F%02d\n' "$dest" "$name" "$n"
            done
        done <<'EOF'
C:\WINDOWS\SYSTEM PRECOPY1.CAB netapi.dll
C:\WINDOWS\SYSTEM WIN95_02.CAB vredir.vxd vnetsup.vxd rpcltc1.dll pmspl.dll msnet32.dll msab32.dll mssp.vxd
C:\WINDOWS\SYSTEM WIN95_02.CAB msnp32.dll mspp32.dll lmscript.exe lmscript.pif filesec.vxd choosusr.dll mapi32.dll vlb32.dll
C:\WINDOWS WIN95_02.CAB net.exe net.msg neth.msg winpopup.exe
C:\WINDOWS\HELP WIN95_02.CAB winpopup.hlp winpopup.cnt
C:\WINDOWS\SYSTEM WIN95_02.CAB vtdi.386 vip.386 vtcp.386 vdhcp.386 vnbt.386 icmp.dll afvxd.vxd wshtcp.vxd rpcltc3.dll rpclts3.dll wsock.vxd wsasrv.exe
C:\WINDOWS WIN95_02.CAB ping.exe telnet.exe telnet.hlp ftp.exe hosts.sam lmhosts.sam networks protocol services inetmib1.dll arp.exe nbtstat.exe netstat.exe route.exe tracert.exe winipcfg.exe winsock.dll
EOF
        cat <<'EOF'
ECHO complete> C:\USOS9X\NET\NFILES.OK
DEL C:\USOS9X\NET\NFILES.RUN > NUL
GOTO END
:FAIL
ECHO original network file preparation failed> C:\USOS9X\NET\NFILES.ERR
:END
EOF
    } | sed 's/$/\r/' > "$nfdir/NET/NFILES.BAT"
}

# TCP/IP needs its machine-wide Winsock registration as well as the
# NetTrans/Enum bindings. CopyFiles alone does not run MSTCP.Install.
# These settings correspond to the original 950 MSTCP.AddReg globals;
# the class-relative settings are already in NET95.REG. Keep a separate
# companion so the installed-system repair can import it without Setup.
w9x_reg95_tcp_write() {
    [ -d "$1/NET" ] || return 1
    sed 's/$/\r/' > "$1/NET/TCP95.REG" <<'EOF'
REGEDIT4

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VxD\Winsock]
"Ancillary Function Driver for Winsock"="afvxd.vxd"

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VxD\AFVXD]
"MSTCP Helper for Winsock"="wshtcp.vxd"

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VxD\MSTCP\Parameters\Winsock]
"MaxSockAddrLength"=hex:10,00,00,00
"MinSockAddrLength"=hex:10,00,00,00
"HelperDllName"="%windir%\\system\\wsock32.dll"

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VxD\MSTCP\ServiceProvider]
"LocalPriority"=hex:f3,01,00,00
"HostsPriority"=hex:f4,01,00,00
"DnsPriority"=hex:d0,07,00,00
"NetbtPriority"=hex:d1,07,00,00
"Class"=hex:08,00,00,00
"ProviderPath"="%windir%\\system\\wsock32.dll"

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Winsock\Parameters]
"MSTCP"=""

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\ServiceProvider\Order\ExcludedProviders]

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\ServiceProvider\Order\ProviderOrder]
"MSTCP"=""

[HKEY_LOCAL_MACHINE\Software\Microsoft\Rpc\ClientProtocols]
"ncacn_ip_tcp"="rpcltc3.dll"

[HKEY_LOCAL_MACHINE\Software\Microsoft\Rpc\ServerProtocols]
"ncacn_ip_tcp"="rpclts3.dll"

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\SessionManager\CheckVerDLLs]
"WINSOCK.DLL"="0"

EOF
}

# Original 950 first-GUI Network PnP removes the early static protocol and
# client classes (R111). Reapply just networking once the original
# RunOnce\Setup subtree is gone. No timer, desktop helper or forced reboot.
w9x_reg95_netlate_write() {
    [ -d "$1/NET" ] || return 1
    sed 's/$/\r/' > "$1/NET/NET95L.BAT" <<'EOF'
@ECHO OFF
IF EXIST C:\USOS9X\NET\NLATE.ERR GOTO FAIL
IF EXIST C:\USOS9X\NET\NLATE.RUN GOTO FAIL
IF EXIST C:\USOS9X\NET\NLATE.OK GOTO END
IF NOT EXIST C:\USOS9X\REG95.OK GOTO END
IF NOT EXIST C:\USOS9X\NET\NFILES.OK GOTO FAIL
IF NOT EXIST C:\USOS9X\NET\NET95.REG GOTO FAIL
IF NOT EXIST C:\USOS9X\NET\TCP95.REG GOTO FAIL
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO FAIL
IF NOT EXIST C:\WINDOWS\COMMAND\ATTRIB.EXE GOTO FAIL
IF NOT EXIST C:\WINDOWS\COMMAND\FIND.EXE GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO FAIL
IF NOT EXIST C:\WINDOWS\USER.DAT GOTO FAIL
C:
CD \WINDOWS
IF EXIST C:\USOS9X\NL1.REG DEL C:\USOS9X\NL1.REG > NUL
IF EXIST C:\USOS9X\NL1.REG GOTO FAIL
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\NL1.REG HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\RunOnce
IF NOT EXIST C:\USOS9X\NL1.REG GOTO FAIL
C:\WINDOWS\COMMAND\FIND.EXE /I "\RunOnce]" C:\USOS9X\NL1.REG > NUL
IF ERRORLEVEL 1 GOTO FAIL
C:\WINDOWS\COMMAND\FIND.EXE /I "\RunOnce\Setup]" C:\USOS9X\NL1.REG > NUL
IF ERRORLEVEL 2 GOTO FAIL
IF NOT ERRORLEVEL 1 GOTO PENDING
IF NOT EXIST C:\WINDOWS\SYSTEM\AFVXD.VXD GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\WSHTCP.VXD GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\WSOCK32.DLL GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\VREDIR.VXD GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\VTCP.386 GOTO FAIL
IF NOT EXIST C:\WINDOWS\SYSTEM\VDHCP.386 GOTO FAIL
IF EXIST C:\USOS9X\NL2.REG DEL C:\USOS9X\NL2.REG > NUL
IF EXIST C:\USOS9X\NL3.REG DEL C:\USOS9X\NL3.REG > NUL
IF EXIST C:\USOS9X\NL4.REG DEL C:\USOS9X\NL4.REG > NUL
IF EXIST C:\USOS9X\NL2.REG GOTO FAIL
IF EXIST C:\USOS9X\NL3.REG GOTO FAIL
IF EXIST C:\USOS9X\NL4.REG GOTO FAIL
ECHO run> C:\USOS9X\NET\NLATE.RUN
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE -S -R -H USER.DAT
REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\NET\NET95.REG
REGEDIT /L:SYSTEM.DAT /R:USER.DAT C:\USOS9X\NET\TCP95.REG
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\NL2.REG HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VxD
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\NL3.REG HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class\NetTrans
REGEDIT /L:SYSTEM.DAT /R:USER.DAT /E C:\USOS9X\NL4.REG HKEY_LOCAL_MACHINE\Enum\Network
C:\WINDOWS\COMMAND\FIND.EXE "MaxSockAddrLength" C:\USOS9X\NL2.REG > NUL
IF ERRORLEVEL 1 GOTO RESTORE
C:\WINDOWS\COMMAND\FIND.EXE "HelperDllName" C:\USOS9X\NL2.REG > NUL
IF ERRORLEVEL 1 GOTO RESTORE
C:\WINDOWS\COMMAND\FIND.EXE "TCP/IP" C:\USOS9X\NL3.REG > NUL
IF ERRORLEVEL 1 GOTO RESTORE
C:\WINDOWS\COMMAND\FIND.EXE "NetTrans\\0009" C:\USOS9X\NL4.REG > NUL
IF ERRORLEVEL 1 GOTO RESTORE
C:\WINDOWS\COMMAND\FIND.EXE "NetClient\\0009" C:\USOS9X\NL4.REG > NUL
IF ERRORLEVEL 1 GOTO RESTORE
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT
ECHO complete> C:\USOS9X\NET\NLATE.OK
DEL C:\USOS9X\NET\NLATE.RUN > NUL
GOTO PENDING
:RESTORE
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H SYSTEM.DAT
C:\WINDOWS\COMMAND\ATTRIB.EXE +S +R +H USER.DAT
:FAIL
ECHO post-Setup network preparation failed> C:\USOS9X\NET\NLATE.ERR
:PENDING
CD \
:END
EOF
}

# w9x_reg95_write DIR INF [usoslog] [vmd inf] [NET95.REG] [source version]
# NET95.REG (tools/network_setup.sh usos_net_w95_reg, in DIR/NET): the
# usosnet4 adapter, TCP/IP and client registry for a fresh install; its
# sections are appended to REG95.REG (one import) and REG95.BAT exports
# them afterwards to DIR\NET\C1..C3.REG and checks them with FIND:
# NET\NET95.OK or NET\NET95.ERR (the in-place kit 95-net's evidence files).
w9x_reg95_write() {
    dir=$1 inf=$2 usoslog=${3:-} vmd=${4:-} net=${5:-} source_version=${6:-}
    [ -d "$dir" ] && [ -r "$inf" ] || return 1
    grep -qi '^\[install\]' "$inf" || return 1
    reg95_identity=''
    if [ -n "$net" ] && [ "$source_version" = '4 0 0 950' ]; then reg95_identity=1; fi
    w9x_reg95_convert "$inf" "$usoslog" "$vmd" "$reg95_identity" >"$dir/REG95.REG" || return 1
    grep -q '^\[HKEY_' "$dir/REG95.REG" || { rm -f "$dir/REG95.REG"; return 1; }
    if grep -q 'START\.HTM' "$dir/REG95.REG"; then w9x_reg95_start_page > "$dir/START.HTM" || return 1; fi
    U='C:\USOS9X\'
    A='C:\WINDOWS\COMMAND\ATTRIB.EXE'
    F='C:\WINDOWS\COMMAND\FIND.EXE'
    R='REGEDIT /L:SYSTEM.DAT /R:USER.DAT'
    run='HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run'
    netbat='' netprep='' netguard='' netfail='' neterrjump='' net_findfail=NETEND tcp95='' netlate=''
    run_guard="IF EXIST ${U}REG95.RUN GOTO END"
    if [ -n "$net" ] && [ "$source_version" = '4 0 0 950' ]; then
        w9x_reg95_netfiles_write "$dir" || return 1
        w9x_reg95_tcp_write "$dir" || return 1
        w9x_reg95_netlate_write "$dir" || return 1
        tcp95="$dir/NET/TCP95.REG"
        netlate="CALL ${U}NET\\NET95L.BAT
IF EXIST ${U}NET\\NLATE.ERR GOTO PREPERR
IF EXIST ${U}NET\\NLATE.RUN GOTO PREPERR"
        netprep="CALL ${U}NET\\NFILES.BAT
IF NOT EXIST ${U}NET\\NFILES.OK GOTO PREPERR"
        netguard="IF EXIST ${U}NET\\NET95.ERR GOTO PREPERR
IF EXIST ${U}NET\\NFILES.ERR GOTO PREPERR
IF EXIST ${U}NET\\NFILES.RUN GOTO PREPERR"
        run_guard="IF EXIST ${U}REG95.RUN GOTO PREPERR"
        neterrjump='GOTO REGFAIL'
        net_findfail=REGFAIL
        netfail=":REGFAIL
$A +S +R +H SYSTEM.DAT
$A +S +R +H USER.DAT
:PREPERR
ECHO Network preparation failed. See C:\\USOS9X\\NET. Windows start withheld.
:PREPWAIT
PAUSE > NUL
GOTO PREPWAIT"
    fi
    if [ -n "$net" ]; then
        devnode=$(tr -d '\r' < "$net" | sed -n 's/^\[\(HKEY_LOCAL_MACHINE\\Enum\\PCI\\[^]\\]*\\[^]\\]*\)\]$/\1/p' | head -n 1)
        [ -n "$devnode" ] || return 1
        # Before the "; USOS: not converted" comments, which stay last.
        # CRLF made once at the end (Git for Windows grep / sed drop the CR).
        { tr -d '\r' < "$dir/REG95.REG" | sed '/^; USOS:/d'; tr -d '\r' < "$net" | sed '1{/^REGEDIT4$/d}'
          if [ -n "$tcp95" ]; then tr -d '\r' < "$tcp95" | sed '1{/^REGEDIT4$/d}'; fi
          tr -d '\r' < "$dir/REG95.REG" | sed -n '/^; USOS:/p'; } | sed 's/$/\r/' > "$dir/REG95.NEW" &&
            mv "$dir/REG95.NEW" "$dir/REG95.REG" || return 1
        N="${U}NET\\"
        netbat="IF NOT EXIST $F GOTO $net_findfail
$R /E ${N}C1.REG $devnode
$R /E ${N}C2.REG HKEY_LOCAL_MACHINE\\System\\CurrentControlSet\\Services\\Class\\Net
$R /E ${N}C3.REG HKEY_LOCAL_MACHINE\\Enum\\Network
$F \"usosnet.sys\" ${N}C2.REG > NUL
IF ERRORLEVEL 1 GOTO NETERR
$F \"Net\\\\0009\" ${N}C1.REG > NUL
IF ERRORLEVEL 1 GOTO NETERR
$F \"NetClient\\\\0009\" ${N}C3.REG > NUL
IF ERRORLEVEL 1 GOTO NETERR
ECHO ok> ${N}NET95.OK
GOTO NETEND
:NETERR
ECHO registry check after the import failed (C1..C3.REG)> ${N}NET95.ERR
$neterrjump
:NETEND"
    fi
    sed 's/$/\r/' > "$dir/REG95.BAT" <<EOF || return 1
@ECHO OFF
REM USOS: Windows 95 answer registry (tools/w9x_reg95.sh): 95 Setup ignores
REM MSBATCH.INF [Install] AddReg. Runs from AUTOEXEC.BAT, imports once.
$netguard
$netlate
IF EXIST ${U}REG95.OK GOTO END
$run_guard
IF NOT EXIST ${U}REG95.REG GOTO END
IF NOT EXIST C:\WINDOWS\REGEDIT.EXE GOTO END
IF NOT EXIST C:\WINDOWS\SYSTEM.DAT GOTO END
IF NOT EXIST C:\WINDOWS\USER.DAT GOTO END
IF NOT EXIST $A GOTO END
$netprep
ECHO run> ${U}REG95.RUN
C:
CD \WINDOWS
$A -S -R -H SYSTEM.DAT
$A -S -R -H USER.DAT
$R /D HKEY_LOCAL_MACHINE\\Network\\Logon
$R ${U}REG95.REG
$R /E ${U}REG95CHK.REG $run
$R /E ${U}REG95LGN.REG HKEY_LOCAL_MACHINE\\Network\\Logon
$netbat
$A +S +R +H SYSTEM.DAT
$A +S +R +H USER.DAT
ECHO ok> ${U}REG95.OK
CD \\
GOTO END
$netfail
:END
EOF
}
