# Optional legacy LAN staging. Source only: no disk discovery or writes on import.
# All operations receive an already-selected target root from the existing flow.
usos_net_answer_config() {
    awk -v os="$2" '
      /^;USOS-/ {sub(/\r$/, ""); pos=index($0,"="); k=substr($0,7,pos-7); v=substr($0,pos+1);
        if(k~/^(NETWORK|IP|GATEWAY|DNS|HOME|DIALUP)$/){if(seen[k]++)exit 1; a[k]=v}}
      END {if(seen["NETWORK"]>1)exit 1;
        printf "system=%s\nnetwork=%s\nip=%s\ngateway=%s\ndns=%s\nhome_page=%s\ndialup=%s\n", os,
        (a["NETWORK"]=="on"?"on":"off"),(a["IP"]==""?"dhcp":a["IP"]),a["GATEWAY"],a["DNS"],
        (a["HOME"]==""?"about:blank":a["HOME"]),(os=="ME"?"off":(a["DIALUP"]=="on"?"on":"off"))}' "$1"
}
usos_net_w2k_config() {
    if [ -n "${1:-}" ] && [ -f "$1" ]; then
        awk 'BEGIN{a["network"]="on";a["ip"]="dhcp";a["home_page"]="about:blank"}
          {sub(/\r$/, "");pos=index($0,"=");k=substr($0,1,pos-1);v=substr($0,pos+1);
           if(k~/^(network|ip|gateway|dns|home_page)$/){if(seen[k]++)exit 1;a[k]=v}}
          END{printf "system=W2K\nnetwork=%s\nip=%s\ngateway=%s\ndns=%s\nhome_page=%s\ndialup=off\n",(a["network"]==""?"on":a["network"]),(a["ip"]==""?"dhcp":a["ip"]),a["gateway"],a["dns"],(a["home_page"]==""?"about:blank":a["home_page"])}' "$1"
    else printf '%s\n' 'system=W2K' 'network=on' 'ip=dhcp' 'gateway=' 'dns=' 'home_page=about:blank' 'dialup=off'; fi
}
usos_net_value() { awk -v k="$2" 'index($0,k"=")==1 {sub(/^[^=]*=/, "");sub(/\r$/, "");print;exit}' "$1"; }
usos_net_valid_config() {
    awk '
      function addr(s, p,n,i,r){n=split(s,p,".");if(n!=4)return -1;r=0;for(i=1;i<=4;i++){if(p[i]!~/^[0-9]+$/||length(p[i])>3||p[i]>255||(length(p[i])>1&&substr(p[i],1,1)=="0"))return -1;r=r*256+p[i]}return p[1]>0&&p[1]<224&&p[1]!=127?r:-1}
      {sub(/\r$/, "");e=index($0,"=");k=substr($0,1,e-1);v=substr($0,e+1);
       if(!e||k!~/^(system|network|ip|gateway|dns|home_page|dialup)$/||seen[k]++||length(v)>200||v~/[^ -~]/||v~/["\\|]/)bad=1;a[k]=v}
      END{if(a["system"]!~/^(95|98|98SE|ME|NT4|W2K)$/||a["network"]!~/^(on|off)$/||a["dialup"]!~/^(on|off)$/)bad=1;
       if(a["ip"]!="dhcp"){n=split(a["ip"],p,"/");own=addr(p[1]);if(n!=2||own<0||p[2]!~/^[1-9][0-9]?$/||p[2]<1||p[2]>30)bad=1;else{span=2^(32-p[2]);net=int(own/span);host=own%span;if(host==0||host==span-1)bad=1}}
       if(a["gateway"]!=""){gw=addr(a["gateway"]);if(gw<0||a["ip"]=="dhcp"||gw==own||!span)bad=1;else if(int(gw/span)!=net||gw%span==0||gw%span==span-1)bad=1}
       if(a["dns"]!=""){n=split(a["dns"],d,",");if(n>3)bad=1;for(i=1;i<=n;i++)if(addr(d[i])<0)bad=1}
       if(a["home_page"]!="about:blank"&&(a["home_page"]!~/^https?:\/\/[^\/ ?#]/||a["home_page"]~/[^A-Za-z0-9_.~:\/?#[!$&()*+,;=%\]-]/))bad=1;
       exit bad?1:0}' "$1"
}
usos_net_pci_cards() {
    for _un_pci in "$1"/*; do
        [ -d "$_un_pci" ] || continue
        _un_class=$(cat "$_un_pci/class" 2>/dev/null || true)
        case "$_un_class" in 0x0200*) ;; *) continue ;; esac
        _un_v=$(cat "$_un_pci/vendor" 2>/dev/null || true); _un_d=$(cat "$_un_pci/device" 2>/dev/null || true)
        _un_sv=$(cat "$_un_pci/subsystem_vendor" 2>/dev/null || true); _un_sd=$(cat "$_un_pci/subsystem_device" 2>/dev/null || true)
        _un_rev=$(cat "$_un_pci/revision" 2>/dev/null || true)
        printf '%s %s\n' "$_un_v" "$_un_d" | grep -Eq '^0x[0-9a-fA-F]{4} 0x[0-9a-fA-F]{4}$' || continue
        printf 'PCI\\VEN_%s&DEV_%s' "${_un_v#0x}" "${_un_d#0x}" | tr 'a-f' 'A-F'
        if printf '%s %s\n' "$_un_sd" "$_un_sv" | grep -Eq '^0x[0-9a-fA-F]{4} 0x[0-9a-fA-F]{4}$'; then
            printf '&SUBSYS_%s%s' "${_un_sd#0x}" "${_un_sv#0x}" | tr 'a-f' 'A-F'
        fi
        if printf '%s\n' "$_un_rev" | grep -Eq '^0x[0-9a-fA-F]{2}$'; then printf '&REV_%s' "${_un_rev#0x}" | tr 'a-f' 'A-F'; fi
        printf '\n'
    done
}
usos_net_inf_match() {
    USOS_NET_CARD=$2 awk '
      BEGIN{card=toupper(ENVIRON["USOS_NET_CARD"]);n=split(card,c,"&");for(i=1;i<=n;i++)have[c[i]]=1}
      {s=toupper($0);sub(/;.*/,"",s);if(s!~/=/)next;n=split(s,a,",");
       if(n<2)next;id=a[2];gsub(/[ \t\r"]/,"",id);if(id!~/^PCI\\VEN_[0-9A-F]+&DEV_[0-9A-F]+/)next;
       n=split(id,need,"&");ok=1;for(i=1;i<=n;i++)if(!have[need[i]])ok=0;
       if(ok){print id;exit}}' "$1"
}
usos_net_log() { printf '%s\n' "$*" >> "$_un_log"; printf '[NETSETUP] %s\n' "$*"; }
usos_net_stage() {
    # CONFIG TARGET_ROOT LIB_ROOT PCI_ROOT. State/path outputs are prefixed globals.
    _un_cfg=$1 _un_root=$2 _un_lib=$3 _un_pci_root=$4
    usos_net_valid_config "$_un_cfg" || return 1
    _un_os=$(usos_net_value "$_un_cfg" system); _un_state=off _un_driver_path='' _un_hwid='' _un_matches=0
    if [ "$(usos_net_value "$_un_cfg" network)" = off ]; then printf '[NETSETUP] network=off; original flow\n'; return 0; fi
    case "$_un_os" in
        95|98|98SE|ME) _un_app=$_un_root/USOS9X; _un_log=$_un_app/LOGS/NETSETUP.TXT; _un_helper=USOSLAN9X.EXE; _un_inf=usosnet9x.inf; _un_driver=$_un_app/NET ;;
        NT4|W2K) _un_app=$_un_root/USOS/$_un_os; _un_log=$_un_app/NETSETUP.TXT; _un_helper=USOSLANNT.EXE; _un_inf=usosnet.inf; _un_driver=$_un_root/USOS/Drivers/USOSNET ;;
    esac
    mkdir -p "$(dirname "$_un_log")" || return 1
    usos_net_log "system=$_un_os network=on ip=$(usos_net_value "$_un_cfg" ip) dns=$(usos_net_value "$_un_cfg" dns) home=$(usos_net_value "$_un_cfg" home_page)"
    _un_cards=$(usos_net_pci_cards "$_un_pci_root")
    usos_net_log "PCI=${_un_cards:-none}"
    if [ "$_un_os" = 95 ] || [ "$_un_os" = NT4 ]; then
        _un_state=ndis4_pending; usos_net_log 'usosnet: NDIS 4 build not available; NDIS 5 is not staged'
    elif [ ! -f "$_un_lib/network/usosnet.sys" ] || [ ! -f "$_un_lib/network/$_un_inf" ]; then
        _un_state=missing; usos_net_log 'usosnet: missing from build (brak w kompilacji)'
    elif [ -z "$_un_cards" ]; then _un_state=no_card; usos_net_log 'usosnet: no Ethernet card'
    else
        for _un_card in $_un_cards; do
            _un_id=$(usos_net_inf_match "$_un_lib/network/$_un_inf" "$_un_card")
            if [ -n "$_un_id" ]; then _un_hwid=$_un_id; _un_matches=$((_un_matches+1)); fi
        done
        if [ "$_un_matches" = 0 ]; then _un_state=unsupported; usos_net_log 'usosnet: card not listed in INF'
        else
            mkdir -p "$_un_driver" || return 1
            if cp "$_un_lib/network/$_un_inf" "$_un_driver/USOSNET.INF" && cp "$_un_lib/network/usosnet.sys" "$_un_driver/USOSNET.SYS" &&
               cmp -s "$_un_lib/network/$_un_inf" "$_un_driver/USOSNET.INF" && cmp -s "$_un_lib/network/usosnet.sys" "$_un_driver/USOSNET.SYS"; then
                _un_state=staged; _un_driver_path='USOS\Drivers\USOSNET'; usos_net_log "usosnet: staged $_un_hwid matches=$_un_matches; INF and PollMode unchanged"
            else
                rm -f "$_un_driver/USOSNET.INF" "$_un_driver/USOSNET.SYS"
                _un_state=copy_error; usos_net_log 'usosnet: copy/readback failed; optional package skipped'
            fi
        fi
    fi
    if [ "$(usos_net_value "$_un_cfg" ip)" != dhcp ]; then
        case "$_un_os" in
          W2K) [ "$_un_state" = staged ] && [ "$_un_matches" = 1 ] || usos_net_log 'static IP not applied: requires exactly one matched LAN adapter; DHCP remains available' ;;
          NT4) usos_net_log 'static LAN IP deferred: NT4 loopback placeholder only; NDIS 4 pending' ;;
        esac
    fi
    if [ "$_un_os" = W2K ] && [ "$_un_state" = staged ]; then
        # W2K media layouts differ in the position of $OEM$. Both existing
        # local-source roots receive only this USOS-owned package.
        for _un_oem in "$_un_root/\$WIN_NT\$.~LS/\$OEM\$" "$_un_root/\$WIN_NT\$.~LS/I386/\$OEM\$"; do
            _un_dest=$_un_oem/\$1/USOS/Drivers/USOSNET
            mkdir -p "$_un_dest" || return 1
            for _un_file in USOSNET.INF USOSNET.SYS; do
                cp "$_un_driver/$_un_file" "$_un_dest/$_un_file" && cmp -s "$_un_driver/$_un_file" "$_un_dest/$_un_file" || return 1
            done
        done
        usos_net_log 'Windows 2000 OEM LAN package copied and read back; OemPreinstall=Yes'
    fi
    awk '{sub(/\r$/, "");print $0 "\r"}' "$_un_cfg" > "$_un_app/NETCFG.INI" || return 1
    printf 'driver=%s\r\n' "$_un_state" >> "$_un_app/NETCFG.INI"
    if [ -f "$_un_lib/network/$_un_helper" ]; then
        cp "$_un_lib/network/$_un_helper" "$_un_app/USOSLAN.EXE" || return 1
        usos_net_log 'LAN helper staged: hardware desktop only; no network wait or restart'
        if [ "$_un_os" = NT4 ] || [ "$_un_os" = W2K ]; then usos_net_run_reg "$_un_os" > "$_un_app/LAN.REG" || return 1; fi
    else
        usos_net_log 'LAN helper missing from build; Setup registry defaults only'
        if [ -f "$_un_app/MSBATCH.INF" ]; then
            sed '/^HKLM,.*Run.*USOSLan,,/d' "$_un_app/MSBATCH.INF" > "$_un_app/MSBATCH.NEW" &&
              mv "$_un_app/MSBATCH.NEW" "$_un_app/MSBATCH.INF" || return 1
        fi
    fi
}

usos_net_run_reg() {
    case "$1" in NT4|W2K) ;; *) return 1 ;; esac
    printf '%s\r\n' 'REGEDIT4' '' '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows\CurrentVersion\Run]'
    printf '"USOSLan"="C:\\\\USOS\\\\%s\\\\USOSLAN.EXE"\r\n' "$1"
}

