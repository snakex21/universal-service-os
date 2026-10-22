"""Add USB/LAN evidence columns without converting OS desktop PASS to I/O PASS."""
from pathlib import Path
import argparse
from datetime import date


NT351_R18F_ROW = (
    r'Windows NT 3.51\Windows NT 3.51 Workstation 3.51.1057.1 EN.7z',
    '3.51.1057 (NtBuildNumber; zasób 3.51.1025.1)',
    'en-US / x86',
    'windows-nt-3-51 / nt3-x86-qemu-csmwrap',
)

NT31_R19C_ROW = (
    r'Windows NT 3.1\Windows NT 3.1 Workstation 3.10.511.1 EN (ISO).7z',
    '3.10.5098.1',
    'nie odczytano / x86',
    'windows-nt-3-1 / nt3-x86-qemu-csmwrap',
)

NT35_R20_ROW = (
    r'Windows NT 3.5\Windows NT 3.5 Workstation 3.50.807 EN (ISO + boot disks).7z',
    '3.50.800.1',
    'en-US / x86',
    'windows-nt-3-5 / nt3-x86-qemu-csmwrap',
)

NT4_CANDIDATE03_ROW = (
    r'Windows NT 4.0\Windows NT 4.0 Workstation PL.iso',
    '4.0.1381.1',
    'pl-PL / x86',
    'windows-nt-4 / nt4-x86-qemu-csmwrap',
)

def nt4_candidate03(row):
    """Bind the completed NT4 HID overlay to its exact base ISO row [S14]."""
    return len(row) >= 4 and tuple(value.casefold() for value in row[:4]) == tuple(
        value.casefold() for value in NT4_CANDIDATE03_ROW)


def nt35_r20(row):
    """Bind fresh R20 LAN and separate R20b USB to their exact source [S6]."""
    return len(row) >= 4 and tuple(value.casefold() for value in row[:4]) == tuple(
        value.casefold() for value in NT35_R20_ROW)


def nt31_r19c(row):
    """Bind USB HID only to the exact completed R19c inventory row [S5]."""
    return len(row) >= 4 and tuple(value.casefold() for value in row[:4]) == tuple(
        value.casefold() for value in NT31_R19C_ROW)


def nt351_r18f(row):
    """Bind a completed diagnostic to its exact frozen inventory row [S4]."""
    return len(row) >= 4 and tuple(value.casefold() for value in row[:4]) == tuple(
        value.casefold() for value in NT351_R18F_ROW)


