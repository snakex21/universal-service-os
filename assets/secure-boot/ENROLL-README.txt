USOS and Secure Boot - add the USOS key once per computer
=========================================================

[EN] English
------------
USOS starts with Secure Boot ON after its key has been added once on that
computer. No password is needed in any of the ways below.

The USOS menu shows the state of this computer in Tools -> Secure Boot
(Secure Boot on/off, whether the USOS key is saved, whether Secure Boot can
be turned on) and has "Add the key" and "Open BIOS settings" there.

Way 1 - easiest: start USOS once with Secure Boot OFF
1. Turn Secure Boot off in the BIOS/UEFI settings (in Windows the USOS
   installer has "Restart into BIOS settings").
2. Start the computer from the USOS stick. The home screen shows
   "USOS cannot find its Secure Boot key on this computer. Add it?"
   Choose Add -> Add the key -> "Yes, save the key".
   (Or later: Tools -> Secure Boot -> Add the key.)
3. "Key saved." Choose "Open BIOS settings" and turn Secure Boot back on.
   Done: USOS now starts with Secure Boot ON, no MokManager at all.

Way 2 - Secure Boot stays ON (MokManager, from the stick alone)
Optional first step in Windows: USOS installer -> "Prepare (one time)".
It only makes MokManager wait on its menu instead of a 10 s countdown.

1. "Verification failed"     2. Enroll key from disk      3. the USOS stick
+-------------------------+  +-------------------------+  +-------------------------+
|          ERROR          |  |  Perform MOK management |  |        Select Key       |
|   Verification failed   |  |      Continue boot      |  |       > USOS_ESP <      |
|          > OK <         |  | > Enroll key from disk <|  |           ...           |
+-------------------------+  |  Enroll hash from disk  |  +-------------------------+
                             +-------------------------+
   press Enter ONCE             arrows, Enter                Enter

4. the key file              5. Continue                  6. Yes, then 7. Reboot
+-------------------------+  +-------------------------+  +-------------------------+
|         USOS_ESP        |  |       [Enroll MOK]      |  |    Enroll the key(s)?   |
|           EFI/          |  |        View key 0       |  |            No           |
|     > USOS-KEY.cer <    |  |       > Continue <      |  |         > Yes <         |
+-------------------------+  +-------------------------+  +-------------------------+

1. Boot the computer from the USOS stick.
2. Blue screen "Verification failed: (0x1A) Security Violation": press Enter
   ONCE and release it. MokManager ("Shim UEFI key management") opens; if it
   shows a 10 s countdown, tap any key once.
3. Choose "Enroll key from disk".
4. Choose the USOS stick (USOS_ESP), then USOS-KEY.cer (the same file is
   also in EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer).
5. Choose "Continue", then "Yes", then "Reboot". Arrows + Enter (D-pad + A
   on a handheld) are enough.

Handhelds (ROG Ally and similar): tap each button ONCE, do not hold it. A held
button or auto-repeat skips the screens, picks "Continue boot" and the
computer starts the next system (e.g. Windows) - it then looks as if
MokManager never appeared. Way 1 avoids MokManager completely.

You never need to repeat this on this computer, unless the Secure Boot keys
in the firmware settings are reset.
With Secure Boot ON, entries that need a legacy boot path (Windows XP through
CSM, Windows 7 and Vista) are marked "Requires Secure Boot off" in the menu.
To remove the key: MokManager "Delete MOK", "mokutil --delete USOS-KEY.cer"
in Linux, or reset the Secure Boot keys in the firmware settings.
Advanced: the installer can also write a MokNew request with a password
("USOS Installer.exe" -prepare-mok-enrollment -mok-password P).

[PL] Polski
-----------
USOS uruchamia sie przy WLACZONYM Secure Boot po jednorazowym dodaniu jego
klucza na danym komputerze. Zaden z ponizszych sposobow nie wymaga hasla.

W menu USOS stan komputera widac w Narzedzia -> Secure Boot (Secure Boot
wlaczony/wylaczony, czy klucz USOS jest zapisany, czy Secure Boot da sie
wlaczyc); sa tam tez "Dodaj klucz" i "Otworz ustawienia BIOS".

Sposob 1 - najprosciej: uruchom USOS raz przy WYLACZONYM Secure Boot
1. Wylacz Secure Boot w ustawieniach BIOS/UEFI (w Windows instalator USOS
   ma przycisk "Uruchom ponownie do ustawien BIOS").
2. Uruchom komputer z pendrive'a USOS. Ekran glowny pokaze "Nie wykryto
   klucza Secure Boot potrzebnego do uruchamiania USOS. Dodac go?".
   Wybierz Dodaj -> Dodaj klucz -> "Tak, zapisz klucz".
   (Albo pozniej: Narzedzia -> Secure Boot -> Dodaj klucz.)
3. "Klucz zapisany." Wybierz "Otworz ustawienia BIOS" i wlacz z powrotem
   Secure Boot. Gotowe: USOS startuje z wlaczonym Secure Boot, bez
   MokManagera.