usos_net_w2k_sif() {
    # After usos_net_stage: stdin answer, stdout revised answer. No XP/2003 calls.
    USOS_NET_PATH=$_un_driver_path USOS_NET_ID=$_un_hwid USOS_NET_COUNT=$_un_matches USOS_NET_CFG=$_un_cfg awk '
      BEGIN{path=ENVIRON["USOS_NET_PATH"];id=ENVIRON["USOS_NET_ID"];
        while((getline s < ENVIRON["USOS_NET_CFG"])>0){p=index(s,"=");a[substr(s,1,p-1)]=substr(s,p+1)}
        close(ENVIRON["USOS_NET_CFG"]);static=(a["ip"]!="dhcp" && ENVIRON["USOS_NET_COUNT"]=="1" && path!="");
        if(static){split(a["ip"],v,"/");ip=v[1];bits=v[2]+0;for(i=1;i<=4;i++){n=bits>8?8:bits;if(n<0)n=0;mask=mask (i==1?"":".") (256-2^(8-n));bits-=8}}}
      {sub(/\r$/, "");low=tolower($0);if(low=="[identification]")identification=1;if(low~/^\[/){section=low;skip=(section~/^\[(networking|netclients|netprotocols|netservices|usos\.msclient|usos\.tcpip)\]$/)}}
      skip {next}
      path!=""&&low~/^oempreinstall[ \t]*=/ {next}
      path!=""&&low~/^oempnpdriverspath[ \t]*=/ {old=$0;sub(/^[^=]*=/,"",old);gsub(/^[ \t"]+|[ \t"]+$/,"",old);next}
      {lines[++nline]=$0}
      END{for(i=1;i<=nline;i++){print lines[i] "\r";
        if(path!=""&&tolower(lines[i])=="[unattended]")print "OemPreinstall=Yes\r\nOemPnPDriversPath=\"" path (old!=""?";"old:"") "\"\r"}
        if(!identification)print "\r\n[Identification]\r\nJoinWorkgroup=WORKGROUP\r";
        print "\r\n[Networking]\r\nInstallDefaultComponents=No\r\n[NetClients]\r\nMS_MSClient=USOS.MSClient\r\n[USOS.MSClient]\r\n[NetProtocols]\r\nMS_TCPIP=USOS.TCPIP\r\n[NetServices]\r\n[USOS.TCPIP]\r";
        if(static)print "AdapterSections=USOS.LAN.TCPIP\r";
        if(static){print "[NetAdapters]\r\nUSOSLAN=USOS.LAN.Adapter\r\n[USOS.LAN.Adapter]\r\nInfID=\"" id "\"\r\n[USOS.LAN.TCPIP]\r\nSpecificTo=USOSLAN\r\nDHCP=No\r\nIPAddress="ip"\r\nSubnetMask="mask"\r";
          if(a["gateway"]!="")print "DefaultGateway="a["gateway"]"\r";
          if(a["dns"]!="")print "DNSServerSearchOrder="a["dns"]"\r"}}'
}