def capability(row):
    path,version,arch,route,*_=row
    p=path.casefold();r=route.casefold()
    pending='brak potwierdzenia; DHCP / ping bramy / DNS: nie zmierzono'
    if p.startswith('bety:'):
        return 'nie dotyczy: poza zakresem macierzy','nie dotyczy: poza zakresem macierzy'
    if any(s in p for s in ('servicepacks','service pack 6a','usb support patch','3.51 sp5','(cd2)')):
        return 'nie dotyczy: nośnik aktualizacji/dodatków','nie dotyczy: nośnik aktualizacji/dodatków'
    if p.endswith('.img'):
        return 'nie dotyczy: nośnik rozruchowy, nie osobny zainstalowany OS','nie dotyczy: nośnik rozruchowy'
    if any(s in p for s in ('winframe','fundamentals','embedded standard','nt 4.0 embedded')):
        return 'brak: osobna ścieżka instalacji wymaga uzupełnienia',pending
    if any(s in r for s in ('windows-nt-3-1','windows-nt-3-5','windows-nt-3-51')):
        usb='brak MSC; obecne HID; pendrive dla NT3 po 1.0'
        if nt351_r18f(row):
            net='QEMU PASS nt351-irq-fresh01: świeży normalny USOS z SYS f579, DHCP renew, ping3/3<10ms, strict DNS/HTTP200 [S11]; osobny fresh Client/noSharing FAIL: Server/Browser RUNNING/Start2. QEMU PASS R22: świeży normalny USOS z dawnym SYS około2s [S7]; R26 oddzielnie kwalifikuje IRQ [S8], R18f/R27 USB/HID osobno [S4,S8]. Osobny policy overlay apply02/cold01 PASS: Server/Browser STOPPED/Disabled, Workstation/TCPIP RUNNING, cold ping3/3<10ms [S12]; bez fresh AUTO policy PASS'
        elif nt35_r20(row):
            net='QEMU PASS nt35-irq-fresh01: świeży normalny USOS z SYS d94, DHCP release/renew, ping3/3<10ms, strict FIXED DNS1.1.1.1/8.8.8.8, native resolver i HTTP200 [S15]; configuredDNS10.0.2.3 potwierdzone przez ipconfig, bez strict configuredDNS testu. Fresh Client/noSharing FAIL: Server/Browser RUNNING/Start2. QEMU PASS R20 [S6]: około2s, pierwszy ping2/3 i warm3/3, historia zachowana. Installed IRQ/HID usb01 osobno [S9]. Osobny policy overlay apply03/cold01 PASS: Server/Browser STOPPED/Disabled, Workstation/TCPIP RUNNING, cold ping3/3<10ms [S13]; bez fresh AUTO policy PASS'
        elif nt31_r19c(row):
            net='QEMU PASS R24c: usosnet31 full-MAC, UP + igb 8086:10C9/BDF00:05.0; statyczny TCP/IP, DHCP nie dotyczy; dwa ping3/3, strict DNS30ms, native DNS i HTTP68k200 [S10]. Ręczna integracja NCPA na zachowanej instalacji, bez fresh auto networkflow; R24d Server RUNNING zachowany jako FAIL; osobny helper R24e/R24f po coldboot potwierdza Server/Browser Disabled i Workstation/TCPIP RUNNING [S10]'
        elif 'windows-nt-3-1' in r:
            net='brak portu Intel: wymagany full-MAC, nie miniport NDIS 3; stock NT3.1 ma statyczny TCP/IP, DHCP nie dotyczy; LAN nie zmierzono'
        elif 'windows-nt-3-51' in r:
            net='brak pomiaru tego źródła/edycji: własny usosnet351 NDIS 3 istnieje; R18f Workstation [S4] nie kwalifikuje Servera ani innych nośników'
        else:
            net='brak runtime: port NDIS 3 dla NT3.5 wymaga osobnej obsługi PCI i zasobów; brakujące API wykluczają niezmieniony usosnet351; loopback nie jest LAN'
        if nt35_r20(row):
            net=('QEMU PASS AUTO35 [S21]: świeży normalny USOS/blank target, POST87cb/SYSd94; Server/Browser STOPPED/Disabled od pierwszego targetboot bez ręcznego helpera, Workstation/DHCP aktywne; DHCP renew, ping3/3<10ms, strict FIXED DNS/native resolver/HTTP200, nativeShutdown/rc0/actualreadback. Strict configuredDNS10.0.2.3 NOT_TESTED, PS/2 baseline; bez nowego USB/MSC/USER/Server/X470 PASS. Historia wcześniejszych oddzielnych pakietów: '+net)
        elif nt351_r18f(row):
            net=('QEMU PASS AUTO351 [S22]: świeży normalny USOS/blank target PROFILE, POST615f/SYSf579; Server/Browser STOPPED/Disabled od pierwszego targetboot bez ręcznej zmiany usług, Workstation/DHCP aktywne; DHCP renew, ping3/3 (10/<10/<10ms), strict FIXED DNS/native configured resolver/HTTP200, nativeShutdown/rc0/actualreadback. Brak strict configuredDNS10.0.2.3 packet PASS; PS/2 baseline, bez nowego USB/MSC/DEFAULT/USER/Server/X470 PASS. Historia wcześniejszych oddzielnych pakietów: '+net)
        return usb,net
    if 'windows-nt-4' in r or 'windows nt 4.0' in p:
        if nt4_candidate03(row):
            return ('QEMU PASS tuple09 [S20]: basic coexistence USB313952/43648B HID+MSC + NET89b/21248B, i8042prt Start4/NDISLoop Start2; FAT16 start/hot-plug/flush/close/read/persisted reinsert. Nowe okno Explorer aktualizuje prawy panel; treeghostE/auto-refresh nie jest PASS. Installed BIOS, bez fresh AUTO/X470/Server PASS. Historia: QEMU PASS combo01 [S19]: HID+MSC na tym samym frozenUSB313952/43648B; FAT16/MBR start/hot-plug, zapis/flush/close/read i persisted reinsert, helper75cef; i8042prt Start4, NDISLoop Start3. Nowe okno Explorer pokazuje dyski; auto-refresh nie jest PASS. Osobny BIOS installed overlay, bez LAN/fresh AUTO/X470 PASS. Historia: QEMU PASS MSC04 [S17] na frozenUSB313952/43648B, PS/2 dozwolone/Start1, bez własnej kwalifikacji HID/LAN',
                    'QEMU PASS tuple09 [S20]: basic coexistence z frozenUSB313952 HID+MSC, actualSYS89b/21248B/Start2; fresh own log, actual token/TESTNET_DONE, DHCP DORA/lease, ICMP echo_match1/0ms, strict configuredUDP DNS10.0.2.3:53/id706F/question matched. Końcowy ping po USB4/4 (16/<10/<10/<10ms). Bez pełnej trasy IRQ/fresh AUTO/HTTP/Server/X470 PASS. Historia: QEMU PASS LAN08b [S18]: actualSYS89b/21248B, actual first-logon/TESTNET_DONE, DHCP DORA/lease, ICMP echo_match1/0ms i strict configuredUDP DNS10.0.2.3:53/id2B11/question matched; native ping4/4<10ms. IRQ_delivery_observed=false: ograniczenie pomiaru pełnej trasy IRQ; osobno 57 assertedC0 clears/114IMS/57INTx, bez pełnego IRQ PASS. QEMU PASS LAN07 [S16] zachowany: oldSYS4f2, helper82279/loggerfe4ffa, DHCP/ICMP/strict configuredDNS PASS. LAN05 false zachowany: hiddenFIRSTLO_FAILED/stary DNS logger; matched Start3 control06 bez adaptera [S14], Start2 fixf00b1597. Osobne BIOS installed overlays, bez fresh AUTO/combinedMSC/HTTP/Server/X470 PASS')
        return 'brak MSC w bazie; gotowa osobna feat/nt4-usb-sticks ed1e1459, start / hot-swap oczekują świeżego QEMU [S2]', 'brak pomiaru: usosnet4 NDIS 4, takeover NDISLoop1 + DHCP; świeży QEMU oczekuje'
    if 'windows-95' in r or 'windows 95' in p:
        if 'rtm' in p or 'osr1' in p:
            return 'brak runtime; fix/win95-usb 6b18f5c3 wybiera FAT16 dla RTM/OSR1; USB/NDIS nadal niepotwierdzone',pending
        if 'osr2.1 pl' not in p:
            return 'brak testu tego źródła; odniesienie OSR2 X470 PASS [U] nie jest PASS tego wydania',pending+'; odnieść do usosnet4 OSR2'
        return 'X470 PASS rodziny OSR2: USOSUSB.MPD + UDS, start / hot-swap [U]; nie przenosi PASS na inne wydania', 'X470 PASS rodziny OSR2: usosnet4 NDIS 4 [U]; DHCP/ping/DNS tego ISO wymagają osobnych logów'
    if any(s in r for s in ('windows-98','windows-me')) or any(s in p for s in ('windows 98','windows me')):
        if any(s in p for s in (' en ','upgrade','update')):
            return 'brak osobnego testu EN/Upgrade/Update; rodzinny X470 PASS [U] nie wystarcza',pending+'; usosnet NDIS5 rodzinny, nie test tego źródła'
        return 'X470 PASS rodziny FE/SE/Me: USOSUSB.MPD + UDS, start / hot-swap [U]; nowe EN/Upgrade bez osobnego PASS', 'X470 PASS rodziny FE/SE/Me: usosnet 0.5 NDIS 5 [U]; dokładny zestaw DHCP/ping/DNS niepotwierdzony dla każdego ISO'
    if any(s in r for s in ('windows-2000','windows-xp','windows-server-2003','posready-2009')):
        usb='brak potwierdzenia MSC start / hot-swap; xhci98 + stos USB/HID z nośnika/pakietu; HID PASS nie oznacza MSC PASS'
        if 'x64' in arch.lower():
            net='brak potwierdzenia; usosnet SYS w bazie jest x86, nie nadaje się do x64; sprawdzić zgodny pakiet DATA/Drivers'
        elif 'windows-2000' in r:
            net='brak pomiaru; matching usosnet NDIS 5 + OEM LAN stage; DHCP z Setupu, ping/DNS oczekują'
        else:net='brak pomiaru; baza XP/2003 ma InstallDefaultComponents=Yes; fix/nt5-net d51b445a/513cda9a wybiera client/TCP-IP bez sharing i umożliwia XP pakiety Class=Net z DATA/Drivers; runtime i zgodny NIC oczekują'
        return usb,net
    if any(s in r for s in ('windows-7','windows-vista','windows-server-2008','posready-7')):
        is_x86='x86' in arch.lower() and 'x64' not in arch.lower()
        if is_x86 and '7601' in version and 'windows-7' in r:
            usb='X470 PASS Win7 SP1 x86: bundled usosusb NT6 + usos-drivenotify, FAT32 start / hot-swap [S1,U]; nie test każdego ISO'
        elif is_x86 and '6002' in version:
            usb='brak runtime PASS: :nt60_usb / :usb_drive_notify wspólne z Win7; importy zgodne, świeży Vista/2008 x86 oczekuje'
        elif is_x86:usb='brak potwierdzenia; bundled fallback ograniczony do 6002 / 7601, starsze SP osobno'
        else:usb='brak potwierdzenia; sprawdzić redystrybuowalny stos xHCI / DATA; x64 KMCS i tryb testowy pozostają bez zmian'
        return usb,pending+'; sprawdzić inbox/OEM/Drivers zamiast zakładać działanie usosnet x86'
    if any(s in r for s in ('windows-8','windows-10','windows-11','industry')):
        return 'brak pomiaru start / hot-swap: stos xHCI/USBSTOR w systemie nie jest wynikiem QEMU',pending+'; preferencja inbox/OEM'
    if any(s in r for s in ('windows-1-','windows-2-','windows-3-','windows-wfw')):
        return 'brak potwierdzenia: dostęp DOS/INT13 nie dowodzi wymiany pendrive na pulpicie', 'brak: osobny sterownik DOS/NDIS oraz TCP/IP; nie używać usosnet NDIS4/5 jako dowodu'
    return 'brak: wariant wymaga osobnego przypisania',pending


