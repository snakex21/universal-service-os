package winhost

import (
	"path/filepath"
	"strings"
)

// xpSettingsDirectory holds the hands-off Windows XP settings read by the
// micro-Linux staging (tools/xp_user_settings.sh).
var xpSettingsDirectory = filepath.Join("Systems", "Windows", "Windows XP", "Unattended")

// xpSettingsExample is rewritten on every install and update; usos-xp.ini is
// the user's own file and is only created (inactive, from the same text)
// when it is missing.
var xpSettingsExample = dataGuide{
	relativePath: filepath.Join(xpSettingsDirectory, "usos-xp.example.ini"),
	contents:     []byte(strings.ReplaceAll(xpSettingsText, "\n", "\r\n")),
}

const xpSettingsFileName = "usos-xp.ini"

const xpSettingsText = `; Universal Service OS - Windows XP bez pytań / hands-off Windows XP
;
; [PL] Skopiuj ten plik jako usos-xp.ini (albo edytuj istniejący usos-xp.ini)
; i wpisz co najmniej user=. Gdy user= jest puste, plik jest nieaktywny i XP
; Setup pyta jak zwykle. Plik jest czytany przy przygotowaniu instalacji XP
; (UEFI-CSM) bez własnego pliku .sif; wybrany plik .sif ma pierwszeństwo.
; Złe wartości zatrzymują przygotowanie, zanim cokolwiek zostanie zapisane na
; dysk docelowy. Tylko znaki ASCII; wielkość liter kluczy bez znaczenia.
;
;   user=      pierwsze konto (administrator), 1-20 znaków A-Z a-z 0-9 . _ - spacja
;   user2=     opcjonalne drugie konto (administrator)
;   computer=  nazwa komputera, 1-15 znaków A-Z a-z 0-9 -, domyślnie USOS-XP
;   org=       organizacja (opcjonalnie)
;   key=       klucz produktu XXXXX-XXXXX-XXXXX-XXXXX-XXXXX; bez klucza Setup
;              zatrzyma się tylko na stronie klucza produktu
;   timezone=  numer strefy czasowej XP; domyślnie 95 (Warszawa) dla polskiego
;              XP, 4 dla angielskiego (US), inaczej 85 (Londyn/GMT)
;   password=  hasło kont i konta Administrator (puste = bez hasła), bez spacji
;              i znaków " % ^ & | < >
;
; Hasło i klucz są zapisane w tym pliku jawnym tekstem. Konta pojawiają się na
; ekranie powitalnym; automatyczne logowanie nie jest włączane.
;
; [EN] Copy this file as usos-xp.ini (or edit the existing usos-xp.ini) and
; fill in at least user=. With user= empty the file is inactive and XP Setup
; asks as usual. The file is read when an XP (UEFI-CSM) installation is
; prepared without a custom .sif; a selected .sif file wins. Invalid values
; stop the preparation before anything is written to the target disk. ASCII
; only; key names are case-insensitive.
;
;   user=      first account (administrator), 1-20 characters A-Z a-z 0-9 . _ - space
;   user2=     optional second account (administrator)
;   computer=  computer name, 1-15 characters A-Z a-z 0-9 -, default USOS-XP
;   org=       organization (optional)
;   key=       product key XXXXX-XXXXX-XXXXX-XXXXX-XXXXX; without it Setup
;              stops only at the product key page
;   timezone=  XP time zone index; default 95 (Warsaw) for Polish XP, 4 for
;              English (US), otherwise 85 (London/GMT)
;   password=  password of the accounts and of Administrator (empty = none), no
;              spaces and no " % ^ & | < >
;
; The password and the key are stored in this file as plain text. The accounts
; are listed on the Welcome screen; automatic logon is not enabled.

user=
user2=
computer=
org=
key=
timezone=
password=
`
