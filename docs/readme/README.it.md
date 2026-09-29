# Universal Service OS (USOS) 1.0.0

> Questa è una traduzione. Fa fede la [versione inglese del README](../../README.md).

**Lingue:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
[Deutsch](README.de.md) ·
[Ελληνικά](README.el.md) ·
[Español](README.es.md) ·
[Eesti](README.et.md) ·
[Suomi](README.fi.md) ·
[Français](README.fr.md) ·
[Hrvatski](README.hr.md) ·
[Magyar](README.hu.md) ·
Italiano ·
[Lietuvių](README.lt.md) ·
[Latviešu](README.lv.md) ·
[Norsk bokmål](README.nb.md) ·
[Nederlands](README.nl.md) ·
[Polski](README.pl.md) ·
[Português (Brasil)](README.pt-BR.md) ·
[Română](README.ro.md) ·
[Русский](README.ru.md) ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Indice

1. [Che cos'è USOS](#what-usos-is)
2. [Funzionalità](#features)
3. [Sistemi e modalità firmware supportati](#supported-systems)
4. [Avvio rapido](#quick-start)
5. [Struttura delle cartelle su DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profili di risposta](#answer-profiles)
8. [Problemi noti](#known-issues)
9. [Compilare dai sorgenti](#building)
10. [Licenza](#licence)
11. [Supporto](#support)
12. [Documentazione](#documentation)

<a id="what-usos-is"></a>
## 1. Che cos'è USOS

USOS è un'unica chiavetta USB per installare e avviare sistemi operativi, da
MS-DOS a Windows 11 e Linux, su computer BIOS e UEFI, compreso UEFI con
Secure Boot. Le proprie immagini ISO si copiano sulla chiavetta come normali
file; USOS offre un unico menu, una scelta esplicita e protetta del disco di
destinazione e i driver e le correzioni di cui i vecchi sistemi hanno
bisogno sull'hardware nuovo. La chiavetta si prepara in Windows con
`USOS-Installer-1.0.0.exe`. USOS non include immagini di Windows, codici
Product Key né alcun aggiramento dell'attivazione.

![Menu UEFI di USOS, schermata iniziale](../images/menu-home.png)

<a id="features"></a>
## 2. Funzionalità

- **Un solo menu, BIOS e UEFI.** La stessa chiavetta si avvia in BIOS Legacy
  e in UEFI (x64) con lo stesso catalogo. Il menu UEFI funziona con
  tastiera, mouse, touch e gamepad USB.
- **Le immagini restano file.** Le immagini ISO, WIM, IMG, VHD, VHDX ed EFI
  vengono lette direttamente dalla partizione NTFS DATA; non si estrae nulla
  e dopo la copia non occorre eseguire nulla.
- **Disco di destinazione protetto.** Il disco lo scegliete e confermate
  sempre voi; la chiavetta USOS stessa non viene mai proposta.
- **Secure Boot** tramite shim 16.1 (firmato da Microsoft) e la chiave USOS
  (MOK), registrata una volta per computer.
- **Vecchio Windows su hardware nuovo.** Windows XP con un pacchetto di
  driver e PAE su UEFI con CSM; XP e Vista su UEFI senza CSM tramite
  CSMWrap (sperimentale); Windows 7 x64 senza CSM tramite UefiSeven e un
  dispatcher di instradamento VGA; integrazione di USB 3 e NVMe per
  Windows 7.
- **Profili di risposta** per installazioni automatiche di Windows e Linux,
  modificati nel menu UEFI con una tastiera su schermo.
- **ISO Linux da DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla e altre), su UEFI con e senza Secure Boot e su BIOS.
- **Strumenti:** FreeDOS integrato con un file manager e un pannello
  Hardware & SMART (BIOS), la EDK2 UEFI Shell (UEFI), i vostri strumenti
  avviabili in `Utilities`, i vostri driver UEFI e cartelle di driver INF
  per Windows.
- **Programma di installazione con quattro modalità:** Installazione,
  Aggiornamento locale (**Aggiorna USOS**, conserva le immagini e i vostri
  file), Riparazione (**Ripara ESP**), Disinstallazione.
- **27 lingue** (l'inglese è il riferimento; le altre lingue, tranne il
  polacco, sono indicate come tradotte automaticamente in parte o per
  intero), temi con un editor nel menu, supporto touch e gamepad sul ROG
  Ally.

| | |
|---|---|
| ![Elenco dei sistemi Windows con badge di stato](../images/windows-list.png) | ![Elenco delle distribuzioni Linux](../images/linux-list.png) |
| Sistemi Windows con badge di stato | ISO Linux da DATA |
| ![Menu BIOS Legacy](../images/bios-menu.png) | ![Temi integrati e dell'utente](../images/themes-grid.png) |
| Il menu BIOS Legacy | Temi: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Sistemi e modalità firmware supportati

**HW** = testato su hardware reale, **VM** = testato solo in
QEMU/VirtualBox, **sper.** = sperimentale (indicato come tale nel menu),
**non testato** = il percorso esiste ma non è registrata alcuna esecuzione,
**—** = non supportato (il menu indica il motivo). Macchine di test:
**X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100**
(MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
con Secure Boot).

| Sistema | BIOS (Legacy) | UEFI + CSM | UEFI senza CSM (CSMWrap) | Secure Boot attivo |
|---|---|---|---|---|
| Il menu USOS stesso | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 in modalità standard, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW parziale (MS-7100: Setup fino alla preparazione del primo avvio, desktop non confermato) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | sper., VM (fino alla copia dei file) | sper., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (senza pacchetto di driver, senza PAE) | HW (X470: pacchetto di driver, PAE, 31,9 GB) | sper., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | non testato | sper., VM (fino al Setup grafico); X470: STOP 0xA5 | sper., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | non testato | sper., VM (fino al Setup grafico); X470 non testato con la 1.0 | sper., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | sper., HW (X470, CSMWrap, MBR legacy) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (installazione completa) | HW (X470, UefiSeven + dispatcher) | — |
| Windows 8 / 8.1 | non testato | non testato | non testato | non testato |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | UEFI nativo, stesso percorso che con CSM | VM (fino al loader di Windows) |
| Windows 11 | non testato | HW (segnalazione di un utente) | UEFI nativo, stesso percorso che con CSM | VM (fino al loader di Windows) |
| Windows Server 2008 - 2025 | sper., mai avviato | sper., mai avviato | sper., mai avviato | 2008/2008 R2: —; 2012+: non testato |
| ISO Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | come con CSM | HW Fedora, Mint (X470); VM il resto |
| SystemRescue | VM | HW (X470) | come con CSM | — (nessun boot loader firmato) |
| FreeDOS, Hardware & SMART (integrati) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, fornita da voi) | HW | versione `.efi` da `Utilities` (non testato) | come con CSM | solo `.efi` firmato |
| UEFI Shell (integrata) | — | VM | VM | VM (si avvia, non può lanciare strumenti) |

UEFI con o senza CSM conta solo per i percorsi legacy (2000, XP, 2003,
Vista, 7); tutte le altre voci UEFI eseguono lo stesso codice in entrambe le
modalità. Windows XP, Vista e 7 e ogni percorso CSMWrap richiedono Secure
Boot disattivato. La tabella completa con note e i risultati su hardware per
ogni build si trovano nella
[guida utente, sezione 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
e nelle [note di rilascio](../release-notes-1.0.md#supported-systems) (in
inglese).

<a id="quick-start"></a>
## 4. Avvio rapido

File del rilascio:

**Non sai quale scegliere? Scarica l'installer completo.**

| File | Scopo |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Installer completo**: tutto USOS più il donatore WinPE ed entrambi i pacchetti XP; funziona offline |
| `USOS-Installer-1.0.0-online.exe` | **Installer online**: download piccolo; scarica il donatore WinPE e i pacchetti XP da questa release quando servono e li verifica |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | donatore PE10, necessario per Vista e le ISO originali di Windows 7 su UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | pacchetto UEFI per Windows XP x86 SP3, ciascuno per esattamente una ISO originale (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installato con l'incluso `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | sorgenti dei componenti di terze parti e l'offerta scritta dei sorgenti |
| `USOS-1.0.0-buildkit.zip` | toolchain bloccate e input di build per una ricompilazione offline |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | testi delle licenze e avvisi |
| `SHA256SUMS` | SHA-256 di ogni file |

Verificate un download con `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(o `Get-FileHash` in PowerShell) confrontandolo con `SHA256SUMS`.

![Programma di installazione USOS: scelta dell'operazione](../images/installer-mode.png)

1. Procuratevi una chiavetta USB di **almeno 32 GiB** (in pratica 64 GB; una
   chiavetta venduta come «32 GB» di solito è troppo piccola). **Tutto il
   suo contenuto verrà cancellato.**
2. Su un PC Windows avviate `USOS-Installer-1.0.0.exe` (chiede i diritti di
   amministratore), scegliete **Installazione**, selezionate la chiavetta,
   digitate il testo di conferma e fate clic su **CANCELLA E INSTALLA**.
3. Copiate le vostre immagini ISO sulla partizione DATA, nella cartella
   `Images` di ciascun sistema, ad es. `Systems\Windows\Windows 11\Images\`.
4. Facoltativo: per Vista o Windows 7 originale su UEFI, copiate la cartella
   `Programs` dallo zip del donatore PE10 nella radice di DATA ed eseguite
   **Aggiorna USOS**; per XP su UEFI, eseguite come amministratore
   `install-xp-package.ps1` dal pacchetto XP corrispondente alla vostra ISO
   (un pacchetto alla volta).
5. Avviate il PC di destinazione dalla chiavetta (BIOS o UEFI). Con Secure
   Boot attivo, registrate una volta la chiave USOS
   ([Secure Boot](#secure-boot)). Scegliete il sistema e l'immagine,
   facoltativamente un profilo di risposta, confermate il disco di
   destinazione e seguite il programma di installazione del sistema.

Le istruzioni passo per passo per ogni schermata si trovano nella guida
utente: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Struttura delle cartelle su DATA

Il programma di installazione crea la chiavetta con tre partizioni:
`USOS_ESP` (FAT32, 1 GiB: file di avvio, chiave, impostazioni, log,
profili), `USOS_DATA` (NTFS: i vostri file) e `USOS_WORK` (NTFS, spazio di
lavoro per alcuni programmi di installazione di Windows). Tutte le cartelle
su DATA vengono create automaticamente:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versione>\  Images\  Unattended\   (da Windows 3.1 a 11, Server 2003-2025)
│  ├─ Linux\<distribuzione>\ Images\  Unattended\   (Other Linux\ per le ISO sconosciute)
│  ├─ Betas\
│  └─ DOS\<variante>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programmi DOS per il FreeDOS integrato
│  ├─ UEFI Shell\Tools\     strumenti EFI per la UEFI Shell
│  └─ <vostro strumento>\Images\   ad es. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nome>\          driver .efi caricati dal menu USOS
│  └─ <versione Windows>\   Storage\  USB\  Other\  (pacchetti INF)
├─ Themes\<nome>\theme.ini  i vostri temi (menu UEFI)
└─ Programs\
   └─ USOS\                 gestito da USOS (donatore PE10), non toccare
```

Dopo aver aggiunto un `icon.png` o una nuova cartella di strumento, eseguite
**Aggiorna USOS**. L'albero completo si trova nella
[guida utente, sezione 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Con Secure Boot attivo, USOS si avvia tramite **shim 16.1** (build di
Fedora, firmato dalla Microsoft UEFI CA) e MokManager. USOS stesso e i suoi
componenti sono firmati con la **chiave USOS**, che si registra **una volta
per computer**:

- **Il modo più semplice:** disattivate Secure Boot, avviate dalla
  chiavetta, scegliete **Aggiungi** nella schermata iniziale e confermate
  con **Sì, salva la chiave**, poi riattivate Secure Boot. Funziona anche in
  Setup Mode (confermato sull'X470).
- **Mantenendo Secure Boot attivo:** alla schermata «Verification failed»
  usate MokManager -> **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (confermato sul ROG Ally). La scheda **Prepara (una
  tantum)** del programma di installazione fa sì che MokManager attenda
  invece di avviare il conto alla rovescia.

Un reset della NVRAM rimuove la chiave; registratela di nuovo. XP, Vista, 7,
ogni percorso CSMWrap, SystemRescue e gli strumenti avviati dalla UEFI Shell
richiedono Secure Boot disattivato. Il kernel non è ancora bloccato (punto
N6 della roadmap), quindi registrare la chiave USOS significa fidarsi di
tutto ciò che è firmato con essa. Dettagli:
[guida utente, sezione 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profili di risposta

Un piccolo profilo (account, nome del computer, lingua, fuso orario,
personalizzazioni facoltative) viene trasformato all'avvio in `WINNT.SIF`
(2000/XP/2003), `autounattend.xml` (da Vista a 11, Server) oppure in
autoinstall di Ubuntu, preseed di Debian o kickstart di Fedora. I profili si
creano nel menu UEFI (**Installazione automatica** -> **+ Aggiungi un nuovo
profilo**) e vengono salvati sulla ESP.

![Editor dei profili di risposta con la sezione Aspetto ed extra](../images/profile-editor-appearance.png)

- Il disco di destinazione si sceglie **sempre a mano**; un profilo non
  seleziona né cancella mai un disco.
- Un codice Product Key viene salvato solo se spuntate «Ricorda la chiave su
  questa chiavetta»; altrimenti resta solo fino al riavvio. **USOS non
  include chiavi** e non aggira né l'attivazione né la pagina del codice
  Product Key.
- Le password e le chiavi ricordate sono salvate sulla chiavetta come testo
  in chiaro (mai mostrate in elenchi o log). I profili Linux funzionano solo
  su UEFI.

Dettagli: [guida utente, sezione 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Problemi noti

- **Vista su schede madri solo USB 3 (X470):** le chiavette USB non sono
  visibili nel sistema installato e Vista resta in modalità test (backport
  USB 3 con firma di test). Una scheda PCIe Renesas uPD72020x evita
  entrambi i problemi.
- **Percorsi CSMWrap:** richiedono una scheda grafica con VBIOS legacy
  (altrimenti schermo nero), occupano un thread della CPU, richiedono un
  disco di destinazione MBR (che viene cancellato) e Secure Boot
  disattivato.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) sull'X470 e nessun input
  USB sulle schede solo xHCI.
- **Windows 2000** non funziona sulle schede solo AHCI (nessun driver AHCI
  per NT 5.0); **XP** non supporta NVMe e in modalità BIOS non riceve né il
  pacchetto di driver né PAE.
- **Secure Boot:** SystemRescue è bloccato (nessun loader firmato); la UEFI
  Shell non può lanciare strumenti; dopo l'aggiornamento DBX contro
  BlackLotus i supporti Windows più vecchi non si avviano.
- **Linux:** il programma di installazione di Ubuntu Server preseleziona il
  disco più grande, che può essere la chiavetta USOS; controllate sempre la
  destinazione.
- **Il firmware AMI** elenca ogni partizione della chiavetta come voce di
  avvio separata.
- L'helper micro-Linux richiede una CPU x86-64 e almeno 256 MiB di RAM.

L'elenco completo con le soluzioni alternative, e l'elenco onesto di ciò che
**non è ancora stato testato** su hardware (ad es. Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 con Secure Boot su hardware, la ISO originale
di Windows 7 SP1 tramite il donatore PE10), si trovano nelle
[note di rilascio](../release-notes-1.0.md#known-issues) (in inglese) e
nella [guida utente, sezioni 9 e 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Compilare dai sorgenti

La build si esegue in Windows. Istruzioni complete:
[BUILDING.md](../BUILDING.md) (in inglese).

- `build.bat` compila il rilascio completo (programma EFI, micro-Linux,
  nucleo BIOS, payload e `installer\USOS Installer.exe`) con un unico ID di
  build (`BYYMMDD-HHMMSS-XXXXXXXX`). Viene usato lo Zig portatile in
  `tools/zig`; Go e Python devono essere nel `PATH`.
- `tools/tests/run.ps1` esegue i test automatici, ad es.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  produce i file del rilascio in `zig-out\release-1.0\`.
- **Build offline:** estraete `USOS-1.0.0-buildkit.zip`, impostate
  `USOS_BUILDKIT` sulla cartella estratta `USOS-1.0.0-buildkit` ed eseguite
  `build.bat`; il kit viene verificato rispetto al suo manifesto e i
  download sono disattivati.
- **Chiave di firma:** la chiave Secure Boot (MOK) si trova **fuori dal
  repository**, in `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` la
  sostituisce). Senza di essa la build è **non firmata** e si avvia solo
  con Secure Boot disattivato. Non fate mai commit della chiave e non
  condividetela.

Le ISO di Windows, i driver e gli altri supporti di terze parti non fanno
mai parte del repository.

<a id="licence"></a>
## 10. Licenza

- Il codice proprio di USOS è distribuito con licenza **GNU General Public
  License, versione 3 o successiva** (GPL-3.0-or-later): vedere
  [LICENSE](../../LICENSE) e [NOTICE](../../NOTICE). Copyright (C) 2026 The
  USOS Authors.
- I componenti di terze parti mantengono le proprie licenze. Sono programmi
  separati aggregati sulla chiavetta; vedere `THIRD-PARTY-NOTICES.txt` e
  `LICENSES/` nel rilascio e [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- I file Microsoft presenti nel rilascio (file di aggiornamento e di driver,
  i file nei pacchetti XP, il donatore WinPE) sono conservati a scopo di
  preservazione, ridistribuiti a rischio e pericolo del manutentore, non coperti da
  alcuna licenza USOS e verranno rimossi su richiesta del titolare dei
  diritti.
- I contributi sono accettati secondo [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (una concessione di licenza semplificata da parte di chi contribuisce).

Windows, MS-DOS e i nomi correlati sono marchi di Microsoft. USOS non è
affiliato a Microsoft.

<a id="support"></a>
## 11. Supporto

- Domande e segnalazioni di bug: GitHub Issues. Allegate i log descritti
  nella [guida utente, sezione 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  e verificate che non contengano password o chiavi.
- Per le aziende è disponibile su richiesta un'assistenza a pagamento per la
  configurazione; per ora, contattateci tramite GitHub Issues.
- Sponsorizzazioni: tramite `.github/FUNDING.yml`, una volta compilato.

<a id="documentation"></a>
## 12. Documentazione

- Guida utente: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Note di rilascio 1.0](../release-notes-1.0.md) (in inglese)
- [Come funziona USOS](../HOW-IT-WORKS.md)
- [Compilazione](../BUILDING.md)
- [Verifica delle licenze](../LICENSES-AUDIT.md)
- [Piano di test del rilascio 1.0](../RELEASE-TEST-1.0.md)
- [Roadmap](../ROADMAP.md) (in polacco) e [risultati dei test](../../TESTING.md) (in polacco)
