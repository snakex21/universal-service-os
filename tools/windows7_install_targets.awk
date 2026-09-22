# List every install image target as "ARCH MAJOR MINOR BUILD" (one line per <IMAGE>).
# Input is UTF-16LE decoded by the caller; no shell expressions are evaluated.
# BUILD lives inside VERSION (WIM XML), ARCH inside WINDOWS.
BEGIN { RS="<"; FS=">"; in_image=0; windows=0; version=0; arch=""; major=""; minor=""; build="" }
{
    tag=$1; value=$2
    if (tag ~ /^IMAGE[ \t\r\n]+INDEX="[0-9]+"[ \t\r\n]*$/) {
        in_image=1; windows=0; version=0; arch=""; major=""; minor=""; build=""
    }
    if (!in_image) next
    if (tag == "WINDOWS") windows=1
    if (tag == "/WINDOWS") windows=0
    if (windows && tag == "VERSION") version=1
    if (tag == "/VERSION") version=0
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", value)
    if (windows && tag == "ARCH" && value ~ /^[0-9]+$/) arch=value
    if (version && tag == "MAJOR" && value ~ /^[0-9]+$/) major=value
    if (version && tag == "MINOR" && value ~ /^[0-9]+$/) minor=value
    if (version && tag == "BUILD" && value ~ /^[0-9]+$/) build=value
    if (tag == "/IMAGE") {
        if (arch != "" && major != "" && minor != "" && build != "") print arch " " major " " minor " " build
        else { print "incomplete" > "/dev/stderr"; exit 1 }
        in_image=0
    }
}
