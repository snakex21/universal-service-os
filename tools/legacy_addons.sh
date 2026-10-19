# Legacy compatibility pack staging for an already guarded target root.
# BusyBox ash / Git sh. No device discovery, network access or disk commands.
usos_addons_config() {
    awk 'BEGIN{preset="none"}
      {sub(/\r$/, "");if($0~/^;USOS-ADDONS-(PRESET|OPTIONS|EXCLUDE)=/){p=index($0,"=");k=substr($0,14,p-14);v=substr($0,p+1);if(seen[k]++)bad=1;a[k]=v}
       if($0==";USOS-DIALUP=on")dialup="on"}
      END{if(bad)exit 1;print "preset="(a["PRESET"]==""?preset:a["PRESET"]);print "options="a["OPTIONS"];print "exclude="a["EXCLUDE"];print "dialup="(dialup=="on"?"on":"off")}' "$1"
}
usos_addons_log() { printf '[ADDONS] %s\n' "$*"; printf '%s\r\n' "$*" >> "$_ad_log"; }
usos_addons_offer() {
    local source=$1 size hash
    size=$(wc -c < "$source" | tr -d ' \r\n')
    awk -F'|' -v size="$size" '$1=="file"&&$6==size{found=1;exit}END{exit !found}' "$_ad_plan" || return 0
    hash=$(sha256sum "$source");hash=${hash%% *}
    awk -F'|' -v hash="$hash" '$1=="file"&&$5==hash{found=1;exit}END{exit !found}' "$_ad_plan" || return 0
    [ -f "$_ad_tmp/RAW/$hash" ] || { cp "$source" "$_ad_tmp/RAW/$hash" && cmp -s "$source" "$_ad_tmp/RAW/$hash"; } || return 1
}
# BusyBox streams the selected compressed member. File names are data.
usos_addons_unzip() { if command -v unzip >/dev/null 2>&1; then unzip "$@"; else /bin/busybox unzip "$@"; fi; }
# BusyBox does not compensate for a prepended SFX stub with relative ZIP
# offsets. Strip only the envelope in private scratch; pinned input stays intact.
usos_addons_zip_prepare() {
    _ad_zip=$1
    local normalized
    normalized=$(mktemp "$_ad_tmp/ZIPNXXXXXX") || return 1
    if "$_ad_tool" prepare-zip "$1" "$normalized"; then _ad_zip=$normalized; else rm -f "$normalized"; fi
}
usos_addons_zip_list() {
    # BusyBox canonicalizes ../ in its listing. Read original central names
    # so the 8.3/path checks below see the actual archive member names.
    "$_ad_tool" list-zip "$1" 2>/dev/null | tr -d '\r'
}
usos_addons_scan() {
    local source=$1 depth=$2 file size member suffix scan archive count=0
    [ -d "$source" ] || return 0
    find "$source" -type f > "$source_list_base.$depth"
    while IFS= read -r file; do
        usos_addons_offer "$file" || return 1
        [ "$depth" -lt 3 ] || continue
        suffix=$(printf '%s' "$file" | tr 'A-Z' 'a-z')
        case "$suffix" in
          *.iso)
            scan=$(mktemp -d "$_ad_tmp/ISOXXXXXX") || return 1
            if "$_ad_tool" scan-iso "$file" "$scan" "$_ad_plan"; then usos_addons_scan "$scan" 3 || return 1; fi ;;
          *.zip|*.exe)
            usos_addons_zip_prepare "$file" || return 1; archive=$_ad_zip
            usos_addons_zip_list "$archive" > "$_ad_tmp/MEMBERS.$depth"
            if [ ! -s "$_ad_tmp/MEMBERS.$depth" ] && head -c 4194304 "$file" | grep -a -q 'Inno Setup'; then
                usos_addons_log "container needs existing host Inno import: $file; flat pinned members remain supported"
            fi
            while IFS='|' read -r size member; do
                [ -n "$member" ] || continue
                suffix=$(printf '%s' "$member" | tr 'A-Z' 'a-z')
                scan=no
                case "$suffix" in *.zip|*.iso|*.exe) [ "$size" -le 536870912 ] && scan=yes ;; esac
                if [ "$scan" = yes ] || awk -F'|' -v size="$size" '$1=="file"&&$6==size{found=1;exit}END{exit !found}' "$_ad_plan"; then
                    count=$((count+1));scan=$(mktemp -d "$_ad_tmp/ZIPXXXXXX") || return 1
                    # Some self-extracting ZIPs return a warning despite a
                    # complete member stream; the pinned digest is decisive.
                    suffix=${suffix##*.}
                    usos_addons_unzip -p "$archive" "$member" > "$scan/MEMBER.$suffix" 2>/dev/null || true
                    usos_addons_scan "$scan" $((depth+1)) || return 1
                fi
            done < "$_ad_tmp/MEMBERS.$depth" ;;
        esac
    done < "$source_list_base.$depth"
}
usos_addons_unpack_zip() {
    local archive=$1 dest=$2 list root strip=1 size member relative written=0
    usos_addons_zip_prepare "$archive" || return 1;archive=$_ad_zip
    list=$(mktemp "$_ad_tmp/UNPACKXXXXXX") || return 1
    usos_addons_zip_list "$archive" > "$list"
    [ -s "$list" ] || return 1
    root=$(awk -F'|' 'NR==1{n=split($2,a,"/");if(n>1)print a[1]}' "$list")
    [ -n "$root" ] || strip=0
    if [ "$strip" = 1 ]; then awk -F'|' -v root="$root" '{split($2,a,"/");if(a[1]!=root||index($2,"/")==0)bad=1}END{exit bad}' "$list" || strip=0; fi
    while IFS='|' read -r size member; do
        [ -n "$member" ] || continue
        relative=$member;[ "$strip" != 1 ] || relative=${relative#*/}
        relative=$(printf '%s' "$relative" | tr 'a-z' 'A-Z')
        # Do not depend on interval regular expressions in BusyBox awk.
        printf '%s\n' "$relative" | awk -F/ '{for(i=1;i<=NF;i++){if($i!~/^[A-Z0-9_.-]+$/)exit 1;n=split($i,a,/\./);if(n>2||length(a[1])<1||length(a[1])>8||(n==2&&(length(a[2])<1||length(a[2])>3)))exit 1}}' || continue
        mkdir -p "$dest/$(dirname "$relative")" || return 1
        usos_addons_unzip -p "$archive" "$member" > "$dest/$relative" 2>/dev/null || return 1
        [ "$(wc -c < "$dest/$relative" | tr -d ' \r\n')" = "$size" ] || return 1
        written=$((written+1))
    done < "$list"
    [ "$written" -gt 0 ]
}
usos_addons_run_reg() {
    printf '%s\r\n' 'REGEDIT4' '' '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]' '"USOSAddons"="C:\\USOS\\ADDONS\\USOSADD.EXE"'
}
usos_addons_stage() {
    # CONFIG TARGET_ROOT LIB_ROOT DATA_ADDONS OS_TOKEN LANGUAGE [NTSP]
    local cfg=$1 target=$2 lib=$3 data=$4 os=$5 lang=$6 ntsp=${7:-} preset options exclude dialup
    local kind id dir file hash size unpack source copied=0 missing=0 duns
    preset=$(sed -n 's/^preset=//p' "$cfg");options=$(sed -n 's/^options=//p' "$cfg");exclude=$(sed -n 's/^exclude=//p' "$cfg");dialup=$(sed -n 's/^dialup=//p' "$cfg")
    case "$preset" in none) printf '[ADDONS] preset=none; original flow\n';return 0 ;; praca|retro|minimal) ;; *) return 1 ;; esac
    printf '%s\n' "$options" "$exclude" | awk 'length>512||/[^a-z0-9,-]/||/^,|,$|,,/ {bad=1}END{exit bad}' || return 1
    case "$os" in 95|98FE|98SE|ME|NT4) ;; *) return 1 ;; esac
    case "$lang" in PL|EN|XX) ;; *) return 1 ;; esac
    _ad_app=$target/USOS/ADDONS
    case "$os" in NT4) _ad_log=$target/USOS/NT4/ADDONS.LOG ;; *) _ad_log=$target/USOS9X/LOGS/ADDONS.LOG ;; esac
    mkdir -p "$(dirname "$_ad_log")" "$_ad_app/TMP" || return 1
    usos_addons_log "staging system=$os lang=$lang preset=$preset"
    _ad_tool=$lib/addons/legacy-stage-plan
    if [ ! -f "$_ad_tool" ] || [ ! -f "$lib/addons/USOSADD.EXE" ]; then usos_addons_log 'runner/planner missing from build; OS installation continues';return 0; fi
    _ad_tmp=$(mktemp -d "$_ad_app/TMP/STGXXXXXX") || return 1
    _ad_plan=$_ad_tmp/PLAN.TXT
    source_list_base=$_ad_tmp/SOURCES
    mkdir "$_ad_tmp/RAW" || return 1
    # DUN must not restore a modem path that the network task disabled.
    if [ "$os" = ME ] || [ "$dialup" != on ]; then
        duns=$(awk '/^\[pkg:dun/{s=$0;sub(/^\[pkg:/,"",s);sub(/\].*/,"",s);printf "%s%s",sep,s;sep=","}' "$lib/addons/LEGACY.EN")
        exclude=${exclude:+$exclude,}$duns
    fi
    { printf '[select]\r\npreset=%s\r\noptions=%s\r\nexclude=%s\r\nexpect=%s\r\nlang=%s\r\n' "$preset" "$options" "$exclude" "$os" "$lang"; } > "$_ad_app/SELECT.INI"
    source=$lib/addons/LEGACY.EN;[ "$lang" != PL ] || source=$lib/addons/LEGACY.PL
    cp "$source" "$_ad_app/LEGACY.INI" && cp "$lib/addons/USOSADD.EXE" "$_ad_app/USOSADD.EXE" || return 1
    "$_ad_tool" "$_ad_app/LEGACY.INI" "$_ad_app/SELECT.INI" "$os" "$lang" "$ntsp" > "$_ad_tmp/PLAN.RAW" || return 1
    # Host Windows builds emit CRLF; the shell protocol always uses LF.
    tr -d '\r' < "$_ad_tmp/PLAN.RAW" > "$_ad_plan" || return 1
    usos_addons_scan "$data" 0 && usos_addons_scan "$lib/addons/bundled" 0 || return 1
    mkdir -p "$_ad_app/PKG" || return 1
    while IFS='|' read -r kind id dir file hash size unpack; do
        if [ "$kind" = unavailable ]; then missing=$((missing+1));usos_addons_log "unavailable $id status=$unpack";continue;fi
        [ "$kind" = file ] || continue
        if [ ! -f "$_ad_tmp/RAW/$hash" ]; then missing=$((missing+1));usos_addons_log "missing $id/$file (pinned size/SHA-256 not found)";continue;fi
        mkdir -p "$_ad_app/PKG/$dir" || return 1
        case "$unpack" in
          zip) source=$(mktemp -d "$_ad_tmp/UNZIPXXXXXX") || return 1
               if usos_addons_unpack_zip "$_ad_tmp/RAW/$hash" "$source"; then cp -R "$source/." "$_ad_app/PKG/$dir/" || return 1
               else usos_addons_log "missing $id: unsupported ZIP or extraction failed";missing=$((missing+1));continue;fi ;;
          iso) "$_ad_tool" unpack-iso "$_ad_tmp/RAW/$hash" "$_ad_app/PKG/$dir" || { usos_addons_log "missing $id: ISO has no supported root files";missing=$((missing+1));continue; } ;;
          *) cp "$_ad_tmp/RAW/$hash" "$_ad_app/PKG/$dir/$file" || return 1
             source=$(sha256sum "$_ad_app/PKG/$dir/$file");[ "${source%% *}" = "$hash" ] || return 1 ;;
        esac
        copied=$((copied+1));usos_addons_log "staged $id/$file SHA-256=$hash size=$size"
    done < "$_ad_plan"
    cp "$_ad_plan" "$_ad_app/PLAN.TXT" || return 1
    usos_addons_run_reg > "$_ad_app/ADDONS.REG"
    usos_addons_log "staging complete files=$copied missing=$missing; missing packages do not stop Windows Setup"
    # Delete only this freshly generated, owned private scratch directory.
    case "$_ad_tmp" in "$_ad_app"/TMP/STG*) [ ! -L "$_ad_tmp" ] && rm -rf -- "$_ad_tmp" ;; *) return 1 ;; esac
}
