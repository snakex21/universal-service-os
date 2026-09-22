# Format smartctl's English ATA/NVMe/SCSI reports without inventing values.
# Parse the ATA header by name: both normal and brief smartctl layouts occur.
function clean(value) {
    gsub(/\t/, " ", value); gsub(/[^ -~]/, "?", value); gsub(/\|/, "/", value)
    sub(/^ +/, "", value); sub(/ +$/, "", value)
    return substr(value, 1, 160)
}
function field(name) { return column[name] ? $(column[name]) : "" }
function add_metric(name, value,    tone, flags) {
    if (count >= 108) return
    tone = "normal"
    if (name == "Critical Warning") {
        flags = value; sub(/^0[xX]/, "", flags); gsub(/[0 ]/, "", flags)
        if (flags != "") tone = "failure"
    } else if ((name == "Percentage Used" && value + 0 >= 100) ||
               ((name == "Media and Data Integrity Errors" || name == "Error Information Log Entries" || name == "Non-medium error count") && value + 0 > 0)) tone = "warning"
    metric[++count] = substr(clean(name),1,64); result[count] = substr(clean(value),1,140); tones[count] = tone
}
/^[[:space:]]*ID#[[:space:]]+ATTRIBUTE_NAME[[:space:]]/ {
    for (i = 1; i <= NF; i++) column[$i] = i
    ata = 1; next
}
ata && $1 ~ /^[0-9]+$/ && column["RAW_VALUE"] && NF >= column["RAW_VALUE"] {
    if (count >= 108) next
    raw = ""
    for (i = column["RAW_VALUE"]; i <= NF; i++) raw = raw (raw == "" ? "" : " ") $i
    failed = column["WHEN_FAILED"] ? field("WHEN_FAILED") : field("FAIL")
    tone = "normal"; status = "-"
    if (failed == "FAILING_NOW" || failed == "NOW") { tone = "failure"; status = "FAILED" }
    else if (failed != "-" && failed != "") { tone = "warning"; status = clean(failed) }
    name = field("ATTRIBUTE_NAME"); gsub(/_/, " ", name)
    rows[++count] = tone "|" substr(clean($1),1,3) "|" substr(clean(name),1,48) "|" substr(clean(field("VALUE")),1,6) "|" substr(clean(field("WORST")),1,6) "|" substr(clean(field("THRESH")),1,6) "|" substr(clean(raw),1,104) "|" substr(status,1,16)
    next
}
/^SMART\/Health Information \(NVMe/ { nvme = 1; next }
nvme && /^$/ { nvme = 0 }
nvme && /^[A-Za-z][^:]*:/ {
    at = index($0, ":"); add_metric(substr($0, 1, at - 1), clean(substr($0, at + 1))); next
}
!ata && /^(Current Drive Temperature|Drive Trip Temperature|Accumulated power on time|Elements in grown defect list|Non-medium error count|Percentage used endurance indicator|Specified cycle count over device lifetime|Accumulated start-stop cycles|Specified load-unload count over device lifetime|Accumulated load-unload cycles):/ {
    at = index($0, ":"); add_metric(substr($0, 1, at - 1), clean(substr($0, at + 1)))
}
END {
    if (count == 0) {
        print "info=No attribute table was returned by this device. Open the full report for details."
    } else if (ata) {
        print "info=Value, Worst and Limit are normalized; RAW is manufacturer-specific. A dash means no reported threshold failure."
        print "table_header=ID|Attribute|Value|Worst|Limit|RAW value|State"
        for (i = 1; i <= count; i++) print "table_row=" rows[i]
    } else {
        print "info=Values reported by the device. Colored rows show warnings or recorded errors; see the full report for context."
        print "table_header=Parameter|Reported value"
        for (i = 1; i <= count; i++) print "table_row=" tones[i] "|" metric[i] "|" result[i]
    }
}
