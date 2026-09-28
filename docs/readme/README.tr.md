# Universal Service OS (USOS) 1.0.0

> Bu bir çeviridir. Bağlayıcı olan [README'nin İngilizce sürümüdür](../../README.md).

**Diller:** [English](../../README.md) ·
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
Türkçe ·
[Українська](README.uk.md)

## İçindekiler

1. [USOS nedir](#what-usos-is)
2. [Özellikler](#features)
3. [Desteklenen sistemler ve ürün yazılımı modları](#supported-systems)
4. [Hızlı başlangıç](#quick-start)
5. [DATA klasör yapısı](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Yanıt profilleri](#answer-profiles)
8. [Bilinen sorunlar](#known-issues)
9. [Kaynaktan derleme](#building)
10. [Lisans](#licence)
11. [Destek](#support)
12. [Belgeler](#documentation)

<a id="what-usos-is"></a>
## 1. USOS nedir

USOS, MS-DOS'tan Windows 11'e ve Linux'a kadar işletim sistemlerini BIOS ve
UEFI bilgisayarlarda, Secure Boot'lu UEFI dahil, kurmak ve başlatmak için
tek bir USB bellektir. Kendi ISO kalıplarınızı belleğe normal dosyalar gibi
kopyalarsınız; USOS size tek bir menü, hedef diskin açık ve korumalı
seçimini ve eski sistemlerin yeni donanımda ihtiyaç duyduğu sürücüleri ve
düzeltmeleri sunar. Bellek, Windows'ta `USOS-Installer-1.0.0.exe` ile
hazırlanır. USOS hiçbir Windows kalıbı, ürün anahtarı veya etkinleştirme
atlatma aracı içermez.

![USOS UEFI menüsü, ana ekran](../images/menu-home.png)

<a id="features"></a>
## 2. Özellikler

- **Tek menü, BIOS ve UEFI.** Aynı bellek, aynı katalogla hem Legacy
  BIOS'ta hem de UEFI'de (x64) başlar. UEFI menüsü klavye, fare, dokunmatik
  ekran ve USB oyun kumandalarıyla çalışır.
- **Kalıplar dosya olarak kalır.** ISO, WIM, IMG, VHD, VHDX ve EFI
  kalıpları doğrudan NTFS DATA bölümünden okunur; hiçbir şey açılmaz ve
  kopyalamadan sonra hiçbir şeyin çalıştırılması gerekmez.
- **Korumalı hedef disk.** Diski her zaman siz seçer ve onaylarsınız; USOS
  belleğinin kendisi asla önerilmez.
- **Secure Boot**, shim 16.1 (Microsoft tarafından imzalı) ve her
  bilgisayara bir kez kaydedilen USOS anahtarı (MOK) üzerinden.
- **Yeni donanımda eski Windows.** CSM'li UEFI'de sürücü paketi ve PAE ile
  Windows XP; CSMWrap aracılığıyla CSM'siz UEFI'de XP ve Vista (deneysel);
  UefiSeven ve bir VGA yönlendirme dağıtıcısı ile CSM'siz Windows 7 x64;
  Windows 7 için USB 3 ve NVMe entegrasyonu.
- **Yanıt profilleri**: Windows ve Linux'un gözetimsiz kurulumları için,
  UEFI menüsünde ekran klavyesiyle düzenlenir.
- **DATA'dan Linux ISO'ları** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla ve diğerleri), Secure Boot'lu ve Secure Boot'suz
  UEFI'de ve BIOS'ta.
- **Araçlar:** dosya yöneticisi ve Hardware & SMART paneli ile yerleşik
  FreeDOS (BIOS), EDK2 UEFI Kabuğu (UEFI), `Utilities` içinde kendi
  önyüklenebilir araçlarınız, kendi UEFI sürücüleriniz ve Windows INF
  sürücü klasörleri.
- **Dört modlu yükleyici:** Kurulum, Yerel güncelleme (**USOS'u güncelle**,
  kalıpları ve dosyalarınızı korur), Onarım (**ESP'yi onar**), Kaldırma.
- **27 dil** (başvuru dili İngilizcedir; Lehçe dışındaki diğer diller
  kısmen veya tamamen makine çevirisi olarak işaretlenmiştir), menü içi
  düzenleyiciye sahip temalar, ROG Ally'de dokunmatik ekran ve kumanda
  desteği.

| | |
|---|---|
| ![Durum rozetleriyle Windows sistemleri listesi](../images/windows-list.png) | ![Linux dağıtımları listesi](../images/linux-list.png) |
| Durum rozetleriyle Windows sistemleri | DATA'dan Linux ISO'ları |
| ![Legacy BIOS menüsü](../images/bios-menu.png) | ![Yerleşik ve kullanıcı temaları](../images/themes-grid.png) |
| Legacy BIOS menüsü | Temalar: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Desteklenen sistemler ve ürün yazılımı modları

**HW** = gerçek donanımda test edildi, **VM** = yalnızca QEMU/VirtualBox'ta
test edildi, **den.** = deneysel (menüde bu şekilde işaretli), **test
edilmedi** = yol mevcut ama kayıtlı bir çalıştırma yok, **—** =
desteklenmiyor (menü nedenini gösterir). Test makineleri: **X470** (ASRock
X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939,
Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, Secure Boot'lu UEFI).

| Sistem | BIOS (Legacy) | UEFI + CSM | CSM'siz UEFI (CSMWrap) | Secure Boot açık |
|---|---|---|---|---|
| USOS menüsünün kendisi | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (standart modda Windows 3.1, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW kısmen (MS-7100: Setup ilk önyükleme hazırlığına kadar, masaüstü doğrulanmadı) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | den., VM (dosya kopyalamaya kadar) | den., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (sürücü paketi yok, PAE yok) | HW (X470: sürücü paketi, PAE, 31,9 GB) | den., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | test edilmedi | den., VM (GUI Setup'a kadar); X470: STOP 0xA5 | den., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | test edilmedi | den., VM (GUI Setup'a kadar); X470 1.0 ile test edilmedi | den., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | den., HW (X470, CSMWrap, legacy MBR) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (tam kurulum) | HW (X470, UefiSeven + dağıtıcı) | — |
| Windows 8 / 8.1 | test edilmedi | test edilmedi | test edilmedi | test edilmedi |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | yerel UEFI, CSM'li ile aynı yol | VM (Windows yükleyicisine kadar) |
| Windows 11 | test edilmedi | HW (kullanıcı bildirimi) | yerel UEFI, CSM'li ile aynı yol | VM (Windows yükleyicisine kadar) |
| Windows Server 2008 - 2025 | den., hiç başlatılmadı | den., hiç başlatılmadı | den., hiç başlatılmadı | 2008/2008 R2: —; 2012+: test edilmedi |
| Linux ISO'ları (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | CSM'li ile aynı | HW Fedora, Mint (X470); geri kalanı VM |
| SystemRescue | VM | HW (X470) | CSM'li ile aynı | — (imzalı önyükleyici yok) |
| FreeDOS, Hardware & SMART (yerleşik) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (i586 ISO, kendiniz sağlarsınız) | HW | `Utilities` içinden `.efi` sürümü (test edilmedi) | CSM'li ile aynı | yalnızca imzalı `.efi` |
| UEFI Kabuğu (yerleşik) | — | VM | VM | VM (başlar, araçları çalıştıramaz) |

UEFI'nin CSM'li veya CSM'siz olması yalnızca eski (legacy) yollar için
önemlidir (2000, XP, 2003, Vista, 7); diğer tüm UEFI girişleri her iki
modda da aynı kodu çalıştırır. Windows XP, Vista ve 7 ile tüm CSMWrap
yolları Secure Boot'un kapalı olmasını gerektirir. Notlarla birlikte tam
tablo ve derleme başına donanım sonuçları
[kullanıcı kılavuzu, bölüm 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
(İngilizce) ve [sürüm notları](../release-notes-1.0.md#supported-systems)
(İngilizce) içindedir.

<a id="quick-start"></a>
## 4. Hızlı başlangıç

Sürüm dosyaları:

| Dosya | Amaç |
|---|---|
| `USOS-Installer-1.0.0.exe` | yükleyici; USOS'un tamamını içerir |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | PE10 donörü; UEFI'de Vista ve orijinal Windows 7 ISO'ları için gerekli |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | Windows XP x86 SP3 UEFI paketi, her biri tam olarak bir orijinal ISO için (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), birlikte gelen `install-xp-package.ps1` ile kurulur |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | üçüncü taraf bileşenlerin kaynak kodları ve yazılı kaynak kodu teklifi |
| `USOS-1.0.0-buildkit.zip` | çevrimdışı yeniden derleme için sabitlenmiş araç zincirleri ve derleme girdileri |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | lisans metinleri ve bildirimler |
| `SHA256SUMS` | her dosyanın SHA-256 değeri |

İndirilen bir dosyayı `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(veya PowerShell'de `Get-FileHash`) ile `SHA256SUMS` dosyasına göre
doğrulayın.

![USOS yükleyicisi: işlem seçimi](../images/installer-mode.png)

1. **En az 32 GiB** bir USB bellek edinin (pratikte 64 GB; “32 GB” olarak
   satılan bir bellek genellikle çok küçüktür). **Üzerindeki her şey
   silinecektir.**
2. Bir Windows bilgisayarda `USOS-Installer-1.0.0.exe` dosyasını çalıştırın
   (yönetici hakları ister), **Kurulum**'u seçin, belleği seçin, onay
   metnini yazın ve **SİL VE KUR**'a tıklayın.
3. ISO kalıplarınızı DATA bölümüne, her sistemin `Images` klasörüne
   kopyalayın, ör. `Systems\Windows\Windows 11\Images\`.
4. İsteğe bağlı: UEFI'de Vista veya orijinal Windows 7 için PE10 donör
   zip'indeki `Programs` klasörünü DATA'nın köküne kopyalayın ve **USOS'u
   güncelle**'yi çalıştırın; UEFI'de XP için ISO'nuza uyan XP paketindeki
   `install-xp-package.ps1` betiğini yönetici olarak çalıştırın (bir
   seferde bir paket).
5. Hedef bilgisayarı bellekten başlatın (BIOS veya UEFI). Secure Boot
   açıksa USOS anahtarını bir kez kaydedin ([Secure Boot](#secure-boot)).
   Sistemi ve kalıbı, isteğe bağlı olarak bir yanıt profilini seçin, hedef
   diski onaylayın ve sistemin yükleyicisini izleyin.

Her ekran için adım adım talimatlar kullanıcı
kılavuzundadır: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. DATA klasör yapısı

Yükleyici belleği üç bölümle oluşturur: `USOS_ESP` (FAT32, 1 GiB:
önyükleme dosyaları, anahtar, ayarlar, günlükler, profiller), `USOS_DATA`
(NTFS: dosyalarınız) ve `USOS_WORK` (NTFS, bazı Windows yükleyicileri için
çalışma alanı). DATA üzerindeki tüm klasörler sizin için oluşturulur:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<sürüm>\      Images\  Unattended\   (Windows 3.1'den 11'e, Server 2003-2025)
│  ├─ Linux\<dağıtım>\      Images\  Unattended\   (bilinmeyen ISO'lar için Other Linux\)
│  ├─ Betas\
│  └─ DOS\<tür>\            Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     yerleşik FreeDOS için DOS programları
│  ├─ UEFI Shell\Tools\     UEFI Kabuğu için EFI araçları
│  └─ <aracınız>\Images\    ör. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<ad>\            USOS menüsünün yüklediği .efi sürücüleri
│  └─ <Windows sürümü>\     Storage\  USB\  Other\  (INF paketleri)
├─ Themes\<ad>\theme.ini    kendi temalarınız (UEFI menüsü)
└─ Programs\
   └─ USOS\                 USOS tarafından yönetilir (PE10 donörü), dokunmayın
```

Bir `icon.png` veya yeni bir araç klasörü ekledikten sonra **USOS'u
güncelle**'yi çalıştırın. Tam ağaç
[kullanıcı kılavuzu, bölüm 4](../USER-GUIDE.en.md#4-folder-layout-on-data)
(İngilizce) içindedir.

<a id="secure-boot"></a>
## 6. Secure Boot

Secure Boot açıkken USOS, **shim 16.1** (Fedora derlemesi, Microsoft UEFI
CA tarafından imzalı) ve MokManager üzerinden başlar. USOS'un kendisi ve
bileşenleri, **her bilgisayara bir kez** kaydedilen **USOS anahtarı** ile
imzalanmıştır:

- **En kolayı:** Secure Boot'u kapatın, bellekten başlatın, ana ekranda
  **Ekle**'yi seçip **Evet, anahtarı kaydet** ile onaylayın, ardından
  Secure Boot'u yeniden açın. Bu, Setup Mode'da da çalışır (X470'te
  doğrulandı).
- **Secure Boot açık kalırken:** “Verification failed” ekranında
  MokManager'da **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  yolunu izleyin (ROG Ally'de doğrulandı). Yükleyicinin **Hazırla (bir
  kez)** kartı, MokManager'ın geri sayım yapmak yerine beklemesini sağlar.

NVRAM sıfırlaması anahtarı siler; anahtarı yeniden kaydedin. XP, Vista, 7,
tüm CSMWrap yolları, SystemRescue ve UEFI Kabuğu'ndan başlatılan araçlar
Secure Boot'un kapalı olmasını gerektirir. Çekirdek henüz kilitlenmemiştir
(yol haritası maddesi N6); bu nedenle USOS anahtarını kaydetmek, onunla
imzalanmış her şeye güvenmek anlamına gelir. Ayrıntılar:
[kullanıcı kılavuzu, bölüm 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok)
(İngilizce), [secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Yanıt profilleri

Küçük bir profil (hesaplar, bilgisayar adı, dil, saat dilimi, isteğe bağlı
ince ayarlar) başlangıçta `WINNT.SIF` (2000/XP/2003), `autounattend.xml`
(Vista'dan 11'e, Server) veya Ubuntu autoinstall, Debian preseed ya da
Fedora kickstart dosyasına dönüştürülür. Profiller UEFI menüsünde
(**Gözetimsiz kurulum** -> **+ Yeni profil ekle**) oluşturulur ve ESP'de
saklanır.

![Yanıt profili düzenleyicisi, “Görünüm ve ekstralar” bölümü](../images/profile-editor-appearance.png)

- Hedef disk **her zaman elle seçilir**; bir profil asla disk seçmez veya
  silmez.
- Ürün anahtarı yalnızca “Anahtarı bu bellekte hatırla” seçeneğini
  işaretlerseniz saklanır; aksi halde yalnızca yeniden başlatmaya kadar
  tutulur. **USOS hiçbir anahtar içermez** ve etkinleştirmeyi veya ürün
  anahtarı sayfasını atlatmaz.
- Parolalar ve hatırlanan anahtarlar bellekte düz metin olarak saklanır
  (listelerde veya günlüklerde asla gösterilmez). Linux profilleri yalnızca
  UEFI'de çalışır.

Ayrıntılar: [kullanıcı kılavuzu, bölüm 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks)
(İngilizce), [answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Bilinen sorunlar

- **Yalnızca USB 3'lü anakartlarda Vista (X470):** USB bellekler kurulu
  sistemde görünmez ve Vista test modunda kalır (test imzalı USB 3
  backport'u). Bir Renesas uPD72020x PCIe kartı her ikisini de önler.
- **CSMWrap yolları:** legacy VBIOS'lu bir ekran kartı gerektirir (aksi
  halde siyah ekran), bir CPU iş parçacığı kullanır, MBR hedef disk
  (silinir) ve kapalı Secure Boot gerektirir.
- **Server 2003 x86 / XP x64:** X470'te STOP 0xA5 (ACPI) ve yalnızca
  xHCI'lı anakartlarda USB girişi yok.
- **Windows 2000**, yalnızca AHCI'lı anakartlarda çalışmaz (NT 5.0 için
  AHCI sürücüsü yok); **XP**'nin NVMe desteği yoktur ve BIOS modunda sürücü
  paketi veya PAE almaz.
- **Secure Boot:** SystemRescue engellenir (imzalı yükleyici yok); UEFI
  Kabuğu araçları çalıştıramaz; BlackLotus DBX güncellemesinden sonra eski
  Windows ortamları başlamaz.
- **Linux:** Ubuntu Server yükleyicisi en büyük diski önceden seçer; bu
  USOS belleği olabilir; hedefi her zaman kontrol edin.
- **AMI ürün yazılımı**, belleğin her bölümünü ayrı bir önyükleme girişi
  olarak listeler.
- Yardımcı mikro-Linux, x86-64 bir CPU ve en az 256 MiB RAM gerektirir.

Geçici çözümleriyle birlikte tam liste ve donanımda henüz **test
edilmemiş** olanların dürüst listesi (ör. Windows Server 2008-2025,
Windows 8/8.1, donanımda Secure Boot ile Windows 10/11, PE10 donörü
aracılığıyla orijinal Windows 7 SP1 ISO'su)
[sürüm notları](../release-notes-1.0.md#known-issues) (İngilizce) ve
[kullanıcı kılavuzu, bölüm 9 ve 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds)
(İngilizce) içindedir.

<a id="building"></a>
## 9. Kaynaktan derleme

Derleme Windows'ta çalışır. Tam talimatlar: [BUILDING.md](../BUILDING.md)
(İngilizce).

- `build.bat`, tüm sürümü (EFI programı, mikro-Linux, BIOS çekirdeği,
  payload ve `installer\USOS Installer.exe`) tek bir derleme kimliğiyle
  (`BYYMMDD-HHMMSS-XXXXXXXX`) derler. `tools/zig` içindeki taşınabilir Zig
  kullanılır; Go ve Python `PATH` üzerinde olmalıdır.
- `tools/tests/run.ps1` otomatik testleri çalıştırır, ör.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  sürüm dosyalarını `zig-out\release-1.0\` içinde üretir.
- **Çevrimdışı derleme:** `USOS-1.0.0-buildkit.zip` dosyasını açın,
  `USOS_BUILDKIT` değişkenini açılan `USOS-1.0.0-buildkit` klasörüne
  ayarlayın ve `build.bat`'ı çalıştırın; kit kendi manifestine göre
  denetlenir ve indirmeler devre dışıdır.
- **İmzalama anahtarı:** Secure Boot (MOK) anahtarı **deponun dışında**,
  `%APPDATA%\USOS\signing\` içinde bulunur (`USOS_SIGNING_DIR` bunu
  geçersiz kılar). Anahtar olmadan derleme **imzasızdır** ve yalnızca Secure
  Boot kapalıyken başlar. Anahtarı asla commit etmeyin veya paylaşmayın.

Windows ISO'ları, sürücüler ve diğer üçüncü taraf ortamlar asla deponun
parçası değildir.

<a id="licence"></a>
## 10. Lisans

- USOS'un kendi kodu **GNU General Public License, sürüm 3 veya üzeri**
  (GPL-3.0-or-later) ile lisanslanmıştır: bkz. [LICENSE](../../LICENSE) ve
  [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Üçüncü taraf bileşenler kendi lisanslarını korur. Bunlar bellekte bir
  araya getirilmiş ayrı programlardır; sürümdeki `THIRD-PARTY-NOTICES.txt`
  ve `LICENSES/` ile [LICENSES-AUDIT.md](../LICENSES-AUDIT.md) dosyasına
  bakın.
- Sürümdeki Microsoft dosyaları (güncelleme ve sürücü dosyaları, XP
  paketlerindeki dosyalar, WinPE donörü) koruma amacıyla tutulur, riski
  bakımcının kendisine ait olmak üzere yeniden dağıtılır, hiçbir USOS
  lisansı kapsamında değildir ve hak sahibinin talebi üzerine kaldırılır.
- Katkılar [CONTRIBUTING.md](../../CONTRIBUTING.md) kapsamında kabul edilir
  (basit bir katkıcı lisans devri).

Windows, MS-DOS ve ilgili adlar Microsoft'un ticari markalarıdır. USOS'un
Microsoft ile bir bağlantısı yoktur.

<a id="support"></a>
## 11. Destek

- Sorular ve hata bildirimleri: GitHub Issues. Lütfen
  [kullanıcı kılavuzu, bölüm 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  (İngilizce) içinde açıklanan günlükleri ekleyin ve parola veya anahtar
  içermediklerini kontrol edin.
- İşletmeler için ücretli kurulum yardımı talep üzerine sunulur; şimdilik
  GitHub Issues üzerinden iletişime geçin.
- Sponsorluk: doldurulduktan sonra `.github/FUNDING.yml` üzerinden.

<a id="documentation"></a>
## 12. Belgeler

- Kullanıcı kılavuzu: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Sürüm notları 1.0](../release-notes-1.0.md) (İngilizce)
- [USOS nasıl çalışır](../HOW-IT-WORKS.md)
- [Derleme](../BUILDING.md)
- [Lisans denetimi](../LICENSES-AUDIT.md)
- [Sürüm test planı 1.0](../RELEASE-TEST-1.0.md)
- [Yol haritası](../ROADMAP.md) (Lehçe) ve [test sonuçları](../../TESTING.md) (Lehçe)
