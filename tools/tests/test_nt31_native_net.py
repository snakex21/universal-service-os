"""Native NT 3.1 LAN (docs/nt-native-plan.md section 8.10): the prep-side
library tools/nt31_network_setup.sh (preflight, address source, staging,
GUI Setup INF filters), the INITIAL.INF marker of nt31_native_initial, the
POST.CMD /net31 line and the USOSNT3 / USOSANS31 code. Host only: Git sh,
temp folders, fake sysfs, mocked modprobe / udhcpc; no VM, no disk. The
INF fixtures are synthetic section shapes of the NT 3.1 CD.
"""
from pathlib import Path
import hashlib
import shutil
import subprocess
import tempfile
import unittest

from test_w9x_phase1_qemu import sh
from test_nt4_flow import function_text

ROOT = Path(__file__).resolve().parents[2]
LIB31 = ROOT / 'tools/nt31_network_setup.sh'
TARGET = ROOT / 'tools/nt4_csmwrap_target.sh'
USOSNT3 = ROOT / 'tools/nt3/usosnt3/src/usosnt3.c'
ANS31 = ROOT / 'tools/nt3/native31/usosans31.c'

NTLANMAN = ('[NetworkVars]\r\nProtoInfList       = ^(ProtoData, 1)\r\n[ProtoData]\r\n'
            'ProtoData_1        = "OEMNXPNB.INF","NBF",4,Nbf\r\n[ServiceData]\r\n'
            'ServiceData_1      = "OEMNSVSV.INF","SRV",3,LanmanServer\r\n')
OEMNXPTC = (
    'configureadapter = +\r\n    ifstr(i) $(Option) == "TCPIP"\r\n'
    '        ifstr(i) $(BindList) == ""\r\n            debug-output "OEMNXPTC.INF: no binding info; warning user"\r\n'
    '            read-syms InfoDlgCantConfigure\r\n            goto infomsg\r\n        endif\r\n'
    '        ForListDo *($(BindList),4)\r\n            set CardName = *($(BindInfo),6)\r\n'
    'SkipSetDefault = +\r\n        EndForListDo\r\n        set FLibraryErrCtl = 1\r\n'
    '        ifstr(i) $(CardList) != ""\r\n'
    '            LibraryProcedure ResultList, $(!NCPA_HANDLE), CPlTcpip, $(!STF_HWND), $(CardList), $(!STF_COMPUTERNAME), ""\r\n'
    'bindingadapter =+\r\n    set FLibraryErrCtl = 1\r\n    ForListDo $(X)\r\n    EndForListDo\r\n')
INITIAL = (
    '[LoadSetupLibrary]\r\n    exit\r\n[Shell Commands]\r\n    install   LoadSetupLibrary\r\n'
    '    detect    ProcessorVar\r\nntlanman = +\r\n    ifstr(i) $(DoNetwork) == $(!Chosen)\r\n        EndWait\r\n'
    '        shell "ntlanman.inf" DoNetwork\r\n        StartWait\r\n    endif\r\n'
    '[UsosNt31Post]\r\n'
    '    shell "registry.inf" CreateKey $(UsosSvc) {{Scsidisk,0,33554432}} {{Start,0,$(!REG_VT_DWORD),0}}\r\n'
    '    ifstr(i) $($R0) == STATUS_SUCCESSFUL\r\n        CloseRegKey $($R1)\r\n    endif\r\n')


