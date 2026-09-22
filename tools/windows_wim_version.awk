# Extract only the boot image's Windows architecture/version from WIM XML.
# Input is UTF-16LE decoded by the caller; no shell expressions are evaluated.
BEGIN { RS="<"; FS=">"; selected=0; windows=0; version=0; matches=0 }
{
    tag=$1; value=$2
    if (tag ~ /^IMAGE[ \t\r\n]+INDEX="[0-9]+"[ \t\r\n]*$/) {
        index_text=tag; sub(/^.*INDEX="/, "", index_text); sub(/".*$/, "", index_text)
        selected=(index_text+0 == boot_index+0)
        windows=0; version=0; arch=""; major=""; minor=""
    }
    if (!selected) next
    if (tag == "WINDOWS") windows=1
    if (tag == "/WINDOWS") windows=0
    if (windows && tag == "VERSION") version=1
    if (tag == "/VERSION") version=0
    gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", value)
    if (windows && tag == "ARCH" && value ~ /^[0-9]+$/) arch=value
    if (version && tag == "MAJOR" && value ~ /^[0-9]+$/) major=value
    if (version && tag == "MINOR" && value ~ /^[0-9]+$/) minor=value
    if (tag == "/IMAGE") {
        if (arch != "" && major != "" && minor != "") { result=arch " " major " " minor; matches++ }
        selected=0
    }
}
END { if (matches != 1) exit 1; print result }
