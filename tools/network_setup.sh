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
    # 95 OSR2 / NT4 (NDIS 4.0) never get the NDIS 5.0 usosnet.sys: their
    # driver is usosnet4.sys. 95 stages it as USOSNET.SYS beside its own INF
    # (the 9x DOS flow copies NET\USOSNET.*); NT4 has no INF installer: the IDs
    # come from usosnet.inf (same chip table) and USOSNET.REG takes over the
    # inbox loopback adapter (usos_net_nt4_reg, POST.CMD).
    _un_sys=usosnet.sys _un_dsys=USOSNET.SYS
    case "$_un_os" in
        95) _un_inf=usosnet95.inf; _un_sys=usosnet4.sys ;;
        NT4) _un_sys=usosnet4.sys; _un_dsys=USOSNET4.SYS ;;
    esac
    mkdir -p "$(dirname "$_un_log")" || return 1
    usos_net_log "system=$_un_os network=on ip=$(usos_net_value "$_un_cfg" ip) dns=$(usos_net_value "$_un_cfg" dns) home=$(usos_net_value "$_un_cfg" home_page)"
    if [ "$_un_os" = NT4 ]; then
        if ! cp "$_un_lib/network/USOSLOG.EXE" "$_un_app/USOSLOG.EXE" ||
           ! cmp -s "$_un_lib/network/USOSLOG.EXE" "$_un_app/USOSLOG.EXE"; then
            usos_net_log 'NT4 silent network evidence helper missing or copy/readback failed'
            return 1
        fi
        usos_net_log 'NT4 silent evidence helper copied and read back; first hardware desktop, no console'
    fi
    _un_cards=$(usos_net_pci_cards "$_un_pci_root")
    usos_net_log "PCI=${_un_cards:-none}"
    if [ ! -f "$_un_lib/network/$_un_sys" ] || [ ! -f "$_un_lib/network/$_un_inf" ]; then
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
            if cp "$_un_lib/network/$_un_inf" "$_un_driver/USOSNET.INF" && cp "$_un_lib/network/$_un_sys" "$_un_driver/$_un_dsys" &&
               cmp -s "$_un_lib/network/$_un_inf" "$_un_driver/USOSNET.INF" && cmp -s "$_un_lib/network/$_un_sys" "$_un_driver/$_un_dsys"; then
                _un_state=staged; _un_driver_path='USOS\Drivers\USOSNET'; usos_net_log "usosnet: staged $_un_hwid matches=$_un_matches ($_un_sys as $_un_dsys); INF and PollMode unchanged"
                if [ "$_un_os" = 95 ]; then usos_net_w95_stage; fi
                if [ "$_un_os" = NT4 ]; then
                    if usos_net_nt4_reg "$_un_cfg" > "$_un_app/USOSNET.REG"; then
                        usos_net_log 'usosnet4: USOSNET.REG staged (POST.CMD: NDISLoop -> usosnet4.sys, NDISLoop1 TCP/IP)'
                    else
                        rm -f "$_un_app/USOSNET.REG" "$_un_driver/USOSNET.INF" "$_un_driver/$_un_dsys"
                        _un_state=copy_error; usos_net_log 'usosnet4: USOSNET.REG not written; optional package skipped'
                    fi
                fi
            else
                rm -f "$_un_driver/USOSNET.INF" "$_un_driver/$_un_dsys"
                _un_state=copy_error; usos_net_log 'usosnet: copy/readback failed; optional package skipped'
            fi
        fi
    fi
    if [ "$(usos_net_value "$_un_cfg" ip)" != dhcp ]; then
        case "$_un_os" in
          W2K) [ "$_un_state" = staged ] && [ "$_un_matches" = 1 ] || usos_net_log 'static IP not applied: requires exactly one matched LAN adapter; DHCP remains available' ;;
          NT4) if [ "$_un_state" = staged ]; then usos_net_log 'static LAN IP in USOSNET.REG for the first card usosnet4 finds (NDISLoop1)'
               else usos_net_log 'static LAN IP deferred: no usosnet4 adapter staged; loopback placeholder only'; fi ;;
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

