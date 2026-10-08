# The product key of the installation disc's own answer file (I386\WINNT.SIF
# on OEM / Media Center media such as the XP Media Center Edition 2005 SP3
# disc) as the last fallback when neither the answer profile, usos-xp.ini nor
# a .sif chosen in the menu gives one. The key is never printed or logged.
#
#   usos_nt5_media_sif_path SOURCE_ROOT          -> path of I386/WINNT.SIF (any case)
#   usos_nt5_answer_has_key FIELD < winnt.sif    -> 0 when [UserData] FIELD has a value
#   usos_nt5_media_key SOURCE_SIF                -> the key (5x5 shape) on stdout
#   usos_nt5_put_key FIELD KEY < winnt.sif > out -> FIELD set in [UserData]
# FIELD: ProductKey (XP / 2003) or ProductID (2000).

usos_nt5_media_sif_path() {
    _dir=$(find "$1" -maxdepth 1 -type d -iname i386 2>/dev/null | head -n 1)
    [ -n "$_dir" ] || return 1
    _sif=$(find "$_dir" -maxdepth 1 -type f -iname winnt.sif 2>/dev/null | head -n 1)
    [ -n "$_sif" ] || return 1
    printf '%s\n' "$_sif"
}

usos_nt5_answer_has_key() {
    tr -d '\r' | awk -v field="$1" '
        /^[ \t]*\[/ { s = tolower($0); gsub(/[ \t]/, "", s); next }
        s == "[userdata]" && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", k)
            if (tolower(k) != tolower(field)) next
            v = substr($0, index($0, "=") + 1); gsub(/[ \t"]/, "", v)
            if (v != "") found = 1
        }
        END { exit found ? 0 : 1 }'
}

usos_nt5_media_key() {
    tr -d '\r' < "$1" | awk '
        /^[ \t]*\[/ { s = tolower($0); gsub(/[ \t]/, "", s); next }
        s == "[userdata]" && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", k); k = tolower(k)
            if (k != "productkey" && k != "productid") next
            v = substr($0, index($0, "=") + 1); gsub(/[ \t"]/, "", v); v = toupper(v)
            if (v ~ /^[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9](-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])(-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])(-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])(-[A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9])$/) { print v; found = 1; exit }
        }
        END { exit found ? 0 : 1 }'
}

usos_nt5_put_key() {
    tr -d '\r' | USOS_NT5_KEY=$2 awk -v field="$1" '
        function put() { print field "=\"" ENVIRON["USOS_NT5_KEY"] "\""; done = 1 }
        /^[ \t]*\[/ {
            if (s == "[userdata]" && !done) put()
            s = tolower($0); gsub(/[ \t]/, "", s); print; next
        }
        s == "[userdata]" && index($0, "=") {
            k = substr($0, 1, index($0, "=") - 1); gsub(/[ \t]/, "", k)
            if (tolower(k) == tolower(field)) { if (!done) put(); next }
        }
        { print }
        END {
            if (!done) { if (s != "[userdata]") print "[UserData]"; put() }
        }'
}