def run_lib(script, files=None):
    tmp = Path(tempfile.mkdtemp(prefix='usos-nt31-net-'))
    try:
        for name, data in (files or {}).items():
            p = tmp / name
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_bytes(data if isinstance(data, bytes) else data.encode())
        rc, out, err = sh(f'T="{tmp.as_posix()}"\n. "{LIB31.as_posix()}"\n{script}')
        result = {p.relative_to(tmp).as_posix(): p.read_bytes() for p in tmp.rglob('*') if p.is_file()}
        return rc, out, err, result
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def fake_lib(answer_extra=''):
    driver = b'MZ usosnet31 test image'
    sha = hashlib.sha256(driver).hexdigest()
    answer = ';USOS-NT31-NETWORK=on\r\n;USOS-NT31-WORKGROUP=PRACOWNIA\r\n;USOS-NETWORK=on\r\n' + answer_extra
    return {
        'lib/nt3/USOSNET31.SYS': driver,
        'lib/nt3/USOSNET31.SHA256': f'{sha}  USOSNET31.SYS\n',
        'lib/network_setup.sh': (ROOT / 'tools/network_setup.sh').read_bytes(),
        'answer.sif': answer,
        # sysfs folder names carry ':' (not on a Windows host): uevent gives the slot
        'pci/nic/uevent': 'DRIVER=igb\nPCI_SLOT_NAME=0000:05:00.0\n',
        'pci/nic/class': '0x020000\n', 'pci/nic/vendor': '0x8086\n',
        'pci/nic/device': '0x1539\n',
        'pci/xhci/class': '0x0c0330\n', 'pci/xhci/vendor': '0x1022\n',
        'pci/xhci/device': '0x145f\n',
    }, sha


