#!/bin/sh
# USOS: hands-off Windows XP Setup from a small settings file on DATA
#   Systems\Windows\<Windows XP|Windows 2000>\Unattended\usos-xp.ini
# (written by the USOS installer with every value empty = inactive).
#
#   usos_xp_settings_load FILE OUT LAYOUT
#       Parses FILE (key=value, case-insensitive keys, UTF-8 BOM and CRLF
#       tolerated, ';'/'#' comments and [sections] ignored), validates every
#       value and writes a normalized OUT (one key=value per line).
#       LAYOUT is the source's default keyboard layout (TXTSETUP.SIF [nls]
#       DefaultLayout, e.g. 00000415) and picks the default time zone
#       (95 Polish, 4 US English, otherwise 85).
#       Returns 0 = active, 2 = inactive (no user=), 1 = invalid (message on
#       stderr, the values themselves are never printed).
#   usos_xp_settings_sif BASE.SIF SETTINGS
#       Prints BASE.SIF with the unattended sections merged in (stdout).
#   usos_xp_settings_accounts SETTINGS FILE
#       Writes FILE (C:\USOS\XP\usos-users.cmd next to pae.exe): pae.exe runs
#       it without a console window at setup end (UserExecute; first-logon
#       retry) and deletes it. The accounts are local administrators, so the
#       Welcome screen lists them.
#   usos_xp_settings_plan PLAN SOURCE_ROOT
#       The menu chose a USOS answer profile (usos.xp_settings=plan): PLAN is
#       the ESP's EFI/USOS/answer/usos-plan.ini; its rendered settings file
#       (src/flow/answer/nt5.zig) is loaded in profile mode and deleted.
# Keys: user user2 computer org key timezone password (docs/xp-unattended.md).
# Profile mode (a rendered answer profile, docs/answer-profiles.md) also
# accepts family (xp, 2000, 2003), locale, input_locale and language_group.

