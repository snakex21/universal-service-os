# Universal Service OS (USOS) 1.0.0

> Це переклад. Основною є [англійська версія README](../../README.md).

**Мови:** [English](../../README.md) ·
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
[Русский](README.ru.md) ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
Українська

## Зміст

1. [Що таке USOS](#what-usos-is)
2. [Можливості](#features)
3. [Підтримувані системи та режими прошивки](#supported-systems)
4. [Швидкий старт](#quick-start)
5. [Структура папок на DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Профілі відповідей](#answer-profiles)
8. [Відомі проблеми](#known-issues)
9. [Збирання з вихідного коду](#building)
10. [Ліцензія](#licence)
11. [Підтримка](#support)
12. [Документація](#documentation)

<a id="what-usos-is"></a>
## 1. Що таке USOS

USOS — це одна USB-флешка для встановлення та запуску операційних систем,
від MS-DOS до Windows 11 і Linux, на комп'ютерах з BIOS та UEFI, зокрема
з UEFI та увімкненим Secure Boot. Власні образи ISO ви копіюєте на флешку
як звичайні файли; USOS дає одне меню, явний і захищений вибір цільового
диска, а також драйвери й виправлення, потрібні старим системам на новому
обладнанні. Флешку готують у Windows програмою `USOS-Installer-1.0.0.exe`.
USOS не містить образів Windows, ключів продукту та засобів обходу
активації.

![Меню UEFI USOS, головний екран](../images/menu-home.png)

<a id="features"></a>
## 2. Можливості

- **Одне меню для BIOS і UEFI.** Та сама флешка запускається в Legacy BIOS
  і в UEFI (x64) з тим самим каталогом. Меню UEFI працює з клавіатурою,
  мишею, сенсорним екраном і USB-геймпадами.
- **Образи залишаються файлами.** Образи ISO, WIM, IMG, VHD, VHDX та EFI
  читаються безпосередньо з розділу NTFS DATA; нічого не розпаковується,
  і після копіювання нічого не треба запускати.
- **Захищений цільовий диск.** Диск ви завжди вибираєте й підтверджуєте
  самі; сама флешка USOS ніколи не пропонується.
- **Secure Boot** через shim 16.1 (підписаний Microsoft) і ключ USOS (MOK),
  який додається один раз на кожному комп'ютері.
- **Старі Windows на новому обладнанні.** Windows XP з пакетом драйверів
  і PAE в UEFI з CSM; XP і Vista в UEFI без CSM через CSMWrap
  (експериментально); Windows 7 x64 без CSM через UefiSeven і диспетчер,
  що перенаправляє VGA; інтеграція USB 3 і NVMe для Windows 7.
- **Профілі відповідей** для автоматичного встановлення Windows і Linux,
  редагуються в меню UEFI з екранною клавіатурою.
- **ISO-образи Linux з DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla та інші) в UEFI із Secure Boot і без нього, а також
  у BIOS.
- **Інструменти:** вбудований FreeDOS з файловим менеджером і панеллю
  Hardware & SMART (BIOS), оболонка UEFI з EDK2 (UEFI), ваші власні
  завантажувальні інструменти в `Utilities`, ваші драйвери UEFI та папки
  з INF-драйверами для Windows.
- **Інсталятор із чотирма режимами:** Встановлення, Локальне оновлення
  (**Оновити USOS**, зберігає образи та ваші файли), Відновлення
  (**Відновити ESP**), Видалення.
- **27 мов** (еталон — англійська; решта мов, крім польської, позначені як
  частково або повністю перекладені машинним способом), теми з редактором
  просто в меню, підтримка сенсорного екрана й геймпада на ROG Ally.

| | |
|---|---|
| ![Список систем Windows зі значками стану](../images/windows-list.png) | ![Список дистрибутивів Linux](../images/linux-list.png) |
| Системи Windows зі значками стану | ISO-образи Linux з DATA |
| ![Меню Legacy BIOS](../images/bios-menu.png) | ![Вбудовані та користувацькі теми](../images/themes-grid.png) |
| Меню Legacy BIOS | Теми: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Підтримувані системи та режими прошивки

**HW** = перевірено на реальному обладнанні, **VM** = перевірено лише
в QEMU/VirtualBox, **експ.** = експериментально (так і позначено в меню),
**не перевірено** = шлях існує, але жодного запуску не зафіксовано,
**—** = не підтримується (меню показує причину). Тестові машини: **X470**
(ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI,
Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
із Secure Boot).

| Система | BIOS (Legacy) | UEFI + CSM | UEFI без CSM (CSMWrap) | Secure Boot увімкнено |
|---|---|---|---|---|
| Саме меню USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 у стандартному режимі, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW частково (MS-7100: Setup до підготовки першого запуску, робочий стіл не підтверджено) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | експ., VM (до копіювання файлів) | експ., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (без пакета драйверів, без PAE) | HW (X470: пакет драйверів, PAE, 31,9 GB) | експ., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | не перевірено | експ., VM (до GUI Setup); X470: STOP 0xA5 | експ., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | не перевірено | експ., VM (до GUI Setup); X470 з 1.0 не перевірявся | експ., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | експ., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (повне встановлення) | HW (X470, UefiSeven + диспетчер) | — |
| Windows 8 / 8.1 | не перевірено | не перевірено | не перевірено | не перевірено |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | нативний UEFI, той самий шлях, що й із CSM | VM (до завантажувача Windows) |
| Windows 11 | не перевірено | HW (повідомлення користувача) | нативний UEFI, той самий шлях, що й із CSM | VM (до завантажувача Windows) |
| Windows Server 2008 - 2025 | експ., жодного разу не запускався | експ., жодного разу не запускався | експ., жодного разу не запускався | 2008/2008 R2: —; 2012+: не перевірено |
| ISO-образи Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | як із CSM | HW Fedora, Mint (X470); решта VM |
| SystemRescue | VM | HW (X470) | як із CSM | — (немає підписаного завантажувача) |
| FreeDOS, Hardware & SMART (вбудовані) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, надаєте самі) | HW | збірка `.efi` з `Utilities` (не перевірено) | як із CSM | лише підписаний `.efi` |
| Оболонка UEFI (вбудована) | — | VM | VM | VM (запускається, але не може запускати інструменти) |

UEFI з CSM чи без нього має значення лише для legacy-шляхів (2000, XP,
2003, Vista, 7); усі інші пункти UEFI виконують той самий код в обох
режимах. Windows XP, Vista і 7, а також усі шляхи через CSMWrap потребують
вимкненого Secure Boot. Повна таблиця з примітками та результатами на
обладнанні для окремих збірок — у
[посібнику користувача, розділ 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
(англійською) і в [примітках до випуску](../release-notes-1.0.md#supported-systems)
(англійською).

<a id="quick-start"></a>
## 4. Швидкий старт

Файли випуску:

| Файл | Призначення |
|---|---|
| `USOS-Installer-1.0.0.exe` | інсталятор; містить увесь USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | донор PE10, потрібен для Vista та оригінальних ISO Windows 7 в UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | пакет UEFI для Windows XP x86 SP3, кожен рівно для одного оригінального ISO (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), встановлюється доданим скриптом `install-xp-package.ps1` |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | вихідний код сторонніх компонентів і письмова пропозиція надати вихідний код |
| `USOS-1.0.0-buildkit.zip` | зафіксовані набори інструментів і вхідні дані збирання для офлайн-перезбирання |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | тексти ліцензій і повідомлення |
| `SHA256SUMS` | SHA-256 кожного файлу |

Перевірте завантажений файл командою
`certutil -hashfile USOS-Installer-1.0.0.exe SHA256` (або `Get-FileHash`
у PowerShell), порівнявши результат із `SHA256SUMS`.

![Інсталятор USOS: вибір операції](../images/installer-mode.png)

1. Візьміть USB-флешку обсягом **щонайменше 32 GiB** (на практиці 64 GB;
   флешка, що продається як «32 GB», зазвичай замала). **Усе, що на ній є,
   буде стерто.**
2. На комп'ютері з Windows запустіть `USOS-Installer-1.0.0.exe` (він
   запитає права адміністратора), виберіть **Встановлення**, вкажіть
   флешку, введіть текст підтвердження і натисніть **СТЕРТИ І ВСТАНОВИТИ**.
3. Скопіюйте образи ISO на розділ DATA, у папку `Images` відповідної
   системи, наприклад `Systems\Windows\Windows 11\Images\`.
4. Необов'язково: для Vista або оригінальної Windows 7 в UEFI скопіюйте
   папку `Programs` з архіву донора PE10 до кореня DATA і запустіть
   **Оновити USOS**; для XP в UEFI запустіть від імені адміністратора
   `install-xp-package.ps1` з пакета XP, що відповідає вашому ISO (лише
   один пакет за раз).
5. Завантажте цільовий комп'ютер із флешки (BIOS або UEFI). Якщо Secure
   Boot увімкнено, один раз додайте ключ USOS ([Secure Boot](#secure-boot)).
   Виберіть систему й образ, за бажанням профіль відповідей, підтвердьте
   цільовий диск і дотримуйтеся вказівок інсталятора системи.

Покрокові інструкції для кожного екрана — у посібнику
користувача: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Структура папок на DATA

Інсталятор створює на флешці три розділи: `USOS_ESP` (FAT32, 1 GiB:
завантажувальні файли, ключ, налаштування, журнали, профілі), `USOS_DATA`
(NTFS: ваші файли) і `USOS_WORK` (NTFS, робочий простір для деяких
інсталяторів Windows). Усі папки на DATA створюються автоматично:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<версія>\      Images\  Unattended\   (від Windows 3.1 до 11, Server 2003-2025)
│  ├─ Linux\<дистрибутив>\   Images\  Unattended\   (Other Linux\ для невідомих ISO)
│  ├─ Betas\
│  └─ DOS\<варіант>\         Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\      програми DOS для вбудованого FreeDOS
│  ├─ UEFI Shell\Tools\      інструменти EFI для оболонки UEFI
│  └─ <ваш інструмент>\Images\   напр. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<назва>\          драйвери .efi, що завантажуються меню USOS
│  └─ <версія Windows>\      Storage\  USB\  Other\  (пакети INF)
├─ Themes\<назва>\theme.ini  ваші власні теми (меню UEFI)
└─ Programs\
   └─ USOS\                  керується USOS (донор PE10), не чіпати
```

Після додавання `icon.png` або нової папки з інструментом запустіть
**Оновити USOS**. Повне дерево — у
[посібнику користувача, розділ 4](../USER-GUIDE.en.md#4-folder-layout-on-data)
(англійською).

<a id="secure-boot"></a>
## 6. Secure Boot

Якщо Secure Boot увімкнено, USOS запускається через **shim 16.1** (збірка
Fedora, підписана Microsoft UEFI CA) і MokManager. Сам USOS і його
компоненти підписані **ключем USOS**, який додається **один раз на кожному
комп'ютері**:

- **Найпростіше:** вимкніть Secure Boot, завантажтеся з флешки, на
  головному екрані виберіть **Додати** і підтвердьте **Так, зберегти
  ключ**, потім знову увімкніть Secure Boot. Це працює і в Setup Mode
  (підтверджено на X470).
- **Не вимикаючи Secure Boot:** на екрані «Verification failed» виберіть
  у MokManager **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (підтверджено на ROG Ally). Картка **Підготувати (одноразово)**
  в інсталяторі змушує MokManager чекати замість зворотного відліку.

Скидання NVRAM видаляє ключ; додайте його знову. XP, Vista, 7, усі шляхи
через CSMWrap, SystemRescue та інструменти, що запускаються з оболонки
UEFI, потребують вимкненого Secure Boot. Ядро поки не заблоковано (пункт N6
дорожньої карти), тому додавання ключа USOS означає довіру до всього, що
ним підписано. Докладніше:
[посібник користувача, розділ 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok)
(англійською), [secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Профілі відповідей

Один невеликий профіль (облікові записи, ім'я комп'ютера, мова, часовий
пояс, необов'язкові налаштування) під час запуску перетворюється на
`WINNT.SIF` (2000/XP/2003), `autounattend.xml` (від Vista до 11, Server)
або на Ubuntu autoinstall, Debian preseed чи Fedora kickstart. Профілі
створюються в меню UEFI (**Автоматичне встановлення** -> **+ Додати новий
профіль**) і зберігаються на ESP.

![Редактор профілю відповідей, розділ «Зовнішній вигляд і додатки»](../images/profile-editor-appearance.png)

- Цільовий диск **завжди вибирається вручну**; профіль ніколи не вибирає
  і не стирає диск.
- Ключ продукту зберігається, лише якщо ви позначите «Запам'ятати ключ на
  цій флешці»; інакше він зберігається тільки до перезавантаження. **USOS
  не містить ключів** і не обходить активацію чи сторінку введення ключа
  продукту.
- Паролі та запам'ятовані ключі зберігаються на флешці відкритим текстом
  (вони ніколи не показуються у списках чи журналах). Профілі Linux
  працюють лише в UEFI.

Докладніше: [посібник користувача, розділ 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks)
(англійською), [answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Відомі проблеми

- **Vista на платах лише з USB 3 (X470):** USB-флешки не видно
  у встановленій системі, а Vista залишається в тестовому режимі (бекпорт
  USB 3 з тестовим підписом). Карта PCIe Renesas uPD72020x усуває обидві
  проблеми.
- **Шляхи через CSMWrap:** потрібна відеокарта з legacy VBIOS (інакше
  чорний екран), займають один потік CPU, потребують цільового диска MBR
  (його буде стерто) і вимкненого Secure Boot.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) на X470 і немає введення
  з USB на платах лише з xHCI.
- **Windows 2000** не працює на платах лише з AHCI (немає драйвера AHCI
  для NT 5.0); **XP** не підтримує NVMe і в режимі BIOS не отримує ні
  пакета драйверів, ні PAE.
- **Secure Boot:** SystemRescue заблоковано (немає підписаного
  завантажувача); оболонка UEFI не може запускати інструменти; після
  оновлення DBX проти BlackLotus старі носії Windows не запускаються.
- **Linux:** інсталятор Ubuntu Server заздалегідь вибирає найбільший диск,
  яким може виявитися флешка USOS; завжди перевіряйте цільовий диск.
- **Прошивки AMI** показують кожен розділ флешки як окремий пункт
  завантаження.
- Допоміжному micro-Linux потрібен процесор x86-64 і щонайменше 256 MiB
  RAM.

Повний список з обхідними шляхами, а також чесний список того, що ще **не
перевірено** на обладнанні (наприклад, Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 із Secure Boot на обладнанні, оригінальний
ISO Windows 7 SP1 через донор PE10), наведено в
[примітках до випуску](../release-notes-1.0.md#known-issues) (англійською)
і в [посібнику користувача, розділи 9 і 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds)
(англійською).

<a id="building"></a>
## 9. Збирання з вихідного коду

Збирання виконується в Windows. Повна інструкція: [BUILDING.md](../BUILDING.md)
(англійською).

- `build.bat` збирає весь випуск (програму EFI, micro-Linux, ядро BIOS,
  payload і `installer\USOS Installer.exe`) з одним ідентифікатором
  збірки (`BYYMMDD-HHMMSS-XXXXXXXX`). Використовується портативний Zig
  з `tools/zig`; Go і Python мають бути в `PATH`.
- `tools/tests/run.ps1` запускає автоматичні тести, наприклад
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  створює файли випуску в `zig-out\release-1.0\`.
- **Офлайн-збирання:** розпакуйте `USOS-1.0.0-buildkit.zip`, вкажіть
  у `USOS_BUILDKIT` шлях до розпакованої папки `USOS-1.0.0-buildkit`
  і запустіть `build.bat`; набір перевіряється за його маніфестом,
  завантаження вимкнено.
- **Ключ підпису:** ключ Secure Boot (MOK) зберігається **поза
  репозиторієм**, у `%APPDATA%\USOS\signing\` (змінна `USOS_SIGNING_DIR`
  перевизначає цей шлях). Без нього збірка **не підписана** і
  завантажується лише з вимкненим Secure Boot. Ніколи не комітьте ключ
  і нікому його не передавайте.

ISO-образи Windows, драйвери та інші сторонні носії ніколи не входять до
репозиторію.

<a id="licence"></a>
## 10. Ліцензія

- Власний код USOS поширюється за ліцензією **GNU General Public License
  версії 3 або новішої** (GPL-3.0-or-later): див. [LICENSE](../../LICENSE)
  і [NOTICE](../../NOTICE). Copyright (C) 2026 The USOS Authors.
- Сторонні компоненти зберігають власні ліцензії. Це окремі програми,
  зібрані разом на флешці; див. `THIRD-PARTY-NOTICES.txt` і `LICENSES/`
  у випуску та [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Файли Microsoft у випуску (файли оновлень і драйверів, файли в пакетах
  XP, донор WinPE) збережено з архівною метою, вони поширюються на власний
  ризик супровідника проєкту, не підпадають під жодну ліцензію USOS і будуть
  видалені на вимогу правовласника.
- Внески приймаються на умовах [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (спрощене надання ліцензії автором внеску).

Windows, MS-DOS і пов'язані з ними назви є торговельними марками Microsoft.
USOS не пов'язаний з Microsoft.

<a id="support"></a>
## 11. Підтримка

- Запитання та повідомлення про помилки: GitHub Issues. Додайте журнали,
  описані в [посібнику користувача, розділ 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  (англійською), і перевірте, що в них немає паролів чи ключів.
- Платна допомога з налаштуванням для компаній доступна на запит; поки що
  звертайтеся через GitHub Issues.
- Спонсорство: через `.github/FUNDING.yml`, коли його буде заповнено.

<a id="documentation"></a>
## 12. Документація

- Посібник користувача: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Примітки до випуску 1.0](../release-notes-1.0.md) (англійською)
- [Як працює USOS](../HOW-IT-WORKS.md)
- [Збирання](../BUILDING.md)
- [Аудит ліцензій](../LICENSES-AUDIT.md)
- [План тестування випуску 1.0](../RELEASE-TEST-1.0.md)
- [Дорожня карта](../ROADMAP.md) (польською) і [результати тестів](../../TESTING.md) (польською)
