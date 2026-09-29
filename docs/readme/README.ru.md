# Universal Service OS (USOS) 1.0.0

> Это перевод. Основной является [английская версия README](../../README.md).

**Языки:** [English](../../README.md) ·
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
[Italiano](README.it.md) ·
[Lietuvių](README.lt.md) ·
[Latviešu](README.lv.md) ·
[Norsk bokmål](README.nb.md) ·
[Nederlands](README.nl.md) ·
[Polski](README.pl.md) ·
[Português (Brasil)](README.pt-BR.md) ·
[Română](README.ro.md) ·
Русский ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Содержание

1. [Что такое USOS](#what-usos-is)
2. [Возможности](#features)
3. [Поддерживаемые системы и режимы прошивки](#supported-systems)
4. [Быстрый старт](#quick-start)
5. [Структура папок на DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Профили ответов](#answer-profiles)
8. [Известные проблемы](#known-issues)
9. [Сборка из исходного кода](#building)
10. [Лицензия](#licence)
11. [Поддержка](#support)
12. [Документация](#documentation)

<a id="what-usos-is"></a>
## 1. Что такое USOS

USOS — это одна USB-флешка для установки и запуска операционных систем, от
MS-DOS до Windows 11 и Linux, на компьютерах с BIOS и UEFI, в том числе
с UEFI и включённым Secure Boot. Свои образы ISO вы копируете на флешку как
обычные файлы; USOS даёт одно меню, явный и защищённый выбор целевого диска,
а также драйверы и исправления, которые нужны старым системам на новом
оборудовании. Флешка готовится в Windows программой
`USOS-Installer-1.0.0.exe`. USOS не содержит образов Windows, ключей
продукта и средств обхода активации.

![Меню UEFI USOS, главный экран](../images/menu-home.png)

<a id="features"></a>
## 2. Возможности

- **Одно меню для BIOS и UEFI.** Одна и та же флешка запускается в Legacy
  BIOS и в UEFI (x64) с одним и тем же каталогом. Меню UEFI работает
  с клавиатурой, мышью, сенсорным экраном и USB-геймпадами.
- **Образы остаются файлами.** Образы ISO, WIM, IMG, VHD, VHDX и EFI
  читаются прямо с раздела NTFS DATA; ничего не распаковывается, и после
  копирования ничего не нужно запускать.
- **Защищённый целевой диск.** Диск вы всегда выбираете и подтверждаете
  сами; сама флешка USOS никогда не предлагается.
- **Secure Boot** через shim 16.1 (подписан Microsoft) и ключ USOS (MOK),
  который добавляется один раз на каждом компьютере.
- **Старые Windows на новом оборудовании.** Windows XP с пакетом драйверов
  и PAE в UEFI с CSM; XP и Vista в UEFI без CSM через CSMWrap
  (экспериментально); Windows 7 x64 без CSM через UefiSeven и диспетчер,
  перенаправляющий VGA; интеграция USB 3 и NVMe для Windows 7.
- **Профили ответов** для автоматической установки Windows и Linux,
  редактируются в меню UEFI с экранной клавиатурой.
- **ISO-образы Linux с DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla и другие) в UEFI с Secure Boot и без него, а также
  в BIOS.
- **Инструменты:** встроенный FreeDOS с файловым менеджером и панелью
  Hardware & SMART (BIOS), оболочка UEFI из EDK2 (UEFI), ваши собственные
  загрузочные инструменты в `Utilities`, ваши драйверы UEFI и папки
  с INF-драйверами для Windows.
- **Установщик с четырьмя режимами:** Установка, Локальное обновление
  (**Обновить USOS**, сохраняет образы и ваши файлы), Восстановление
  (**Восстановить ESP**), Удаление.
- **27 языков** (эталон — английский; остальные языки, кроме польского,
  помечены как частично или полностью переведённые машинным способом), темы
  с редактором прямо в меню, поддержка сенсорного экрана и геймпада на ROG
  Ally.

| | |
|---|---|
| ![Список систем Windows со значками состояния](../images/windows-list.png) | ![Список дистрибутивов Linux](../images/linux-list.png) |
| Системы Windows со значками состояния | ISO-образы Linux с DATA |
| ![Меню Legacy BIOS](../images/bios-menu.png) | ![Встроенные и пользовательские темы](../images/themes-grid.png) |
| Меню Legacy BIOS | Темы: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Поддерживаемые системы и режимы прошивки

**HW** = проверено на реальном оборудовании, **VM** = проверено только
в QEMU/VirtualBox, **эксп.** = экспериментально (так и помечено в меню),
**не проверено** = путь существует, но ни одного запуска не зафиксировано,
**—** = не поддерживается (меню показывает причину). Тестовые машины:
**X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100**
(MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
с Secure Boot).

| Система | BIOS (Legacy) | UEFI + CSM | UEFI без CSM (CSMWrap) | Secure Boot включён |
|---|---|---|---|---|
| Само меню USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 в стандартном режиме, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW частично (MS-7100: Setup до подготовки первого запуска, рабочий стол не подтверждён) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | эксп., VM (до копирования файлов) | эксп., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (без пакета драйверов, без PAE) | HW (X470: пакет драйверов, PAE, 31,9 GB) | эксп., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | не проверено | эксп., VM (до GUI Setup); X470: STOP 0xA5 | эксп., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | не проверено | эксп., VM (до GUI Setup); X470 с 1.0 не проверялся | эксп., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | эксп., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (полная установка) | HW (X470, UefiSeven + диспетчер) | — |
| Windows 8 / 8.1 | не проверено | не проверено | не проверено | не проверено |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | нативный UEFI, тот же путь, что и с CSM | VM (до загрузчика Windows) |
| Windows 11 | не проверено | HW (сообщение пользователя) | нативный UEFI, тот же путь, что и с CSM | VM (до загрузчика Windows) |
| Windows Server 2008 - 2025 | эксп., ни разу не запускался | эксп., ни разу не запускался | эксп., ни разу не запускался | 2008/2008 R2: —; 2012+: не проверено |
| ISO-образы Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | как с CSM | HW Fedora, Mint (X470); остальное VM |
| SystemRescue | VM | HW (X470) | как с CSM | — (нет подписанного загрузчика) |
| FreeDOS, Hardware & SMART (встроенные) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, предоставляете сами) | HW | сборка `.efi` из `Utilities` (не проверено) | как с CSM | только подписанный `.efi` |
| Оболочка UEFI (встроенная) | — | VM | VM | VM (запускается, но не может запускать инструменты) |

UEFI с CSM или без него имеет значение только для legacy-путей (2000, XP,
2003, Vista, 7); все остальные пункты UEFI выполняют один и тот же код
в обоих режимах. Windows XP, Vista и 7, а также все пути через CSMWrap
требуют выключенного Secure Boot. Полная таблица с примечаниями
и результатами на оборудовании по отдельным сборкам — в
[руководстве пользователя, раздел 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
(на английском) и в [примечаниях к выпуску](../release-notes-1.0.md#supported-systems)
(на английском).

<a id="quick-start"></a>
## 4. Быстрый старт

Файлы выпуска:

| Файл | Назначение |
|---|---|
| `USOS-Installer-1.0.0.exe` | **Полный установщик**: весь USOS, донор WinPE и оба пакета XP; работает без интернета |
| `USOS-Installer-1.0.0-online.exe` | **Онлайн-установщик**: небольшой файл; при необходимости скачивает донор WinPE и пакеты XP из этого выпуска и проверяет их |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | донор PE10, нужен для Vista и оригинальных ISO Windows 7 в UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | пакет UEFI для Windows XP x86 SP3, каждый ровно для одного оригинального ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), устанавливается прилагаемым скриптом `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | исходный код сторонних компонентов и письменное предложение о предоставлении исходного кода |
| `USOS-1.0.0-buildkit.zip` | зафиксированные наборы инструментов и входные данные сборки для офлайн-пересборки |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | тексты лицензий и уведомления |
| `SHA256SUMS` | SHA-256 каждого файла |

Проверьте загруженный файл командой
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (или `Get-FileHash`
в PowerShell), сравнив результат с `SHA256SUMS`.

![Установщик USOS: выбор операции](../images/installer-mode.png)

1. Возьмите USB-флешку объёмом **не менее 32 GiB** (на практике 64 GB;
   флешка, продаваемая как «32 GB», обычно слишком мала). **Всё, что на ней
   есть, будет стёрто.**
2. На компьютере с Windows запустите `USOS-Installer-1.0.0.exe` (он
   запросит права администратора), выберите **Установка**, укажите флешку,
   введите текст подтверждения и нажмите **СТЕРЕТЬ И УСТАНОВИТЬ**.
3. Скопируйте образы ISO на раздел DATA, в папку `Images` соответствующей
   системы, например `Systems\Windows\Windows 11\Images\`.
4. Необязательно: для Vista или оригинальной Windows 7 в UEFI скопируйте
   папку `Programs` из архива донора PE10 в корень DATA и запустите
   **Обновить USOS**; для XP в UEFI запустите от имени администратора
   `install-xp-package.ps1` из пакета XP, подходящего к вашему ISO (только
   один пакет за раз).
5. Загрузите целевой компьютер с флешки (BIOS или UEFI). При включённом
   Secure Boot один раз добавьте ключ USOS ([Secure Boot](#secure-boot)).
   Выберите систему и образ, при желании профиль ответов, подтвердите
   целевой диск и следуйте указаниям установщика системы.

Пошаговые инструкции для каждого экрана — в руководстве
пользователя: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Структура папок на DATA

Установщик создаёт на флешке три раздела: `USOS_ESP` (FAT32, 1 GiB:
загрузочные файлы, ключ, настройки, журналы, профили), `USOS_DATA` (NTFS:
ваши файлы) и `USOS_WORK` (NTFS, рабочее пространство для некоторых
установщиков Windows). Все папки на DATA создаются автоматически:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<версия>\      Images\  Unattended\   (от Windows 3.1 до 11, Server 2003-2025)
│  ├─ Linux\<дистрибутив>\   Images\  Unattended\   (Other Linux\ для неизвестных ISO)
│  ├─ Betas\
│  └─ DOS\<вариант>\         Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\      программы DOS для встроенного FreeDOS
│  ├─ UEFI Shell\Tools\      инструменты EFI для оболочки UEFI
│  └─ <ваш инструмент>\Images\   напр. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<имя>\            драйверы .efi, загружаемые меню USOS
│  └─ <версия Windows>\      Storage\  USB\  Other\  (пакеты INF)
├─ Themes\<имя>\theme.ini    ваши собственные темы (меню UEFI)
└─ Programs\
   └─ USOS\                  управляется USOS (донор PE10), не трогать
```

После добавления `icon.png` или новой папки с инструментом запустите
**Обновить USOS**. Полное дерево — в
[руководстве пользователя, раздел 4](../USER-GUIDE.en.md#4-folder-layout-on-data)
(на английском).

<a id="secure-boot"></a>
## 6. Secure Boot

При включённом Secure Boot USOS запускается через **shim 16.1** (сборка
Fedora, подписана Microsoft UEFI CA) и MokManager. Сам USOS и его
компоненты подписаны **ключом USOS**, который добавляется **один раз на
каждом компьютере**:

- **Проще всего:** выключите Secure Boot, загрузитесь с флешки, на главном
  экране выберите **Добавить** и подтвердите **Да, сохранить ключ**, затем
  снова включите Secure Boot. Это работает и в Setup Mode (подтверждено на
  X470).
- **Не выключая Secure Boot:** на экране «Verification failed» выберите
  в MokManager **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (подтверждено на ROG Ally). Карточка **Подготовить (однократно)**
  в установщике заставляет MokManager ждать вместо обратного отсчёта.

Сброс NVRAM удаляет ключ; добавьте его снова. XP, Vista, 7, все пути через
CSMWrap, SystemRescue и инструменты, запускаемые из оболочки UEFI, требуют
выключенного Secure Boot. Ядро пока не заблокировано (пункт N6
дорожной карты), поэтому добавление ключа USOS означает доверие всему, что
им подписано. Подробности:
[руководство пользователя, раздел 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok)
(на английском), [secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Профили ответов

Один небольшой профиль (учётные записи, имя компьютера, язык, часовой пояс,
необязательные настройки) при запуске превращается в `WINNT.SIF`
(2000/XP/2003), `autounattend.xml` (от Vista до 11, Server) или в Ubuntu
autoinstall, Debian preseed или Fedora kickstart. Профили создаются в меню
UEFI (**Автоматическая установка** -> **+ Добавить новый профиль**)
и хранятся на ESP.

![Редактор профиля ответов, раздел «Внешний вид и дополнения»](../images/profile-editor-appearance.png)

- Целевой диск **всегда выбирается вручную**; профиль никогда не выбирает
  и не стирает диск.
- Ключ продукта сохраняется, только если вы отметите «Запомнить ключ на
  этой флешке»; иначе он хранится только до перезагрузки. **USOS не
  содержит ключей** и не обходит активацию или страницу ввода ключа
  продукта.
- Пароли и запомненные ключи хранятся на флешке открытым текстом (они
  никогда не показываются в списках или журналах). Профили Linux работают
  только в UEFI.

Подробности: [руководство пользователя, раздел 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks)
(на английском), [answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Известные проблемы

- **Vista на платах только с USB 3 (X470):** USB-флешки не видны
  в установленной системе, а Vista остаётся в тестовом режиме (бэкпорт
  USB 3 с тестовой подписью). Карта PCIe Renesas uPD72020x устраняет обе
  проблемы.
- **Пути через CSMWrap:** нужна видеокарта с legacy VBIOS (иначе чёрный
  экран), занимают один поток CPU, требуют целевой диск MBR (он стирается)
  и выключенный Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) на X470 и нет ввода с USB
  на платах только с xHCI.
- **Windows 2000** не работает на платах только с AHCI (нет драйвера AHCI
  для NT 5.0); **XP** не поддерживает NVMe и в режиме BIOS не получает ни
  пакета драйверов, ни PAE.
- **Secure Boot:** SystemRescue заблокирован (нет подписанного загрузчика);
  оболочка UEFI не может запускать инструменты; после обновления DBX против
  BlackLotus старые носители Windows не запускаются.
- **Linux:** установщик Ubuntu Server заранее выбирает самый большой диск,
  которым может оказаться флешка USOS; всегда проверяйте целевой диск.
- **Прошивки AMI** показывают каждый раздел флешки как отдельный пункт
  загрузки.
- Вспомогательному micro-Linux нужен процессор x86-64 и не менее 256 MiB
  RAM.

Полный список с обходными путями, а также честный список того, что ещё **не
проверено** на оборудовании (например, Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 с Secure Boot на оборудовании, оригинальный
ISO Windows 7 SP1 через донор PE10), приведены в
[примечаниях к выпуску](../release-notes-1.0.md#known-issues) (на
английском) и в
[руководстве пользователя, разделы 9 и 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds)
(на английском).

<a id="building"></a>
## 9. Сборка из исходного кода

Сборка выполняется в Windows. Полная инструкция: [BUILDING.md](../BUILDING.md)
(на английском).

- `build.bat` собирает весь выпуск (программу EFI, micro-Linux, ядро BIOS,
  payload и `installer\USOS Installer.exe`) с одним идентификатором сборки
  (`BYYMMDD-HHMMSS-XXXXXXXX`). Используется портативный Zig из `tools/zig`;
  Go и Python должны быть в `PATH`.
- `tools/tests/run.ps1` запускает автоматические тесты, например
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  создаёт файлы выпуска в `zig-out\release-1.0\`.
- **Офлайн-сборка:** распакуйте `USOS-1.0.0-buildkit.zip`, укажите
  в `USOS_BUILDKIT` путь к распакованной папке `USOS-1.0.0-buildkit`
  и запустите `build.bat`; набор проверяется по своему манифесту, загрузки
  отключены.
- **Ключ подписи:** ключ Secure Boot (MOK) хранится **вне репозитория**,
  в `%APPDATA%\USOS\signing\` (переменная `USOS_SIGNING_DIR` переопределяет
  этот путь). Без него сборка **не подписана** и загружается только при
  выключенном Secure Boot. Никогда не коммитьте ключ и никому его не
  передавайте.

ISO-образы Windows, драйверы и другие сторонние носители никогда не входят
в репозиторий.

<a id="licence"></a>
## 10. Лицензия

- Собственный код USOS распространяется по лицензии **GNU General Public
  License версии 3 или более поздней** (GPL-3.0-or-later): см.
  [LICENSE](../../LICENSE) и [NOTICE](../../NOTICE). Copyright (C) 2026 The
  USOS Authors.
- Сторонние компоненты сохраняют свои собственные лицензии. Это отдельные
  программы, собранные вместе на флешке; см. `THIRD-PARTY-NOTICES.txt`
  и `LICENSES/` в выпуске и [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Файлы Microsoft в выпуске (файлы обновлений и драйверов, файлы в пакетах
  XP, донор WinPE) сохранены в архивных целях, распространяются на
  собственный риск сопровождающего проекта, не подпадают ни под одну
  лицензию USOS и будут удалены по запросу правообладателя.
- Вклад в проект принимается на условиях [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (упрощённое предоставление лицензии автором вклада).

Windows, MS-DOS и связанные с ними названия являются товарными знаками
Microsoft. USOS не связан с Microsoft.

<a id="support"></a>
## 11. Поддержка

- Вопросы и сообщения об ошибках: GitHub Issues. Приложите журналы,
  описанные в [руководстве пользователя, раздел 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  (на английском), и проверьте, что в них нет паролей или ключей.
- Платная помощь с настройкой для компаний доступна по запросу; пока
  связывайтесь через GitHub Issues.
- Спонсорство: через `.github/FUNDING.yml`, когда он будет заполнен.

<a id="documentation"></a>
## 12. Документация

- Руководство пользователя: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Примечания к выпуску 1.0](../release-notes-1.0.md) (на английском)
- [Как работает USOS](../HOW-IT-WORKS.md)
- [Сборка](../BUILDING.md)
- [Аудит лицензий](../LICENSES-AUDIT.md)
- [План тестирования выпуска 1.0](../RELEASE-TEST-1.0.md)
- [Дорожная карта](../ROADMAP.md) (на польском) и [результаты тестов](../../TESTING.md) (на польском)
