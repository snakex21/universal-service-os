# Universal Service OS (USOS) 1.0.0

> Това е превод. Меродавна е [английската версия на README](../../README.md).

**Езици:** [English](../../README.md) ·
Български ·
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

## Съдържание

1. [Какво е USOS](#what-usos-is)
2. [Възможности](#features)
3. [Поддържани системи и режими на фърмуера](#supported-systems)
4. [Бърз старт](#quick-start)
5. [Структура на папките в DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Профили с отговори](#answer-profiles)
8. [Известни проблеми](#known-issues)
9. [Компилиране от изходния код](#building)
10. [Лиценз](#licence)
11. [Поддръжка](#support)
12. [Документация](#documentation)

<a id="what-usos-is"></a>
## 1. Какво е USOS

USOS е една USB флашка за инсталиране и стартиране на операционни системи,
от MS-DOS до Windows 11 и Linux, на компютри с BIOS и UEFI, включително
UEFI с включен Secure Boot. Копирате собствените си ISO образи на флашката
като обикновени файлове; USOS ви дава едно меню, изричен и защитен избор на
целевия диск, както и драйверите и поправките, от които старите системи се
нуждаят на нов хардуер. Флашката се подготвя под Windows с
`USOS-Installer-1.0.0.exe`. USOS не съдържа образи на Windows, продуктови
ключове или средства за заобикаляне на активацията.

![Меню на UEFI на USOS, начален екран](../images/menu-home.png)

<a id="features"></a>
## 2. Възможности

- **Едно меню за BIOS и UEFI.** Една и съща флашка стартира в Legacy BIOS
  и в UEFI (x64) с един и същ каталог. Менюто на UEFI работи с клавиатура,
  мишка, сензорен екран и USB геймпади.
- **Образите остават файлове.** Образите ISO, WIM, IMG, VHD, VHDX и EFI се
  четат направо от NTFS дяла DATA; нищо не се разархивира и след
  копирането не е нужно да се стартира нищо.
- **Защитен целеви диск.** Винаги вие избирате и потвърждавате диска;
  самата флашка USOS никога не се предлага.
- **Secure Boot** чрез shim 16.1 (подписан от Microsoft) и ключа на USOS
  (MOK), който се добавя веднъж на всеки компютър.
- **Стари Windows на нов хардуер.** Windows XP с пакет драйвери и PAE на
  UEFI с CSM; XP и Vista на UEFI без CSM чрез CSMWrap (експериментално);
  Windows 7 x64 без CSM чрез UefiSeven и диспечер, пренасочващ VGA;
  интеграция на USB 3 и NVMe за Windows 7.
- **Профили с отговори** за автоматично инсталиране на Windows и Linux,
  редактирани в менюто на UEFI с екранна клавиатура.
- **Linux ISO образи от DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla и други) на UEFI със и без Secure Boot, както и на
  BIOS.
- **Инструменти:** вграден FreeDOS с файлов мениджър и панел Hardware &
  SMART (BIOS), UEFI обвивка от EDK2 (UEFI), собствени стартиращи
  инструменти в `Utilities`, собствени UEFI драйвери и папки с INF драйвери
  за Windows.
- **Инсталатор с четири режима:** Инсталиране, Локално обновяване
  (**Обнови USOS**, запазва образите и вашите файлове), Поправка
  (**Поправи ESP**), Деинсталиране.
- **27 езика** (еталон е английският; останалите, с изключение на полския,
  са отбелязани като частично или изцяло машинно преведени), теми
  с редактор в самото меню, поддръжка на сензорен екран и геймпад на ROG
  Ally.

| | |
|---|---|
| ![Списък със системи Windows със значки за състояние](../images/windows-list.png) | ![Списък с Linux дистрибуции](../images/linux-list.png) |
| Системи Windows със значки за състояние | Linux ISO образи от DATA |
| ![Меню на Legacy BIOS](../images/bios-menu.png) | ![Вградени и потребителски теми](../images/themes-grid.png) |
| Менюто на Legacy BIOS | Теми: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Поддържани системи и режими на фърмуера

**HW** = тествано на реален хардуер, **VM** = тествано само
в QEMU/VirtualBox, **експ.** = експериментално (отбелязано така в менюто),
**нетествано** = пътят съществува, но няма записано изпълнение,
**—** = не се поддържа (менюто показва причината). Тестови машини:
**X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100**
(MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
със Secure Boot).

| Система | BIOS (Legacy) | UEFI + CSM | UEFI без CSM (CSMWrap) | Secure Boot включен |
|---|---|---|---|---|
| Самото меню на USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 в стандартен режим, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW частично (MS-7100: Setup до подготовката за първо стартиране, работният плот не е потвърден) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | експ., VM (до копирането на файлове) | експ., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (без пакет драйвери, без PAE) | HW (X470: пакет драйвери, PAE, 31,9 GB) | експ., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | нетествано | експ., VM (до GUI Setup); X470: STOP 0xA5 | експ., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | нетествано | експ., VM (до GUI Setup); X470 нетестван с 1.0 | експ., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | експ., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (пълна инсталация) | HW (X470, UefiSeven + диспечер) | — |
| Windows 8 / 8.1 | нетествано | нетествано | нетествано | нетествано |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | нативен UEFI, същият път като с CSM | VM (до зареждащата програма на Windows) |
| Windows 11 | нетествано | HW (съобщение от потребител) | нативен UEFI, същият път като с CSM | VM (до зареждащата програма на Windows) |
| Windows Server 2008 - 2025 | експ., никога не е стартиран | експ., никога не е стартиран | експ., никога не е стартиран | 2008/2008 R2: —; 2012+: нетествано |
| Linux ISO образи (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | както с CSM | HW Fedora, Mint (X470); останалите VM |
| SystemRescue | VM | HW (X470) | както с CSM | — (няма подписана зареждаща програма) |
| FreeDOS, Hardware & SMART (вградени) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, осигурявате го вие) | HW | `.efi` версия от `Utilities` (нетествано) | както с CSM | само подписан `.efi` |
| UEFI обвивка (вградена) | — | VM | VM | VM (стартира, но не може да стартира инструменти) |

UEFI със или без CSM има значение само за legacy пътищата (2000, XP, 2003,
Vista, 7); всички останали UEFI елементи изпълняват един и същ код и в двата
режима. Windows XP, Vista и 7, както и всеки път през CSMWrap изискват
изключен Secure Boot. Пълната таблица с бележки и резултатите от хардуера
за отделните компилации са в
[ръководството за потребителя, раздел 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
(на английски) и в [бележките към изданието](../release-notes-1.0.md#supported-systems)
(на английски).

<a id="quick-start"></a>
## 4. Бърз старт

Файлове на изданието:

| Файл | Предназначение |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Пълен инсталатор**: целият USOS плюс донора WinPE и двата пакета за XP; работи офлайн |
| `USOS-Installer-1.0.0-online.exe` | **Онлайн инсталатор**: малък файл; при нужда изтегля донора WinPE и пакетите за XP от това издание и ги проверява |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | донор PE10, нужен за Vista и оригиналните ISO образи на Windows 7 на UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | UEFI пакет за Windows XP x86 SP3, всеки за точно един оригинален ISO образ (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), инсталира се с приложения `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | изходният код на компонентите на трети страни и писменото предложение за изходен код |
| `USOS-1.0.0-buildkit.zip` | фиксирани инструменти и входни данни за компилиране без интернет |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | текстове на лицензите и известия |
| `SHA256SUMS` | SHA-256 на всеки файл |

Проверете изтегления файл с
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (или `Get-FileHash`
в PowerShell), като сравните резултата със `SHA256SUMS`.

![Инсталатор на USOS: избор на операция](../images/installer-mode.png)

1. Вземете USB флашка с капацитет **поне 32 GiB** (на практика 64 GB;
   флашка, продавана като „32 GB“, обикновено е твърде малка). **Всичко
   на нея ще бъде изтрито.**
2. На компютър с Windows стартирайте `USOS-Installer-1.0.0.exe` (ще поиска
   администраторски права), изберете **Инсталиране**, посочете флашката,
   въведете текста за потвърждение и щракнете **ИЗТРИЙ И ИНСТАЛИРАЙ**.
3. Копирайте ISO образите си в дяла DATA, в папката `Images` на
   съответната система, напр. `Systems\Windows\Windows 11\Images\`.
4. По избор: за Vista или оригинален Windows 7 на UEFI копирайте папката
   `Programs` от архива на донора PE10 в корена на DATA и стартирайте
   **Обнови USOS**; за XP на UEFI стартирайте като администратор
   `install-xp-package.ps1` от пакета за XP, който отговаря на вашия ISO
   образ (само един пакет наведнъж).
5. Стартирайте целевия компютър от флашката (BIOS или UEFI). При включен
   Secure Boot добавете ключа на USOS веднъж ([Secure Boot](#secure-boot)).
   Изберете системата и образа, по желание профил с отговори, потвърдете
   целевия диск и следвайте инсталатора на системата.

Инструкции стъпка по стъпка за всеки екран има в ръководството за
потребителя: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Структура на папките в DATA

Инсталаторът създава на флашката три дяла: `USOS_ESP` (FAT32, 1 GiB:
файлове за стартиране, ключ, настройки, журнали, профили), `USOS_DATA`
(NTFS: вашите файлове) и `USOS_WORK` (NTFS, работно пространство за някои
инсталатори на Windows). Всички папки в DATA се създават автоматично:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<версия>\       Images\  Unattended\   (от Windows 3.1 до 11, Server 2003-2025)
│  ├─ Linux\<дистрибуция>\    Images\  Unattended\   (Other Linux\ за непознати ISO образи)
│  ├─ Betas\
│  └─ DOS\<вариант>\          Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\       DOS програми за вградения FreeDOS
│  ├─ UEFI Shell\Tools\       EFI инструменти за UEFI обвивката
│  └─ <ваш инструмент>\Images\   напр. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<име>\             .efi драйвери, зареждани от менюто на USOS
│  └─ <версия на Windows>\    Storage\  USB\  Other\  (INF пакети)
├─ Themes\<име>\theme.ini     собствени теми (UEFI меню)
└─ Programs\
   └─ USOS\                   управлява се от USOS (донор PE10), не пипайте
```

След добавяне на `icon.png` или нова папка с инструмент стартирайте
**Обнови USOS**. Пълното дърво е в
[ръководството за потребителя, раздел 4](../USER-GUIDE.en.md#4-folder-layout-on-data)
(на английски).

<a id="secure-boot"></a>
## 6. Secure Boot

При включен Secure Boot USOS стартира чрез **shim 16.1** (компилация на
Fedora, подписана от Microsoft UEFI CA) и MokManager. Самият USOS и
компонентите му са подписани с **ключа на USOS**, който се добавя **веднъж
на всеки компютър**:

- **Най-лесно:** изключете Secure Boot, стартирайте от флашката, изберете
  **Добави** на началния екран и потвърдете с **Да, запиши ключа**, след
  което отново включете Secure Boot. Това работи и в Setup Mode
  (потвърдено на X470).
- **Без да изключвате Secure Boot:** на екрана „Verification failed“
  изберете в MokManager **Enroll key from disk** -> `USOS_ESP` ->
  `USOS-KEY.cer` (потвърдено на ROG Ally). Картата **Подготви
  (еднократно)** в инсталатора кара MokManager да чака, вместо да отброява.

Нулирането на NVRAM премахва ключа; добавете го отново. XP, Vista, 7,
всеки път през CSMWrap, SystemRescue и инструментите, стартирани от UEFI
обвивката, изискват изключен Secure Boot. Ядрото все още не е заключено
(точка N6 от пътната карта), така че добавянето на ключа на USOS означава
доверие към всичко, подписано с него. Подробности:
[ръководство за потребителя, раздел 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok)
(на английски), [secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Профили с отговори

Един малък профил (акаунти, име на компютъра, език, часова зона, незадължителни
настройки) при стартиране се превръща в `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (от Vista до 11, Server) или в Ubuntu autoinstall,
Debian preseed или Fedora kickstart. Профилите се създават в менюто на UEFI
(**Автоматично инсталиране** -> **+ Добавяне на нов профил**) и се
съхраняват в ESP.

![Редактор на профил с отговори, раздел „Външен вид и допълнения“](../images/profile-editor-appearance.png)

- Целевият диск **винаги се избира ръчно**; профилът никога не избира и не
  изтрива диск.
- Продуктовият ключ се запазва само ако отметнете „Запомни ключа на тази
  флашка“; иначе се пази само до рестартирането. **USOS не съдържа
  ключове** и не заобикаля активацията или страницата за продуктов ключ.
- Паролите и запомнените ключове се съхраняват на флашката като обикновен
  текст (никога не се показват в списъци или журнали). Профилите за Linux
  работят само на UEFI.

Подробности: [ръководство за потребителя, раздел 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks)
(на английски), [answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Известни проблеми

- **Vista на дънни платки само с USB 3 (X470):** USB флашките не се виждат
  в инсталираната система, а Vista остава в тестов режим (backport на USB 3
  с тестов подпис). PCIe карта Renesas uPD72020x избягва и двата проблема.
- **Пътища през CSMWrap:** изискват видеокарта с legacy VBIOS (иначе черен
  екран), заемат една нишка на процесора, изискват целеви диск с MBR (той
  се изтрива) и изключен Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) на X470 и липса на USB
  вход на дънни платки само с xHCI.
- **Windows 2000** не работи на дънни платки само с AHCI (няма AHCI драйвер
  за NT 5.0); **XP** няма поддръжка на NVMe и в режим BIOS не получава
  пакет драйвери, нито PAE.
- **Secure Boot:** SystemRescue е блокиран (няма подписана зареждаща
  програма); UEFI обвивката не може да стартира инструменти; след
  обновяването на DBX срещу BlackLotus по-старите носители на Windows не
  стартират.
- **Linux:** инсталаторът на Ubuntu Server предварително избира най-големия
  диск, който може да е флашката USOS; винаги проверявайте целевия диск.
- **Фърмуерът AMI** показва всеки дял на флашката като отделен елемент за
  стартиране.
- Помощният микро-Linux изисква процесор x86-64 и поне 256 MiB RAM.

Пълният списък с начини за заобикаляне, както и честният списък на това,
което все още **не е тествано** на хардуер (напр. Windows Server
2008-2025, Windows 8/8.1, Windows 10/11 със Secure Boot на хардуер,
оригиналният ISO образ на Windows 7 SP1 чрез донора PE10), са в
[бележките към изданието](../release-notes-1.0.md#known-issues) (на
английски) и в
[ръководството за потребителя, раздели 9 и 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds)
(на английски).

<a id="building"></a>
## 9. Компилиране от изходния код

Компилирането се извършва под Windows. Пълни инструкции:
[BUILDING.md](../BUILDING.md) (на английски).

- `build.bat` компилира цялото издание (EFI програмата, микро-Linux, ядрото
  за BIOS, payload и `installer\USOS Installer.exe`) с един идентификатор
  на компилацията (`BYYMMDD-HHMMSS-XXXXXXXX`). Използва се преносимият Zig
  от `tools/zig`; Go и Python трябва да са в `PATH`.
- `tools/tests/run.ps1` изпълнява автоматичните тестове, напр.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  създава файловете на изданието в `zig-out\release-1.0\`.
- **Компилиране без интернет:** разархивирайте `USOS-1.0.0-buildkit.zip`,
  задайте в `USOS_BUILDKIT` разархивираната папка `USOS-1.0.0-buildkit`
  и стартирайте `build.bat`; комплектът се проверява спрямо манифеста си,
  а изтеглянията са изключени.
- **Ключ за подписване:** ключът за Secure Boot (MOK) се намира **извън
  хранилището**, в `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` променя
  това място). Без него компилацията е **неподписана** и стартира само при
  изключен Secure Boot. Никога не къмитвайте и не споделяйте ключа.

ISO образи на Windows, драйвери и други носители на трети страни никога не
са част от хранилището.

<a id="licence"></a>
## 10. Лиценз

- Собственият код на USOS е лицензиран под **GNU General Public License,
  версия 3 или по-нова** (GPL-3.0-or-later): вижте [LICENSE](../../LICENSE)
  и [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Компонентите на трети страни запазват собствените си лицензи. Те са
  отделни програми, събрани заедно на флашката; вижте
  `THIRD-PARTY-NOTICES.txt` и `LICENSES/` в изданието и
  [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Файловете на Microsoft в изданието (файлове за обновяване и драйвери,
  файловете в пакетите за XP, донорът WinPE) са запазени с архивна цел,
  разпространяват се на собствен риск на поддържащия проекта, не са обхванати
  от никой лиценз на USOS и ще бъдат премахнати по искане на притежателя на
  правата.
- Приносите се приемат съгласно [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (опростено предоставяне на лиценз от автора на приноса).

Windows, MS-DOS и свързаните с тях имена са търговски марки на Microsoft.
USOS не е свързан с Microsoft.

<a id="support"></a>
## 11. Поддръжка

- Въпроси и доклади за грешки: GitHub Issues. Моля, приложете журналите,
  описани в [ръководството за потребителя, раздел 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  (на английски), и проверете, че в тях няма пароли или ключове.
- Платена помощ при настройката за фирми е налична при запитване; засега се
  свържете чрез GitHub Issues.
- Спонсориране: чрез `.github/FUNDING.yml`, след като бъде попълнен.

<a id="documentation"></a>
## 12. Документация

- Ръководство за потребителя: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Бележки към изданието 1.0](../release-notes-1.0.md) (на английски)
- [Как работи USOS](../HOW-IT-WORKS.md)
- [Компилиране](../BUILDING.md)
- [Одит на лицензите](../LICENSES-AUDIT.md)
- [План за тестване на изданието 1.0](../RELEASE-TEST-1.0.md)
- [Пътна карта](../ROADMAP.md) (на полски) и [резултати от тестовете](../../TESTING.md) (на полски)
