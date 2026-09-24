USOS and Secure Boot - enroll the USOS key once
================================================

[EN] English
------------
USOS starts with Secure Boot ON after you enroll its key once per computer.
There are two ways. Method A needs Windows on that computer and a USB
keyboard for one password; method B works from the stick alone.

Method A - prepare it in Windows (recommended for handhelds, e.g. ROG Ally)
1. In Windows on THAT computer run "USOS Installer.exe" as administrator and
   choose "Prepare key enrollment on this computer" in the Secure Boot note.
   Pick a short password (default "usos"). Nothing else is changed.
2. Restart and boot the USOS stick. A blue "Shim UEFI key management"
   screen appears by itself (no error first). Press ONE key/button briefly
   within 10 seconds.
3. Choose "Enroll MOK" -> "Continue" -> "Yes", type the password, Enter.
4. Choose "Reboot". USOS now starts with Secure Boot ON.
   If the 10 seconds passed, run step 1 again (the request is used once).

Method B - from the stick (no Windows needed)
1. Boot the computer from the USOS stick.
2. A blue screen says "Verification failed: (0x1A) Security Violation".
   Tap Enter (OK) ONCE and release it: "Shim UEFI key management"
   (MokManager) opens with a 10 second countdown. Tap any key within 10 s.
   Holding the key/button (or a handheld pad's auto-repeat) skips the
   countdown, picks "Continue boot" and the computer boots the next system
   (e.g. Windows) - that looks like "MokManager never appeared".
3. Choose "Enroll key from disk".
4. Choose the USOS stick (USOS_ESP), then EFI -> USOS ->
   ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. Choose "Continue", then "Yes", then "Reboot". No password is needed, so
   arrows + Enter (D-pad + A on a handheld) are enough.
6. USOS now starts normally with Secure Boot ON. You never need to repeat this
   on this computer (unless the firmware settings are reset).

With Secure Boot ON, entries that need a legacy boot path (Windows XP through
CSM, Windows 7 and Vista) are marked "Requires Secure Boot off" in the menu;
you can still select them to read why.
To remove the key later: MokManager "Delete MOK", or in Linux
"mokutil --delete ENROLL_THIS_KEY_IN_MOKMANAGER.cer".

[PL] Polski
-----------
USOS uruchamia sie przy WLACZONYM Secure Boot po jednorazowym dodaniu
(enroll) jego klucza na danym komputerze. Sa dwa sposoby. Sposob A wymaga
Windows na tym komputerze i klawiatury USB do wpisania hasla; sposob B
dziala z samego pendrive'a.

Sposob A - przygotowanie w Windows (zalecany dla konsol, np. ROG Ally)
1. W Windows na TYM komputerze uruchom "USOS Installer.exe" jako
   administrator i w uwadze o Secure Boot wybierz "Przygotuj rejestracje
   klucza na tym komputerze". Wybierz krotkie haslo (domyslnie "usos").
   Nic innego nie jest zmieniane.
2. Uruchom ponownie i wystartuj z pendrive'a USOS. Sam pojawi sie niebieski
   ekran "Shim UEFI key management" (bez bledu przed nim). W ciagu 10 sekund
   nacisnij krotko JEDEN klawisz/przycisk.
3. Wybierz "Enroll MOK" -> "Continue" -> "Yes", wpisz haslo, Enter.
4. Wybierz "Reboot". USOS startuje juz z wlaczonym Secure Boot.
   Jesli minelo 10 sekund, powtorz krok 1 (zgloszenie dziala raz).

Sposob B - z pendrive'a (bez Windows)
1. Uruchom komputer z pendrive'a USOS.
2. Pojawi sie niebieski ekran "Verification failed: (0x1A) Security
   Violation". Nacisnij Enter (OK) RAZ i pusc. Otworzy sie "Shim UEFI key
   management" (MokManager) z odliczaniem 10 sekund; w tym czasie nacisnij
   krotko dowolny klawisz. Przytrzymanie klawisza/przycisku (albo
   autopowtarzanie pada w konsoli) pomija odliczanie, wybiera "Continue
   boot" i komputer uruchamia kolejny system (np. Windows) - wyglada to
   tak, jakby MokManager sie nie pojawil.
3. Wybierz "Enroll key from disk".
4. Wybierz pendrive USOS (USOS_ESP), nastepnie EFI -> USOS ->
   ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. Wybierz "Continue", potem "Yes", potem "Reboot". Haslo nie jest potrzebne,
   wystarcza strzalki + Enter (krzyzak + A na konsoli).
6. USOS startuje juz normalnie z wlaczonym Secure Boot. Na tym komputerze nie
   trzeba tego powtarzac (chyba ze ustawienia firmware zostana zresetowane).

Przy wlaczonym Secure Boot pozycje wymagajace starszej sciezki startu
(Windows XP przez CSM, Windows 7 i Vista) sa w menu oznaczone "Wymaga
wylaczenia Secure Boot"; mozna je zaznaczyc, zeby przeczytac wyjasnienie.
Usuniecie klucza: w MokManager "Delete MOK" albo w Linuksie
"mokutil --delete ENROLL_THIS_KEY_IN_MOKMANAGER.cer".

The following sections are machine-translated.

[DE] Deutsch
------------
USOS startet mit aktiviertem Secure Boot, nachdem sein Schluessel einmal pro
Computer registriert wurde.
Methode A (Windows): "USOS Installer.exe" als Administrator starten,
"Schluesselregistrierung auf diesem Computer vorbereiten" waehlen, Passwort
festlegen. Neu starten, vom USOS-Stick booten, im blauen Bildschirm
innerhalb von 10 s kurz eine Taste druecken, "Enroll MOK" -> "Continue" ->
"Yes", Passwort eingeben (USB-Tastatur), "Reboot".
Methode B (Stick):
1. Vom USOS-Stick starten.
2. Bei "Verification failed: (0x1A) Security Violation" EINMAL kurz Enter
   druecken. "Shim UEFI key management" (MokManager) oeffnet sich; innerhalb
   von 10 Sekunden kurz eine Taste druecken (nicht gedrueckt halten).
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
Methode A (Windows) : lancez "USOS Installer.exe" en administrateur, choisissez
"Preparer l'enregistrement de la cle sur cet ordinateur", choisissez un mot
de passe. Redemarrez sur la cle USOS, dans l'ecran bleu appuyez brievement
sur une touche en moins de 10 s, "Enroll MOK" -> "Continue" -> "Yes", tapez
le mot de passe (clavier USB), "Reboot".
Methode B (cle) :
1. Demarrez depuis la cle USOS.
2. A "Verification failed: (0x1A) Security Violation", appuyez UNE fois
   brievement sur Entree. "Shim UEFI key management" (MokManager) s'ouvre ;
   appuyez brievement sur une touche dans les 10 secondes.
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
Metodo A (Windows): ejecute "USOS Installer.exe" como administrador, elija
"Preparar el registro de la clave en este equipo" y una contrasena. Reinicie
desde la memoria USOS, en la pantalla azul pulse brevemente una tecla antes
de 10 s, "Enroll MOK" -> "Continue" -> "Yes", escriba la contrasena
(teclado USB), "Reboot".
Metodo B (memoria):
1. Arranque desde la memoria USOS.
2. En "Verification failed: (0x1A) Security Violation" pulse Intro UNA vez,
   brevemente. Se abre "Shim UEFI key management" (MokManager); pulse
   brevemente una tecla antes de 10 segundos.
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
Metodo A (Windows): execute "USOS Installer.exe" como administrador, escolha
"Preparar o registro da chave neste computador" e uma senha. Reinicie pelo
pendrive USOS, na tela azul pressione rapidamente uma tecla em ate 10 s,
"Enroll MOK" -> "Continue" -> "Yes", digite a senha (teclado USB), "Reboot".
Metodo B (pendrive):
1. Inicie pelo pendrive USOS.
2. Em "Verification failed: (0x1A) Security Violation" pressione Enter UMA
   vez, rapidamente. O "Shim UEFI key management" (MokManager) abre;
   pressione rapidamente uma tecla em ate 10 segundos.
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
Sposob A (Windows): zapustite "USOS Installer.exe" ot imeni administratora,
vyberite "Podgotovit registraciyu klyucha na etom kompyutere" i parol.
Perezagruzites s fleshki USOS, na sinem ekrane v techenie 10 s korotko
nazhmite klavishu, "Enroll MOK" -> "Continue" -> "Yes", vvedite parol
(USB-klaviatura), "Reboot".
Sposob B (fleshka):
1. Zagruzites s fleshki USOS.
2. Pri "Verification failed: (0x1A) Security Violation" ODIN raz korotko
   nazhmite Enter. Otkroetsya "Shim UEFI key management" (MokManager);
   korotko nazhmite lyubuyu klavishu v techenie 10 sekund.
3. Vyberite "Enroll key from disk".
4. Fleshka USOS (USOS_ESP) -> EFI -> USOS -> ENROLL_THIS_KEY_IN_MOKMANAGER.cer
5. "Continue", "Yes", "Reboot".
6. Teper USOS zapuskaetsya s vklyuchennym Secure Boot.
Punkty, trebuyushchie otklyuchit Secure Boot (Windows XP cherez CSM,
Windows 7, Vista), otmecheny v menyu.
