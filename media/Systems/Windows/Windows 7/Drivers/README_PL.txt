USOS — Windows 7 x64: Drivers (biblioteka uniwersalna)
=====================================================

Struktura:
  Drivers/x64/USB_AMD/      - sterowniki USB/XHCI AMD (INF+SYS+CAT)
  Drivers/x64/USB_Intel/    - sterowniki USB/XHCI Intel (INF+SYS+CAT)
  Drivers/x64/USB_Generic/  - ogolne USB (klawiatura/mysz/hub)
  Drivers/x64/NVMe/         - sterowniki NVMe na instalacje z SATA

STAN BIBLIOTEKI (sprawdzone 2026-09-20):
  USB_Generic/ - ZAPELNIONE. Microsoft generic xHCI + UAS, komplet x64:
                 usbxhci.inf/.cat + usbxhci.sys, usbhub3.sys, ucx01000.sys,
                 usbd8.sys (Class=USB, DriverVer 11/12/2023 6.2.9200.24610)
                 oraz uaspstor.inf/.cat/.sys (Class=SCSIAdapter,
                 DriverVer 06/21/2006 10.0.19041.1).
                 Zrodlo: katalog ./driwer/x64 dostarczony przez uzytkownika.
                 To JEST paczka wieloproducentowa: sekcja Generic.NTamd64.6.1
                 obejmuje PCI\CC_0C0330 (dowolny kontroler xHCI) oraz HWID
                 AMD (VEN_1022), Intel (VEN_8086), ASMedia (VEN_1B21),
                 Renesas/NEC (VEN_1033, VEN_1912), VIA (VEN_1106),
                 Etron (VEN_1B6F), Fresco Logic (VEN_1B73), TI (VEN_104C).
  USB_AMD/     - PUSTE (no-op). Nie ma osobnej paczki AMD; HWID VEN_1022
                 obsluguje juz USB_Generic. Kopiowanie tego samego INF tutaj
                 tylko dublowaloby prace DISM.
  USB_Intel/   - PUSTE (no-op). Jak wyzej, HWID VEN_8086 jest w USB_Generic.
                 Osobna paczka ma sens dopiero dla Intel USB 3.0 eXtensible
                 Host Controller Driver (iusb3xhc/iusb3hub, chipsety 6/7 gen).
  NVMe/        - ZAPELNIONE (2026-09-20). Podkatalog NVMe/MS_StorNVMe/:
                 stornvme.inf + stornvme.sys (bez .cat - patrz PODPISY).
                 Producent: Microsoft ("Standard NVM Express Controller").
                 Class=SCSIAdapter, ClassGUID={4D36E97B-E325-11CE-BFC1-
                 08002BE10318}, PnpLockdown=1.
                 DriverVer=06/21/2006, 6.1.7601.18615 (galaz win7sp1_gdr,
                 build 140928-1509). stornvme.sys = 50616 B, PE32+ (x64,
                 Machine=0x8664) - bitnosc potwierdzona z naglowka PE,
                 nie z dekoracji INF.
                 HWID (jedyny): PCI\CC_010802 - kod klasy NVM Express.
                 Dziala wiec na KAZDYM kontrolerze NVMe zgodnym ze
                 specyfikacja, niezaleznie od VEN_/DEV_ (Samsung, WD,
                 Kingston, Crucial, Phison, SM2262 itd.). Nie ma tu
                 zadnych HWID producenta i nie sa potrzebne.
                 Sekcje: [Manufacturer] %MS-NVME% = NVME, NTamd64, NTx86.
                 Dekoracje sa BEZ wersji systemu (nie ma .6.3 ani .10.0),
                 wiec sekcja NVME.NTamd64 obowiazuje rowniez dla NT 6.1.
                 Zgodnosc z Windows 7 x64: TAK (to jest oryginalny inbox
                 driver Win7 SP1, a nie backport z Win8/Win10).
                 Usluga: stornvme, SERVICE_BOOT_START (0),
                 ERROR_CRITICAL (3), LoadOrderGroup "SCSI Miniport",
                 czyli miniport StorPort ladowany na starcie - dokladnie
                 to, czego potrzebuje dysk systemowy.
                 ZRODLO: wypakowane z ../Updates/windows6.1-kb2990941-v3
                 -x64.msu (kopia tego samego pliku lezy w ./driwer/nvme).
                 Pakiet MSU nie zawiera gotowego folderu sterownika - INF
                 i SYS siedza w kontenerze CBS
                 amd64_stornvme.inf_31bf3856ad364e35_6.1.7601.18615_none_
                 0f7246380afbdee1. Oryginalne MSU NIE zostalo usuniete ani
                 przeniesione; to jest kopia.
                 SHA256 stornvme.sys =
                 040289582e64d60907703f9d1d092441505dc4820299fa203c0710d8
                 aa4f75cb
                 SHA256 stornvme.inf =
                 927357f3f87cae3752ca28c814588b5b0d6e22eeb84352219dd78bf2
                 62b6d850
                 PODPISY: INF nie ma dyrektywy CatalogFile i paczka nie ma
                 wlasnego .cat (inbox drivery sa pokryte katalogiem
                 systemowym, nie wlasnym). Przy /Add-Driver konieczne jest
                 wiec /ForceUnsigned - i injektor je podaje. To NIE jest
                 problem przy boot-start na Win7 x64: sam stornvme.sys ma
                 WLASNY, wbudowany podpis Authenticode Microsoftu
                 (CN=Microsoft Windows, OU=MOPR; status Valid), wiec
                 winload zweryfikuje go przy starcie mimo braku .cat.
                 WERSJA GDR vs LDR: MSU niesie dwie galezie - 6.1.7601.18615
                 (GDR) i 6.1.7601.22823 (LDR). Oba INF sa identyczne poza
                 linia DriverVer. Swiadomie wziete GDR, bo pasuje do
                 czystego obrazu SP1. Nie wkladac obu naraz - ten sam HWID
                 w dwoch paczkach to niepotrzebny halas w DriverStore.
                 CZEGO TO NIE ZALATWIA: stornvme to miniport StorPort i
                 chce nowego storport.sys. storport.sys jest plikiem
                 systemowym bez wlasnego INF - NIE da sie go wstrzyknac
                 przez /Add-Driver i nie ma go tutaj. Dostarczaja go
                 wylacznie pakiety KB2990941 i KB3087873 (ten drugi nie
                 zawiera NIC poza storport.sys) zakladane przez
                 /Add-Package. Kolejnosc z win7inject.go - KB4474419
                 (SHA-2), potem KB2990941, potem KB3087873, a /Add-Driver
                 dopiero po nich - jest wiec obowiazkowa, nie kosmetyczna.
                 Ten podkatalog ja uzupelnia, a nie zastepuje.