Sposob 2 - Secure Boot zostaje WLACZONY (MokManager, z samego pendrive'a)
Opcjonalnie najpierw w Windows: instalator USOS -> "Przygotuj
(jednorazowo)". To tylko sprawia, ze MokManager czeka na swoim menu zamiast
odliczac 10 s. Obrazki ekranow: patrz sekcja [EN] powyzej.
1. Uruchom komputer z pendrive'a USOS.
2. Niebieski ekran "Verification failed: (0x1A) Security Violation":
   nacisnij Enter RAZ i pusc. Otworzy sie MokManager ("Shim UEFI key
   management"); jesli odlicza 10 s, nacisnij krotko dowolny klawisz.
3. Wybierz "Enroll key from disk".
4. Wybierz pendrive USOS (USOS_ESP), potem USOS-KEY.cer (ten sam plik jest
   tez w EFI\USOS\ENROLL_THIS_KEY_IN_MOKMANAGER.cer).
5. Wybierz "Continue", potem "Yes", potem "Reboot". Wystarcza strzalki +
   Enter (krzyzak + A na konsoli).

Konsole przenosne (ROG Ally itp.): naciskaj kazdy przycisk RAZ, nie
przytrzymuj. Przytrzymanie albo autopowtarzanie przeskakuje ekrany, wybiera
"Continue boot" i komputer uruchamia kolejny system (np. Windows) - wyglada
to tak, jakby MokManager sie nie pojawil. Sposob 1 w ogole omija MokManager.

Na tym komputerze nie trzeba tego powtarzac (chyba ze klucze Secure Boot w
ustawieniach firmware zostana zresetowane).
Przy wlaczonym Secure Boot pozycje wymagajace starszej sciezki startu
(Windows XP przez CSM, Windows 7 i Vista) sa oznaczone "Wymaga wylaczenia
Secure Boot".
Usuniecie klucza: MokManager "Delete MOK", w Linuksie
"mokutil --delete USOS-KEY.cer" albo reset kluczy Secure Boot w firmware.

The following sections are machine-translated.

[DE] Deutsch
------------
USOS startet mit aktiviertem Secure Boot, nachdem sein Schluessel einmal pro
Computer hinzugefuegt wurde. Kein Passwort noetig. Zustand im USOS-Menue:
Werkzeuge -> Secure Boot.
Weg 1 (am einfachsten): Secure Boot im BIOS ausschalten, vom USOS-Stick
starten, auf dem Startbildschirm "Hinzufuegen" -> "Ja, Schluessel speichern"
waehlen, dann Secure Boot wieder einschalten.
Weg 2 (Secure Boot bleibt an): vom USOS-Stick starten, bei "Verification
failed" EINMAL Enter druecken, im MokManager "Enroll key from disk" ->
USOS_ESP -> USOS-KEY.cer -> "Continue" -> "Yes" -> "Reboot".
Handhelds: jede Taste nur einmal kurz druecken, nicht halten.

[FR] Francais
-------------
USOS demarre avec Secure Boot active apres l'ajout unique de sa cle sur
chaque ordinateur. Aucun mot de passe. Etat dans le menu USOS :
Utilitaires -> Secure Boot.
Methode 1 (la plus simple) : desactiver Secure Boot dans le BIOS, demarrer
sur la cle USOS, choisir "Ajouter" -> "Oui, enregistrer la cle" sur l'ecran
d'accueil, puis reactiver Secure Boot.
Methode 2 (Secure Boot reste active) : demarrer sur la cle USOS, a
"Verification failed" appuyer UNE fois sur Entree, dans MokManager
"Enroll key from disk" -> USOS_ESP -> USOS-KEY.cer -> "Continue" -> "Yes"
-> "Reboot".
Consoles portables : appuyer une seule fois sur chaque bouton, sans le tenir.

[ES] Espanol
------------
USOS arranca con Secure Boot activado despues de agregar su clave una vez
en cada equipo. No se necesita contrasena. Estado en el menu de USOS:
Utilidades -> Secure Boot.
Forma 1 (la mas facil): desactive Secure Boot en la BIOS, arranque desde la
memoria USOS, elija "Agregar" -> "Si, guardar la clave" en la pantalla de
inicio y vuelva a activar Secure Boot.
Forma 2 (Secure Boot sigue activado): arranque desde la memoria USOS, en
"Verification failed" pulse Enter UNA vez, en MokManager "Enroll key from
disk" -> USOS_ESP -> USOS-KEY.cer -> "Continue" -> "Yes" -> "Reboot".
Consolas portatiles: pulse cada boton una sola vez, sin mantenerlo.

[PT-BR] Portugues (Brasil)
--------------------------
O USOS inicia com o Secure Boot ativado depois que sua chave e adicionada
uma vez em cada computador. Nenhuma senha e necessaria. Estado no menu do
USOS: Utilitarios -> Secure Boot.
Forma 1 (mais facil): desative o Secure Boot no BIOS, inicie pelo pendrive
USOS, escolha "Adicionar" -> "Sim, salvar a chave" na tela inicial e
reative o Secure Boot.
Forma 2 (Secure Boot continua ativado): inicie pelo pendrive USOS, em
"Verification failed" pressione Enter UMA vez, no MokManager "Enroll key
from disk" -> USOS_ESP -> USOS-KEY.cer -> "Continue" -> "Yes" -> "Reboot".
Consoles portateis: pressione cada botao uma vez, sem segurar.

[RU] Russkij (transliteration)
------------------------------
USOS zapuskaetsya pri vklyuchennom Secure Boot posle odnokratnogo
dobavleniya ego klyucha na kazhdom kompyutere. Parol ne nuzhen. Sostoyanie v
menyu USOS: Utility -> Secure Boot.
Sposob 1 (samyj prostoj): otklyuchite Secure Boot v BIOS, zagruzites s
fleshki USOS, na glavnom ekrane vyberite "Dobavit" -> "Da, sohranit klyuch",
zatem snova vklyuchite Secure Boot.
Sposob 2 (Secure Boot ostaetsya vklyuchennym): zagruzites s fleshki USOS, pri
"Verification failed" ODIN raz nazhmite Enter, v MokManager "Enroll key from
disk" -> USOS_ESP -> USOS-KEY.cer -> "Continue" -> "Yes" -> "Reboot".
Portativnye konsoli: nazhimajte kazhduyu knopku odin raz, ne uderzhivajte.