usos_xp_settings_load() {
    _xs_file=$1
    _xs_out=$2
    _xs_layout=${3:-}
    _xs_profile=${4:-}
    [ -r "$_xs_file" ] || { printf 'usos-xp.ini is not readable\n' >&2; return 1; }
    # A UTF-8 BOM (Notepad) is dropped byte-wise before awk sees the text.
    _xs_text=$_xs_out.text
    if [ "$(head -c 3 "$_xs_file" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
        tail -c +4 "$_xs_file" > "$_xs_text" || return 1
    else
        cp "$_xs_file" "$_xs_text" || return 1
    fi
    LC_ALL=C awk -v layout="$_xs_layout" -v profile="$_xs_profile" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function bad(message) { printf "usos-xp.ini: %s\n", message > "/dev/stderr"; failed = 1 }
        # Printable ASCII without the characters that break WINNT.SIF quoting or cmd.
        function clean(s, allow_space) {
            if (allow_space) { if (s !~ /^[ -~]*$/) return 0 }
            else if (s !~ /^[!-~]*$/) return 0
            return index(s, "\"") == 0 && index(s, "%") == 0 && index(s, "^") == 0 && index(s, "&") == 0 && index(s, "|") == 0 && index(s, "<") == 0 && index(s, ">") == 0
        }
        {
            sub(/\r$/, "")
            line = trim($0)
            if (line == "" || line ~ /^[;#]/ || (substr(line, 1, 1) == "[" && substr(line, length(line)) == "]")) next
            eq = index(line, "=")
            if (eq == 0) { bad("line " NR " is not key=value"); next }
            key = tolower(trim(substr(line, 1, eq - 1)))
            value = trim(substr(line, eq + 1))
            if (value ~ /^".*"$/ && length(value) >= 2) value = substr(value, 2, length(value) - 2)
            if (key !~ /^(user|user2|computer|org|key|timezone|password)$/ && !(profile != "" && key ~ /^(family|locale|input_locale|language_group)$/)) { bad("unknown key on line " NR); next }
            values[key] = value
        }
        END {
            if (failed) exit 1
            user = values["user"]
            if (user == "") exit 2
            reserved = "^(administrator|administrators|guest|system|helpassistant|support_388945a0)$"
            name = "^[A-Za-z0-9][A-Za-z0-9._ -]*$"
            if (length(user) > 20 || user !~ name || user ~ /[. ]$/ || tolower(user) ~ reserved) bad("user= must be 1-20 characters A-Z a-z 0-9 . _ - space, not a built-in account")
            user2 = values["user2"]
            if (user2 != "") {
                if (length(user2) > 20 || user2 !~ name || user2 ~ /[. ]$/ || tolower(user2) ~ reserved) bad("user2= must be 1-20 characters A-Z a-z 0-9 . _ - space, not a built-in account")
                if (tolower(user2) == tolower(user)) bad("user2= must differ from user=")
            }
            computer = values["computer"]
            if (computer == "") computer = "USOS-XP"
            if (length(computer) > 15 || computer !~ /^[A-Za-z0-9-]+$/ || computer ~ /^[0-9]+$/) bad("computer= must be 1-15 characters A-Z a-z 0-9 -, not only digits")
            org = values["org"]
            if (length(org) > 64 || !clean(org, 1)) bad("org= must be up to 64 printable ASCII characters without \" % ^ & | < >")
            key = toupper(values["key"])
            if (key != "" && key !~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9](-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])(-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])(-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])(-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])$/) bad("key= must be XXXXX-XXXXX-XXXXX-XXXXX-XXXXX")
            timezone = values["timezone"]
            # Default from the source language: Polish = 95 (Warszawa), US English = 4
            # (Pacific, the XP default for US), anything else = 85 (GMT).
            if (timezone == "") timezone = layout == "00000415" ? "95" : layout == "00000409" ? "4" : "85"
            if (timezone != "" && (timezone !~ /^[0-9]+$/ || timezone + 0 > 300)) bad("timezone= must be an XP time zone index (for example 95 = Warszawa, 85 = London, 35 = New York)")
            password = values["password"]
            if (length(password) > 64 || !clean(password, 0)) bad("password= must be up to 64 printable ASCII characters without spaces or \" % ^ & | < >")
            if (profile != "") {
                family = values["family"]
                if (family == "") family = "xp"
                if (family !~ /^(xp|2000|2003)$/) bad("family= must be xp, 2000 or 2003")
                locale = toupper(values["locale"])
                if (locale != "" && (length(locale) != 8 || locale !~ /^[0-9A-F]+$/)) bad("locale= must be 8 hex digits (for example 00000415)")
                input = toupper(values["input_locale"])
                if (input != "" && (length(input) != 13 || substr(input, 5, 1) != ":" || substr(input, 1, 4) !~ /^[0-9A-F]+$/ || substr(input, 6) !~ /^[0-9A-F]+$/)) bad("input_locale= must be LLLL:KKKKKKKK")
                group = values["language_group"]
                if (group != "" && group !~ /^[0-9]+(,[0-9]+)*$/) bad("language_group= must be numbers separated by commas")
                if ((locale == "") != (input == "") || (locale == "") != (group == "")) bad("locale=, input_locale= and language_group= go together")
            }
            if (failed) exit 1
            printf "user=%s\nuser2=%s\ncomputer=%s\norg=%s\nkey=%s\ntimezone=%s\npassword=%s\n", user, user2, computer, org, key, timezone, password
            if (profile != "") printf "family=%s\nlocale=%s\ninput_locale=%s\nlanguage_group=%s\n", family, locale, input, group
        }
    ' "$_xs_text" > "$_xs_out.tmp"
    _xs_rc=$?
    rm -f "$_xs_text"
    if [ "$_xs_rc" -eq 0 ]; then
        mv "$_xs_out.tmp" "$_xs_out"
    else
        rm -f "$_xs_out.tmp"
    fi
    return "$_xs_rc"
}

usos_xp_settings_value() {
    awk -F= -v wanted="$1" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$2"
}

