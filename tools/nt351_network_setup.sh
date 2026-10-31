# NT351-only optional LAN. Sourced functions; importing performs no writes.
# Original contract: NT351WS NDIS948d...ab1b, OEMNADLB5f64...fa52.
# NT4/95 and other NT3 minors never call this stage.
usos_nt351_requested() {
    awk '/^;USOS-NT351-NETWORK=/{sub(/\r$/,"");n++;v=substr($0,index($0,"=")+1)}
      END{if(n>1||(n==1&&v!="on"&&v!="off"))exit 1;print n?v:"off"}' "$1"
}

usos_nt351_answer() {
    _u351_group=$(awk '/^;USOS-NT351-WORKGROUP=/{sub(/\r$/,"");n++;v=substr($0,index($0,"=")+1)}
      END{if(n>1)exit 1;if(!n)v="WORKGROUP";if(length(v)<1||length(v)>15||v~/[^A-Za-z0-9_-]/)exit 1;print v}' "$1") || return 1
    awk -v BINMODE=3 -v group="$_u351_group" '
      function emit(s){printf "%s\r\n",s}
      {sub(/\r$/,"");line=$0;low=tolower(line);gsub(/[ \t]/,"",low)
       if(low~/^\[/){sec=low;emit(line)
         if(sec=="[guiunattended]"){emit("!SetupNetwork = YES");emit("!SetupNetWork = YES");gui++}
         if(sec=="[networkadapterdata]"){emit("!AutoNetOption = LOOP");nic++}
         if(sec=="[transportdata]"){emit("!InstallNWLink = 0");emit("!InstallNetBEUI = 0");emit("!InstallTCPIP = 1");tcp++}
         if(sec=="[domaindata]"){emit("!AutoWorkGroup = " group);groups++}
         if(sec=="[adapterparameters]"){emit("Medium = 0");medium++}
         next}
       if(sec=="[guiunattended]"&&low~/^!setupnetwork=/)next
       if((sec=="[networkadapterdata]"||sec=="[transportdata]"||sec=="[domaindata]"||sec=="[adapterparameters]")&&low!=""&&low!~/^;/)next
       emit(line)}
      END{if(gui!=1||nic!=1||tcp!=1||groups!=1||medium>1)exit 1;
          if(!medium){emit("");emit("[AdapterParameters]");emit("Medium = 0")}}' "$1"
}

usos_nt351_preflight() {
    # ANSWER LIB PCI_ROOT [native]. Must happen before target writes.
    # native (no install VM, docs/nt351-native-net-2026-10-28.md): the
    # USOSNET351N.SYS build (CF8h/CFCh without a HAL PCI bus, 20 ms timer),
    # staged under the same USOSNET351.SYS name usosnt3 takes over.
    _u351_answer=$1 _u351_lib=$2 _u351_pci=$3 _u351_variant=${4:-}
    _u351_enabled=$(usos_nt351_requested "$_u351_answer") || return 1
    [ "$_u351_enabled" = on ] || return 0
    . "$_u351_lib/network_setup.sh" || return 1
    _u351_config=$(usos_net_answer_config "$_u351_answer" NT4) || return 1
    # This first runtime fixture deliberately exercises DHCP. Unsupported
    # requested static data must not silently turn into a different mode.
    printf '%s\n' "$_u351_config" | grep -qx 'network=on' || return 1
    printf '%s\n' "$_u351_config" | grep -qx 'ip=dhcp' || return 1
    printf '%s\n' "$_u351_config" | grep -qx 'dns=' || return 1
    _u351_sys=$_u351_lib/nt3/USOSNET351.SYS
    _u351_sha=$_u351_lib/nt3/USOSNET351.SHA256
    if [ "$_u351_variant" = native ]; then
        _u351_sys=$_u351_lib/nt3/USOSNET351N.SYS
        _u351_sha=$_u351_lib/nt3/USOSNET351N.SHA256
    fi
    [ -r "$_u351_sys" ] && [ -r "$_u351_sha" ] || return 1
    _u351_expected=$(awk 'NR==1{print $1}' "$_u351_sha")
    printf '%s\n' "$_u351_expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    _u351_actual=$(sha256sum "$_u351_sys" | awk '{print $1}') || return 1
    [ "$_u351_actual" = "$_u351_expected" ] || return 1
    _u351_logger=$_u351_lib/nt3/USOSLOG351.EXE
    _u351_logger_sha=$_u351_lib/nt3/USOSLOG351.SHA256
    [ -r "$_u351_logger" ] && [ -r "$_u351_logger_sha" ] || return 1
    _u351_logger_expected=$(awk 'NR==1{print $1}' "$_u351_logger_sha")
    printf '%s\n' "$_u351_logger_expected" | grep -Eq '^[0-9a-f]{64}$' || return 1
    [ "$(sha256sum "$_u351_logger" | awk '{print $1}')" = "$_u351_logger_expected" ] || return 1
    _u351_matches=0 _u351_hwid=''
    for _u351_card in $(usos_net_pci_cards "$_u351_pci"); do
        _u351_id=$(usos_net_inf_match "$_u351_lib/network/usosnet.inf" "$_u351_card")
        if [ -n "$_u351_id" ]; then _u351_matches=$((_u351_matches+1)); _u351_hwid=$_u351_id; fi
    done
    [ "$_u351_matches" = 1 ] || return 1
}

usos_nt351_stage() {
    # TARGET_ROOT; preflight globals remain bound to the selected media.
    [ "${_u351_enabled:-off}" = on ] || return 0
    _u351_dir=$1/USOS/NT3
    mkdir -p "$_u351_dir" || return 1
    cp "$_u351_sys" "$_u351_dir/USOSNET351.SYS" &&
        cmp -s "$_u351_sys" "$_u351_dir/USOSNET351.SYS" || return 1
    cp "$_u351_sha" "$_u351_dir/USOSNET351.SHA256" || return 1
    cp "$_u351_logger" "$_u351_dir/USOSLOG.EXE" &&
      cmp -s "$_u351_logger" "$_u351_dir/USOSLOG.EXE" || return 1
    cp "$_u351_logger_sha" "$_u351_dir/USOSLOG.SHA256" || return 1
    printf '%s\r\n' '@echo off' 'rem Run explicitly after the installed desktop appears.' \
      'C:\USOS\NT3\USOSLOG.EXE /once /nohook /nodbg /out C:\USOS\NT3\USABILITY.TXT' > "$_u351_dir/TESTNET.CMD" || return 1
    printf 'network=on\r\nmode=dhcp\r\nservice=NDISLoop\r\nadapter=NDISLoop1\r\nsha256=%s\r\nhardware=%s\r\n' \
        "$_u351_actual" "$_u351_hwid" > "$_u351_dir/NET351.ON" || return 1
    printf '[NET351] staged own NDIS3 driver sha256=%s hardware=%s; original TCP/IP DHCP binding\n' "$_u351_actual" "$_u351_hwid"
}

usos_nt351_client_request() {
    # TARGET_ROOT original-source ProductType answer-kind; never USER/Server.
    [ "${_u351_enabled:-off}" = on ] || return 0
    [ "$2" = 0 ] || return 0
    case "$3" in DEFAULT|PROFILE) ;; *) return 0 ;; esac
    [ -s "$1/USOS/NT3/NET351.ON" ] || return 1
    printf 'USOS NT351 client-no-sharing\r\n' > "$1/USOS/NT3/CLNT351.REQ" || return 1
}

