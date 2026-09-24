USOS and Secure Boot - enroll the USOS key once
================================================

[EN] English
------------
USOS starts with Secure Boot ON after you enroll its key once per computer.

1. Boot the computer from the USOS stick.
2. A blue screen says "Verification failed: (0x1A) Security Violation".
   Press Enter (OK). "Shim UEFI key management" (MokManager) opens.
   Press any key within 10 seconds, otherwise the computer continues/restarts.
3. Choose "Enroll key from disk".
4. Choose the USOS stick (USOS_ESP), then EFI -> USOS ->
   ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. Choose "Continue", then "Yes", then "Reboot".
6. USOS now starts normally with Secure Boot ON. You never need to repeat this
   on this computer (unless the firmware settings are reset).

With Secure Boot ON, entries that need a legacy boot path (Windows XP through
CSM, Windows 7 and Vista) are marked "Requires Secure Boot off" in the menu.
To remove the key later: MokManager "Delete MOK", or in Linux
"mokutil --delete ENROLL_THIS_KEY_IN_MOKMANAGER.cer".
On a keyboard-less handheld (e.g. ROG Ally): MokManager accepts the volume
keys/D-pad as Up/Down only on some firmware; attach a USB keyboard if the
menu does not react.

[PL] Polski
-----------
USOS uruchamia sie przy WLACZONYM Secure Boot po jednorazowym dodaniu
(enroll) jego klucza na danym komputerze.

1. Uruchom komputer z pendrive'a USOS.
2. Pojawi sie niebieski ekran "Verification failed: (0x1A) Security
   Violation". Nacisnij Enter (OK). Otworzy sie "Shim UEFI key management"
   (MokManager). Nacisnij dowolny klawisz w ciagu 10 sekund, inaczej komputer
   pojdzie dalej/zrestartuje sie.
3. Wybierz "Enroll key from disk".
4. Wybierz pendrive USOS (USOS_ESP), nastepnie EFI -> USOS ->
   ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. Wybierz "Continue", potem "Yes", potem "Reboot".
6. USOS startuje juz normalnie z wlaczonym Secure Boot. Na tym komputerze nie
   trzeba tego powtarzac (chyba ze ustawienia firmware zostana zresetowane).

Przy wlaczonym Secure Boot pozycje wymagajace starszej sciezki startu
(Windows XP przez CSM, Windows 7 i Vista) sa w menu oznaczone "Wymaga
wylaczenia Secure Boot".
Usuniecie klucza: w MokManager "Delete MOK" albo w Linuksie
"mokutil --delete ENROLL_THIS_KEY_IN_MOKMANAGER.cer".
Na konsoli bez klawiatury (np. ROG Ally) MokManager nie zawsze reaguje na
przyciski; w razie potrzeby podlacz klawiature USB.

The following sections are machine-translated.

[DE] Deutsch
------------
USOS startet mit aktiviertem Secure Boot, nachdem sein Schluessel einmal pro
Computer registriert wurde.
1. Vom USOS-Stick starten.
2. Bei "Verification failed: (0x1A) Security Violation" Enter druecken.
   "Shim UEFI key management" (MokManager) oeffnet sich; innerhalb von
   10 Sekunden eine Taste druecken.
3. "Enroll key from disk" waehlen.
4. USOS-Stick (USOS_ESP) -> EFI -> USOS -> ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. "Continue", "Yes", "Reboot".
6. USOS startet nun mit aktiviertem Secure Boot.
Eintraege, die Secure Boot aus benoetigen (Windows XP ueber CSM, Windows 7,
Vista), sind im Menue markiert.

[FR] Francais
-------------
USOS demarre avec Secure Boot active apres l'enregistrement unique de sa cle
sur chaque ordinateur.
1. Demarrez depuis la cle USOS.
2. A "Verification failed: (0x1A) Security Violation", appuyez sur Entree.
   "Shim UEFI key management" (MokManager) s'ouvre ; appuyez sur une touche
   dans les 10 secondes.
3. Choisissez "Enroll key from disk".
4. Cle USOS (USOS_ESP) -> EFI -> USOS -> ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. "Continue", "Yes", "Reboot".
6. USOS demarre maintenant avec Secure Boot active.
Les entrees qui exigent Secure Boot desactive (Windows XP via CSM, Windows 7,
Vista) sont signalees dans le menu.

[ES] Espanol
------------
USOS arranca con Secure Boot activado despues de registrar su clave una vez
en cada equipo.
1. Arranque desde la memoria USOS.
2. En "Verification failed: (0x1A) Security Violation" pulse Intro.
   Se abre "Shim UEFI key management" (MokManager); pulse una tecla antes de
   10 segundos.
3. Elija "Enroll key from disk".
4. Memoria USOS (USOS_ESP) -> EFI -> USOS -> ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. "Continue", "Yes", "Reboot".
6. USOS ya arranca con Secure Boot activado.
Las entradas que requieren desactivar Secure Boot (Windows XP mediante CSM,
Windows 7, Vista) aparecen marcadas en el menu.

[PT-BR] Portugues (Brasil)
--------------------------
O USOS inicia com o Secure Boot ativado depois que sua chave e registrada uma
vez em cada computador.
1. Inicie pelo pendrive USOS.
2. Em "Verification failed: (0x1A) Security Violation" pressione Enter.
   O "Shim UEFI key management" (MokManager) abre; pressione uma tecla em ate
   10 segundos.
3. Escolha "Enroll key from disk".
4. Pendrive USOS (USOS_ESP) -> EFI -> USOS -> ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. "Continue", "Yes", "Reboot".
6. O USOS agora inicia com o Secure Boot ativado.
Entradas que exigem desativar o Secure Boot (Windows XP via CSM, Windows 7,
Vista) ficam marcadas no menu.

[RU] Russkij (transliteration)
------------------------------
USOS zapuskaetsya pri vklyuchennom Secure Boot posle odnokratnoj registracii
ego klyucha na kazhdom kompyutere.
1. Zagruzites s fleshki USOS.
2. Pri "Verification failed: (0x1A) Security Violation" nazhmite Enter.
   Otkroetsya "Shim UEFI key management" (MokManager); nazhmite lyubuyu
   klavishu v techenie 10 sekund.
3. Vyberite "Enroll key from disk".
4. Fleshka USOS (USOS_ESP) -> EFI -> USOS -> ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. "Continue", "Yes", "Reboot".
6. Teper USOS zapuskaetsya s vklyuchennym Secure Boot.
Punkty, trebuyushchie otklyuchit Secure Boot (Windows XP cherez CSM,
Windows 7, Vista), otmecheny v menyu.