# Windows 95: the devnode instance 95 OSR2's PCI enumerator gives a card,
# from its sysfs path (/sys/devices/pci0000:00/0000:00:01.3/.../0000:08:00.0).
# On the root bus: BUS_bb&DEV_dd&FUNC_f (two hex digits each). Behind
# bridges: the devfn bytes from the card up to the root-bus bridge, then the
# root bus number, %02X each. X470 95 OSR2.1 PL registry (95-fresh2,
# read-only): I211 at 00:01.3 > 02:00.2 > 03:01.0 > 08:00.0 = 0008020B00,
# the NVMe beside it 0020020B00, the GPU under 00:03.1 = 001900, root-bus
# devices BUS_00&DEV_18&FUNC_03. Fails (no output) without a PCI chain.
usos_net_w95_instance() {
    printf '%s\n' "$1" | awk -F/ '
      function hex(h) { return (index("0123456789abcdef", substr(h, 1, 1)) - 1) * 16 + index("0123456789abcdef", substr(h, 2, 1)) - 1 }
      { for (i = 1; i <= NF; i++) { c = tolower($i)
          if (c ~ /^pci[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]$/) { root = substr(c, 9, 2); n = 0 }
          else if (c ~ /^[0-9a-f][0-9a-f][0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]\.[0-7]$/) comp[++n] = c } }
      END { if (root == "" || n < 1) exit 1
        if (n == 1) { printf "BUS_%02X&DEV_%02X&FUNC_%02X\n", hex(substr(comp[1], 6, 2)), hex(substr(comp[1], 9, 2)), substr(comp[1], 12, 1) + 0; exit }
        for (i = n; i >= 1; i--) printf "%02X", hex(substr(comp[i], 9, 2)) * 8 + substr(comp[i], 12, 1)
        printf "%02X\n", hex(root) }'
}