usos_nt351_loop_inf() {
    # stdin expanded original OEMNADLB; caller verifies source hash first.
    awk -v BINMODE=3 '
      {sub(/\r$/,"");print $0 "\r";
       if($0=="adapteroptions = +"){n++;print "    ;USOS-NT351-LOOP-AUTO\r";
          print "    ifstr(i) $(!STF_GUI_UNATTENDED) == YES\r";
          print "        goto skipoptions\r";print "    endif\r"}
       if($0=="skipoptions = +")skip++}
      END{if(n!=1||skip!=1)exit 1}'
}

usos_nt351_inf_pin() {
    # original OEMNADLB.INF sha256 -> patched sha256 (WS / Server CD)
    case "$1" in
      5f64dac6ee633bf961b9d07e2907c63c962a8dc41186eb00a73836d4647bfa52) echo df77ec120ac57faa3bc5b8ba554d254a1c00be55bf56fdc930519c7b0aa16d33 ;;
      bc73cc4ffc1677bda5cb536aca9d6dc584a7b2970eb93303e629710c91132946) echo 22e9fe3e67d6f097044de0b52e7918aec9e1e5bc10e6f3997c05766727dca125 ;;
      *) return 1 ;;
    esac
}

usos_nt351_source_patch() {
    # LOCAL_SOURCE_DIR WORK_DIR. Native path: no VM start between text mode
    # and GUI Setup, so the local source's OEMNADLB.IN_ (one-file MSZIP
    # cabinet; usos-fb-ui --nt3-cab-get / --nt3-cab-put) gets the same
    # pinned unattended-medium patch before text mode copies it.
    [ "${_u351_enabled:-off}" = on ] || return 0
    _u351_cab=''
    for _u351_name in OEMNADLB.IN_ oemnadlb.in_; do
        [ -f "$1/$_u351_name" ] && _u351_cab=$1/$_u351_name && break
    done
    [ -n "$_u351_cab" ] || return 1
    _u351_inf=$2/nt351-loop.inf
    _u351_fb=${USOS_FB_UI:-usos-fb-ui}
    rm -f "$_u351_inf" "$_u351_inf.new" "$_u351_inf.cab" "$_u351_inf.back"
    "$_u351_fb" --nt3-cab-get "$_u351_cab" "$_u351_inf" >/dev/null 2>&1 && [ -s "$_u351_inf" ] || return 1
    _u351_original=$(sha256sum "$_u351_inf" | awk '{print $1}') || return 1
    _u351_patched=$(usos_nt351_inf_pin "$_u351_original") || { rm -f "$_u351_inf"; return 1; }
    usos_nt351_loop_inf < "$_u351_inf" > "$_u351_inf.new" &&
      [ "$(sha256sum "$_u351_inf.new" | awk '{print $1}')" = "$_u351_patched" ] &&
      "$_u351_fb" --nt3-cab-put "$_u351_cab" "$_u351_inf.new" "$_u351_inf.cab" >/dev/null 2>&1 &&
      "$_u351_fb" --nt3-cab-get "$_u351_inf.cab" "$_u351_inf.back" >/dev/null 2>&1 &&
      cmp -s "$_u351_inf.new" "$_u351_inf.back" &&
      cat "$_u351_inf.cab" > "$_u351_cab" &&
      cmp -s "$_u351_inf.cab" "$_u351_cab" || { rm -f "$_u351_inf" "$_u351_inf.new" "$_u351_inf.cab" "$_u351_inf.back"; return 1; }
    rm -f "$_u351_inf" "$_u351_inf.new" "$_u351_inf.cab" "$_u351_inf.back"
    printf '[NET351] local source OEMNADLB sha256=%s -> %s (unattended 802.3 medium), cabinet read back\n' "$_u351_original" "$_u351_patched"
}

