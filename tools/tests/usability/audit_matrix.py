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
            net='QEMU PASS R22: świeży normalny USOS, usosnet351 NDIS 3 + igb 8086:10C9, DHCP renew, ping3/3, ścisłe DNS, HTTP68k.news200 [S7]; około2s. R18f [S4] pozostaje osobnym diagnostycznym USB/HID'
        elif nt35_r20(row):
            net='QEMU PASS R20: usosnet35 NDIS 3 + igb 8086:10C9, DHCP, ping bramy, ścisłe DNS, HTTP68k.news200; świeży USOS [S6]; około2s, pierwszy ping2/3 i warm3/3, ograniczenia zachowane'
        elif 'windows-nt-3-1' in r:
            net='brak portu Intel: wymagany full-MAC, nie miniport NDIS 3; stock NT3.1 ma statyczny TCP/IP, DHCP nie dotyczy; LAN nie zmierzono'
        elif 'windows-nt-3-51' in r:
            net='brak pomiaru tego źródła/edycji: własny usosnet351 NDIS 3 istnieje; R18f Workstation [S4] nie kwalifikuje Servera ani innych nośników'
        else:
            net='brak runtime: port NDIS 3 dla NT3.5 wymaga osobnej obsługi PCI i zasobów; brakujące API wykluczają niezmieniony usosnet351; loopback nie jest LAN'
        return usb,net
    if 'windows-nt-4' in r or 'windows nt 4.0' in p:
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
    if row and nt31_r19c(row):
        return 'QEMU PASS R19c: klawiatura USB out/in, mysz ruch+klik po in; bez myszy klawiatura obsługuje File; sprzęt i8042 obecny, i8042prt Start4 [S5]; osobny overlay po świeżym USOS, nie konfiguracja domyślna instalatora'
    if row and nt35_r20(row):
        return 'QEMU PASS R20b: klawiatura USB out/in, mysz ruch+klik po in; bez myszy klawiatura obsługuje Run/File; i8042 obecny, i8042prt Start4, stopped readback [S6]; osobny overlay po świeżym R20'
    if row and nt351_r18f(row):
        return 'QEMU PASS R18f: klawiatura USB out/in, mysz ruch+klik po in; bez myszy klawiatura obsługuje Run; sprzęt i8042 obecny, i8042prt Start4 [S4]; nie konfiguracja domyślna instalatora'
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
        'Stan starszych kolejek i oddzielnych poprawek: `docs/usability-staging-audit-2026-10-21.md`. Bieżący raport NT3/NT4/macOS: `C:\\Users\\ASRock\\Documents\\Codex\\zadania\\2026-10-22-nt3-nt4-macos-RAPORT.md`. NT4 candidate02 nie doszedł do logowania; diagnoza działa na osobnych overlay. Wcześniejsza awaria stagingu nie jest wynikiem Windows ani MSC.','',
        '| Obraz | Build / SP | Język / arch | Przepływ | Pendrive (start / hot-swap) | Sieć (sterownik, DHCP, ping bramy, DNS) | Klawiatura / mysz po odpięciu | Test użytkownika |',
        '|---|---|---|---|---|---|---|---|']
    for row in entries:
        usb,net=capability(row)
        tests='nie zlecać teraz: brak ścieżki / poza zakresem' if 'nie dotyczy' in usb or 'osobna ścieżka' in usb or 'NT3 po 1.0' in usb else 'T1 / T2 / T3 / T4 / T5 po gotowym QEMU i cichym loggerze'
        if nt351_r18f(row):tests='T3 / T4 / T5 po przeglądzie zgodnej konfiguracji; MSC po 1.0'
        if nt31_r19c(row):tests='T4 / T5 po przeglądzie zgodnej konfiguracji; MSC po 1.0, Intel LAN brak'
        if nt35_r20(row):tests='T3 / T4 / T5 po przeglądzie zgodnej konfiguracji; MSC po 1.0, latencja LAN do poprawy'
        out.append('| '+' | '.join([*row[:4],usb,net,hid_test(usb,row),tests])+' |')
    out+=['','## Ograniczenia i kolejność','',
        '- NT4 Workstation PL + SP6a: świeży normalny przepływ OVMF → USOS → micro-Linux → CSMWrap; zewnętrzny QEMU `igb` (8086:10C9). Candidate02 nie ukończył Setup; USB MSC i HID wymagają osobnych dowodów, bez przenoszenia wyników NT351.','- W2K/XP/NT5.2: osobno weryfikować faktycznie zainstalowany kontroler, USBSTOR i NIC; stare SP mają blokady pakietu. R11/R12 używają prawidłowego celu 32 GiB thin qcow2.','- Vista SP2 / 2008 SP2 x86: wymagany własny świeży test, wspólny skrypt i importy nie wystarczają. R13 ma osobny prywatny cache fix/nt6x86-usb i donor x86.','- NT3.51: [S7] potwierdza świeży Workstation R22 i LAN; [S4] osobny diagnostyczny USB/HID. Bez MSC. Fallback sieci około2s pozostaje istotnym ograniczeniem. Inne nośniki i Server wymagają osobnych testów.','- QEMU IRQ nie odtwarza braku IRQ karty I211 na X470; działanie pollingu 20 ms pozostaje bramką sprzętową.','- Poprawka `fix/nt6x86-usb` (`4f54df6b`, `655af5ef`): błąd instalacji notyfikatora zatrzymuje restart; log przy EXE, bez PUBLIC fallback. Host PASS, runtime oczekuje. Nie scalono ani nie wdrożono.','']
    out+=['## Pytania sprzętowe — odpowiedzi tylko tak/nie','',
        '- T1: Czy po uruchomieniu systemu widać pendrive i można otworzyć jego START.TXT bez propozycji formatowania?',
        '- T2: Czy po dopięciu drugiego pendrive na pulpicie widać go i można otworzyć HOTPLUG.TXT bez restartu, konsoli i AutoPlay?',
        '- T4: Czy po odpięciu i ponownym podłączeniu klawiatury można normalnie pisać, bez zablokowanego klawisza i restartu?',
        '- T5: Czy po odpięciu i ponownym podłączeniu myszy działają ruch oraz przyciski, bez restartu?',
        '- T3: Czy przeglądarka startuje bez modemu/ICW i otwiera 68k.news z ulubionych? W systemach bez IE użyć dostępnej przeglądarki; jeśli nie ma żadnej, HTTP pozostaje nieprzetestowane.','',
        'T3 nie dowodzi DHCP ani ping do bramy. Te wyniki muszą pochodzić z cichego logu. Logger i podłączenie NT4 przygotowano na fix/nt4-net 9859f850, z testami hosta; runtime nadal oczekuje. Pozostałe nowe ścieżki wymagają własnego podłączenia. Nie jest to jeszcze gotowy pakiet do testu X470.','']
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text('\n'.join(out),encoding='utf-8',newline='\n')
    print('USB_LAN_MATRIX',len(entries),'coverage rows; no new runtime PASS inferred')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--coverage',type=Path,required=True)
    parser.add_argument('--out',type=Path,required=True)
    main(parser.parse_args())
