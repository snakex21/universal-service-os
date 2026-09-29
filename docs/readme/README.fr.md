# Universal Service OS (USOS) 1.0.0

> Ceci est une traduction. La [version anglaise du README](../../README.md) fait foi.

**Langues :** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
[Deutsch](README.de.md) ·
[Ελληνικά](README.el.md) ·
[Español](README.es.md) ·
[Eesti](README.et.md) ·
[Suomi](README.fi.md) ·
Français ·
[Hrvatski](README.hr.md) ·
[Magyar](README.hu.md) ·
[Italiano](README.it.md) ·
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

## Sommaire

1. [Qu'est-ce que USOS](#what-usos-is)
2. [Fonctionnalités](#features)
3. [Systèmes et modes de firmware pris en charge](#supported-systems)
4. [Démarrage rapide](#quick-start)
5. [Organisation des dossiers sur DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Profils de réponses](#answer-profiles)
8. [Problèmes connus](#known-issues)
9. [Compiler depuis les sources](#building)
10. [Licence](#licence)
11. [Assistance](#support)
12. [Documentation](#documentation)

<a id="what-usos-is"></a>
## 1. Qu'est-ce que USOS

USOS est une seule clé USB pour installer et démarrer des systèmes
d'exploitation, de MS-DOS à Windows 11 et Linux, sur des ordinateurs BIOS et
UEFI, y compris en UEFI avec Secure Boot. Vous copiez vos propres images ISO
sur la clé comme des fichiers ordinaires ; USOS vous offre un menu unique, un
choix explicite et protégé du disque cible, ainsi que les pilotes et
correctifs dont les anciens systèmes ont besoin sur du matériel récent. La
clé se prépare sous Windows avec `USOS-Installer-1.0.0.exe`. USOS ne fournit
aucune image Windows, aucune clé de produit et aucun contournement de
l'activation.

![Menu UEFI d'USOS, écran d'accueil](../images/menu-home.png)

<a id="features"></a>
## 2. Fonctionnalités

- **Un seul menu, BIOS et UEFI.** La même clé démarre en BIOS Legacy et en
  UEFI (x64) avec le même catalogue. Le menu UEFI fonctionne au clavier, à
  la souris, au tactile et avec des manettes USB.
- **Les images restent des fichiers.** Les images ISO, WIM, IMG, VHD, VHDX
  et EFI sont lues directement depuis la partition NTFS DATA ; rien n'est
  extrait et rien ne doit être lancé après la copie.
- **Disque cible protégé.** Vous choisissez et confirmez toujours le disque ;
  la clé USOS elle-même n'est jamais proposée.
- **Secure Boot** via shim 16.1 (signé par Microsoft) et la clé USOS (MOK),
  inscrite une fois par ordinateur.
- **Ancien Windows sur matériel récent.** Windows XP avec un paquet de
  pilotes et PAE en UEFI avec CSM ; XP et Vista en UEFI sans CSM via
  CSMWrap (expérimental) ; Windows 7 x64 sans CSM via UefiSeven et un
  répartiteur de routage VGA ; intégration USB 3 et NVMe pour Windows 7.
- **Profils de réponses** pour des installations sans surveillance de
  Windows et de Linux, modifiés dans le menu UEFI avec un clavier à l'écran.
- **ISO Linux depuis DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla et d'autres), en UEFI avec et sans Secure Boot et en
  BIOS.
- **Outils :** FreeDOS intégré avec un gestionnaire de fichiers et un
  panneau Hardware & SMART (BIOS), l'EDK2 UEFI Shell (UEFI), vos propres
  outils amorçables dans `Utilities`, vos propres pilotes UEFI et dossiers
  de pilotes INF pour Windows.
- **Installateur à quatre modes :** Installation, Mise à jour locale
  (**Mettre à jour USOS**, conserve les images et vos fichiers), Réparation
  (**Réparer l'ESP**), Désinstallation.
- **27 langues** (l'anglais est la référence ; les autres langues, sauf le
  polonais, sont signalées comme traduites automatiquement en partie ou en
  totalité), thèmes avec un éditeur dans le menu, prise en charge du
  tactile et de la manette sur le ROG Ally.

| | |
|---|---|
| ![Liste des systèmes Windows avec badges d'état](../images/windows-list.png) | ![Liste des distributions Linux](../images/linux-list.png) |
| Systèmes Windows avec badges d'état | ISO Linux depuis DATA |
| ![Menu BIOS Legacy](../images/bios-menu.png) | ![Thèmes intégrés et personnels](../images/themes-grid.png) |
| Le menu BIOS Legacy | Thèmes : Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Systèmes et modes de firmware pris en charge

**HW** = testé sur du vrai matériel, **VM** = testé uniquement dans
QEMU/VirtualBox, **exp.** = expérimental (signalé comme tel dans le menu),
**non testé** = la voie existe mais aucun essai n'est enregistré, **—** = non
pris en charge (le menu indique la raison). Machines de test : **X470**
(ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI,
Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI avec
Secure Boot).

| Système | BIOS (Legacy) | UEFI + CSM | UEFI sans CSM (CSMWrap) | Secure Boot activé |
|---|---|---|---|---|
| Le menu USOS lui-même | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 en mode standard, MS-7100) | — | — | — |
| Windows 98 SE | VM ; HW partiel (MS-7100 : Setup jusqu'à la préparation du premier démarrage, bureau non confirmé) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (jusqu'à la copie des fichiers) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (sans paquet de pilotes, sans PAE) | HW (X470 : paquet de pilotes, PAE, 31,9 Go) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | non testé | exp., VM (jusqu'au Setup graphique) ; X470 : STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | non testé | exp., VM (jusqu'au Setup graphique) ; X470 non testé avec 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, MBR legacy) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (installation complète) | HW (X470, UefiSeven + répartiteur) | — |
| Windows 8 / 8.1 | non testé | non testé | non testé | non testé |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | UEFI natif, même voie qu'avec CSM | VM (jusqu'au chargeur Windows) |
| Windows 11 | non testé | HW (retour d'utilisateur) | UEFI natif, même voie qu'avec CSM | VM (jusqu'au chargeur Windows) |
| Windows Server 2008 - 2025 | exp., jamais démarré | exp., jamais démarré | exp., jamais démarré | 2008/2008 R2 : — ; 2012+ : non testé |
| ISO Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM ; HW Mint live (MS-7100) | HW (X470 : Mint, Fedora, Debian netinst, Clonezilla, GParted) | comme avec CSM | HW Fedora, Mint (X470) ; VM pour le reste |
| SystemRescue | VM | HW (X470) | comme avec CSM | — (pas de chargeur d'amorçage signé) |
| FreeDOS, Hardware & SMART (intégrés) | VM (FreeDOS) ; HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, fourni par vous) | HW | version `.efi` depuis `Utilities` (non testé) | comme avec CSM | uniquement un `.efi` signé |
| UEFI Shell (intégré) | — | VM | VM | VM (démarre, ne peut pas lancer d'outils) |

UEFI avec ou sans CSM ne compte que pour les voies legacy (2000, XP, 2003,
Vista, 7) ; toutes les autres entrées UEFI exécutent le même code dans les
deux modes. Windows XP, Vista et 7 ainsi que toute voie CSMWrap exigent que
Secure Boot soit désactivé. Le tableau complet avec les remarques et les
résultats matériels par build se trouve dans le
[guide de l'utilisateur, section 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
et les [notes de version](../release-notes-1.0.md#supported-systems) (en
anglais).

<a id="quick-start"></a>
## 4. Démarrage rapide

Fichiers de la version :

| Fichier | Rôle |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Installateur complet** : tout USOS avec le donneur WinPE et les deux paquets XP ; fonctionne hors ligne |
| `USOS-Installer-1.0.0-online.exe` | **Installateur en ligne** : petit téléchargement ; récupère le donneur WinPE et les paquets XP depuis cette version au besoin et les vérifie |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | donneur PE10, nécessaire pour Vista et les ISO originales de Windows 7 en UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | paquet UEFI pour Windows XP x86 SP3, chacun pour exactement une ISO originale (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), installé avec le script fourni `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | sources des composants tiers et offre écrite de fourniture des sources |
| `USOS-1.0.0-buildkit.zip` | chaînes d'outils figées et entrées de build pour une recompilation hors ligne |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | textes des licences et mentions |
| `SHA256SUMS` | SHA-256 de chaque fichier |

Vérifiez un téléchargement avec `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(ou `Get-FileHash` dans PowerShell) par rapport à `SHA256SUMS`.

![Installateur USOS : choix de l'opération](../images/installer-mode.png)

1. Procurez-vous une clé USB d'**au moins 32 Gio** (en pratique 64 Go ; une
   clé vendue comme « 32 Go » est généralement trop petite). **Tout son
   contenu sera effacé.**
2. Sur un PC Windows, lancez `USOS-Installer-1.0.0.exe` (il demande les
   droits d'administrateur), choisissez **Installation**, sélectionnez la
   clé, saisissez le texte de confirmation et cliquez sur **EFFACER ET
   INSTALLER**.
3. Copiez vos images ISO sur la partition DATA, dans le dossier `Images` de
   chaque système, par exemple `Systems\Windows\Windows 11\Images\`.
4. Facultatif : pour Vista ou Windows 7 original en UEFI, copiez le dossier
   `Programs` du zip du donneur PE10 à la racine de DATA et lancez
   **Mettre à jour USOS** ; pour XP en UEFI, exécutez en tant
   qu'administrateur `install-xp-package.ps1` depuis le paquet XP qui
   correspond à votre ISO (un seul paquet à la fois).
5. Démarrez le PC cible sur la clé (BIOS ou UEFI). Avec Secure Boot activé,
   inscrivez une fois la clé USOS ([Secure Boot](#secure-boot)). Choisissez
   le système et l'image, éventuellement un profil de réponses, confirmez le
   disque cible et suivez l'installateur du système.

Les instructions pas à pas pour chaque écran se trouvent dans le guide de
l'utilisateur : [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Organisation des dossiers sur DATA

L'installateur crée la clé avec trois partitions : `USOS_ESP` (FAT32,
1 Gio : fichiers de démarrage, clé, réglages, journaux, profils),
`USOS_DATA` (NTFS : vos fichiers) et `USOS_WORK` (NTFS, espace de travail
pour certains installateurs Windows). Tous les dossiers de DATA sont créés
pour vous :

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<version>\   Images\  Unattended\   (Windows 3.1 à 11, Server 2003-2025)
│  ├─ Linux\<distribution>\ Images\  Unattended\   (Other Linux\ pour les ISO inconnues)
│  ├─ Betas\
│  └─ DOS\<variante>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programmes DOS pour le FreeDOS intégré
│  ├─ UEFI Shell\Tools\     outils EFI pour l'UEFI Shell
│  └─ <votre outil>\Images\   p. ex. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nom>\           pilotes .efi chargés par le menu USOS
│  └─ <version Windows>\    Storage\  USB\  Other\  (paquets INF)
├─ Themes\<nom>\theme.ini   vos propres thèmes (menu UEFI)
└─ Programs\
   └─ USOS\                 géré par USOS (donneur PE10), ne pas toucher
```

Après avoir ajouté un `icon.png` ou un nouveau dossier d'outil, lancez
**Mettre à jour USOS**. L'arborescence complète se trouve dans le
[guide de l'utilisateur, section 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Avec Secure Boot activé, USOS démarre via **shim 16.1** (build de Fedora,
signé par la Microsoft UEFI CA) et MokManager. USOS lui-même et ses
composants sont signés avec la **clé USOS**, qui s'inscrit **une fois par
ordinateur** :

- **Le plus simple :** désactivez Secure Boot, démarrez sur la clé,
  choisissez **Ajouter** sur l'écran d'accueil et confirmez avec **Oui,
  enregistrer la clé**, puis réactivez Secure Boot. Cela fonctionne aussi en
  Setup Mode (confirmé sur le X470).
- **En gardant Secure Boot activé :** sur « Verification failed », utilisez
  MokManager -> **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (confirmé sur le ROG Ally). La carte **Préparer (une fois)** de
  l'installateur fait attendre MokManager au lieu de lancer un compte à
  rebours.

Une réinitialisation de la NVRAM supprime la clé ; inscrivez-la à nouveau.
XP, Vista, 7, toute voie CSMWrap, SystemRescue et les outils lancés depuis
l'UEFI Shell exigent que Secure Boot soit désactivé. Le noyau n'est pas
encore verrouillé (point N6 de la feuille de route) : inscrire la clé USOS
revient donc à faire confiance à tout ce qui est signé avec elle. Détails :
[guide de l'utilisateur, section 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Profils de réponses

Un petit profil (comptes, nom de l'ordinateur, langue, fuseau horaire,
réglages facultatifs) est transformé au démarrage en `WINNT.SIF`
(2000/XP/2003), `autounattend.xml` (Vista à 11, Server) ou en autoinstall
Ubuntu, preseed Debian ou kickstart Fedora. Les profils se créent dans le
menu UEFI (**Installation sans surveillance** -> **+ Ajouter un nouveau
profil**) et sont stockés sur l'ESP.

![Éditeur de profil de réponses avec la section Apparence et extras](../images/profile-editor-appearance.png)

- Le disque cible est **toujours choisi à la main** ; un profil ne
  sélectionne ni n'efface jamais un disque.
- Une clé de produit n'est enregistrée que si vous cochez « Mémoriser la clé
  sur cette clé USB » ; sinon elle n'existe que jusqu'au redémarrage.
  **USOS ne fournit aucune clé** et ne contourne ni l'activation ni la page
  de clé de produit.
- Les mots de passe et les clés mémorisées sont stockés sur la clé en texte
  clair (jamais affichés dans les listes ni dans les journaux). Les profils
  Linux ne fonctionnent qu'en UEFI.

Détails : [guide de l'utilisateur, section 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Problèmes connus

- **Vista sur les cartes mères uniquement USB 3 (X470) :** les clés USB ne
  sont pas visibles dans le système installé, et Vista reste en mode test
  (rétroportage USB 3 signé en mode test). Une carte PCIe Renesas uPD72020x
  évite les deux.
- **Voies CSMWrap :** nécessitent une carte graphique avec un VBIOS legacy
  (sinon écran noir), occupent un thread du processeur, nécessitent un
  disque cible MBR (effacé) et Secure Boot désactivé.
- **Server 2003 x86 / XP x64 :** STOP 0xA5 (ACPI) sur le X470 et aucune
  saisie USB sur les cartes uniquement xHCI.
- **Windows 2000** ne fonctionne pas sur les cartes uniquement AHCI (pas de
  pilote AHCI pour NT 5.0) ; **XP** ne prend pas en charge NVMe et ne reçoit
  ni paquet de pilotes ni PAE en mode BIOS.
- **Secure Boot :** SystemRescue est bloqué (pas de chargeur signé) ;
  l'UEFI Shell ne peut pas lancer d'outils ; après la mise à jour DBX contre
  BlackLotus, les anciens supports Windows ne démarrent pas.
- **Linux :** l'installateur d'Ubuntu Server présélectionne le plus grand
  disque, qui peut être la clé USOS ; vérifiez toujours la cible.
- **Le firmware AMI** affiche chaque partition de la clé comme une entrée de
  démarrage distincte.
- L'assistant micro-Linux nécessite un processeur x86-64 et au moins
  256 Mio de RAM.

La liste complète avec les solutions de contournement, ainsi que la liste
honnête de ce qui n'a **pas encore été testé** sur du matériel (par exemple
Windows Server 2008-2025, Windows 8/8.1, Windows 10/11 avec Secure Boot sur
du matériel, l'ISO originale de Windows 7 SP1 via le donneur PE10), se
trouvent dans les [notes de version](../release-notes-1.0.md#known-issues)
(en anglais) et le
[guide de l'utilisateur, sections 9 et 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Compiler depuis les sources

La compilation se fait sous Windows. Instructions complètes :
[BUILDING.md](../BUILDING.md) (en anglais).

- `build.bat` compile la version complète (programme EFI, micro-Linux, cœur
  BIOS, payload et `installer\USOS Installer.exe`) avec un seul identifiant
  de build (`BYYMMDD-HHMMSS-XXXXXXXX`). Le Zig portable de `tools/zig` est
  utilisé ; Go et Python doivent être dans le `PATH`.
- `tools/tests/run.ps1` exécute les tests automatisés, par exemple
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  produit les fichiers de la version dans `zig-out\release-1.0\`.
- **Compilation hors ligne :** extrayez `USOS-1.0.0-buildkit.zip`, définissez
  `USOS_BUILDKIT` sur le dossier extrait `USOS-1.0.0-buildkit` et lancez
  `build.bat` ; le kit est vérifié par rapport à son manifeste et les
  téléchargements sont désactivés.
- **Clé de signature :** la clé Secure Boot (MOK) se trouve **en dehors du
  dépôt**, dans `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` permet de la
  remplacer). Sans elle, le build est **non signé** et ne démarre qu'avec
  Secure Boot désactivé. Ne commitez et ne partagez jamais la clé.

Les ISO Windows, les pilotes et les autres supports tiers ne font jamais
partie du dépôt.

<a id="licence"></a>
## 10. Licence

- Le code propre à USOS est distribué sous la **GNU General Public License,
  version 3 ou ultérieure** (GPL-3.0-or-later) : voir [LICENSE](../../LICENSE)
  et [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Les composants tiers conservent leurs propres licences. Ce sont des
  programmes distincts regroupés sur la clé ; voir
  `THIRD-PARTY-NOTICES.txt` et `LICENSES/` dans la version ainsi que
  [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Les fichiers Microsoft de la version (fichiers de mise à jour et de
  pilotes, fichiers des paquets XP, donneur WinPE) sont conservés à des fins
  de préservation, redistribués aux propres risques du mainteneur, ne sont
  couverts par aucune licence USOS et seront retirés à la demande du
  titulaire des droits.
- Les contributions sont acceptées selon [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (une concession de licence allégée par les contributeurs).

Windows, MS-DOS et les noms associés sont des marques de Microsoft. USOS
n'est pas affilié à Microsoft.

<a id="support"></a>
## 11. Assistance

- Questions et rapports de bogues : GitHub Issues. Joignez les journaux
  décrits dans le [guide de l'utilisateur, section 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  et vérifiez qu'ils ne contiennent ni mots de passe ni clés.
- Une aide payante à la mise en place pour les entreprises est disponible
  sur demande ; pour l'instant, prenez contact via GitHub Issues.
- Parrainage : via `.github/FUNDING.yml` une fois celui-ci rempli.

<a id="documentation"></a>
## 12. Documentation

- Guide de l'utilisateur : [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Notes de version 1.0](../release-notes-1.0.md) (en anglais)
- [Comment fonctionne USOS](../HOW-IT-WORKS.md)
- [Compilation](../BUILDING.md)
- [Audit des licences](../LICENSES-AUDIT.md)
- [Plan de test de la version 1.0](../RELEASE-TEST-1.0.md)
- [Feuille de route](../ROADMAP.md) (en polonais) et [résultats des tests](../../TESTING.md) (en polonais)