# Windows 95: NET95.REG (C:\USOS9X\NET; tools/w9x_reg95.sh imports it with
# REG95.REG by real-mode REGEDIT before the first Windows start on the PC):
# what 95's own installers write when the card is set up from USOSNET.INF,
# so no New Hardware step on the first desktop and TCP/IP + client bound to
# the card. The X470 in-place kit 95-net wrote the same values (2026-10-20,
# PASS). The devnode Enum\PCI\<id>\<instance> is made ahead of 95's PnP
# pass, bound to Class\Net\0009 (usosnet95.inf AddReg values), TCP/IP
# NetTrans\0009 (DHCP) on it, Client for Microsoft Networks NetClient\0009
# with the MSNP32 provider (no file and printer sharing). Network\Logon
# (Windows Logon as the primary logon) comes from REG95 itself for every 95
# install (tools/w9x_reg95.sh). Instance numbers
# 0009: free in every 95 registry USOS made (Setup uses 0000-0002).
# Args: INF PCI id, devnode instance, card description, INF model section.
# CRLF out.
usos_net_w95_reg() {
    _un_ide=$(printf '%s' "$1" | sed 's/\\/\\\\/g')
    _un_k='HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\Class'
    sed -e "s|@K@|$(printf '%s' "$_un_k" | sed 's/\\/\\\\/g')|g" -e "s|@ENUM@|$(printf '%s' "$1\\$2" | sed 's/\\/\\\\/g; s/&/\\&/g')|g" \
        -e "s|@IDE@|$(printf '%s' "$_un_ide" | sed 's/\\/\\\\/g; s/&/\\&/g')|g" -e "s|@DESC@|$(printf '%s' "$3" | sed 's/[\\&|]/\\&/g')|g" \
        -e "s|@SECT@|${4:-USOSNETI211.ndi}|g" -e 's/$/\r/' <<'EOF'
REGEDIT4

[@K@\Net\0009]
"DriverDesc"="@DESC@"
"InfPath"="USOSNET.INF"
"InfSection"="@SECT@"
"ProviderName"="Universal Service OS"
"DriverDate"="10-20-2026"
"MatchingDeviceId"="@IDE@"
"DevLoader"="*ndis"
"DeviceVxDs"="usosnet.sys"
"EnumPropPages"="netdi.dll,EnumPropPages"
"PollMode"="0"
"SkipPhy"="0"
"DebugPort"="0"

[@K@\Net\0009\Ndi]
"DeviceID"="@IDE@"
"HelpText"="USOS own NDIS 4.0 driver for Intel I211 / I210 / 82576 Ethernet (Windows 95 OSR2)."
"InstallInf"=""

[@K@\Net\0009\Ndi\params\DebugPort]
"ParamDesc"="Debug I/O port (decimal; 233 = E9h in QEMU; 0 = off)"
"type"="dword"
"default"="0"
"min"="0"
"max"="65535"

[@K@\Net\0009\Ndi\params\NetworkAddress]
"ParamDesc"="Network Address"
"type"="edit"
"LimitText"="12"
"UpperCase"="1"
"optional"="1"
"default"=""

[@K@\Net\0009\Ndi\params\PollMode]
"ParamDesc"="Poll mode (no interrupt, diagnostics)"
"type"="enum"
"default"="0"

[@K@\Net\0009\Ndi\params\PollMode\enum]
"0"="Off"
"1"="On"

[@K@\Net\0009\Ndi\params\SkipPhy]
"ParamDesc"="Skip PHY setup (diagnostics)"
"type"="enum"
"default"="0"

[@K@\Net\0009\Ndi\params\SkipPhy\enum]
"0"="Off"
"1"="On"

[@K@\Net\0009\Ndi\Interfaces]
"DefUpper"="ndis3"
"DefLower"="ethernet"
"UpperRange"="ndis3"
"LowerRange"="ethernet"
"Upper"="ndis3"
"Lower"="ethernet"

[@K@\Net\0009\Ndi\Install]
"ndis3"="USOSNET.ndis3"

[@K@\Net\0009\NDIS]
"LogDriverName"="USOSNET"
"MajorNdisVersion"=hex:04
"MinorNdisVersion"=hex:00

[HKEY_LOCAL_MACHINE\Enum\@ENUM@]
"Class"="Net"
"Driver"="Net\\0009"
"Mfg"="Intel"
"DeviceDesc"="@DESC@"

[HKEY_LOCAL_MACHINE\Enum\@ENUM@\Bindings]
"MSTCP\\0009"=""

[@K@\NetTrans\0009]
"DriverDesc"="TCP/IP"
"IPAddress"="0.0.0.0"
"IPMask"="0.0.0.0"
"DeviceVxDs"="vtdi.386,vip.386,vtcp.386,vdhcp.386,vnbt.386"
"InstallVnbt"="0"
"InfPath"="NETTRANS.INF"
"DevLoader"="*ndis"

[@K@\NetTrans\0009\Ndi]
"DeviceID"="MSTCP"
"MaxInstance"="8"
"NdiInstaller"="mstcp.dll,TcpNdiProc"
"InstallInf"=""
"InfSection"="MSTCP.ndi"

[@K@\NetTrans\0009\Ndi\Interfaces]
"DefUpper"="netbios,tdi,winsock"
"DefLower"="ndis2,ndis3,odi"
"UpperRange"="netbios,tdi,winsock"
"LowerRange"="ndis2,ndis3,odi"
"Upper"="netbios,tdi,winsock"
"Lower"="ndis2,ndis3,odi"

[@K@\NetTrans\0009\Ndi\Install]
@="MSTCP.Install"

[@K@\NetTrans\0009\Ndi\Remove]
@="MSTCP.Remove"

[@K@\NetTrans\0009\Ndi\Default]
@="True"

[@K@\NetTrans\0009\NDIS]
"LogDriverName"="MSTCP"
"MajorNdisVersion"=hex:03
"MinorNdisVersion"=hex:0a

[HKEY_LOCAL_MACHINE\Enum\Network\MSTCP\0009]
"Class"="NetTrans"
"Driver"="NetTrans\\0009"
"MasterCopy"="Enum\\Network\\MSTCP\\0009"
"DeviceDesc"="TCP/IP"
"CompatibleIDs"="MSTCP"
"Mfg"="Microsoft"
"ConfigFlags"=hex:00,00,00,00

[HKEY_LOCAL_MACHINE\Enum\Network\MSTCP\0009\Bindings]
"VREDIR\\0009"=""

[@K@\NetClient\0009]
"DriverDesc"="Client for Microsoft Networks"
"InfPath"="NETCLI.INF"
"InfSection"="VREDIR.ndi"
"DevLoader"="*ndis"
"DeviceVxDs"="vredir.vxd"

[@K@\NetClient\0009\Ndi]
"DeviceID"="VREDIR"
"NdiInstaller"="netdi.dll,MSClientNdiProc"
"NetworkProvider"="Microsoft Network"
"InstallInf"=""

[@K@\NetClient\0009\Ndi\Interfaces]
"DefUpper"="winnet4,vredir"
"UpperRange"="winnet4,vredir"
"DefLower"="netbios,ipxDHost"
"LowerRange"="netbios,ipxDHost"
"ExcludeAny"="winnet31"
"Upper"="winnet4,vredir"
"Lower"="netbios,ipxDHost"

[@K@\NetClient\0009\Ndi\Install]
@="VREDIR.Install"

[@K@\NetClient\0009\Ndi\Remove]
@="VREDIR.Remove"

[HKEY_LOCAL_MACHINE\Enum\Network\VREDIR\0009]
"Class"="NetClient"
"Driver"="NetClient\\0009"
"MasterCopy"="Enum\\Network\\VREDIR\\0009"
"DeviceDesc"="Client for Microsoft Networks"
"CompatibleIDs"="VREDIR"
"Mfg"="Microsoft"
"ConfigFlags"=hex:00,00,00,00

[HKEY_LOCAL_MACHINE\Enum\Network\VREDIR\0009\Bindings]

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\VxD\VREDIR]
"StaticVxD"="vredir.vxd"
"Start"=hex:00
"NetClean"=hex:01

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\control\NetworkProvider\Order]
"MSNP32"=""

