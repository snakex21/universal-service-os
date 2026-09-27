# DOSNET [Files] third-column names are additional local-source destinations.
# Keep the original tree as well: multiple Setup copy entries can consume it.
function trim(s) { gsub(/^[ \t"]+|[ \t"]+$/, "", s); return s }
function reject(why) { print "[XP_SOURCE_ALIASES] " why ": " line > "/dev/stderr"; bad=1 }
function safe(s) { return s != "" && s !~ /[^A-Z0-9_.$~\/ -]/ && s !~ /^\// && s !~ /(^|\/)\.\.?($|\/)/ }
{
    line=$0; sub(/\r$/, "", line); sub(/;.*/, "", line); line=trim(line)
    if (line ~ /^\[/) { section=toupper(line); next }
    if (section == "[DIRECTORIES]" && index(line, "=")) {
        split(line, pair, "="); dir=trim(toupper(pair[2])); gsub(/\\/, "/", dir)
        dirs[toupper(trim(pair[1]))]=dir
    }
    if (section != "[FILES]" || line == "") next
    n=split(line, fields, ",")
    if (n < 3 || trim(fields[3]) == "") next
    disk=toupper(trim(fields[1])); src=toupper(trim(fields[2])); dst=toupper(trim(fields[3]))
    gsub(/\\/, "/", src); gsub(/\\/, "/", dst)
    if (!(disk in dirs)) { reject("Undefined source directory " disk); next }
    dir=dirs[disk]
    # Windows 2000 expresses d1 relative to DOSNET.INF inside I386.
    if ((nt5_system == "windows-2000") && (disk in dirs) && (dir == "/" || dir == "")) dir="/I386"
    # src_dir: the Setup source directory (I386; AMD64 for XP x64), whose
    # DOSNET.INF this is; aliases are relative to it.
    top="/" (src_dir == "" ? "I386" : toupper(src_dir))
    if (dir != top && index(dir, top "/") != 1) { reject("Unsupported source directory " dir); next }
    dir=substr(dir, length(top) + 1); sub(/^\//, "", dir)
    if (!safe(src) || !safe(dst) || (dir != "" && !safe(dir))) { reject("Unsafe path"); next }
    prefix=(dir == "" ? "" : dir "/")
    source=prefix src; target=prefix dst
    if (source == target) next
    if (target in origins && origins[target] != source) { bad=1; next }
    if (!(target in origins)) { origins[target]=source; print source "|" target }
}
END { if (bad) exit 1 }
