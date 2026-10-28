# Windows Me first sign-in without the Windows password dialog. Sourced by
# tools/w9x_csmwrap_target.sh; never runs on import. GPL-3.0-or-later.
#
# X470 Me fresh install 2026-10-20 (B261019-210547-5FDA8767): with Client for
# Microsoft Networks and Windows Logon as the primary logon, the first start
# after Setup showed the Windows password dialog once. Setup had written the
# AutoAdminLogon / DefaultUserName "USOS" / empty DefaultPassword values, but
# no password list existed yet: the dialog created C:\WINDOWS\USOS.PWL and
# SYSTEM.INI [Password Lists] USOS=..., and every later start signed in
# silently. USOS seeds that state for the stock user: the empty-password list
# of user USOS (src/platform/bios/win9x/usosme.pwl, the 688-byte list that
# dialog wrote on the X470; data only, no program code), its [Password Lists]
# line and Network\Logon username. Other user names keep Windows' own first
# dialog (no list is generated for them).

# 0 when this answer gets the seeded list: Me, a USOS-made answer (not the
# user's own file copied 1:1) whose auto logon user is exactly USOS and which
# has no [Password Lists] handling of its own.
usos_w9x_pwl_wanted() {
    [ "$2" = ME ] && [ "$3" != USER ] || return 1
    tr -d '\r' < "$1" | awk '
        tolower($0) ~ /^hklm,"software\\microsoft\\windows\\currentversion\\winlogon",defaultusername,,"usos"$/ {user=1}
        tolower($0) ~ /^hklm,"software\\microsoft\\windows\\currentversion\\winlogon",autoadminlogon,,"1"$/ {auto=1}
        tolower($0) ~ /password lists/ {own=1}
        END {exit !(user && auto && !own)}'
}

# The answer with [Install] UpdateInis += USOS.Pwl and AddReg += USOS.PwlReg
# (only Setup's [Install] section; other sections are left alone). The new
# sections go before [USOS.Csm]: it must stay the last section, INSTALL.BAT
# appends Me's usoskey.drv line to it. CRLF out.
usos_w9x_pwl_answer() {
    awk 'function add() {if(done++)return
             printf "[USOS.Pwl]\r\nsystem.ini,\"Password Lists\",,\"USOS=C:\\WINDOWS\\USOS.PWL\"\r\n\r\n"
             printf "[USOS.PwlReg]\r\nHKLM,\"Network\\Logon\",username,,\"USOS\"\r\n\r\n"}
         {sub(/\r$/, ""); low=tolower($0)}
         /^\[/ {install=(low=="[install]"); if(low=="[usos.csm]")add()}
         install && low~/^addreg=/ {$0=$0 ",USOS.PwlReg";a++}
         install && low~/^updateinis=/ {$0=$0 ",USOS.Pwl";u++}
         {printf "%s\r\n",$0}
         END {if(a!=1||u!=1)exit 1; if(!done){printf "\r\n";add()}}' "$1"
}
