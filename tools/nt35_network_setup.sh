# NT35-only optional LAN. Sourced functions; importing performs no writes.
# Original NT35 NDISfa392...5543; exact OEMNADLB hash requires original audit.
# NT4/95 and other NT3 minors never call this stage.
usos_nt35_pci_address() {
    _u35_bdf=$1
    printf '%s\n' "$_u35_bdf" | grep -Eq '^0000:[0-9a-fA-F]{2}:[01][0-9a-fA-F]\.[0-7]$' || return 1
    _u35_parts=${_u35_bdf#0000:};_u35_b=${_u35_parts%%:*};_u35_parts=${_u35_parts#*:}
    _u35_dev=${_u35_parts%.*};_u35_fn=${_u35_parts#*.}
    _u35_bus=$(printf '%d' "0x$_u35_b") || return 1
    _u35_dev=$(printf '%d' "0x$_u35_dev") || return 1
    _u35_slot=$((_u35_dev + _u35_fn * 32))
}
usos_nt35_sysfs_address() { usos_nt35_pci_address "${1##*/}"; }

usos_nt35_requested() {
    awk '/^;USOS-NT35-NETWORK=/{sub(/\r$/,"");n++;v=substr($0,index($0,"=")+1)}
      END{if(n>1||(n==1&&v!="on"&&v!="off"))exit 1;print n?v:"off"}' "$1"
}

usos_nt35_answer() {
    _u35_group=$(awk '/^;USOS-NT35-WORKGROUP=/{sub(/\r$/,"");n++;v=substr($0,index($0,"=")+1)}
      END{if(n>1)exit 1;if(!n)v="WORKGROUP";if(length(v)<1||length(v)>15||v~/[^A-Za-z0-9_-]/)exit 1;print v}' "$1") || return 1
    awk -v BINMODE=3 -v group="$_u35_group" '
      function emit(s){printf "%s\r\n",s}
      {sub(/\r$/,"");line=$0;low=tolower(line);gsub(/[ \t]/,"",low)
       if(low~/^\[/){sec=low;emit(line)
         if(sec=="[guiunattended]"){emit("!SetupNetwork = YES");emit("!SetupNetWork = YES");gui++}
         if(sec=="[networkadapterdata]"){emit("!AutoNetOption = LOOP");nic++}
         if(sec=="[transportdata]"){emit("!InstallNWLink = 0");emit("!InstallNetBEUI = 0");emit("!InstallTCPIP = 1");tcp++}
         if(sec=="[domaindata]"){emit("!AutoWorkGroup = " group);groups++}
         if(sec=="[netcardparameterlist]"){emit("Medium = 0");medium++}
         next}
       if(sec=="[guiunattended]"&&low~/^!setupnetwork=/)next
       if((sec=="[networkadapterdata]"||sec=="[transportdata]"||sec=="[domaindata]"||sec=="[netcardparameterlist]")&&low!=""&&low!~/^;/)next
       emit(line)}
      END{if(gui!=1||nic!=1||tcp!=1||groups!=1||medium>1)exit 1;
          if(!medium){emit("");emit("[NetCardParameterList]");emit("Medium = 0")}}' "$1"
}

usos_nt35_preflight() {
    # ANSWER LIB PCI_ROOT. Must happen before target writes.
    _u35_answer=$1 _u35_lib=$2 _u35_pci=$3
    _u35_enabled=$(usos_nt35_requested "$_u35_answer") || return 1
    [ "$_u35_enabled" = on ] || return 0
    . "$_u35_lib/network_setup.sh" || return 1
    _u35_config=$(usos_net_answer_config "$_u35_answer" NT4) || return 1
    # This first runtime fixture deliberately exercises DHCP. Unsupported
    # requested static data must not silently turn into a different mode.
    printf '%s\n' "$_u35_config" | grep -qx 'network=on' || return 1
    printf '%s\n' "$_u35_config" | grep -qx 'ip=dhcp' || return 1
    printf '%s\n' "$_u35_config" | grep -qx 'dns=' || return 1
    _u35_sys=$_u35_lib/nt3/USOSNET35.SYS
    _u35_sha=$_u35_lib/nt3/USOSNET35.SHA256
    [ -r "$_u35_sys" ] && [ -r "$_u35_sha" ] || return 1
    _u35_expected=$(awk 'NR==1{print $1}' "$_u35_sha")
    printf '%s\n' "$_u35_expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    _u35_actual=$(sha256sum "$_u35_sys" | awk '{print $1}') || return 1
    [ "$_u35_actual" = "$_u35_expected" ] || return 1
    _u35_logger=$_u35_lib/nt3/USOSLOG35.EXE
    _u35_logger_sha=$_u35_lib/nt3/USOSLOG35.SHA256
    [ -r "$_u35_logger" ] && [ -r "$_u35_logger_sha" ] || return 1
    _u35_logger_expected=$(awk 'NR==1{print $1}' "$_u35_logger_sha")
    printf '%s\n' "$_u35_logger_expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    [ "$(sha256sum "$_u35_logger" | awk '{print $1}')" = "$_u35_logger_expected" ] || return 1
    _u35_matches=0 _u35_hwid='' _u35_bus='' _u35_slot=''
    for _u35_node in "$_u35_pci"/*; do
        [ -d "$_u35_node" ] || continue
        _u35_class=$(cat "$_u35_node/class" 2>/dev/null || true)
        case "$_u35_class" in 0x0200*) ;; *) continue ;; esac
        _u35_v=$(cat "$_u35_node/vendor" 2>/dev/null || true)
        _u35_d=$(cat "$_u35_node/device" 2>/dev/null || true)
        printf '%s %s\n' "$_u35_v" "$_u35_d" | grep -Eq '^0x[0-9a-fA-F]{4} 0x[0-9a-fA-F]{4}$' || return 1
        _u35_card=$(printf 'PCI\VEN_%s&DEV_%s' "${_u35_v#0x}" "${_u35_d#0x}" | tr 'a-f' 'A-F')
        _u35_id=$(usos_net_inf_match "$_u35_lib/network/usosnet.inf" "$_u35_card")
        [ -n "$_u35_id" ] || continue
        usos_nt35_sysfs_address "$_u35_node" || return 1
        _u35_matches=$((_u35_matches+1));_u35_hwid=$_u35_id
    done
    [ "$_u35_matches" = 1 ] || return 1
}

usos_nt35_stage() {
    # TARGET_ROOT; preflight globals remain bound to the selected media.
    [ "${_u35_enabled:-off}" = on ] || return 0
    _u35_dir=$1/USOS/NT3
    mkdir -p "$_u35_dir" || return 1
    cp "$_u35_sys" "$_u35_dir/USOSNET35.SYS" &&
        cmp -s "$_u35_sys" "$_u35_dir/USOSNET35.SYS" || return 1
    cp "$_u35_sha" "$_u35_dir/USOSNET35.SHA256" || return 1
    cp "$_u35_logger" "$_u35_dir/USOSLOG.EXE" &&
      cmp -s "$_u35_logger" "$_u35_dir/USOSLOG.EXE" || return 1
    cp "$_u35_logger_sha" "$_u35_dir/USOSLOG.SHA256" || return 1
    printf '%s\r\n' '@echo off' 'rem Run explicitly after the installed desktop appears.' \
      'C:\USOS\NT3\USOSLOG.EXE /once /nohook /nodbg /out C:\USOS\NT3\USABILITY.TXT' > "$_u35_dir/TESTNET.CMD" || return 1
    printf 'network=on\r\nmode=dhcp\r\nservice=NDISLoop\r\nadapter=NDISLoop1\r\nsha256=%s\r\nhardware=%s\r\nbus=%s\r\nslot=%s\r\n' \
        "$_u35_actual" "$_u35_hwid" "$_u35_bus" "$_u35_slot" > "$_u35_dir/NET35.ON" || return 1
    printf '[NET35] staged own NDIS3 driver sha256=%s hardware=%s; original TCP/IP DHCP binding\n' "$_u35_actual" "$_u35_hwid"
}

usos_nt35_client_request() {
    # TARGET_ROOT original-source ProductType answer-kind. No inference from
    # filename, generated account data, or a Server/private answer.
    [ "${_u35_enabled:-off}" = on ] || return 0
    [ "$2" = 0 ] || return 0
    case "$3" in DEFAULT|PROFILE) ;; *) return 0 ;; esac
    [ -s "$1/USOS/NT3/NET35.ON" ] || return 1
    printf 'USOS NT35 client-no-sharing\r\n' > "$1/USOS/NT3/CLNT35.REQ" || return 1
}

usos_nt35_loop_inf() {
    # stdin expanded original OEMNADLB; caller verifies source hash first.
    awk -v BINMODE=3 '
      {sub(/\r$/,"");print $0 "\r";
       if($0=="adapteroptions = +"){n++;print "    ;USOS-NT35-LOOP-AUTO\r";
          print "    ifstr(i) $(!STF_GUI_UNATTENDED) == YES\r";
          print "        goto skipoptions\r";print "    endif\r"}
       if($0=="skipoptions = +")skip++}
      END{if(n!=1||skip!=1)exit 1}'
}

usos_nt35_vm_patch() {
    # Called only AFTER a completed VM boot, before GUI Setup starts.
    # The text-mode installer has expanded OEMNADLB into system32 by then.
    _u35_img=$1@@$NT4_PART_OFFSET
    MTOOLS_SKIP_CHECK=1 mtype -i "$_u35_img" ::/USOS/NT3/NET35.ON >/dev/null 2>&1 || return 0
    MTOOLS_SKIP_CHECK=1 mtype -i "$_u35_img" ::/USOS/NT3/SOURCE.TXT 2>/dev/null | grep -q '^version=3\.50[[:space:]]*$' || return 1
    _u35_inf=$W9X_VM_RUN/../nt35-loop.inf
    MTOOLS_SKIP_CHECK=1 mtype -i "$_u35_img" ::/WINNT/SYSTEM32/OEMNADLB.INF > "$_u35_inf" 2>/dev/null &&
        [ -s "$_u35_inf" ] || { rm -f "$_u35_inf"; return 0; }
    if grep -q '^    ;USOS-NT35-LOOP-AUTO' "$_u35_inf"; then rm -f "$_u35_inf"; return 0; fi
    _u35_original=$(sha256sum "$_u35_inf" | awk '{print $1}') || return 1
    case "$_u35_original" in
      37e16b22d26d7717a91c63cd1d26be4c7b4977d76214de63980831ae547c7cb0) _u35_patched=fff3c06dad680983a3389d906c8d81daa918f0cf191ad2cdbb3fa3894fd327cf ;;
      *) rm -f "$_u35_inf"; return 1 ;;
    esac
    usos_nt35_loop_inf < "$_u35_inf" > "$_u35_inf.new" &&
      [ "$(sha256sum "$_u35_inf.new" | awk '{print $1}')" = "$_u35_patched" ] &&
      MTOOLS_SKIP_CHECK=1 mcopy -o -i "$_u35_img" "$_u35_inf.new" ::/WINNT/SYSTEM32/OEMNADLB.INF &&
      MTOOLS_SKIP_CHECK=1 mtype -i "$_u35_img" ::/WINNT/SYSTEM32/OEMNADLB.INF > "$_u35_inf.readback" &&
      cmp -s "$_u35_inf.new" "$_u35_inf.readback" || { rm -f "$_u35_inf" "$_u35_inf.new" "$_u35_inf.readback"; return 1; }
    printf '[NET35] original OEMNADLB sha256=%s; unattended802.3 medium patch readback verified\n' "$_u35_original"
    rm -f "$_u35_inf" "$_u35_inf.new" "$_u35_inf.readback"
}
