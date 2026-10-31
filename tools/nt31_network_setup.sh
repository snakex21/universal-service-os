# Native NT 3.1 LAN (docs/nt-native-plan.md section 8.10). Sourced
# functions; sourcing performs no writes. Only nt4_csmwrap_target.sh's
# native NT 3.1 path (nt31_native) calls them.
#
# NT 3.1 has no DHCP client (DHCP came with NT 3.5) and no miniport NDIS:
#   driver   usosnet31 (own NDIS 3.1 full-MAC build, polled, CF8h/CFCh; file
#            alignment 0x200, so the NT 3.1 loader takes it as a system /
#            auto start driver), staged as \USOS\NT3\USNET31.SYS (8.3: NT 3.1
#            FAT has no long names); USOSNT3 /net31 puts it in place of the
#            MS Loopback Adapter's LOOP.SYS (service NDISLoop, adapter
#            NDISLoop1) that GUI Setup installs, as on native NT 3.5x;
#   address  static. Source, in this order: the answer profile's static
#            values (;USOS-IP=a.b.c.d/n, GATEWAY, DNS); else a DHCP lease
#            taken here, in the prep Linux on the same PC, for the same NIC
#            and MAC (igb + busybox udhcpc, bounded, no release, so the
#            router keeps the address for that MAC); else a link-local
#            169.254.x.y/16 from the MAC (TCP/IP starts, no route out).
#            NET31.ON records which one was used.
usos_nt31_requested() {
    awk '/^;USOS-NT31-NETWORK=/{sub(/\r$/,"");n++;v=substr($0,index($0,"=")+1)}
      END{if(n>1||(n==1&&v!="on"&&v!="off"))exit 1;print n?v:"off"}' "$1"
}

usos_nt31_workgroup() {
    awk '/^;USOS-NT31-WORKGROUP=/{sub(/\r$/,"");n++;v=substr($0,index($0,"=")+1)}
      END{if(n>1)exit 1;if(!n)v="WORKGROUP";v=toupper(v);if(length(v)<1||length(v)>15||v~/[^A-Z0-9-]/||v~/^-|-$/)exit 1;print v}' "$1"
}

# Dotted mask for a prefix length 1..30.
usos_nt31_mask() {
    awk -v n="$1" 'BEGIN{if(n!~/^[0-9]+$/||n<1||n>30)exit 1;for(i=0;i<4;i++){b=(n>=8)?8:(n>0?n:0);n-=b;v=256-2^(8-b);if(v==256)v=0;o=o (i?".":"") (b==8?255:v)}print o}'
}

# A dotted IPv4 address (unicast, not 0/127/224+), else rc 1.
usos_nt31_ipv4() {
    printf '%s\n' "$1" | awk -F. 'NF!=4{exit 1}{for(i=1;i<=4;i++)if($i!~/^[0-9]+$/||length($i)>3||$i>255)exit 1;if($1==0||$1==127||$1>=224)exit 1}'
}

# usosnet31's PCI ids (U31PciValid): Intel I211 (X470) and 82576.
usos_nt31_supported() {
    case "$1:$2" in 0x8086:0x1539|0x8086:0x10c9|0x8086:0x10C9) return 0 ;; esac
    return 1
}