class Library(unittest.TestCase):
    def test_mask_and_markers(self):
        rc, out, err, _ = run_lib('for n in 8 16 20 24 30; do usos_nt31_mask $n; done; usos_nt31_mask 31 || echo bad31\n'
                                  'printf ";USOS-NT31-NETWORK=on\\r\\n" > "$T/a"; usos_nt31_requested "$T/a"\n'
                                  'printf "x\\r\\n" > "$T/b"; usos_nt31_requested "$T/b"; usos_nt31_workgroup "$T/b"\n'
                                  'printf ";USOS-NT31-WORKGROUP=bad name\\r\\n" > "$T/c"; usos_nt31_workgroup "$T/c" || echo badwg')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.split(), ['255.0.0.0', '255.255.0.0', '255.255.240.0', '255.255.255.0',
                                       '255.255.255.252', 'bad31', 'on', 'off', 'WORKGROUP', 'badwg'])

    def test_preflight_profile_address_and_stage(self):
        files, sha = fake_lib(';USOS-IP=192.168.7.20/24\r\n;USOS-GATEWAY=192.168.7.1\r\n;USOS-DNS=192.168.7.1,1.1.1.1\r\n')
        rc, out, err, result = run_lib(
            'usos_nt31_preflight "$T/answer.sif" "$T/lib" "$T/pci" || exit 7\n'
            'echo "en=$_u31_enabled bdf=$_u31_bdf bus=$_u31_bus dev=$_u31_dev fn=$_u31_fn wg=$_u31_group"\n'
            'modprobe() { echo MODPROBE >&2; return 1; }\n'
            'usos_nt31_address "$T" USOS-NT31 || exit 8\n'
            'mkdir -p "$T/c"; usos_nt31_stage "$T/c" 0 || exit 9', files)
        self.assertEqual(rc, 0, err)
        self.assertIn('en=on bdf=0000:05:00.0 bus=5 dev=0 fn=0 wg=PRACOWNIA', out)
        self.assertNotIn('MODPROBE', err)            # static profile: no DHCP attempt
        on = result['c/USOS/NT3/NET31.ON'].decode()
        for row in ('mode=profile', 'ip=192.168.7.20', 'mask=255.255.255.0', 'gateway=192.168.7.1',
                    'dns=192.168.7.1 1.1.1.1', 'bus=5', 'device=0', 'function=0', 'pci_id=8086:1539',
                    'client=no-sharing', 'workgroup=PRACOWNIA', 'sha256=' + sha):
            self.assertIn(row + '\r\n', on)
        self.assertEqual(result['c/USOS/NT3/USNET31.SYS'], files['lib/nt3/USOSNET31.SYS'])

    def test_dhcp_lease_becomes_the_static_address(self):
        files, _ = fake_lib()
        files.update({'pci/nic/net/eth3/x': '', 'class/eth3/carrier': '1\n',
                      'class/eth3/address': '70:85:c2:00:11:22\n'})
        rc, out, err, result = run_lib(
            'export USOS_NET_CLASS="$T/class"\n'
            'modprobe() { echo "modprobe $*" >> "$T/calls"; return 0; }\n'
            'ip() { echo "ip $*" >> "$T/calls"; }\n'
            'udhcpc() { echo "udhcpc $*" >> "$T/calls"; while [ $# -gt 0 ]; do [ "$1" = -s ] && s=$2; shift; done\n'
            '  ip=192.168.1.57 subnet=255.255.255.0 router="192.168.1.1 192.168.1.2" dns="192.168.1.1 8.8.8.8" domain=lan lease=86400 serverid=192.168.1.1 "$s" bound; }\n'
            'usos_nt31_preflight "$T/answer.sif" "$T/lib" "$T/pci" || exit 7\n'
            'usos_nt31_address "$T/w" USOS-NT31 || exit 8\n'
            'mkdir -p "$T/c"; usos_nt31_stage "$T/c" 1 || exit 9', dict(files, **{'w/.keep': ''}))
        self.assertEqual(rc, 0, err)
        on = result['c/USOS/NT3/NET31.ON'].decode()
        for row in ('mode=dhcp', 'ip=192.168.1.57', 'mask=255.255.255.0', 'gateway=192.168.1.1',
                    'dns=192.168.1.1 8.8.8.8', 'domain=lan', 'lease_s=86400', 'dhcp_server=192.168.1.1', 'client=keep'):
            self.assertIn(row + '\r\n', on)
        calls = result['calls'].decode()
        self.assertIn('modprobe igb', calls)
        self.assertIn('udhcpc -f -q -n', calls)       # no -R: the lease is not released
        self.assertNotIn(' -R', calls)
        self.assertIn('ip link set dev eth3 down', calls)
        self.assertIn('modprobe -r igb', calls)
        self.assertNotIn('w/u31.lease', result)

    def test_no_lease_falls_back_to_link_local(self):
        files, _ = fake_lib()
        files.update({'pci/nic/net/eth3/x': '', 'class/eth3/carrier': '1\n',
                      'class/eth3/address': '70:85:c2:00:11:22\n', 'w/.keep': ''})
        rc, out, err, result = run_lib(
            'export USOS_NET_CLASS="$T/class"\nmodprobe() { :; }\nip() { :; }\nudhcpc() { return 1; }\n'
            'usos_nt31_preflight "$T/answer.sif" "$T/lib" "$T/pci" || exit 7\n'
            'usos_nt31_address "$T/w" USOS || exit 8\nmkdir -p "$T/c"; usos_nt31_stage "$T/c" 0 || exit 9', files)
        self.assertEqual(rc, 0, err)
        on = result['c/USOS/NT3/NET31.ON'].decode()
        self.assertIn('mode=linklocal\r\n', on)
        self.assertIn('ip=169.254.17.34\r\n', on)
        self.assertIn('mask=255.255.0.0\r\n', on)
        self.assertIn('note=no DHCP answer\r\n', on)

    def test_preflight_refusals(self):
        files, _ = fake_lib()
        bad_sha = dict(files, **{'lib/nt3/USOSNET31.SHA256': '0' * 64 + '  USOSNET31.SYS\n'})
        rc, out, err, _ = run_lib('usos_nt31_preflight "$T/answer.sif" "$T/lib" "$T/pci"; echo "rc=$? en=$_u31_enabled"', bad_sha)
        self.assertIn('rc=1 en=off', out)
        two = dict(files, **{'pci/nic2/class': '0x020000\n', 'pci/nic2/vendor': '0x8086\n',
                             'pci/nic2/device': '0x10c9\n'})
        rc, out, err, _ = run_lib('usos_nt31_preflight "$T/answer.sif" "$T/lib" "$T/pci"; echo "rc=$? en=$_u31_enabled"', two)
        self.assertIn('rc=1 en=off', out)
        off = dict(files, **{'answer.sif': ';USOS-NT31-NETWORK=off\r\n'})
        rc, out, err, _ = run_lib('usos_nt31_preflight "$T/answer.sif" "$T/lib" "$T/pci"; echo "rc=$? en=$_u31_enabled"', off)
        self.assertIn('rc=0 en=off', out)

    def test_inf_filters(self):
        rc, out, err, result = run_lib(
            'usos_nt31_ntlanman_tcpip < "$T/n" > "$T/n.out" || exit 3\n'
            'usos_nt31_oemnxptc 192.168.1.57 255.255.255.0 192.168.1.1 < "$T/x" > "$T/x.out" || exit 4\n'
            'usos_nt31_ntlanman_tcpip < "$T/n.out" > /dev/null && exit 5\n'
            'printf "nothing\\r\\n" | usos_nt31_oemnxptc 1.2.3.4 255.0.0.0 "" > /dev/null && exit 6\n'
            'exit 0', {'n': NTLANMAN, 'x': OEMNXPTC})
        self.assertEqual(rc, 0, err)
        n = result['n.out'].decode()
        self.assertIn('ProtoData_1        = "OEMNXPNB.INF","NBF",4,Nbf\r\nProtoData_2        = "OEMNXPTC.INF","TCPIP",0,Tcpip\r\n', n)
        x = result['x.out'].decode()
        self.assertEqual(x.count('"SOFTWARE\\USOS\\NT31NET"'), 1)
        self.assertIn('set IPAddressList  = {"192.168.1.57"}\r\n', x)
        self.assertIn('set SubnetMaskList = {"255.255.255.0"}\r\n', x)
        self.assertIn('$(ServiceTCPIPKeyName)"\\Parameters"', x)
        self.assertIn('{DefaultGateway,0,$(!REG_VT_SZ),"192.168.1.1"}', x)
        # the skip sits after the default writer's loop and before CPlTcpip
        self.assertLess(x.index('SkipSetDefault'), x.index('no address dialog'))
        self.assertLess(x.index('no address dialog'), x.index('CPlTcpip'))
        self.assertLess(x.index('no note'), x.index('read-syms InfoDlgCantConfigure'))
        self.assertTrue(all(line.endswith('\r') or not line for line in x.split('\n')))


