# Universal Service OS (USOS) 1.0.0

> Esta é uma tradução. A [versão em inglês do README](../../README.md) é a que prevalece.

**Idiomas:** [English](../../README.md) ·
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
Português (Brasil) ·
[Română](README.ro.md) ·
[Русский](README.ru.md) ·
[Slovenčina](README.sk.md) ·
[Slovenščina](README.sl.md) ·
[Srpski (latinica)](README.sr-Latn.md) ·
[Svenska](README.sv.md) ·
[Türkçe](README.tr.md) ·
[Українська](README.uk.md)

## Sumário

1. [O que é o USOS](#what-usos-is)
2. [Recursos](#features)
3. [Sistemas e modos de firmware suportados](#supported-systems)
4. [Início rápido](#quick-start)
5. [Estrutura de pastas em DATA](#data-layout)
6. [Secure Boot](#secure-boot)
7. [Perfis de respostas](#answer-profiles)
8. [Problemas conhecidos](#known-issues)
9. [Compilar a partir do código-fonte](#building)
10. [Licença](#licence)
11. [Suporte](#support)
12. [Documentação](#documentation)

<a id="what-usos-is"></a>
## 1. O que é o USOS

O USOS é um único pendrive para instalar e iniciar sistemas operacionais,
do MS-DOS ao Windows 11 e Linux, em computadores BIOS e UEFI, incluindo UEFI
com Secure Boot. Você copia suas próprias imagens ISO para o pendrive como
arquivos comuns; o USOS oferece um único menu, uma escolha explícita e
protegida do disco de destino e os drivers e correções de que sistemas
antigos precisam em hardware novo. O pendrive é preparado no Windows com
`USOS-Installer-1.0.0.exe`. O USOS não inclui imagens do Windows, chaves de
produto nem qualquer forma de burlar a ativação.

![Menu UEFI do USOS, tela inicial](../images/menu-home.png)

<a id="features"></a>
## 2. Recursos

- **Um menu, BIOS e UEFI.** O mesmo pendrive inicia em BIOS Legacy e em
  UEFI (x64) com o mesmo catálogo. O menu UEFI funciona com teclado,
  mouse, toque e controles USB.
- **As imagens continuam sendo arquivos.** Imagens ISO, WIM, IMG, VHD, VHDX
  e EFI são lidas diretamente da partição NTFS DATA; nada é extraído e nada
  precisa ser executado depois da cópia.
- **Disco de destino protegido.** Você sempre escolhe e confirma o disco; o
  próprio pendrive USOS nunca é oferecido.
- **Secure Boot** via shim 16.1 (assinado pela Microsoft) e a chave USOS
  (MOK), registrada uma vez por computador.
- **Windows antigo em hardware novo.** Windows XP com um pacote de drivers e
  PAE em UEFI com CSM; XP e Vista em UEFI sem CSM via CSMWrap
  (experimental); Windows 7 x64 sem CSM via UefiSeven e um despachante de
  roteamento VGA; integração de USB 3 e NVMe para o Windows 7.
- **Perfis de respostas** para instalações autônomas de Windows e Linux,
  editados no menu UEFI com um teclado na tela.
- **ISOs de Linux a partir de DATA** (Ubuntu, Mint, Fedora, Debian,
  SystemRescue, GParted, Clonezilla e outras), em UEFI com e sem Secure Boot
  e em BIOS.
- **Ferramentas:** FreeDOS integrado com um gerenciador de arquivos e um
  painel Hardware & SMART (BIOS), o EDK2 UEFI Shell (UEFI), suas próprias
  ferramentas inicializáveis em `Utilities`, seus próprios drivers UEFI e
  pastas de drivers INF para Windows.
- **Instalador com quatro modos:** Instalação, Atualização local
  (**Atualizar USOS**, mantém as imagens e seus arquivos), Reparo
  (**Reparar ESP**), Desinstalação.
- **27 idiomas** (o inglês é a referência; os demais idiomas, exceto o
  polonês, estão marcados como traduzidos automaticamente em parte ou por
  completo), temas com um editor no menu, suporte a toque e controle no ROG
  Ally.

| | |
|---|---|
| ![Lista de sistemas Windows com selos de status](../images/windows-list.png) | ![Lista de distribuições Linux](../images/linux-list.png) |
| Sistemas Windows com selos de status | ISOs de Linux a partir de DATA |
| ![Menu BIOS Legacy](../images/bios-menu.png) | ![Temas integrados e do usuário](../images/themes-grid.png) |
| O menu BIOS Legacy | Temas: Dark, Light, Retro, Sunset |

<a id="supported-systems"></a>
## 3. Sistemas e modos de firmware suportados

**HW** = testado em hardware real, **VM** = testado apenas em
QEMU/VirtualBox, **exp.** = experimental (marcado assim no menu), **não
testado** = o caminho existe, mas nenhuma execução foi registrada, **—** =
não suportado (o menu mostra o motivo). Máquinas de teste: **X470** (ASRock
X470, Ryzen 7 5700X, Radeon RX 560, UEFI), **MS-7100** (MSI, Socket 939,
Athlon 64 X2, BIOS), **Ally** (ASUS ROG Ally RC71L, UEFI com Secure Boot).

| Sistema | BIOS (Legacy) | UEFI + CSM | UEFI sem CSM (CSMWrap) | Secure Boot ativado |
|---|---|---|---|---|
| O próprio menu USOS | HW | HW | HW | HW (X470, Ally) |
| MS-DOS 6.22, Windows 3.1/3.11 | HW (Windows 3.1 em modo padrão, MS-7100) | — | — | — |
| Windows 98 SE | VM; HW parcial (MS-7100: Setup até a preparação da primeira inicialização, área de trabalho não confirmada) | — | — | — |
| Windows 2000 SP4 | HW (MS-7100) | exp., VM (até a cópia de arquivos) | exp., VM (CSMWrap) | — |
| Windows XP x86 SP3 | VM (sem pacote de drivers, sem PAE) | HW (X470: pacote de drivers, PAE, 31,9 GB) | exp., HW (X470, CSMWrap) | — |
| Windows XP x64 SP2 | não testado | exp., VM (até o Setup gráfico); X470: STOP 0xA5 | exp., VM (CSMWrap) | — |
| Windows Server 2003 R2 SP2 x86 | não testado | exp., VM (até o Setup gráfico); X470 não testado com a 1.0 | exp., VM (CSMWrap) | — |
| Windows Vista SP2 x64 | HW (MS-7100) | HW (X470) | exp., HW (X470, CSMWrap, MBR legacy) | — |
| Windows 7 SP1 x64 | HW (MS-7100) | VM (instalação completa) | HW (X470, UefiSeven + despachante) | — |
| Windows 8 / 8.1 | não testado | não testado | não testado | não testado |
| Windows 10 | HW (x86, MS-7100) | HW (x64, X470) | UEFI nativo, mesmo caminho que com CSM | VM (até o carregador do Windows) |
| Windows 11 | não testado | HW (relato de usuário) | UEFI nativo, mesmo caminho que com CSM | VM (até o carregador do Windows) |
| Windows Server 2008 - 2025 | exp., nunca iniciado | exp., nunca iniciado | exp., nunca iniciado | 2008/2008 R2: —; 2012+: não testado |
| ISOs de Linux (Ubuntu, Mint, Fedora, Debian, GParted, Clonezilla) | VM; HW Mint live (MS-7100) | HW (X470: Mint, Fedora, Debian netinst, Clonezilla, GParted) | igual a com CSM | HW Fedora, Mint (X470); VM o restante |
| SystemRescue | VM | HW (X470) | igual a com CSM | — (sem carregador de inicialização assinado) |
| FreeDOS, Hardware & SMART (integrados) | VM (FreeDOS); HW (Hardware & SMART) | — | — | — |
| MemTest86+ (ISO i586, fornecida por você) | HW | versão `.efi` em `Utilities` (não testado) | igual a com CSM | apenas `.efi` assinado |
| UEFI Shell (integrado) | — | VM | VM | VM (inicia, não consegue executar ferramentas) |

UEFI com ou sem CSM só importa para os caminhos legacy (2000, XP, 2003,
Vista, 7); todas as outras entradas UEFI executam o mesmo código nos dois
modos. Windows XP, Vista e 7 e todo caminho CSMWrap exigem Secure Boot
desativado. A tabela completa com observações e os resultados em hardware
por build estão no
[guia do usuário, seção 5](../USER-GUIDE.en.md#5-what-works-in-which-firmware-mode)
e nas [notas de versão](../release-notes-1.0.md#supported-systems) (em
inglês).

<a id="quick-start"></a>
## 4. Início rápido

Arquivos da versão:

| Arquivo | Finalidade |
|---|---|
| `USOS-Installer-1.0.0.exe` | o instalador; contém todo o USOS |
| `USOS-1.0.0-WinPE-PE10-donor.zip` | doador PE10, necessário para o Vista e as ISOs originais do Windows 7 em UEFI |
| `USOS-1.0.0-XP-package-PL.zip`, `USOS-1.0.0-XP-package-EN.zip` | pacote UEFI para Windows XP x86 SP3, cada um para exatamente uma ISO original (`pl_..._x14-80476.iso` / `en_..._x14-80428.iso`), instalado com o `install-xp-package.ps1` incluído |
| `USOS-1.0.0-sources.zip` + `SOURCE-OFFER.txt` | código-fonte dos componentes de terceiros e a oferta escrita do código-fonte |
| `USOS-1.0.0-buildkit.zip` | toolchains fixadas e entradas de build para recompilar offline |
| `LICENSES/`, `THIRD-PARTY-NOTICES.txt` | textos das licenças e avisos |
| `SHA256SUMS` | SHA-256 de cada arquivo |

Confira um download com `certutil -hashfile USOS-Installer-1.0.0.exe SHA256`
(ou `Get-FileHash` no PowerShell) em relação a `SHA256SUMS`.

![Instalador do USOS: escolher uma operação](../images/installer-mode.png)

1. Arranje um pendrive de **pelo menos 32 GiB** (na prática 64 GB; um
   pendrive vendido como “32 GB” normalmente é pequeno demais). **Tudo o
   que houver nele será apagado.**
2. Em um PC com Windows, execute `USOS-Installer-1.0.0.exe` (ele pede
   direitos de administrador), escolha **Instalação**, selecione o
   pendrive, digite o texto de confirmação e clique em **APAGAR E
   INSTALAR**.
3. Copie suas imagens ISO para a partição DATA, na pasta `Images` de cada
   sistema, por exemplo `Systems\Windows\Windows 11\Images\`.
4. Opcional: para o Vista ou o Windows 7 original em UEFI, copie a pasta
   `Programs` do zip do doador PE10 para a raiz de DATA e execute
   **Atualizar USOS**; para o XP em UEFI, execute como administrador
   `install-xp-package.ps1` a partir do pacote XP correspondente à sua ISO
   (um pacote de cada vez).
5. Inicie o PC de destino pelo pendrive (BIOS ou UEFI). Com o Secure Boot
   ativado, registre a chave USOS uma vez ([Secure Boot](#secure-boot)).
   Escolha o sistema e a imagem, opcionalmente um perfil de respostas,
   confirme o disco de destino e siga o instalador do sistema.

As instruções passo a passo para cada tela estão no guia do usuário:
[English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md).

<a id="data-layout"></a>
## 5. Estrutura de pastas em DATA

O instalador cria o pendrive com três partições: `USOS_ESP` (FAT32, 1 GiB:
arquivos de inicialização, chave, configurações, logs, perfis), `USOS_DATA`
(NTFS: seus arquivos) e `USOS_WORK` (NTFS, espaço de trabalho para alguns
instaladores do Windows). Todas as pastas em DATA são criadas para você:

```
USOS_DATA\
├─ Systems\
│  ├─ Windows\<versão>\    Images\  Unattended\   (Windows 3.1 ao 11, Server 2003-2025)
│  ├─ Linux\<distribuição>\ Images\  Unattended\   (Other Linux\ para ISOs desconhecidas)
│  ├─ Betas\
│  └─ DOS\<variante>\       Images\
├─ Utilities\
│  ├─ FreeDOS\Programs\     programas DOS para o FreeDOS integrado
│  ├─ UEFI Shell\Tools\     ferramentas EFI para o UEFI Shell
│  └─ <sua ferramenta>\Images\   ex.: MemTest86\Images\memtest86.efi
├─ Drivers\
│  ├─ UEFI\<nome>\          drivers .efi carregados pelo menu USOS
│  └─ <versão do Windows>\  Storage\  USB\  Other\  (pacotes INF)
├─ Themes\<nome>\theme.ini  seus próprios temas (menu UEFI)
└─ Programs\
   └─ USOS\                 gerenciado pelo USOS (doador PE10), não mexer
```

Depois de adicionar um `icon.png` ou uma nova pasta de ferramenta, execute
**Atualizar USOS**. A árvore completa está no
[guia do usuário, seção 4](../USER-GUIDE.en.md#4-folder-layout-on-data).

<a id="secure-boot"></a>
## 6. Secure Boot

Com o Secure Boot ativado, o USOS inicia via **shim 16.1** (build do Fedora,
assinado pela Microsoft UEFI CA) e MokManager. O próprio USOS e seus
componentes são assinados com a **chave USOS**, que é registrada **uma vez
por computador**:

- **O mais fácil:** desative o Secure Boot, inicie pelo pendrive, escolha
  **Adicionar** na tela inicial e confirme com **Sim, salvar a chave**;
  depois reative o Secure Boot. Isso também funciona no Setup Mode
  (confirmado no X470).
- **Mantendo o Secure Boot ativado:** em “Verification failed”, use o
  MokManager -> **Enroll key from disk** -> `USOS_ESP` -> `USOS-KEY.cer`
  (confirmado no ROG Ally). O cartão **Preparar (uma vez)** do instalador
  faz o MokManager esperar em vez de fazer contagem regressiva.

Um reset da NVRAM remove a chave; registre-a novamente. XP, Vista, 7, todo
caminho CSMWrap, SystemRescue e ferramentas iniciadas pelo UEFI Shell exigem
Secure Boot desativado. O kernel ainda não está bloqueado (item N6 do
roteiro), portanto registrar a chave USOS significa confiar em tudo o que
for assinado com ela. Detalhes:
[guia do usuário, seção 6](../USER-GUIDE.en.md#6-secure-boot-and-the-usos-key-mok),
[secure-boot-usos.md](../secure-boot-usos.md).

<a id="answer-profiles"></a>
## 7. Perfis de respostas

Um pequeno perfil (contas, nome do computador, idioma, fuso horário, ajustes
opcionais) é convertido na inicialização em `WINNT.SIF` (2000/XP/2003),
`autounattend.xml` (Vista ao 11, Server) ou em autoinstall do Ubuntu,
preseed do Debian ou kickstart do Fedora. Os perfis são criados no menu UEFI
(**Instalação autônoma** -> **+ Adicionar um novo perfil**) e armazenados na
ESP.

![Editor de perfis de respostas com a seção Aparência e extras](../images/profile-editor-appearance.png)

- O disco de destino é **sempre escolhido manualmente**; um perfil nunca
  seleciona nem apaga um disco.
- Uma chave de produto só é armazenada se você marcar “Lembrar a chave neste
  pendrive”; caso contrário, ela só existe até a reinicialização. **O USOS
  não inclui chaves** e não burla a ativação nem a página da chave de
  produto.
- Senhas e chaves lembradas são armazenadas no pendrive como texto simples
  (nunca exibidas em listas ou logs). Perfis de Linux funcionam apenas em
  UEFI.

Detalhes: [guia do usuário, seção 7](../USER-GUIDE.en.md#7-answer-profiles-and-tweaks),
[answer-profiles.md](../answer-profiles.md).

<a id="known-issues"></a>
## 8. Problemas conhecidos

- **Vista em placas somente com USB 3 (X470):** pendrives não ficam
  visíveis no sistema instalado, e o Vista permanece em modo de teste
  (backport de USB 3 com assinatura de teste). Uma placa PCIe Renesas
  uPD72020x evita ambos.
- **Caminhos CSMWrap:** precisam de uma placa de vídeo com VBIOS legacy
  (caso contrário, tela preta), ocupam uma thread da CPU, precisam de um
  disco de destino MBR (apagado) e de Secure Boot desativado.
- **Server 2003 x86 / XP x64:** STOP 0xA5 (ACPI) no X470 e nenhuma entrada
  USB em placas somente com xHCI.
- **Windows 2000** não funciona em placas somente com AHCI (não há driver
  AHCI para NT 5.0); o **XP** não tem suporte a NVMe e não recebe pacote de
  drivers nem PAE no modo BIOS.
- **Secure Boot:** o SystemRescue é bloqueado (sem carregador assinado); o
  UEFI Shell não consegue executar ferramentas; após a atualização da DBX
  contra o BlackLotus, mídias mais antigas do Windows não iniciam.
- **Linux:** o instalador do Ubuntu Server pré-seleciona o maior disco, que
  pode ser o pendrive USOS; sempre confira o destino.
- **Firmware AMI** lista cada partição do pendrive como uma entrada de
  inicialização separada.
- O auxiliar micro-Linux precisa de uma CPU x86-64 e de pelo menos 256 MiB
  de RAM.

A lista completa com soluções alternativas, e a lista honesta do que
**ainda não foi testado** em hardware (por exemplo Windows Server 2008-2025,
Windows 8/8.1, Windows 10/11 com Secure Boot em hardware, a ISO original do
Windows 7 SP1 via doador PE10), estão nas
[notas de versão](../release-notes-1.0.md#known-issues) (em inglês) e no
[guia do usuário, seções 9 e 10](../USER-GUIDE.en.md#9-known-issues-and-workarounds).

<a id="building"></a>
## 9. Compilar a partir do código-fonte

A compilação é feita no Windows. Instruções completas:
[BUILDING.md](../BUILDING.md) (em inglês).

- `build.bat` compila a versão completa (programa EFI, micro-Linux, núcleo
  BIOS, payload e `installer\USOS Installer.exe`) com um único ID de build
  (`BYYMMDD-HHMMSS-XXXXXXXX`). É usado o Zig portátil em `tools/zig`; Go e
  Python precisam estar no `PATH`.
- `tools/tests/run.ps1` executa os testes automatizados, por exemplo
  `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/tests/run.ps1 -Suite all`.
- `powershell -ExecutionPolicy Bypass -File tools\release\make_release.ps1`
  gera os arquivos da versão em `zig-out\release-1.0\`.
- **Build offline:** extraia `USOS-1.0.0-buildkit.zip`, defina
  `USOS_BUILDKIT` para a pasta extraída `USOS-1.0.0-buildkit` e execute
  `build.bat`; o kit é verificado em relação ao seu manifesto e os
  downloads ficam desativados.
- **Chave de assinatura:** a chave do Secure Boot (MOK) fica **fora do
  repositório**, em `%APPDATA%\USOS\signing\` (`USOS_SIGNING_DIR` a
  substitui). Sem ela, o build fica **sem assinatura** e só inicia com o
  Secure Boot desativado. Nunca faça commit da chave nem a compartilhe.

ISOs do Windows, drivers e outras mídias de terceiros nunca fazem parte do
repositório.

<a id="licence"></a>
## 10. Licença

- O código próprio do USOS é licenciado sob a **GNU General Public License,
  versão 3 ou posterior** (GPL-3.0-or-later): veja [LICENSE](../../LICENSE)
  e [NOTICE](../../NOTICE). Copyright (C) 2026 Maksymilian and the USOS Authors.
- Componentes de terceiros mantêm suas próprias licenças. São programas
  separados agregados no pendrive; veja `THIRD-PARTY-NOTICES.txt` e
  `LICENSES/` na versão e [LICENSES-AUDIT.md](../LICENSES-AUDIT.md).
- Os arquivos da Microsoft na versão (arquivos de atualização e de drivers,
  os arquivos dos pacotes XP, o doador WinPE) são mantidos para fins de
  preservação, redistribuídos por conta e risco do mantenedor, não são
  cobertos por nenhuma licença do USOS e serão removidos a pedido do
  detentor dos direitos.
- Contribuições são aceitas nos termos de [CONTRIBUTING.md](../../CONTRIBUTING.md)
  (uma concessão de licença simplificada por quem contribui).

Windows, MS-DOS e nomes relacionados são marcas registradas da Microsoft. O
USOS não é afiliado à Microsoft.

<a id="support"></a>
## 11. Suporte

- Perguntas e relatos de bugs: GitHub Issues. Anexe os logs descritos no
  [guia do usuário, seção 11](../USER-GUIDE.en.md#11-troubleshooting-and-logs)
  e verifique se eles não contêm senhas nem chaves.
- Ajuda paga de configuração para empresas está disponível sob demanda; por
  enquanto, entre em contato pelo GitHub Issues.
- Patrocínio: via `.github/FUNDING.yml`, quando ele estiver preenchido.

<a id="documentation"></a>
## 12. Documentação

- Guia do usuário: [English](../USER-GUIDE.en.md), [Polski](../USER-GUIDE.pl.md)
- [Notas de versão 1.0](../release-notes-1.0.md) (em inglês)
- [Como o USOS funciona](../HOW-IT-WORKS.md)
- [Compilação](../BUILDING.md)
- [Auditoria de licenças](../LICENSES-AUDIT.md)
- [Plano de teste da versão 1.0](../RELEASE-TEST-1.0.md)
- [Roteiro](../ROADMAP.md) (em polonês) e [resultados dos testes](../../TESTING.md) (em polonês)