Uzytkownik doklada SAM: pliki INF+SYS+CAT do odpowiedniego podfolderu.
Pusty folder = no-op: drvload/DISM po prostu nie znajduje nic i instalacja
idzie dalej bez bledu (ostrzezenie w logu, nie fail).

Dobieranie: DISM /Add-Driver /Recurse /ForceUnsigned dobiera paczki po HWID
sprzetu; PnP ignoruje reszte. Nie trzeba recznie wybierac — nadmiarowe INF
sa pomijane automatycznie.

ATTRIBUTION A NIE LICENCJA: wzmianka o pochodzeniu sterownika (np. mody
Canonkong / Daniel_K bazujace na binariach MS/AMD) nie jest licencja na
redystrybucje. Wyjatek: UefiSeven ma licencje i juz jest w repo
(uefiseven-LICENSE.txt). Ryzyko DMCA za dolozone pliki bierze na siebie
Maks — nie USOS.

UWAGI SPRZETOWE (X470 i nowsze):
- Intel 11-14 gen: VMD On = brak dysku w Setup. Wylacz VMD/RST w BIOS.
- Xe / UHD 730/770 i RDNA2 (AM5) = brak driverow pod Windows 7.
  Wymagane dGPU: GTX 900/1000/1600, RTX 2000/3000, RX 400/500/Vega/5000,
  czesc 6000. Bez tego tylko 800x600 VGA.
- Instalacja z SATA omija problem NVMe; tryb CSM omija UefiSeven.
- UefiSeven tylko opt-in: czyste UEFI Class 3 bez CSM, Secure Boot OFF,
  backup bootmgfw.efi -> bootmgfw.original.efi. Na X470 z CSM
  (Video=Legacy) domyslnie OFF.
- acpi.sys (mod) tylko po BSOD A5, z backupem i rollbackiem.