usos_nt31_preflight() {
    # ANSWER LIB PCI_ROOT. Before any target write. Sets _u31_enabled and,
    # when on, the driver, the card's BDF and the profile address values;
    # _u31_off_why says why it stays off (logged and written to the target
    # as \USOS\NT3\NET31.OFF by nt31_native).
    _u31_answer=$1 _u31_lib=$2 _u31_pci=$3 _u31_off_why=''
    _u31_enabled=$(usos_nt31_requested "$_u31_answer") || { _u31_enabled=off; _u31_off_why='bad ;USOS-NT31-NETWORK line'; return 1; }
    [ "$_u31_enabled" = on ] || { _u31_off_why='network off in the answer profile (no ;USOS-NT31-NETWORK=on)'; return 0; }
    _u31_enabled=off
    _u31_group=$(usos_nt31_workgroup "$_u31_answer") || { _u31_off_why='bad workgroup name'; return 1; }
    . "$_u31_lib/network_setup.sh" || { _u31_off_why='network_setup.sh missing'; return 1; }
    _u31_config=$(usos_net_answer_config "$_u31_answer" NT4) || { _u31_off_why='profile LAN keys unreadable (duplicate ;USOS-NETWORK/IP/GATEWAY/DNS?)'; return 1; }
    printf '%s\n' "$_u31_config" | grep -qx 'network=on' || { _u31_off_why='no ;USOS-NETWORK=on'; return 1; }
    _u31_pip=$(printf '%s\n' "$_u31_config" | awk -F= '$1=="ip"{sub(/^[^=]*=/,"");print;exit}')
    _u31_pgw=$(printf '%s\n' "$_u31_config" | awk -F= '$1=="gateway"{sub(/^[^=]*=/,"");print;exit}')
    _u31_pdns=$(printf '%s\n' "$_u31_config" | awk -F= '$1=="dns"{sub(/^[^=]*=/,"");print;exit}')
    if [ "$_u31_pip" != dhcp ]; then
        printf '%s\n' "$_u31_config" > "${TMPDIR:-/tmp}/u31cfg.$$" && usos_net_valid_config "${TMPDIR:-/tmp}/u31cfg.$$" ||
            { rm -f "${TMPDIR:-/tmp}/u31cfg.$$"; _u31_off_why="invalid static profile address ($_u31_pip gw $_u31_pgw)"; return 1; }
        rm -f "${TMPDIR:-/tmp}/u31cfg.$$"
    fi
    _u31_sys=$_u31_lib/nt3/USOSNET31.SYS _u31_sha=$_u31_lib/nt3/USOSNET31.SHA256
    [ -r "$_u31_sys" ] && [ -r "$_u31_sha" ] || { _u31_off_why='USOSNET31.SYS / .SHA256 missing from this build'; return 1; }
    _u31_expected=$(awk 'NR==1{print $1}' "$_u31_sha")
    printf '%s\n' "$_u31_expected" | grep -Eq '^[0-9a-f]{64}$' || { _u31_off_why='bad USOSNET31.SHA256'; return 1; }
    _u31_actual=$(sha256sum "$_u31_sys" | awk '{print $1}') || { _u31_off_why='sha256sum failed'; return 1; }
    [ "$_u31_actual" = "$_u31_expected" ] || { _u31_off_why='USOSNET31.SYS hash mismatch'; return 1; }
    _u31_matches=0 _u31_bdf='' _u31_seen=''
    for _u31_node in "$_u31_pci"/*; do
        [ -d "$_u31_node" ] || continue
        _u31_class=$(cat "$_u31_node/class" 2>/dev/null || true)
        case "$_u31_class" in 0x0200*) ;; *) continue ;; esac
        _u31_v=$(cat "$_u31_node/vendor" 2>/dev/null || true) _u31_d=$(cat "$_u31_node/device" 2>/dev/null || true)
        _u31_seen="$_u31_seen ${_u31_node##*/}=$_u31_v:$_u31_d"
        usos_nt31_supported "$_u31_v" "$_u31_d" || continue
        # The slot name (sysfs: the folder name, also PCI_SLOT_NAME in uevent).
        _u31_slot=$(awk -F= '$1=="PCI_SLOT_NAME"{print $2;exit}' "$_u31_node/uevent" 2>/dev/null || true)
        _u31_matches=$((_u31_matches + 1)) _u31_bdf=${_u31_slot:-${_u31_node##*/}} _u31_nodepath=$_u31_node
        _u31_dev_id=$_u31_d
    done
    [ "$_u31_matches" = 1 ] || { _u31_off_why="$_u31_matches supported Ethernet cards (seen:${_u31_seen:- none})"; return 1; }
    printf '%s\n' "$_u31_bdf" | grep -Eq '^0000:[0-9a-fA-F]{2}:[01][0-9a-fA-F]\.[0-7]$' || { _u31_off_why="unexpected PCI slot name $_u31_bdf"; return 1; }
    _u31_rest=${_u31_bdf#0000:}
    _u31_bus=$(printf '%d' "0x${_u31_rest%%:*}") || { _u31_off_why="bad bus in $_u31_bdf"; return 1; }
    _u31_rest=${_u31_rest#*:}
    _u31_dev=$(printf '%d' "0x${_u31_rest%.*}") || { _u31_off_why="bad device in $_u31_bdf"; return 1; }
    _u31_fn=${_u31_rest#*.}
    _u31_enabled=on
}

# busybox applet or the real tool.
usos_nt31_bb() { if command -v "$1" >/dev/null 2>&1; then "$@"; else busybox "$@"; fi; }

# The DHCP lease of the preflight's card: igb + udhcpc, at most ~60 s.
# rc 0 with _u31_ip/_u31_mask/_u31_gw/_u31_dns/_u31_domain/_u31_lease/
# _u31_server set; rc 1 without a lease. WORK_DIR HOSTNAME.
usos_nt31_dhcp() {
    _u31_work=$1 _u31_host=$2 _u31_if='' _u31_mac=''
    modprobe af_packet 2>/dev/null || true
    modprobe igb 2>/dev/null || { _u31_why='igb module not loaded'; return 1; }
    _u31_i=0
    while [ "$_u31_i" -lt 20 ] && [ -z "$_u31_if" ]; do
        for _u31_n in "$_u31_nodepath"/net/*; do [ -e "$_u31_n" ] && _u31_if=${_u31_n##*/}; done
        [ -n "$_u31_if" ] || { sleep 1; _u31_i=$((_u31_i + 1)); }
    done
    [ -n "$_u31_if" ] || { _u31_why='no network interface for the card'; usos_nt31_dhcp_end; return 1; }
    _u31_mac=$(cat "${USOS_NET_CLASS:-/sys/class/net}/$_u31_if/address" 2>/dev/null || true)
    usos_nt31_bb ip link set dev "$_u31_if" up 2>/dev/null || { _u31_why='link up failed'; usos_nt31_dhcp_end; return 1; }
    _u31_i=0
    while [ "$_u31_i" -lt 15 ] && [ "$(cat "${USOS_NET_CLASS:-/sys/class/net}/$_u31_if/carrier" 2>/dev/null)" != 1 ]; do
        sleep 1; _u31_i=$((_u31_i + 1))
    done
    if [ "$(cat "${USOS_NET_CLASS:-/sys/class/net}/$_u31_if/carrier" 2>/dev/null)" != 1 ]; then
        _u31_why='no link (cable?)'; usos_nt31_dhcp_end; return 1
    fi
    rm -f "$_u31_work/u31.lease"
    cat > "$_u31_work/u31-dhcp.sh" <<'EOF'
#!/bin/sh
case "$1" in bound|renew)
    printf 'ip=%s\nmask=%s\nrouter=%s\ndns=%s\ndomain=%s\nlease=%s\nserver=%s\n' \
        "$ip" "$subnet" "$router" "$dns" "$domain" "$lease" "$serverid" > "$U31_LEASE" ;;
esac
exit 0
EOF
    chmod 755 "$_u31_work/u31-dhcp.sh"
    # -q: exit with the lease, no release (the router keeps the address for
    # this MAC); -n: give up after 5 tries x 4 s.
    U31_LEASE=$_u31_work/u31.lease
    export U31_LEASE
    usos_nt31_bb udhcpc -f -q -n -t 5 -T 4 -A 2 -i "$_u31_if" \
        -s "$_u31_work/u31-dhcp.sh" -x "hostname:$_u31_host" >/dev/null 2>&1 || true
    usos_nt31_dhcp_end
    [ -s "$_u31_work/u31.lease" ] || { _u31_why='no DHCP answer'; return 1; }
    _u31_val() { awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$_u31_work/u31.lease"; }
    _u31_ip=$(_u31_val ip) _u31_mask=$(_u31_val mask)
    _u31_gw=$(_u31_val router | awk '{print $1}')
    _u31_dns=$(_u31_val dns | awk '{for(i=1;i<=NF&&i<=3;i++)printf "%s%s",(i>1?" ":""),$i}')
    _u31_domain=$(_u31_val domain | awk '{print $1}' | tr -cd 'A-Za-z0-9.-')
    _u31_lease=$(_u31_val lease | tr -cd 0-9) _u31_server=$(_u31_val server | tr -cd 0-9.)
    rm -f "$_u31_work/u31.lease" "$_u31_work/u31-dhcp.sh"
    usos_nt31_ipv4 "$_u31_ip" || { _u31_why="lease without a usable address ($_u31_ip)"; return 1; }
    printf '%s\n' "$_u31_mask" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || { _u31_why='lease without a subnet mask'; return 1; }
    [ -z "$_u31_gw" ] || usos_nt31_ipv4 "$_u31_gw" || _u31_gw=''
    return 0
}
# The card's MAC without DHCP (static profile address): igb loaded only to
# read it, then unloaded. Sets _u31_mac ('' when it cannot).
usos_nt31_read_mac() {
    _u31_if='' _u31_mac=''
    modprobe igb 2>/dev/null || return 0
    _u31_i=0
    while [ "$_u31_i" -lt 10 ] && [ -z "$_u31_if" ]; do
        for _u31_n in "$_u31_nodepath"/net/*; do [ -e "$_u31_n" ] && _u31_if=${_u31_n##*/}; done
        [ -n "$_u31_if" ] || { sleep 1; _u31_i=$((_u31_i + 1)); }
    done
    [ -z "$_u31_if" ] || _u31_mac=$(cat "${USOS_NET_CLASS:-/sys/class/net}/$_u31_if/address" 2>/dev/null || true)
    modprobe -r igb 2>/dev/null || true
}
usos_nt31_dhcp_end() {
    [ -z "$_u31_if" ] || usos_nt31_bb ip link set dev "$_u31_if" down 2>/dev/null || true
    modprobe -r igb 2>/dev/null || true
}

usos_nt31_address() {
    # WORK_DIR HOSTNAME. After the preflight; sets _u31_mode and the values.
    _u31_ip='' _u31_mask='' _u31_gw='' _u31_dns='' _u31_domain='' _u31_lease='' _u31_server='' _u31_why='' _u31_mac=''
    if [ "$_u31_pip" != dhcp ]; then
        _u31_mode=profile _u31_ip=${_u31_pip%/*}
        _u31_mask=$(usos_nt31_mask "${_u31_pip#*/}") || return 1
        _u31_gw=$_u31_pgw _u31_dns=$(printf '%s' "$_u31_pdns" | tr ',' ' ')
        usos_nt31_read_mac
        return 0
    fi
    if usos_nt31_dhcp "$1" "$2"; then
        _u31_mode=dhcp
        # Profile DNS servers win over the lease's.
        [ -z "$_u31_pdns" ] || _u31_dns=$(printf '%s' "$_u31_pdns" | tr ',' ' ')
        return 0
    fi
    # No lease: link-local from the MAC (TCP/IP and NetBT start without
    # errors; no route out). The profile's DNS stays.
    _u31_mode=linklocal
    _u31_a=86 _u31_b=31
    if printf '%s\n' "$_u31_mac" | grep -Eq '^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$'; then
        _u31_a=$(printf '%d' "0x$(printf '%s' "$_u31_mac" | cut -d: -f5)")
        _u31_b=$(printf '%d' "0x$(printf '%s' "$_u31_mac" | cut -d: -f6)")
        { [ "$_u31_a" -ge 1 ] && [ "$_u31_a" -le 254 ]; } || _u31_a=86
        { [ "$_u31_b" -ge 1 ] && [ "$_u31_b" -le 254 ]; } || _u31_b=31
    fi
    _u31_ip=169.254.$_u31_a.$_u31_b
    _u31_mask=255.255.0.0
    _u31_dns=$(printf '%s' "$_u31_pdns" | tr ',' ' ')
}

usos_nt31_stage() {
    # TARGET_ROOT PRODUCT(0 WS / 1 AS). After usos_nt31_address.
    [ "${_u31_enabled:-off}" = on ] || return 0
    _u31_dir=$1/USOS/NT3
    mkdir -p "$_u31_dir" || return 1
    cp "$_u31_sys" "$_u31_dir/USNET31.SYS" && cmp -s "$_u31_sys" "$_u31_dir/USNET31.SYS" || return 1
    _u31_client=keep
    [ "$2" != 0 ] || _u31_client=no-sharing
    printf 'network=on\r\nmode=%s\r\nip=%s\r\nmask=%s\r\ngateway=%s\r\ndns=%s\r\ndomain=%s\r\nlease_s=%s\r\ndhcp_server=%s\r\nnote=%s\r\nbus=%s\r\ndevice=%s\r\nfunction=%s\r\npci_id=8086:%s\r\nsha256=%s\r\nworkgroup=%s\r\nclient=%s\r\nmac=%s\r\n' \
        "$_u31_mode" "$_u31_ip" "$_u31_mask" "$_u31_gw" "$_u31_dns" "$_u31_domain" "$_u31_lease" "$_u31_server" "$_u31_why" \
        "$_u31_bus" "$_u31_dev" "$_u31_fn" "${_u31_dev_id#0x}" "$_u31_actual" "$_u31_group" "$_u31_client" "$(printf %s "${_u31_mac:-}" | tr -d : | tr a-f A-F)" > "$_u31_dir/NET31.ON" || return 1
    printf '[NET31] usosnet31 sha256=%s at %s; TCP/IP static %s %s/%s gw %s dns %s%s\n' "$_u31_actual" "$_u31_bdf" \
        "$_u31_mode" "$_u31_ip" "$_u31_mask" "${_u31_gw:-none}" "${_u31_dns:-none}" "${_u31_why:+ ($_u31_why)}"
}

# GUI Setup INF filters for the local source (stdin -> stdout, CR LF; rc 1
# when the anchor is not there exactly once).
#
# NTLANMAN.INF [ProtoData]: TCP/IP after NetBEUI (OEMNXPTC.INF option
# TCPIP, no billboard). Its files come from the local source with the rest
# of the network copy list (NTLANMAN Install-All-Files-Now).
usos_nt31_ntlanman_tcpip() {
    awk -v BINMODE=3 '
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low); printf "%s\r\n", line }
        low ~ /^protodata_1="oemnxpnb\.inf","nbf",/ { printf "ProtoData_2        = \"OEMNXPTC.INF\",\"TCPIP\",0,Tcpip\r\n"; hit++ }
        low ~ /^protodata_2=/ { other++ }
        END { if (hit != 1 || other) { print "NTLANMAN.INF: no single [ProtoData] NBF row" > "/dev/stderr"; exit 1 } }'
}