def rows(path):
    active=False
    for line in path.read_text(encoding='utf-8').splitlines():
        if line.startswith('| Obraz |'):active=True;continue
        if active and not line.startswith('|'):break
        if not active or line.startswith('|---'):continue
        values=[v.strip() for v in line.strip('|').split('|')]
        if len(values)!=8:raise ValueError('Unexpected coverage table shape')
        yield values


def hid_test(usb,row=None):
    if 'nie dotyczy' in usb:return 'nie dotyczy'
    if row and nt4_candidate03(row):
        return 'QEMU PASS tuple09 [S20]: basic coexistence ten sam USB313952/43648B HID+MSC + NET89b/21248B, i8042prt Start4/NDISLoop Start2; negative keyboard/mouse out/in, live keyboard przy mouseout, ruch+Start click i klik po MSC replug PASS. Installed BIOS, bez fresh AUTO/X470/Server PASS. Historia: QEMU PASS combo01 [S19]: keyboard out negative/in typing, mouse out bez ruchu z żywą klawiaturą/in ruch+Start click, także klik po MSC replug; ten sam frozenUSB313952/43648B dla HID+MSC, i8042 obecny/i8042prt Start4, NDISLoop Start3, stopped readback. Osobny BIOS overlay, bez LAN/fresh AUTO/X470 PASS. Historia: QEMU PASS NT4 HID01: USB1.3/2d455, keyboard/mouse out/in, actualreadback [S14]; odrębny pakiet i BIOS cold overlay completed03'
    if row and nt31_r19c(row):
        return 'QEMU PASS R19c: klawiatura USB out/in, mysz ruch+klik po in; bez myszy klawiatura obsługuje File [S5]. R24d powtarza negative keyboard control, out/in, mouse Fileclick i ping3/3 z full-MAC b49 [S10]; sprzęt i8042 obecny, i8042prt Start4; osobne overlay, nie fresh auto networkflow'
    if row and nt35_r20(row):
        return 'QEMU PASS R20b: klawiatura USB out/in, mysz ruch+klik po in; bez myszy klawiatura obsługuje Run/File [S6]. Osobny nt35-irq-usb01 powtarza negative keyboard control, out/in i Filemenu click z SYS d94 [S9]; i8042 obecny, i8042prt Start4, stopped readback; osobne overlay po świeżym R20'
    if row and nt351_r18f(row):
        return 'QEMU PASS R18f: klawiatura USB out/in, mysz ruch+klik po in; bez myszy klawiatura obsługuje Run [S4]. R27 powtarza out/in z poprawionym IRQ SYS f579, negative controls i kliknięciem File [S8]; sprzęt i8042 obecny, i8042prt Start4; osobny installed overlay, nie konfiguracja domyślna instalatora'
    if row and 'windows-7' in row[3] and '7601' in row[1] and 'pl-PL' in row[2] and 'x86' in row[2] and 'x64' not in row[2]:
        return 'X470 PASS rodziny Win7 SP1 PL x86: klawiatura i mysz out/in, tył i przód, usosusb 1.3-nt6 [S3]; brak powiązania z hashem tego ISO'
    return 'brak pomiaru: odpięcie i ponowne podłączenie klawiatury oraz myszy; wejście na pulpicie T4 / T5'


