#!/bin/sh

# Print one normalized risky directive per line. No file contents or ProductKey
# values are echoed; this helper is safe to use in serial logs.
usos_xp_sif_risks() {
    sif=$1
    [ -f "$sif" ] || return 2
    awk '
    function compact(s) {
        gsub(/[ \t]/, "", s)
        return toupper(s)
    }
    {
        line=$0
        sub(/\r$/, "", line)
        sub(/;.*/, "", line)
        normalized=compact(line)
        if (normalized ~ /^AUTOPARTITION=("?1"?)$/) auto_partition=1
        if (normalized ~ /^REPARTITION=("?YES"?)$/) repartition=1
    }
    END {
        if (auto_partition) print "AutoPartition=1"
        if (repartition) print "Repartition=Yes"
    }
    ' "$sif"
}

usos_xp_sif_is_safe() {
    sif=$1
    risks=$(usos_xp_sif_risks "$sif") || return $?
    [ -z "$risks" ]
}
