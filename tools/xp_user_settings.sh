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
#   usos_xp_settings_oem SETTINGS DIR
#       Writes DIR/cmdlines.txt and DIR/usos-users.cmd ($OEM$ of the local
#       source): the accounts are created by GUI Setup (cmdlines.txt) as local
#       administrators, so the Welcome screen lists them.
# Keys: user user2 computer org key timezone password (docs/xp-unattended.md).

usos_xp_settings_load() {
    _xs_file=$1
    _xs_out=$2
    _xs_layout=${3:-}
    [ -r "$_xs_file" ] || { printf 'usos-xp.ini is not readable\n' >&2; return 1; }
    # A UTF-8 BOM (Notepad) is dropped byte-wise before awk sees the text.
    _xs_text=$_xs_out.text
    if [ "$(head -c 3 "$_xs_file" | od -An -tx1 | tr -d ' \n')" = efbbbf ]; then
        tail -c +4 "$_xs_file" > "$_xs_text" || return 1
    else
        cp "$_xs_file" "$_xs_text" || return 1
    fi
    LC_ALL=C awk -v layout="$_xs_layout" '
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
            if (key !~ /^(user|user2|computer|org|key|timezone|password)$/) { bad("unknown key on line " NR); next }
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
            if (failed) exit 1
            printf "user=%s\nuser2=%s\ncomputer=%s\norg=%s\nkey=%s\ntimezone=%s\npassword=%s\n", user, user2, computer, org, key, timezone, password
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
    awk -v settings="$_xs_set" '
        BEGIN {
            while ((getline line < settings) > 0) { eq = index(line, "="); v[substr(line, 1, eq - 1)] = substr(line, eq + 1) }
            close(settings)
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
        section == "unattended" && /^OemPreinstall=/ { print "OemPreinstall=Yes"; next }
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
            if (v["key"] != "") print "ProductKey=" v["key"]
            print "[Identification]"
            print "JoinWorkgroup=WORKGROUP"
            print "[Networking]"
            print "InstallDefaultComponents=Yes"
        }
    ' "$_xs_base"
}

usos_xp_settings_oem() {
    _xs_set=$1
    _xs_dir=$2
    mkdir -p "$_xs_dir" || return 1
    printf '[Commands]\r\n"usos-users.cmd"\r\n' > "$_xs_dir/cmdlines.txt" || return 1
    awk -v settings="$_xs_set" '
        BEGIN {
            while ((getline line < settings) > 0) { eq = index(line, "="); v[substr(line, 1, eq - 1)] = substr(line, eq + 1) }
            printf "@echo off\r\n"
            printf "rem USOS: local administrator accounts from usos-xp.ini, created by GUI Setup (cmdlines.txt).\r\n"
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
    ' > "$_xs_dir/usos-users.cmd"
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
    ' "$2/I386/TXTSETUP.SIF" 2>/dev/null)
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