usos_nt351_vm_patch() {
    # Called only AFTER a completed VM boot, before GUI Setup starts.
    # The text-mode installer has expanded OEMNADLB into system32 by then.
    _u351_img=$1@@$NT4_PART_OFFSET
    MTOOLS_SKIP_CHECK=1 mtype -i "$_u351_img" ::/USOS/NT3/NET351.ON >/dev/null 2>&1 || return 0
    MTOOLS_SKIP_CHECK=1 mtype -i "$_u351_img" ::/USOS/NT3/SOURCE.TXT 2>/dev/null | grep -q '^version=3\.51' || return 1
    _u351_inf=$W9X_VM_RUN/../nt351-loop.inf
    MTOOLS_SKIP_CHECK=1 mtype -i "$_u351_img" ::/WINNT/SYSTEM32/OEMNADLB.INF > "$_u351_inf" 2>/dev/null &&
        [ -s "$_u351_inf" ] || { rm -f "$_u351_inf"; return 0; }
    if grep -q '^    ;USOS-NT351-LOOP-AUTO' "$_u351_inf"; then rm -f "$_u351_inf"; return 0; fi
    _u351_original=$(sha256sum "$_u351_inf" | awk '{print $1}') || return 1
    case "$_u351_original" in
      5f64dac6ee633bf961b9d07e2907c63c962a8dc41186eb00a73836d4647bfa52) _u351_patched=df77ec120ac57faa3bc5b8ba554d254a1c00be55bf56fdc930519c7b0aa16d33 ;;
      bc73cc4ffc1677bda5cb536aca9d6dc584a7b2970eb93303e629710c91132946) _u351_patched=22e9fe3e67d6f097044de0b52e7918aec9e1e5bc10e6f3997c05766727dca125 ;;
      *) rm -f "$_u351_inf"; return 1 ;;
    esac
    usos_nt351_loop_inf < "$_u351_inf" > "$_u351_inf.new" &&
      [ "$(sha256sum "$_u351_inf.new" | awk '{print $1}')" = "$_u351_patched" ] &&
      MTOOLS_SKIP_CHECK=1 mcopy -o -i "$_u351_img" "$_u351_inf.new" ::/WINNT/SYSTEM32/OEMNADLB.INF &&
      MTOOLS_SKIP_CHECK=1 mtype -i "$_u351_img" ::/WINNT/SYSTEM32/OEMNADLB.INF > "$_u351_inf.readback" &&
      cmp -s "$_u351_inf.new" "$_u351_inf.readback" || { rm -f "$_u351_inf" "$_u351_inf.new" "$_u351_inf.readback"; return 1; }
    printf '[NET351] original OEMNADLB sha256=%s; unattended802.3 medium patch readback verified\n' "$_u351_original"
    rm -f "$_u351_inf" "$_u351_inf.new" "$_u351_inf.readback"
}
