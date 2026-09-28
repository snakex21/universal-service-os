# Universal Service OS (USOS) 1.0.0

> Esto es una traducción. La [versión en inglés del README](../../README.md) es la que prevalece.

**Idiomas:** [English](../../README.md) ·
[Български](README.bg.md) ·
[Čeština](README.cs.md) ·
[Dansk](README.da.md) ·
[Deutsch](README.de.md) ·
[Ελληνικά](README.el.md) ·
Español ·
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

## Contenido

1. [Qué es USOS](#what-usos-is)
2. [Características](#features)
3. [Sistemas y modos de firmware compatibles](#supported-systems)
4. [Inicio rápido](#quick-start)
5. [Estructura de carpetas en DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Perfiles de respuestas](#answer-profiles)
8. [Problemas conocidos](#known-issues)
9. [Compilar desde el código fuente](#building)
10. [Licencia](#licence)
11. [Soporte](#support)
12. [Documentación](#documentation)

<a id="what-usos-is"></a>
## 1. Qué es USOS

USOS es una sola memoria USB para instalar y arrancar sistemas operativos,
desde MS-DOS hasta Windows 11 y Linux, en equipos BIOS y UEFI, incluido UEFI
con Secure Boot. Usted copia sus propias imágenes ISO a la memoria como
archivos normales; USOS le ofrece un único menú, una elección explícita y
protegida del disco de destino, y los controladores y correcciones que los
sistemas antiguos necesitan en hardware nuevo. La memoria se prepara en
Windows con `USOS-Installer-1.0.0.exe`. USOS no incluye imágenes de Windows,
ni claves de producto, ni ninguna forma de eludir la activación.

![Menú UEFI de USOS, pantalla de inicio](../images/menu-home.png)

<a id="features"></a>
## 2. Características

- **Un menú, BIOS y UEFI.** La misma memoria arranca en BIOS Legacy y en
  UEFI (x64) con el mismo catálogo. El menú UEFI funciona con teclado,
  ratón, pantalla táctil y mandos USB.
- **Las imágenes siguen siendo archivos.** Las imágenes ISO, WIM, IMG, VHD,
  VHDX y EFI se leen directamente de la partición NTFS DATA; no se extrae
  nada y no hay que ejecutar nada después de copiarlas.
- **Disco de destino protegido.** Usted siempre elige y confirma el disco;
  la propia memoria USOS nunca se ofrece.
- **Secure Boot** mediante shim 16.1 (firmado por Microsoft) y la clave USOS
  (MOK), que se registra una vez por equipo.
- **Windows antiguo en hardware nuevo.** Windows XP con un paquete de
  controladores y PAE en UEFI con CSM; XP y Vista en UEFI sin CSM mediante
  CSMWrap (experimental); Windows 7 x64 sin CSM mediante UefiSeven y un
  despachador de enrutamiento VGA; integración de USB 3 y NVMe para
  Windows 7.
- **Perfiles de respuestas** para instalaciones desatendidas de Windows y
  Linux, editados en el menú UEFI con un teclado en pantalla.
- **ISO de Linux desde DATA** (Ubuntu, Mint, Fedora, Debian, SystemRescue,
  GParted, Clonezilla y otras), en UEFI con y sin Secure Boot y en BIOS.
- **Herramientas:** FreeDOS integrado con un gestor de archivos y un panel
  Hardware & SMART (BIOS), la EDK2 UEFI Shell (UEFI), sus propias
  herramientas de arranque en `Utilities`, sus propios controladores UEFI y
  carpetas de controladores INF para Windows.
- **Instalador con cuatro modos:** Instalación, Actualización local
  (**Actualizar USOS**, conserva las imágenes y sus archivos), Reparación
  (**Reparar ESP**), Desinstalación.
- **27 idiomas** (el inglés es la referencia; los demás idiomas, salvo el
  polaco, están marcados como traducidos automáticamente en parte o en su
  totalidad), temas con un editor en el menú, soporte táctil y de mando en
  el ROG Ally.

| | |
|---|---|
| ![Lista de sistemas Windows con distintivos de estado](../images/windows-list.png) | ![Lista de distribuciones Linux](../images/linux-list.png) |
| Sistemas Windows con distintivos de estado | ISO de Linux desde DATA |
| ![Menú BIOS Legacy](../images/bios-menu.png) | ![Temas integrados y del usuario](../images/themes-grid.png) |
| El menú BIOS Legacy | Temas: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Sistemas y modos de firmware compatibles

**HW** = probado en hardware real, **VM** = probado solo en
QEMU/VirtualBox, **exp.** = experimental (marcado así en el menú),
**sin probar** = la ruta existe pero no hay ninguna ejecución registrada,
**—** = no compatible (el menú muestra el motivo). Equipos de prueba:
**X470** (ASRock X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100**
(MSI, Socket 939, Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI
con Secure Boot).

| Sistema | BIOS (Legacy) | UEFI + CSM | UEFI sin CSM (CSMWrap) | Secure Boot activado |
|---|---|---|---|---|
| El propio menú USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 en modo estándar, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW parcial (MS-7100: Setup hasta la preparación del primer arranque, escritorio sin confirmar) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (hasta la copia de archivos) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (sin paquete de controladores, sin PAE) | HW (X470: paquete de controladores, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | sin probar | exp., VM (hasta el Setup gráfico); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | sin probar | exp., VM (hasta el Setup gráfico); X470 sin probar con 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, MBR legacy) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (instalación completa) | HW (X470, UefiSeven + despachador) | — |
| Windows 8 / 8.1 | sin probar | sin probar | sin probar | sin probar |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | UEFI nativo, la misma ruta que con CSM | VM (hasta el cargador de Windows) |
| Windows 11 | sin probar | HW (informe de usuario) | UEFI nativo, la misma ruta que con CSM | VM (hasta el cargador de Windows) |
| Windows Server 2008 - 2025 | exp., nunca arrancado | exp., nunca arrancado | exp., nunca arrancado | 2008/2008 R2: —; 2012+: sin probar |
| ISO de Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | igual que con CSM | HW Fedora, Mint (X470); VM el resto |
| SystemRescue | VM | HW (X470) | igual que con CSM | — (sin cargador de arranque firmado) |
| FreeDOS, Hardware & SMART (integrados) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, la aporta usted) | HW | versión `.efi` desde `Utilities` (sin probar) | igual que con CSM | solo `.efi` firmado |
| UEFI Shell (integrada) | — | VM | VM | VM (arranca, no puede iniciar herramientas) |

UEFI con o sin CSM solo importa para las rutas legacy (2000, XP, 2003,
Vista, 7); todas las demás entradas UEFI ejecutan el mismo código en ambos
modos. Windows XP, Vista y 7 y todas las rutas CSMWrap requieren Secure Boot
desactivado. La tabla completa con notas y los resultados en hardware por
build están en la
[guía del usuario, sección 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
y en las [notas de la versión](../release-notes-1.0.md#supported-systems)
(en inglés).

<a id="quick-start"></a>
## 4. Inicio rápido

Archivos de la versión:

| Archivo | Finalidad |
|---|---|
| `USOS-Installer-1.0.0.exe` | el instalador; contiene todo USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | donante PE10, necesario para Vista y las ISO originales de Windows 7 en UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | paquete UEFI para Windows XP x86 SP3, cada uno para exactamente una ISO original (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instalado con el `install-xp-package.ps1` incluido |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | código fuente de los componentes de terceros y la oferta escrita del código fuente |
| `USOS-1.0.0-buildkit.zip` | cadenas de herramientas fijadas y entradas de compilación para recompilar sin conexión |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | textos de licencias y avisos |
| `SHA256SUMS` | SHA-256 de cada archivo |

Compruebe una descarga con `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(o `Get-FileHash` en PowerShell) frente a `SHA256SUMS`.

![Instalador de USOS: elegir una operación](../images/installer-mode.png)

1. Consiga una memoria USB de **al menos 32 GiB** (en la práctica 64 GB;
   una memoria vendida como «32 GB» suele ser demasiado pequeña). **Se
   borrará todo su contenido.**
2. En un PC con Windows ejecute `USOS-Installer-1.0.0.exe` (pide derechos
   de administrador), elija **Instalación**, seleccione la memoria, escriba
   el texto de confirmación y haga clic en **BORRAR E INSTALAR**.
3. Copie sus imágenes ISO a la partición DATA, en la carpeta `Images` de
   cada sistema, p. ej. `Systems\Windows\Windows 11\Images\`.
4. Opcional: para Vista o Windows 7 original en UEFI, copie la carpeta
   `Programs` del zip del donante PE10 a la raíz de DATA y ejecute
   **Actualizar USOS**; para XP en UEFI, ejecute como administrador
   `install-xp-package.ps1` desde el paquete XP que corresponda a su ISO
   (un paquete cada vez).
5. Arranque el PC de destino desde la memoria (BIOS o UEFI). Con Secure Boot
   activado, registre la clave USOS una vez ([Secure Boot](#secure-boot)).
   Elija el sistema y la imagen, opcionalmente un perfil de respuestas,
   confirme el disco de destino y siga el instalador del sistema.

Las instrucciones paso a paso de cada pantalla están en la guía del
usuario: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Estructura de carpetas en DATA

El instalador crea la memoria con tres particiones: `USOS_ESP` (FAT32,
1 GiB: archivos de arranque, clave, ajustes, registros, perfiles),
`USOS_DATA` (NTFS: sus archivos) y `USOS_WORK` (NTFS, espacio de trabajo
para algunos instaladores de Windows). Todas las carpetas de DATA se crean
automáticamente:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versión>\   Images\  Unattended\   (Windows 3.1 a 11, Server 2003-2025)
│  ├─ Linux\<distribución>\ Images\  Unattended\   (Other Linux\ para ISO desconocidas)
│  ├─ Betas\
│  └─ DOS\<variante>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programas DOS para el FreeDOS integrado
│  ├─ UEFI Shell\Tools\     herramientas EFI para la UEFI Shell
│  └─ <su herramienta>\Images\   p. ej. MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nombre>\        controladores .efi cargados por el menú USOS
│  └─ <versión de Windows>\ Storage\  USB\  Other\  (paquetes INF)
├─ Themes\<nombre>\theme.ini  sus propios temas (menú UEFI)
└─ Programs\
   └─ USOS\                 gestionado por USOS (donante PE10), no tocar
```

Después de añadir un `icon.png` o una carpeta de herramienta nueva, ejecute
**Actualizar USOS**. El árbol completo está en la
[guía del usuario, sección 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Con Secure Boot activado, USOS arranca mediante **shim 16.1** (build de
Fedora, firmado por la Microsoft UEFI CA) y MokManager. El propio USOS y sus
componentes están firmados con la **clave USOS**, que se registra **una vez
por equipo**:

- **Lo más sencillo:** desactive Secure Boot, arranque desde la memoria,
  elija **Añadir** en la pantalla de inicio y confirme con **Sí, guardar la
  clave**; después vuelva a activar Secure Boot. También funciona en Setup
  Mode (confirmado en el X470).
- **Manteniendo Secure Boot activado:** ante «Verification failed», use
  MokManager -> **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (confirmado en el ROG Ally). La tarjeta **Preparar (una vez)** del
  instalador hace que MokManager espere en lugar de iniciar una cuenta
  atrás.

Un reinicio de la NVRAM elimina la clave; vuelva a registrarla. XP, Vista,
7, todas las rutas CSMWrap, SystemRescue y las herramientas iniciadas desde
la UEFI Shell requieren Secure Boot desactivado. El kernel todavía no está
bloqueado (punto N6 de la hoja de ruta), así que registrar la clave USOS
supone confiar en todo lo que esté firmado con ella. Detalles:
[guía del usuario, sección 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Perfiles de respuestas

Un pequeño perfil (cuentas, nombre del equipo, idioma, zona horaria, ajustes
opcionales) se convierte al arrancar en `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista a 11, Server) o en autoinstall de Ubuntu, preseed
de Debian o kickstart de Fedora. Los perfiles se crean en el menú UEFI
(**Instalación desatendida** -> **+ Añadir un perfil nuevo**) y se guardan
en la ESP.

![Editor de perfiles de respuestas con la sección Apariencia y extras](../images/profile-editor-appearance.png)

- El disco de destino **siempre se elige a mano**; un perfil nunca
  selecciona ni borra un disco.
- Una clave de producto solo se guarda si marca «Recordar la clave en esta
  memoria»; si no, solo se conserva hasta el reinicio. **USOS no incluye
  claves** y no elude la activación ni la página de la clave de producto.
- Las contraseñas y las claves recordadas se guardan en la memoria como
  texto sin cifrar (nunca se muestran en listas ni en registros). Los
  perfiles de Linux solo funcionan en UEFI.

Detalles: [guía del usuario, sección 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Problemas conocidos

- **Vista en placas solo con USB 3 (X470):** las memorias USB no son
  visibles en el sistema instalado, y Vista se queda en modo de prueba
  (backport de USB 3 con firma de prueba). Una tarjeta PCIe Renesas
  uPD72020x evita ambas cosas.
- **Rutas CSMWrap:** necesitan una tarjeta gráfica con VBIOS legacy (si no,
  pantalla negra), ocupan un hilo de la CPU, necesitan un disco de destino
  MBR (que se borra) y Secure Boot desactivado.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) en el X470 y sin entrada
  USB en placas solo con xHCI.
- **Windows 2000** no funciona en placas solo con AHCI (no hay controlador
  AHCI para NT 5.0); **XP** no admite NVMe y en modo BIOS no recibe paquete
  de controladores ni PAE.
- **Secure Boot:** SystemRescue está bloqueado (sin cargador firmado); la
  UEFI Shell no puede iniciar herramientas; tras la actualización de DBX
  contra BlackLotus, los medios de Windows más antiguos no arrancan.
- **Linux:** el instalador de Ubuntu Server preselecciona el disco más
  grande, que puede ser la memoria USOS; compruebe siempre el destino.
- **El firmware AMI** muestra cada partición de la memoria como una entrada
  de arranque independiente.
- El asistente micro-Linux necesita una CPU x86-64 y al menos 256 MiB de
  RAM.

La lista completa con soluciones alternativas, y la lista honesta de lo que
**aún no se ha probado** en hardware (p. ej. Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 con Secure Boot en hardware, la ISO original de
Windows 7 SP1 mediante el donante PE10), están en las
[notas de la versión](../release-notes-1.0.md#known-issues) (en inglés) y en
la [guía del usuario, secciones 9 y 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Compilar desde el código fuente

La compilación se ejecuta en Windows. Instrucciones completas:
[BUILDING.md](../BUILDING.md) (en inglés).

- `build.bat` compila la versión completa (programa EFI, micro-Linux,
  núcleo BIOS, payload e `installer\USOS Installer.exe`) con un único
  identificador de build (`BYYMMDD-HHMMSS-XXXXXXXX`). Se usa el Zig portátil
  de `tools/zig`; Go y Python deben estar en el `PATH`.
- `tools/tests/run.ps1` ejecuta las pruebas automáticas, p. ej.
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  genera los archivos de la versión en `zig-out\release-1.0\`.
- **Compilación sin conexión:** extraiga `USOS-1.0.0-buildkit.zip`, asigne
  a `USOS_BUILDKIT` la carpeta extraída `USOS-1.0.0-buildkit` y ejecute
  `build.bat`; el kit se comprueba frente a su manifiesto y las descargas
  quedan desactivadas.
- **Clave de firma:** la clave de Secure Boot (MOK) está **fuera del
  repositorio**, en `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` la
  sustituye). Sin ella, el build queda **sin firmar** y solo arranca con
  Secure Boot desactivado. Nunca haga commit de la clave ni la comparta.

Las ISO de Windows, los controladores y otros medios de terceros nunca
forman parte del repositorio.

<a id="licence"></a>
## 10. Licencia

- El código propio de USOS se publica bajo la **GNU General Public License,
  versión 3 o posterior** (GPL-3.0-or-later): véanse [LICENSE](../../LICENSE)
  y [NOTICE](../../NOTICE). Copyright (C) 2026 The USOS Authors.
- Los componentes de terceros conservan sus propias licencias. Son programas
  independientes agrupados en la memoria; véanse `THIRD-PARTY-NOTICES.txt`
  y `LICENSES/` en la versión y [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Los archivos de Microsoft incluidos en la versión (archivos de
  actualizaciones y controladores, los archivos de los paquetes XP, el
  donante WinPE) se conservan con fines de preservación, se redistribuyen
  por cuenta y riesgo del mantenedor, no están cubiertos por ninguna
  licencia de USOS y se retirarán a petición del titular de los derechos.
- Las contribuciones se aceptan según [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (una concesión de licencia sencilla por parte de quien contribuye).

Windows, MS-DOS y los nombres relacionados son marcas comerciales de
Microsoft. USOS no está afiliado a Microsoft.

<a id="support"></a>
## 11. Soporte

- Preguntas e informes de errores: GitHub Issues. Adjunte los registros
  descritos en la [guía del usuario, sección 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  y compruebe que no contienen contraseñas ni claves.
- Hay ayuda de configuración de pago para empresas bajo petición; por ahora,
  póngase en contacto a través de GitHub Issues.
- Patrocinio: mediante `.github/FUNDING.yml` cuando esté completado.

<a id="documentation"></a>
## 12. Documentación

- Guía del usuario: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Notas de la versión 1.0](../release-notes-1.0.md) (en inglés)
- [Cómo funciona USOS](../HOW-IT-WORKS.md)
- [Compilación](../BUILDING.md)
- [Auditoría de licencias](../LICENSES-AUDIT.md)
- [Plan de prueba de la versión 1.0](../RELEASE-TEST-1.0.md)
- [Hoja de ruta](../ROADMAP.md) (en polaco) y [resultados de las pruebas](../../TESTING.md) (en polaco)