class Target(unittest.TestCase):
    def initial(self, net31):
        tmp = Path(tempfile.mkdtemp(prefix='usos-nt31-init-'))
        try:
            (tmp / 'in').write_text(INITIAL, newline='')
            fn = function_text(TARGET, 'nt31_native_initial')
            # the CPU / answerer / Scsidisk anchors of the real filter
            rc, out, err = sh(f'{fn}\nNT31_NET31={net31} nt31_native_initial < "{(tmp / "in").as_posix()}" > "{(tmp / "out").as_posix()}"')
            return rc, (tmp / 'out').read_text(newline=''), err
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_initial_marker_only_with_net31(self):
        rc, text, err = self.initial('net31')
        self.assertEqual(rc, 0, err)
        self.assertEqual(text.count('{{USOS,0,33554432},{NT31NET,0,33554432}} {}'), 1)
        self.assertLess(text.index('NT31NET'), text.index('shell "ntlanman.inf" DoNetwork'))
        rc, text, err = self.initial("''")
        self.assertEqual(rc, 0, err)
        self.assertNotIn('NT31NET', text)

    def test_target_wiring(self):
        t = TARGET.read_text(encoding='utf-8')
        fn = function_text(TARGET, 'nt31_native')
        self.assertIn('. "$LIB/nt31_network_setup.sh"', t)
        self.assertIn('usos_nt31_preflight "$work/WINNT.SIF" "$LIB"', t)
        self.assertIn('usos_nt31_address "$work" "$q_comp"', fn)
        self.assertIn('nt31_native_szdd "$ls_dir/OEMNXPTC.IN_" usos_nt31_oemnxptc', fn)
        self.assertIn('nt31_native_szdd "$ls_dir/NTLANMAN.IN_" nt31_ntlanman_net31', fn)
        self.assertIn('printf "C:\\\\USOS\\\\NT3\\\\USOSNT3.EXE /net31\\r\\n"', fn)
        self.assertLess(fn.index('/net31\\r\\n'), fn.index('/finish31\\r\\n"'))
        self.assertIn('workgroup=%s', fn)
        build = (ROOT / 'tools/build_micro_linux.py').read_text(encoding='utf-8')
        for piece in ('"kernel/drivers/net/ethernet/intel/igb/igb.ko"', '"kernel/net/packet/af_packet.ko"',
                      "'usr/lib/usos/nt3/USOSNET31.SYS'", '"usr/lib/usos/nt31_network_setup.sh"',
                      "tools/nt/usosnet/bin/nt31-native/i386/usosnet31.sys"):
            self.assertIn(piece, build)