def main(args):
    entries=list(rows(args.coverage))
    if not entries:raise ValueError('No source coverage rows')
    out=['# USB i sieć — przegląd, testy runtime nieukończone','',
        f'Data: {date.today()}. Baza audytu `f28a3fd8155b82dd1be22608f6ef17e82437ad1d`.','',
        'Każdy poniższy wiersz pochodzi z macierzy instalacji. PASS pulpitu nie jest PASS pendrive ani LAN. „Brak” obejmuje brak implementacji lub brak pomiaru — przyczyna jest wypisana jawnie.','',
        '[U] Stan rodzin przekazany przez użytkownika w zadaniu; nie certyfikacja wszystkich języków, SP i nośników. [S1] `tools/nt4/usosusb/README.md`, USB mass storage: Win7 SP1 x86, FAT32 i dwa hot-plugi; `aa868ba8` opisuje scalony test X470.','',
        '[S2] Niezmienione binaria `feat/nt4-usb-sticks` na `ed1e14598927516c70a778d1a7cabfab7428d539`, zamrożone wejście B261020-200536-968CCBE8. To osobny pakiet do testu, bez scalenia i bez użycia gałęzi hubów. Nie jest runtime PASS.','',
        '[S3] `docs/usosusb-hubs-2026-10-21.md:180`: runda 2 X470, Win7 SP1 x86, root-port replug klawiatury i myszy PASS. `docs/release-notes-1.0.md:186` potwierdza świeżą instalację PL x86 z dołączonym donorem. Huby pozostają QEMU only. Dokumenty nie podają hasha ISO, więc wynik jest rodzinny.','',
        '[S4] `docs/nt351-r18f-usability-evidence.md`: zakończony rzeczywisty NT3.51 Workstation R18f, źródło i sterowniki przypięte hashami. Diagnostyczny overlay po normalnym USOS, jawne wyłączenie i8042prt; QEMU only, bez MSC i bez kwalifikacji całego przepływu instalatora.','',
        '[S5] `docs/nt31-r19c-usb-evidence.md`: normalny USOS R19 doszedł do pulpitu NT3.1; osobny overlay R19c z wyłączeniem i8042prt przeszedł USB HID out/in. Sterownik przypięty hashem i odczytany po native Shutdown. Nie jest to MSC ani Intel LAN PASS.','',
        '[S6] `docs/nt35-r20-usability-evidence.md`: świeży NT3.5 Workstation R20 doszedł do pulpitu i przeszedł LAN; osobny R20b izoluje USB przy i8042prt Start4. Pierwszy ping2/3 i opóźnienia około2s pozostają ograniczeniami; R20b logger1s ICMP FAIL zachowany. Bez MSC i bez przenoszenia wyniku na Server.','',
        '[S7] `docs/nt351-r22-fresh-usability-evidence.md`: świeży normalny USOS R22, pulpit Workstation3.51 build1057, native DHCP renew, ping3/3, ścisłe DNS i HTTP68k200. PS/2 dozwolone; bez nowego USB PASS. Native safeShutdown i rc0. Około2s latencji pozostaje wadą.','',
        '[S8] `docs/nt351-r26-irq-evidence.md`: osobny installed overlay R26 zmienia tylko własny SYS/4offsety IRQ. Native ping3/3<10ms, ICMP0ms, ścisły DNS60/40ms i HTTP200. Trace65IMS/32INTx/31PICIRQ11; nativeShutdown/rc0 i stoppedreadback. Nie jest świeżym instalatorem z nowymSYS ani testem X470.','',
        '[S9] `docs/nt35-irq-qualified-evidence.md`: osobny installed NT35 IRQ candidate d94, DHCPrenew, ping3/3<10ms, strict DNS/HTTP200, nativeShutdown/rc0 i actualSYSreadback. R20 zachowuje dawny wolnySYS; osobny świeży d94 kwalifikuje [S15]. R27 w [S8] potwierdza HID po poprawce NT351; bez MSC/X470.','',
        '[S10] `docs/nt31-r24c-network-evidence.md`: rzeczywisty own full-MAC b49, statyczny TCP/IP, native ping/DNS/HTTP i stopped readback; DHCP nie dotyczy. R24d potwierdza USB HID out/in z b49 i zachowuje Server RUNNING jako policy FAIL. Osobne R24e/R24f potwierdzają policy apply i cold PASS: Browser/Server STOPPED/Disabled, Workstation/TCPIP RUNNING, ping3/3. R24/error193 i R24b/STOP zachowane. UP i jawny BDF, manual NCPA; bez fresh auto networkflow/X470.','',
        '[S11] `docs/nt351-fresh-network-evidence.md`: świeży normalny USOS/blank target z SYS f579, desktop/DHCP/ping3/3<10ms/DNS/HTTP i actual SYS readback PASS. Oddzielnie fresh Client/noSharing FAIL: Server/Browser RUNNING/Start2, zachowany pomimo osobnej poprawki [S12]. Bez nowego USB/MSC/X470 ani fresh AUTO policy PASS.','',
        '[S12] `docs/nt351-client-policy-evidence.md`: osobny diagnostic overlay po świeżej instalacji: helper-only apply02 i niezmieniony cold01 PASS, Server/Browser STOPPED/Disabled, Workstation/TCPIP RUNNING, cold ping3/3<10ms. Native safeShutdown/rc0, SCM/native list i stopped readback. Nie jest fresh AUTO policy PASS; bez nowego USB/DHCP/DNS/HTTP/MSC/X470.','',
        '[S13] `docs/nt35-client-policy-evidence.md`: osobny installed NT35 policy apply03 i niezmieniony cold01 PASS: Server/Browser STOPPED/Disabled, Workstation/TCPIP RUNNING, cold ping3/3<10ms. Nowy log /check bez NativeNetExit, native safeShutdown/rc0 i stopped readback; d94/USB2d455/helper4a927 oraz i8042prt Start4 przypięte. Ta próba policy nie jest fresh AUTO ani nowym HID/MSC/DHCP/DNS/HTTP/X470 PASS; osobny świeży d94 i jego policyFAIL są w [S15].','',
        '[S14] `docs/nt4-candidate03-hid-evidence.md`: NT4 candidate03 kończy świeży Setup/pulpit, a osobny HID01 przechodzi keyboard/mouse out/in z nativeShutdown/rc0/readback. Start2/Start3 ma matched native DHCP/ping control, ale oficjalny LAN05 pozostaje false. Ten HID01 używa innego SYS niż odrębny MSC04 [S17].','',
        '[S15] `docs/nt35-fresh-irq-evidence.md`: świeży NT35 Workstation nt35-irq-fresh01 z d94, normalny USOS/pusty4GiB, DHCPrenew/ping3/3<10ms, strict FIXED DNS i native resolver/HTTP200 PASS; dwa actualSYSreadback, nativeShutdown/rc0. Prywatny cache zmienia tylko SYS+SHA; 835 innych effective entries identycznych. Fresh noSharingFAIL zachowany osobno od policy coldPASS [S13]; PS/2 baseline, bez nowego HID/MSC/AUTO/Server/X470 PASS.','',
        '[S16] `docs/nt4-installed07-lan-evidence.md`: zakończony installed LAN07 kwalifikuje oldSYS4f2 osobno od HID [S14]. Actual first-logon/TESTNET_DONE, DHCP DORA/lease, ICMP echo i strict configuredDNS10.0.2.3 zgodne; nativeShutdown/rc0 i stopped payload readback. Helper82279/loggerfe4ffa przypięte jawnie, strict gates zachowane. LAN05 false/control06 zachowane; MSC ma odrębny dowód [S17], późniejszy LAN nowego SYS89 kwalifikuje [S18], bez fresh AUTO/X470/Server PASS.','',
        '[S17] `docs/nt4-msc04-evidence.md`: zakończony MSC04 na frozenUSB313952/43648B: FAT16/MBR startup read, desktop hot-plug, Write/Flush/Close/new read i persisted reinsert PASS; nativeShutdown/rc0/stoppedreadback. PS/2/Start1, małe64MiB; nowe okno Explorer potrzebne, auto-refresh nie jest PASS. MSC03 harness timeout zachowany. Osobne od HID1.3 [S14] i LAN07 [S16], bez fresh AUTO/X470/Server PASS.','',
        '[S18] `docs/nt4-installed08-lan-evidence.md`: zakończony installed08/newSYS89b/21248B i readonly collector08b: actual token/TESTNET_DONE, DORA/lease, echo_match1 oraz strict configuredDNS10.0.2.3:id2B11 PASS; native ping4/4<10ms, nativeShutdown/rc0 i exact stopped readback. Logi odziedziczone z07 usunięto przed finalnym testem. IRQ_delivery_observed=false pozostaje ograniczeniem pomiaru pełnej trasy; 57 assertedC0 clears/114IMS/57INTx osobno, bez pełnego IRQ PASS. LAN07 [S16], LAN05 false/control06, HID [S14] i MSC [S17] pozostają odrębne; bez fresh AUTO/combinedMSC/HTTP/Server/X470 PASS.','',
        '[S19] `docs/nt4-combined-usb-evidence.md`: zakończony combo01/6457ab4b kwalifikuje HID+MSC na tym samym frozenUSB313952/43648B: negative keyboard/mouse controls, rzeczywisty wpis/ruch/klik po in, FAT16 start/hot-plug, Write/Flush/Close/read i persisted reinsert; klik myszy po MSC replug także PASS. i8042 obecny/Start4, NDISLoop Start3, nativeShutdown/rc0/stoppedreadback; źródło exact NT4 PL. MSC04 [S17] i HID1.3 [S14] zachowują historię, LAN [S18] jest osobny. Nowe okno Explorer potrzebne; auto-refresh, LAN współistnienia, fresh AUTO i X470 nie uzyskują PASS z combo01.','',
        '[S20] `docs/nt4-tuple09-coexistence-evidence.md`: jedna zakończona installed VM tuple09 potwierdza podstawowe współistnienie frozenUSB313952/43648B (HID+MSC), i8042prt Start4 oraz NET89b/21248B/Start2. Świeży własny log/actual token/TESTNET_DONE, strict DHCP/brama/configuredDNS706F, negative HID out/in, startup/hot/flush/close/persisted reinsert i końcowy ping po USB4/4 (16/<10/<10/<10ms) PASS. NativeSafe36/QMP0 i stoppedreadbacks; parent08 unchanged. Dawne [S14,S16,S17,S18,S19] są odrębne. TreeghostE/auto-refresh, pełna trasa IRQ, fresh AUTO/HTTP/Server/X470 bez PASS.','',
        'Stan starszych kolejek i oddzielnych poprawek: `docs/usability-staging-audit-2026-10-21.md`. Bieżący raport NT3/NT4/macOS: `C:\\Users\\ASRock\\Documents\\Codex\\zadania\\2026-10-22-nt3-nt4-macos-RAPORT.md`. Dawne błędy NT4 candidate02 pozostają; nowszy wynik pulpitu nie nadaje MSC/LAN PASS.','',
        '[S21] `docs/nt35-fresh-auto-client-evidence.md`: zakończony AUTO35/e129273f kwalifikuje świeży normalny USOS i noSharing przed pierwszym targetboot, POST87cb/SYSd94, DHCP/ping/fixedDNS/native resolver/HTTP200 oraz nativeShutdown/rc0/readback. Bez ręcznego policy helpera; strict configuredDNS.3 NOT_TESTED, brak nowego USB/MSC/Server/X470. Stary fresh policyFAIL [S15] i osobny overlay [S13] pozostają historycznie odrębne.','',
        '[S22] `docs/nt351-fresh-auto-client-evidence.md`: zakończony AUTO351/b7757f22 kwalifikuje świeży normalny USOS PROFILE i noSharing przed pierwszym targetboot, POST615f/SYSf579, DHCP/ping3 (10/<10/<10ms)/fixedDNS/native configured resolver/HTTP200 oraz nativeShutdown/rc0/readback. Błąd kolektora CLNT3511 zachowany, rzeczywiste CLNT351 zweryfikowane przez osobny bounded stopped reader. Bez nowego USB/MSC/DEFAULT/Server/X470 i bez natywnej kwalifikacji POST615 na NT35.','',
        '| Obraz | Build / SP | Język / arch | Przepływ | Pendrive (start / hot-swap) | Sieć (sterownik, DHCP, ping bramy, DNS) | Klawiatura / mysz po odpięciu | Test użytkownika |',
        '|---|---|---|---|---|---|---|---|']
    for row in entries:
        usb,net=capability(row)
        tests='nie zlecać teraz: brak ścieżki / poza zakresem' if 'nie dotyczy' in usb or 'osobna ścieżka' in usb or 'NT3 po 1.0' in usb else 'T1 / T2 / T3 / T4 / T5 po gotowym QEMU i cichym loggerze'
        if nt351_r18f(row):tests='T3 / T4 / T5 po przeglądzie zgodnej konfiguracji; MSC po 1.0'
        if nt31_r19c(row):tests='T3 / T4 / T5 po integracji/przeglądzie zgodnej konfiguracji; statyczne IP [S10], MSC po 1.0'
        if nt35_r20(row):tests='T3 / T4 / T5 po przeglądzie zgodnej konfiguracji; MSC po 1.0; d94 fresh [S15] i osobny HID [S9] wymagają integracji/przeglądu'
        out.append('| '+' | '.join([*row[:4],usb,net,hid_test(usb,row),tests])+' |')
    out+=['','## Ograniczenia i kolejność','',
        '- NT4 Workstation PL + SP6a: świeży normalny przepływ OVMF → USOS → micro-Linux → CSMWrap; zewnętrzny QEMU `igb` (8086:10C9). Candidate03 ukończył Setup/pulpit, osobny HID01 PASS [S14]; osobne installed LAN07 [S16] i nowy SYS89/LAN08b [S18] mają zakończone strict dowody; oddzielny MSC04 PASS [S17]. Combo01 [S19] potwierdza HID+MSC na tym samym313952 przy i8042prt Start4/NDISLoop Start3; nie nadaje LAN współistnienia ani fresh AUTO/X470 PASS. Tuple09 [S20] potwierdza podstawowe współistnienie USB313952 HID+MSC z NET89b/Start2, fresh DHCP/strictDNS i ping po USB. Pełna trasa IRQ89/08 pozostaje niezakwalifikowana; Explorer treeghost/auto-refresh nadal bez PASS.','- W2K/XP/NT5.2: osobno weryfikować faktycznie zainstalowany kontroler, USBSTOR i NIC; stare SP mają blokady pakietu. R11/R12 używają prawidłowego celu 32 GiB thin qcow2.','- Vista SP2 / 2008 SP2 x86: wymagany własny świeży test, wspólny skrypt i importy nie wystarczają. R13 ma osobny prywatny cache fix/nt6x86-usb i donor x86.','- NT3.51: [S7] potwierdza świeży Workstation R22 i LAN; [S4] osobny diagnostyczny USB/HID. Bez MSC. Dawne około2s opóźnienie zachowano jako historię; installed candidate [S8] je usuwa i przechodzi osobną regresję HID R27. Inne nośniki i Server wymagają osobnych testów.','- QEMU IRQ nie odtwarza braku IRQ karty I211 na X470; działanie pollingu 20 ms pozostaje bramką sprzętową.','- Poprawka `fix/nt6x86-usb` (`4f54df6b`, `655af5ef`): błąd instalacji notyfikatora zatrzymuje restart; log przy EXE, bez PUBLIC fallback. Host PASS, runtime oczekuje. Nie scalono ani nie wdrożono.','']
    out+=['## Pytania sprzętowe — odpowiedzi tylko tak/nie','',
        '- T1: Czy po uruchomieniu systemu widać pendrive i można otworzyć jego START.TXT bez propozycji formatowania?',
        '- T2: Czy po dopięciu drugiego pendrive na pulpicie widać go i można otworzyć HOTPLUG.TXT bez restartu, konsoli i AutoPlay?',
        '- T4: Czy po odpięciu i ponownym podłączeniu klawiatury można normalnie pisać, bez zablokowanego klawisza i restartu?',
        '- T5: Czy po odpięciu i ponownym podłączeniu myszy działają ruch oraz przyciski, bez restartu?',
        '- T3: Czy przeglądarka startuje bez modemu/ICW i otwiera 68k.news z ulubionych? W systemach bez IE użyć dostępnej przeglądarki; jeśli nie ma żadnej, HTTP pozostaje nieprzetestowane.','',
        'T3 nie dowodzi DHCP ani ping do bramy. Te wyniki muszą pochodzić z cichego logu. NT4 ma osobne kwalifikacje HID01 [S14], LAN07 [S16], MSC04 [S17] i LAN08b z nowym SYS89 [S18]. Combo01 [S19] potwierdza HID+MSC na jednym313952 i odczyt zapisanego pliku po ponownym włożeniu, bez LAN/fresh AUTO/X470 PASS; istniejący Explorer nie odświeża się automatycznie. Tuple09 [S20] potwierdza podstawowe współistnienie USB313952 HID+MSC z NET89b/Start2, fresh DHCP/strictDNS i ping po USB. Pełna trasa IRQ89/08 pozostaje niezakwalifikowana; Explorer treeghost/auto-refresh nadal bez PASS. Pozostałe nowe ścieżki wymagają własnego podłączenia. Nie jest to jeszcze gotowy pakiet do testu X470.','']
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text('\n'.join(out),encoding='utf-8',newline='\n')
    print('USB_LAN_MATRIX',len(entries),'coverage rows; no new runtime PASS inferred')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--coverage',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    main(parser.parse_args())
