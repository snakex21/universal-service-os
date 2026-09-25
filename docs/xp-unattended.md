# Windows XP bez pytań (usos-xp.ini)

Plik `DATA\Systems\Windows\Windows XP\Unattended\usos-xp.ini` pozwala przejść
instalację XP (profil UEFI-CSM, automatyczny układ jednej partycji) bez
żadnego pytania: tryb tekstowy, GUI Setup i ekran powitalny (OOBE).

- Instalator USOS zapisuje przy każdej instalacji i aktualizacji
  `usos-xp.example.ini` (opis PL/EN), a `usos-xp.ini` tworzy tylko, gdy go nie
  ma, z tą samą treścią i pustymi wartościami. Istniejący `usos-xp.ini` nie
  jest nigdy nadpisywany.
- Plik jest nieaktywny, dopóki `user=` jest puste. Wtedy `WINNT.SIF` jest
  bajt w bajt taki jak bez pliku.
- Ekran „Instalacja nienadzorowana” w menu UEFI dla XP pokazuje się zawsze.
  Pierwszy wiersz to stan `usos-xp.ini`: „usos-xp.ini: Tester, USOS-XP-TEST”
  (pierwsze konto i nazwa komputera; klucza i hasła menu nie pokazuje) albo
  „Bez ustawień (instalacja interaktywna)”. Kolejne wiersze to pliki `.sif`
  z `Unattended\`. Podsumowanie powtarza wybór w polu „Plik odpowiedzi”.
- Wybrany `.sif` jest **łączony** z automatyczną odpowiedzią
  (`usos_xp_custom_sif`): klucze użytkownika wygrywają poza tymi, których
  wymaga ścieżka USOS (całe `[Data]`; `Repartition`, `FileSystem`,
  `TargetPath`, `DriverSigningPolicy`, `NonDriverSigningPolicy`,
  `WaitForReboot`, `OemPreinstall` w `[Unattended]`; `UserExecute` w
  `[SetupParams]`); `[GuiRunOnce]` zachowuje polecenia użytkownika, a na końcu
  dopisuje sprawdzenie pae.exe. Z `.sif` plik `usos-xp.ini` nie jest używany.
  `AutoPartition=1`/`Repartition=Yes` są nadal odrzucane przed zapisem.

## Format

`klucz=wartość`, klucze bez względu na wielkość liter, BOM UTF-8 i CRLF
dozwolone, komentarze `;` lub `#`, nagłówki `[sekcja]` ignorowane, wartości
można ująć w cudzysłów. Nieznany klucz albo zła wartość zatrzymują
przygotowanie **przed** jakimkolwiek zapisem na dysk docelowy (komunikat w
logu nie zawiera wartości).

| klucz | znaczenie | reguła |
|---|---|---|
| `user` | pierwsze konto, administrator lokalny | 1–20 znaków `A-Z a-z 0-9 . _ -` i spacja, nie nazwa wbudowana |
| `user2` | opcjonalne drugie konto, administrator | jak `user`, inne niż `user` |
| `computer` | nazwa komputera | 1–15 znaków `A-Z a-z 0-9 -`, nie same cyfry; domyślnie `USOS-XP` |
| `org` | organizacja | do 64 znaków ASCII bez `" % ^ & \| < >` |
| `key` | klucz produktu | `XXXXX-XXXXX-XXXXX-XXXXX-XXXXX` |
| `timezone` | indeks strefy czasowej XP | 0–300; domyślnie z języka źródła: 95 (PL, `DefaultLayout=00000415`), 4 (US), inaczej 85 |
| `password` | hasło kont i konta Administrator | do 64 znaków ASCII bez spacji i `" % ^ & \| < >`; puste = bez hasła |

Klucz produktu i hasło są w pliku jawnym tekstem; żaden klucz nie jest w
repozytorium.

## Co USOS z tym robi

`tools/xp_user_settings.sh`:

1. `legacy_xp_staging.sh` po sprawdzeniu źródła (ISO zamontowane, nic nie
   zapisane) waliduje plik (`usos_xp_settings_stage`), kopię znormalizowaną
   trzyma w `/run/usos-xp-settings`.
2. `prepare_xp_windows_partition.sh` łączy ją z automatycznym `WINNT.SIF`:
   - `[Unattended]`: `UnattendMode=FullUnattended` (z kluczem) albo
     `DefaultHide` (bez klucza: pokazana zostaje tylko strona klucza
     produktu), `UnattendSwitch=Yes` (bez OOBE),
     `OemSkipEula=Yes` jak dotąd;
   - `[GuiUnattended]`: `OEMSkipRegional=1`, `OemSkipWelcome=1`, `TimeZone`,
     `AdminPassword` (`*` = puste), `EncryptedAdminPassword=No`;
   - `[UserData]`: `FullName`, `OrgName`, `ComputerName`, `ProductKey`;
   - `[Identification]`: `JoinWorkgroup=WORKGROUP`;
   - `[Networking]`: `InstallDefaultComponents=Yes`.
   `[SetupParams] UserExecute` (pae.exe v5), `[GuiRunOnce]`,
   `DriverSigningPolicy`, `Repartition=No`, `FileSystem=LeaveAlone` i
   `TargetPath` zostają bez zmian; `boot.ini timeout` i `CrashDumpEnabled`
   dalej ustawia pae.exe.
3. Konta: `prepare_xp_ntfs_target.sh` zapisuje `C:\USOS\XP\usos-users.cmd`
   (`net user … /add` i `net localgroup` dla zlokalizowanych nazw grupy
   Administratorzy/Administrators/…; log `%SystemRoot%\usos-users.log`).
   `pae.exe` uruchamia go **bez okna konsoli** na końcu GUI Setup
   (UserExecute; przy pierwszym logowaniu ponownie, jeśli wcześniej się nie
   udało), czeka do 180 s, zapisuje kod wyjścia w `pae-install.log` i usuwa
   plik (może zawierać hasło). Konta są na ekranie powitalnym, automatyczne
   logowanie nie jest włączane. `$OEM$`/`cmdlines.txt` nie są używane.

## Testy

- host: `sh` + `tools/xp_user_settings.sh` (BOM, CRLF, błędne wartości,
  scalony SIF, skrypt kont, scalanie wybranego `.sif`); `check_xp_pae.py`
  (pae.exe uruchamia skrypt kont i go usuwa); `src/flow/xp_settings_summary.zig`
  (golden: plik -> wiersz ekranu);
- `installer/internal/winhost/data_guide_xp_test.go` (szablon nieaktywny,
  CRLF, lista kluczy zgodna z parserem);
- QEMU: `run_seabios_xp_uefi_csm_textmode.py --prepare-only --settings
  PLIK.ini` (bez `--settings` cyfrowy odcisk dysku jak golden), potem
  instalacja w VirtualBox: `tools/tests/legacy_bios/run_xp_vbox.py`.