# FullUnattended when a product key is given; DefaultHide otherwise, so only
# the product key page stays interactive (every other page is answered).
usos_xp_settings_sif() {
    _xs_base=$1
    _xs_set=$2
    awk -v settings="$_xs_set" -v nt5_system="${NT5_SYSTEM:-windows-xp}" '
        BEGIN {
            while ((getline line < settings) > 0) { eq = index(line, "="); v[substr(line, 1, eq - 1)] = substr(line, eq + 1) }
            close(settings)
            # usos-xp.ini has no family=: the staged system decides (Windows 2000).
            if (v["family"] == "" && nt5_system == "windows-2000") v["family"] = "2000"
            if (v["family"] == "" && nt5_system == "windows-server-2003") v["family"] = "2003"
            mode = v["key"] != "" ? "FullUnattended" : "DefaultHide"
        }
        { sub(/\r$/, "") }
        /^\[/ {
            if (section == "unattended") print "UnattendSwitch=Yes"
            # No regex with [ or ]: BusyBox awk parses such bracket expressions differently.
            section = tolower(substr($0, 2)); e = index(section, "]"); if (e) section = substr(section, 1, e - 1)
            if (section == "setupparams" && !added) { extra(); added = 1 }
        }
        section == "unattended" && /^UnattendMode=/ { print "UnattendMode=" mode; next }
        { print }
        END {
            if (section == "unattended") print "UnattendSwitch=Yes"
            if (!added) extra()
        }
        function extra() {
            print "[GuiUnattended]"
            print "OEMSkipRegional=1"
            print "OemSkipWelcome=1"
            print "TimeZone=" v["timezone"]
            print "AdminPassword=" (v["password"] != "" ? "\"" v["password"] "\"" : "*")
            print "EncryptedAdminPassword=No"
            print "[UserData]"
            print "FullName=\"" v["user"] "\""
            print "OrgName=\"" v["org"] "\""
            print "ComputerName=" v["computer"]
            # Windows 2000 names the key ProductID.
            if (v["key"] != "") print (v["family"] == "2000" ? "ProductID=" : "ProductKey=") v["key"]
            print "[Identification]"
            print "JoinWorkgroup=WORKGROUP"
            print "[Networking]"
            print "InstallDefaultComponents=Yes"
            # Profile mode: Server 2003 stops on the licensing page without this.
            if (v["family"] == "2003") { print "[LicenseFilePrintData]"; print "AutoMode=PerServer"; print "AutoUsers=5" }
            if (v["locale"] != "") {
                print "[RegionalSettings]"
                print "LanguageGroup=\"" v["language_group"] "\""
                print "SystemLocale=" v["locale"]
                print "UserLocale=" v["locale"]
                print "InputLocale=" v["input_locale"]
            }
        }
    ' "$_xs_base"
}

usos_xp_settings_accounts() {
    _xs_set=$1
    _xs_file=$2
    awk -v settings="$_xs_set" '
        BEGIN {
            while ((getline line < settings) > 0) { eq = index(line, "="); v[substr(line, 1, eq - 1)] = substr(line, eq + 1) }
            printf "@echo off\r\n"
            printf "rem USOS: local administrator accounts from usos-xp.ini, run hidden by pae.exe at setup end.\r\n"
            printf "set USOS_LOG=%%SystemRoot%%\\usos-users.log\r\n"
            account(v["user"])
            if (v["user2"] != "") account(v["user2"])
            printf "exit /b 0\r\n"
        }
        function account(name) {
            if (v["password"] != "") printf "net user \"%s\" \"%s\" /add >> \"%%USOS_LOG%%\" 2>&1\r\n", name, v["password"]
            else printf "net user \"%s\" /add >> \"%%USOS_LOG%%\" 2>&1\r\n", name
            # The Administrators group name is localized; the wrong names fail harmlessly.
            printf "for %%%%G in (Administrators Administratorzy Administratoren Administrateurs Administradores Administratori) do net localgroup %%%%G \"%s\" /add >> \"%%USOS_LOG%%\" 2>&1\r\n", name
        }
    ' > "$_xs_file"
}

# usos_xp_custom_sif BASE.SIF USER.SIF
#   A .sif chosen in the menu, merged into the automatic answer (stdout).
#   The user's keys win, except the ones USOS needs for this flow: all of
#   [Data], and Repartition, FileSystem, TargetPath, DriverSigningPolicy,
#   NonDriverSigningPolicy, WaitForReboot, OemPreinstall in [Unattended] and
#   UserExecute in [SetupParams]. [GuiRunOnce] keeps the user's commands
#   (renumbered) followed by the pae.exe first-logon check. Sections and keys
#   match case-insensitively; values are copied as they are.
usos_xp_custom_sif() {
    awk -v user="$2" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        # No regex with [ or ]: BusyBox awk parses such bracket expressions differently.
        function header(s,   e) { if (substr(s, 1, 1) != "[") return ""; s = substr(s, 2); e = index(s, "]"); return e ? tolower(trim(substr(s, 1, e - 1))) : "" }
        function protected(sec, key) {
            if (sec == "data") return 1
            if (sec == "unattended" && key ~ /^(repartition|filesystem|targetpath|driversigningpolicy|nondriversigningpolicy|waitforreboot|oempreinstall)$/) return 1
            if (sec == "setupparams" && key == "userexecute") return 1
            return 0
        }
        BEGIN {
            sec = ""
            while ((getline line < user) > 0) {
                sub(/\r$/, "", line); t = trim(line)
                if (t == "" || substr(t, 1, 1) == ";") continue
                h = header(t)
                if (h != "") { sec = h; if (!(sec in usec)) { usec[sec] = 1; uorder[++nsec] = sec; uname[sec] = t }; continue }
                eq = index(t, "="); if (eq == 0 || sec == "") continue
                key = tolower(trim(substr(t, 1, eq - 1)))
                if (sec == "guirunonce") { run[++nrun] = trim(substr(t, eq + 1)); continue }
                if (!((sec, key) in uval)) { ukeys[sec, ++ukn[sec]] = key }
                uval[sec, key] = trim(substr(t, 1, eq - 1)) "=" trim(substr(t, eq + 1))
            }
            close(user)
        }
        function flush_section(   i, k) {
            if (cur == "") return
            for (i = 1; i <= ukn[cur]; i++) { k = ukeys[cur, i]; if (!((cur, k) in seen) && !protected(cur, k)) print uval[cur, k] }
            if (cur == "guirunonce") { for (i = 1; i <= nrun; i++) print "Command" (i - 1) "=" run[i]; print "Command" nrun "=" pae }
            done[cur] = 1
        }
        { sub(/\r$/, "") }
        header($0) != "" { flush_section(); cur = header($0); print; next }
        {
            eq = index($0, "="); key = eq ? tolower(trim(substr($0, 1, eq - 1))) : ""
            if (cur == "guirunonce") { if (key ~ /^command/) pae = trim(substr($0, eq + 1)); next }
            if (key != "") seen[cur, key] = 1
            if (key != "" && !protected(cur, key) && ((cur, key) in uval)) { print uval[cur, key]; next }
            print
        }
        END {
            flush_section()
            for (i = 1; i <= nsec; i++) {
                s = uorder[i]; if (s in done || s == "guirunonce") continue
                print uname[s]
                for (j = 1; j <= ukn[s]; j++) { k = ukeys[s, j]; if (!protected(s, k)) print uval[s, k] }
            }
            if (!("guirunonce" in done) && nrun) { print "[GuiRunOnce]"; for (i = 1; i <= nrun; i++) print "Command" (i - 1) "=" run[i] }
        }
    ' "$1"
}

# usos_xp_settings_stage INI SOURCE_ROOT
#   Before any target write: validates INI (if present) against the mounted
#   source, keeps the normalized copy in /run and exports XP_USER_SETTINGS
#   (empty = inactive, the automatic WINNT.SIF stays exactly as before).
usos_xp_settings_stage() {
    XP_USER_SETTINGS=''
    export XP_USER_SETTINGS
    if [ ! -f "$1" ]; then
        printf '[XP_SETTINGS] none (%s absent)\n' "${1##*/}"
        return 0
    fi
    _xs_layout=$(awk '
        { sub(/\r$/, "") }
        /^\[/ { section = tolower($0); next }
        section == "[nls]" && tolower($0) ~ /^defaultlayout[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); gsub(/[" \t]/, ""); print; exit }
    ' "$2/${NT5_SOURCE_DIR:-I386}/TXTSETUP.SIF" 2>/dev/null)
    usos_xp_settings_load "$1" /run/usos-xp-settings "$_xs_layout"
    case $? in
        0) ;;
        2) printf '[XP_SETTINGS] inactive (user= is empty)\n'; return 0 ;;
        *) printf '[XP_SETTINGS] STOP: %s is invalid (details above); no target write occurred\n' "${1##*/}"; return 1 ;;
    esac
    XP_USER_SETTINGS=/run/usos-xp-settings
    _xs_yes() { [ -n "$(usos_xp_settings_value "$1" "$XP_USER_SETTINGS")" ] && printf yes || printf no; }
    printf '[XP_SETTINGS] active layout=%s user2=%s key=%s password=%s timezone=%s computer=%s\n' \
        "${_xs_layout:-unknown}" "$(_xs_yes user2)" "$(_xs_yes key)" "$(_xs_yes password)" \
        "$(usos_xp_settings_value timezone "$XP_USER_SETTINGS")" "$(usos_xp_settings_value computer "$XP_USER_SETTINGS")"
    return 0
}

# usos_xp_settings_plan PLAN SOURCE_ROOT
#   A USOS answer profile chosen in the menu: PLAN ([answer] source=profile,
#   format=nt5_settings, file=EFI/USOS/answer/nt5-settings.ini) names the
#   rendered settings next to it. Validated like usos-xp.ini (profile mode),
#   kept in /run, and the file on the ESP is deleted (key, password).
usos_xp_settings_plan() {
    XP_USER_SETTINGS=''
    export XP_USER_SETTINGS
    _xs_plan=$1
    [ -f "$_xs_plan" ] || { printf '[XP_SETTINGS] STOP: answer plan %s is missing\n' "$_xs_plan"; return 1; }
    _xs_answer() {
        awk -v wanted="$1" '
            { sub(/\r$/, "") }
            /^\[/ { section = tolower($0); next }
            section == "[answer]" { eq = index($0, "="); if (eq && tolower(substr($0, 1, eq - 1)) == wanted) { print substr($0, eq + 1); exit } }
        ' "$_xs_plan"
    }
    [ "$(_xs_answer source)" = profile ] || { printf '[XP_SETTINGS] STOP: answer plan has no profile\n'; return 1; }
    [ "$(_xs_answer format)" = nt5_settings ] || { printf '[XP_SETTINGS] STOP: answer plan format is not nt5_settings\n'; return 1; }
    [ "$(_xs_answer file)" = EFI/USOS/answer/nt5-settings.ini ] || { printf '[XP_SETTINGS] STOP: unexpected answer file in the plan\n'; return 1; }
    _xs_rendered=${_xs_plan%/*}/nt5-settings.ini
    [ -f "$_xs_rendered" ] || { printf '[XP_SETTINGS] STOP: rendered answer profile is missing\n'; return 1; }
    _xs_layout=$(awk '
        { sub(/\r$/, "") }
        /^\[/ { section = tolower($0); next }
        section == "[nls]" && tolower($0) ~ /^defaultlayout[ \t]*=/ { sub(/^[^=]*=[ \t]*/, ""); gsub(/[" \t]/, ""); print; exit }
    ' "$2/${NT5_SOURCE_DIR:-I386}/TXTSETUP.SIF" 2>/dev/null)
    # USOS_XP_SETTINGS_OUT: host tests only (the initramfs keeps it in /run).
    _xs_norm=${USOS_XP_SETTINGS_OUT:-/run/usos-xp-settings}
    usos_xp_settings_load "$_xs_rendered" "$_xs_norm" "$_xs_layout" profile
    _xs_rc=$?
    rm -f "$_xs_rendered"
    sync
    [ "$_xs_rc" -eq 0 ] || { printf '[XP_SETTINGS] STOP: answer profile is invalid (details above); no target write occurred\n'; return 1; }
    XP_USER_SETTINGS=$_xs_norm
    _xs_yes() { [ -n "$(usos_xp_settings_value "$1" "$XP_USER_SETTINGS")" ] && printf yes || printf no; }
    printf '[XP_SETTINGS] profile "%s" active layout=%s family=%s user2=%s key=%s password=%s timezone=%s computer=%s locale=%s\n' \
        "$(_xs_answer name | tr -cd 'A-Za-z0-9 ._-')" "${_xs_layout:-unknown}" "$(usos_xp_settings_value family "$XP_USER_SETTINGS")" \
        "$(_xs_yes user2)" "$(_xs_yes key)" "$(_xs_yes password)" \
        "$(usos_xp_settings_value timezone "$XP_USER_SETTINGS")" "$(usos_xp_settings_value computer "$XP_USER_SETTINGS")" \
        "$(usos_xp_settings_value locale "$XP_USER_SETTINGS")"
    return 0
}

# usos_xp_settings_select INI SOURCE_ROOT CUSTOM_SIF MODE [PLAN]
#   Which settings the staging uses: none when a custom WINNT.SIF was
#   selected (non-empty CUSTOM_SIF) or the menu chose the manual installation
#   (MODE=off, kernel option usos.xp_settings=off); a USOS answer profile
#   (MODE=plan: usos_xp_settings_plan PLAN SOURCE_ROOT); otherwise
#   usos_xp_settings_stage INI SOURCE_ROOT.
usos_xp_settings_select() {
    if [ -n "$3" ]; then
        XP_USER_SETTINGS=''; export XP_USER_SETTINGS
        printf '[XP_SETTINGS] ignored: custom WINNT.SIF selected\n'
        return 0
    fi
    if [ "$4" = off ]; then
        XP_USER_SETTINGS=''; export XP_USER_SETTINGS
        printf '[XP_SETTINGS] ignored: manual install chosen\n'
        return 0
    fi
    if [ "$4" = plan ]; then
        usos_xp_settings_plan "${5:-/mnt/esp/EFI/USOS/answer/usos-plan.ini}" "$2"
        return
    fi
    usos_xp_settings_stage "$1" "$2"
}