class Programs(unittest.TestCase):
    def test_usosnt3_net31(self):
        c = USOSNT3.read_text(encoding='utf-8')
        for piece in ('lstrcmpA(opt, "net31") == 0', 'lstrcmpA(opt, "netcheck31") == 0',
                      '"\\\\SystemRoot\\\\System32\\\\drivers\\\\usnet31.sys"', 'DIR "USNET31.SYS"',
                      '"PciBus"', '"PciDevice"', '"PciFunction"', '"IPAddress", REG_SZ', '"SubnetMask", REG_SZ',
                      '"DefaultGateway", REG_SZ', '"NameServer", REG_SZ', '"Hostname", REG_SZ',
                      'n31_service_off("LanmanServer")', 'RegDeleteKeyA(HKEY_LOCAL_MACHINE, "SOFTWARE\\\\USOS\\\\NT31NET")',
                      'DIR "USOSNT3.EXE /netcheck31"', '"Echo Reply:TTL "', '"ping_1.1.1.1="', '"tcp_1.1.1.1_80="'):
            self.assertIn(piece, c)
        # the NT 3.1 path only (GetVersion low word 0x0A03)
        self.assertIn('if ((GetVersion() & 0xFFFFUL) != 0x0A03UL) {\n        say("net31 refused', c)

    def test_usosans31_ws_pages(self):
        c = ANS31.read_text(encoding='utf-8')
        for piece in ('"Domain/Workgroup Settings"', 'control(w,1194,"Button")', 'SetDlgItemTextA(w,1192,workgroup)',
                      '"Welcome to the "', '" workgroup"', '"TCP/IP Configuration"', 'GetDlgItem(w,IDCANCEL)',
                      'GetPrivateProfileStringA("native","workgroup"'):
            self.assertIn(piece, c)


class FreshInstall1(unittest.TestCase):
    """X470 2026-10-30 (B261030-222017): 8.3 names, default answer, zone."""
    def test_names_on_c_are_8_3(self):
        t = TARGET.read_text(encoding='utf-8')
        self.assertIn('cp "$LIB/nt3/USOSANS31.EXE" "$usos/USOSAN31.EXE"', t)
        self.assertNotIn('NT3\\\\USOSANS31.EXE', t)
        c = USOSNT3.read_text(encoding='utf-8')
        self.assertIn('write_file("NET31.STS", g_text)', c)
        self.assertNotIn('"NET31.STATUS"', c)
        import re
        for name in re.findall(r'"([A-Z0-9_]+\.[A-Z0-9]+)"', LIB31.read_text(encoding='utf-8') + c[c.index('Native NT 3.1 LAN (POST.CMD'):]):
            base, ext = name.split('.')
            self.assertTrue(len(base) <= 8 and len(ext) <= 3, name)

    def test_default_answer_has_nt31_lan(self):
        prep = (ROOT / 'tools/w9x_csmwrap_prepare.sh').read_text(encoding='utf-8')
        self.assertIn("      NT31|NT31S)\n        printf ';USOS-NT31-NETWORK=on\\r\\n;USOS-NETWORK=on\\r\\n;USOS-IP=dhcp\\r\\n' ;;", prep)

    def test_zone_prefix(self):
        fn = function_text(TARGET, 'nt31_zone_prefix')
        rc, out, err = sh(fn + '\nfor z in "Central European" "W. Europe" GMT "E. Europe" Nowhere; do printf "[%s]" "$(nt31_zone_prefix "$z")"; done')
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), '[(GMT+1:00) Berlin][(GMT+1:00) Berlin][(GMT) ][(GMT+2:00) Athens][]')
        self.assertIn('CB_FINDSTRING', ANS31.read_text(encoding='utf-8'))


if __name__ == '__main__':
    unittest.main()