# OEMNXPTC.INF configureadapter: while HKLM\SOFTWARE\USOS\NT31NET exists
# (INITIAL.INF creates it right before the network part of GUI Setup;
# USOSNT3 /net31 deletes it at the end): the INF's own per-card default
# writer puts IP ($1) / mask ($2) into each bound card's Parameters\TCPIP
# (as ipinfo.inf defaults would), the gateway ($3) goes to Tcpip\Parameters,
# and the address dialog (CPlTcpip) and the "cannot configure" note are
# skipped. So TCP/IP and LmHosts start with an address when NTLANMAN starts
# the network; USOSNT3 /net31 writes the final values again. Later Control
# Panel runs (no marker) keep the CD behaviour.
usos_nt31_oemnxptc() {
    awk -v BINMODE=3 -v ip="${1:-$_u31_ip}" -v mask="${2:-$_u31_mask}" -v gw="${3-$_u31_gw}" '
        function out(t) { printf "%s\r\n", t }
        { line = $0; sub(/\r$/, "", line); low = tolower(line); gsub(/[ \t]/, "", low) }
        sec == "skip" && low == "endforlistdo" {
            out(line)
            out("; USOS: native NT 3.1 Setup, no address dialog (USOSNT3 /net31)")
            out("        ifint $(UsosNet31) == 1")
            if (gw != "") {
                out("            OpenRegKey $(!REG_H_LOCAL) \"\" $(ServiceTCPIPKeyName)\"\\Parameters\" 33554432 UsosNet31Par")
                out("            ifstr(i) $(UsosNet31Par) != \"\"")
                out("                SetRegValue $(UsosNet31Par) {DefaultGateway,0,$(!REG_VT_SZ),\"" gw "\"}")
                out("                CloseRegKey $(UsosNet31Par)")
                out("            endif")
            }
            # TCPIPSVC needs these DWORDs per card (the NCPA dialog writes them).
            out("            ForListDo *($(BindList),4)")
            out("                Split-String $($), \"\\\", UsosNet31Bind")
            out("                OpenRegKey $(!REG_H_LOCAL) \"\" $(!NTN_ServiceBase)\"\\\"*($(UsosNet31Bind),6)\"\\Parameters\\TCPIP\" 33554432 UsosNet31Tcp")
            out("                ifstr(i) $(UsosNet31Tcp) != \"\"")
            out("                    SetRegValue $(UsosNet31Tcp) {ForwardBroadcasts,0,$(!REG_VT_DWORD),0}")
            out("                    SetRegValue $(UsosNet31Tcp) {KeepAlive,0,$(!REG_VT_DWORD),0}")
            out("                    SetRegValue $(UsosNet31Tcp) {BroadcastType,0,$(!REG_VT_DWORD),1}")
            out("                    SetRegValue $(UsosNet31Tcp) {Trailers,0,$(!REG_VT_DWORD),0}")
            out("                    CloseRegKey $(UsosNet31Tcp)")
            out("                endif")
            out("            EndForListDo")
            # NbtSvc needs Nbt\Parameters ScopeID (empty = no scope).
            out("            OpenRegKey $(!REG_H_LOCAL) \"\" $(!NTN_ServiceBase)\"\\Nbt\\Parameters\" 33554432 UsosNet31Nbt")
            out("            ifstr(i) $(UsosNet31Nbt) != \"\"")
            out("                SetRegValue $(UsosNet31Nbt) {ScopeID,0,$(!REG_VT_SZ),\"\"}")
            out("                CloseRegKey $(UsosNet31Nbt)")
            out("            endif")
            out("            set CommonStatus = STATUS_SUCCESSFUL")
            out("            goto end")
            out("        endif")
            sec = ""; tail++; next
        }
        low == "skipsetdefault=+" { sec = "skip" }
        low == "read-symsinfodlgcantconfigure" {
            out("; USOS: native NT 3.1 Setup, no note")
            out("            ifint $(UsosNet31) == 1")
            out("                set CommonStatus = STATUS_SUCCESSFUL")
            out("                goto end")
            out("            endif")
            note++
        }
        { out(line) }
        low == "configureadapter=+" {
            out("; USOS: native NT 3.1 Setup (SOFTWARE\\USOS\\NT31NET): the address USOS chose")
            out("    set UsosNet31 = 0")
            out("    OpenRegKey $(!REG_H_LOCAL) \"\" \"SOFTWARE\\USOS\\NT31NET\" 33554432 UsosNet31Key")
            out("    ifstr(i) $(UsosNet31Key) != \"\"")
            out("        CloseRegKey $(UsosNet31Key)")
            out("        set UsosNet31 = 1")
            out("        set IPAddressList  = {\"" ip "\"}")
            out("        set SubnetMaskList = {\"" mask "\"}")
            out("    endif")
            hit++
        }
        END { if (hit != 1 || tail != 1 || note != 1 || ip !~ /^[0-9.]+$/ || mask !~ /^[0-9.]+$/ || gw !~ /^[0-9.]*$/) { print "OEMNXPTC.INF: configureadapter anchors " hit "/" tail "/" note " or bad address" > "/dev/stderr"; exit 1 } }'
}