[HKEY_LOCAL_MACHINE\System\CurrentControlSet\Services\MSNP32\NetworkProvider]
"Name"="Microsoft Network"
"ProviderPath"="msnp32.dll"
"Description"="Microsoft Network"
"NetID"=hex:00,00,01,00
"CallOrder"=hex:00,00,00,40

EOF
}

# 95, after USOSNET.INF / USOSNET.SYS were staged: NET95.REG for exactly
# one matched card whose PCI path gives a 95 devnode instance; otherwise
# PnP + USOSNET.INF only (95's New Hardware step). Logged either way.
# USOS_NET_W95_PATH (tests): the card's sysfs path instead of cd -P.
usos_net_w95_stage() {
    rm -f "$_un_driver/NET95.REG"
    if [ "$_un_matches" != 1 ]; then usos_net_log "usosnet4: $_un_matches matched cards; no NET95.REG (PnP + USOSNET.INF)"; return 0; fi
    _un_dev=''
    for _un_pci in "$_un_pci_root"/*; do
        [ -d "$_un_pci" ] || continue
        _un_v=$(cat "$_un_pci/vendor" 2>/dev/null || true); _un_d=$(cat "$_un_pci/device" 2>/dev/null || true)
        [ "$(printf 'PCI\\VEN_%s&DEV_%s' "${_un_v#0x}" "${_un_d#0x}" | tr 'a-f' 'A-F')" = "$_un_hwid" ] || continue
        _un_dev=$(cd -P "$_un_pci" 2>/dev/null && pwd -P) || _un_dev=$_un_pci
        break
    done
    [ -z "${USOS_NET_W95_PATH:-}" ] || _un_dev=$USOS_NET_W95_PATH
    if ! _un_inst=$(usos_net_w95_instance "$_un_dev"); then
        usos_net_log "usosnet4: no PCI path for $_un_hwid ($_un_dev); no NET95.REG (PnP + USOSNET.INF)"; return 0
    fi
    # The card's DeviceDesc from USOSNET.INF ([Strings] of its model line).
    _un_desc=$(USOS_NET_ID=$_un_hwid awk '
        { sub(/\r$/, "") } /^\[/ { sec = tolower($0); next }
        sec == "[strings]" && index($0, "=") { k = $0; sub(/[ \t]*=.*/, "", k); v = $0; sub(/^[^=]*=[ \t]*/, "", v); gsub(/"/, "", v); str[tolower(k)] = v; next }
        /^%/ && index(toupper($0), toupper(ENVIRON["USOS_NET_ID"])) { d = $0; sub(/^%/, "", d); sub(/%.*/, "", d); want = tolower(d)
            m = $0; sub(/^[^=]*=[ \t]*/, "", m); sub(/[ \t]*,.*/, "", m); sect = m }
        END { print ((want in str) ? str[want] : "USOS usosnet Ethernet") "|" sect }' "$_un_driver/USOSNET.INF")
    _un_sect=${_un_desc##*|}; _un_desc=${_un_desc%|*}
    if usos_net_w95_reg "$_un_hwid" "$_un_inst" "$_un_desc" "$_un_sect" > "$_un_driver/NET95.REG"; then
        usos_net_log "usosnet4: NET95.REG staged: Enum\\$_un_hwid\\$_un_inst -> Net\\0009, TCP/IP NetTrans\\0009 (DHCP), client NetClient\\0009; path $_un_dev"
    else
        rm -f "$_un_driver/NET95.REG"; usos_net_log 'usosnet4: NET95.REG not written (PnP + USOSNET.INF)'
    fi
    [ "$(usos_net_value "$_un_cfg" ip)" = dhcp ] || usos_net_log 'static LAN IP not applied on 95: NET95.REG uses DHCP'
}

# REG_MULTI_SZ for NT 4.0 regedit (REGEDIT4: ANSI bytes, NT widens them):
# each argument one string, an empty argument list = the empty list.
usos_net_hex7() {
    printf 'hex(7):'
    { [ $# -gt 0 ] || printf '\000'; for _un_s in "$@"; do printf '%s\000' "$_un_s"; done; printf '\000'; } |
        od -An -v -tx1 | tr -s ' \n' '  ' | sed 's/^ //; s/ $//; s/ /,/g'
}

# NT4: USOSNET.REG for POST.CMD (after usos_net_stage staged usosnet4.sys).
# NT 4.0 has no INF installer for a PCI miniport; the unattended answer
# installs the inbox MS Loopback Adapter (network_defaults.zig: LOOP + TCP/IP;
# OEMNADLB.INF: driver service NDISLoop, adapter NDISLoop1) with every
# binding (TCP/IP, NetBT, Workstation) computed by Setup. This takes that
# adapter over: the NDISLoop service loads usosnet4.sys instead of loop.sys
# (NDIS starts the miniport for NDISLoop's Linkage\Bind \Device\NDISLoop1
# with NDISLoop1\Parameters), BusType 5 (PCI; the driver finds the bus and
# slot itself) and the adapter's TCP/IP becomes DHCP or the profile's
# static address. The Network applet still names the loopback adapter.
# Auto-start is required for TCP/IP binding: matched native NT4 cold boots
# of the same installed image have no adapter at Start=3, DHCP at Start=2.
usos_net_nt4_reg() {
    _un_ip=$(usos_net_value "$1" ip); _un_gw=$(usos_net_value "$1" gateway); _un_dns=$(usos_net_value "$1" dns)
    printf '%s\r\n' 'REGEDIT4' '' \
        '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NDISLoop]' \
        '"ImagePath"="\\SystemRoot\\System32\\drivers\\usosnet4.sys"' \
        '"Start"=dword:00000002' '' \
        '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NDISLoop1\Parameters]' \
        '"BusType"=dword:00000005' '"BusNumber"=dword:00000000' '"PollMode"=dword:00000000' '' \
        '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\NDISLoop1\Parameters\Tcpip]'
    if [ "$_un_ip" = dhcp ]; then
        printf '%s\r\n' '"EnableDHCP"=dword:00000001' \
            "\"IPAddress\"=$(usos_net_hex7 0.0.0.0)" "\"SubnetMask\"=$(usos_net_hex7 0.0.0.0)" \
            "\"DefaultGateway\"=$(usos_net_hex7)"
    else
        _un_mask=$(printf '%s\n' "${_un_ip#*/}" | awk '{b=$1;for(i=1;i<=4;i++){n=b>8?8:b;if(n<0)n=0;m=m (i==1?"":".") (256-2^(8-n))%256;b-=8}print m}')
        printf '%s\r\n' '"EnableDHCP"=dword:00000000' \
            "\"IPAddress\"=$(usos_net_hex7 "${_un_ip%/*}")" "\"SubnetMask\"=$(usos_net_hex7 "$_un_mask")"
        if [ -n "$_un_gw" ]; then printf '"DefaultGateway"=%s\r\n' "$(usos_net_hex7 "$_un_gw")"
        else printf '"DefaultGateway"=%s\r\n' "$(usos_net_hex7)"; fi
    fi
    if [ -n "$_un_dns" ]; then
        printf '\r\n%s\r\n"NameServer"="%s"\r\n' '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters]' "$(printf '%s' "$_un_dns" | tr ',' ' ')"
    fi
    # The DHCP client: Setup may leave it on demand when every adapter was static.
    if [ "$_un_ip" = dhcp ]; then
        printf '\r\n%s\r\n%s\r\n' '[HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services\DHCP]' '"Start"=dword:00000002'
    fi
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
