package install

// Bezpieczny staging instalacji Windows 7 x64 UEFI (WinPE10) z mozliwoscia powrotu.
//
// Zasady:
//   - staging ZAWSZE z WinPE10 (WinPE7 nie wchodzi na nowym USB/XHCI),
//     tylko Win7 x64, GPT + FAT32 ESP, Secure Boot OFF.
//   - backup ESP:\EFI\Microsoft\Boot\{BCD,BCD.LOG*,bootmgfw.efi} + dump
//     NVRAM (bcdedit /enum firmware lub efibootmgr -v) + journal PRZED zapisem.
//   - staging jako one-shot BootNext + timeout, bez ruszania BootOrder.
//   - bcdboot W:\Windows /s S: /f UEFI dopiero po verify apply-image.
//   - watchdog: brak 2. rebootu / SetupComplete OK -> restore BCD+NVRAM +
//     domyslny wpis; USB zostaje do potwierdzenia.
//
// Ten plik jest przenosny (kompiluje sie na kazdym GOOS): zawiera czyste
// konstruktory komend/plikow i decyzje watchdoga. Wykonanie (exec) lezy
// w installer/internal/winhost/win7_uefi_staging_windows.go.

import (
	"fmt"
	"strings"
)

// Win7TargetKind rozroznia retro BIOS vanilla od nowoczesnego UEFI x64.
type Win7TargetKind int

const (
	// Win7BIOSVanilla to retro sciezka: bez zmian, vanilla WIM nietkniety.
	Win7BIOSVanilla Win7TargetKind = iota
	// Win7UEFIX64Modern to staging dla nowego sprzetu (Ryzen/XHCI):
	// Autounattend.xml + offline DISM + SetupComplete.cmd, patch tylko
	// na target po apply-image, nigdy vanilla WIM na stale.
	Win7UEFIX64Modern
)

// ClassifyWin7Target klasyfikuje cel instalacji Win7.
// firmware: "bios" albo "uefi" (case-insensitive, akceptuje tez "legacy",
// "csm", "gpt"); arch: "x64"/"amd64" dla sciezki modern, inne -> vanilla.
//
// Rozbior nazw i sama tabela decyzyjna zyja w win7media.go
// (parseMediaArch/isUEFIFirmware/classifyWin7Target), zeby istniala
// dokladnie jedna implementacja. Gdy znana jest juz sklasyfikowana
// winmedia.Media, uzyj ClassifyWin7TargetForMedia zamiast stringow.
func ClassifyWin7Target(arch, firmware string) Win7TargetKind {
	return classifyWin7Target(parseMediaArch(arch), firmware)
}

// EspBackupFileSet zwraca wzgledne (wobec roota ESP) sciezki objete
// backupem przed zapisem bootloadera na dysk SATA.
func EspBackupFileSet() []string {
	return []string{
		`EFI\Microsoft\Boot\BCD`,
		`EFI\Microsoft\Boot\BCD.LOG`,
		`EFI\Microsoft\Boot\BCD.LOG1`,
		`EFI\Microsoft\Boot\BCD.LOG2`,
		`EFI\Microsoft\Boot\bootmgfw.efi`,
	}
}

// NVRAMDumpFileName to nazwa pliku ze zrzutem kolejnosci rozruchu.
const NVRAMDumpFileName = "nvram-firmware-dump.txt"

// StagingJournalFileName to dziennik operacji stagingu (do audytu/rollbacku).
const StagingJournalFileName = "win7-uefi-staging-journal.txt"

// BcdbootUEFICommand buduje komende zapisujaca bootloader Windows:
// bcdboot W:\Windows /s S: /f UEFI
// Wywolanie dopiero po verify apply-image.
func BcdbootUEFICommand(windowsDir, espVolume string) []string {
	w := strings.TrimSpace(windowsDir)
	if w == "" {
		w = `W:\Windows`
	}
	s := strings.TrimSpace(espVolume)
	if s == "" {
		s = "S:"
	}
	return []string{"bcdboot", w, "/s", s, "/f", "UEFI"}
}

// OneShotBootNextCommands zwraca komendy ustawiajace jednorazowy start
// (BootNext) bez ruszania BootOrder/displayorder.
// Na Windows: bcdedit /set {fwbootmgr} bootsequence {<id>} + /timeout.
// Na Linux: efibootmgr -n <num> + -t. Zwracane sa warianty dla obu OS,
// wykonawca wybiera wlasciwy; zaden nie modyfikuje BootOrder.
func OneShotBootNextCommands(entryID string, timeoutSec int) (windows [][]string, linux [][]string) {
	id := strings.TrimSpace(entryID)
	if id == "" {
		id = "{new-win7-staging}"
	}
	if timeoutSec <= 0 {
		timeoutSec = 10
	}
	t := fmt.Sprintf("%d", timeoutSec)
	windows = [][]string{
		{"bcdedit", "/set", "{fwbootmgr}", "bootsequence", id},
		{"bcdedit", "/timeout", t},
	}
	num := strings.TrimPrefix(strings.Trim(id, "{}"), "Boot")
	num = strings.TrimSpace(num)
	if num == "" || len(num) > 4 {
		num = "XXXX"
	}
	linux = [][]string{
		{"efibootmgr", "-n", num},
		{"efibootmgr", "-t", t},
	}
	return windows, linux
}

// FirmwareDumpCommands zwraca komendy zrzutu NVRAM (odczyt, bez zapisu).
func FirmwareDumpCommands() (windows []string, linux []string) {
	windows = []string{"bcdedit", "/enum", "firmware"}
	linux = []string{"efibootmgr", "-v"}
	return windows, linux
}

// DismOfflineDriverCommands zwraca sekwencje offline DISM dla paczki XHCI:
// mount boot.wim:1,2 + install.wim docelowy + /Image:W:\ /Add-Driver
// /Recurse /ForceUnsigned. windowsDir to np. "W:", driverDir to sciezka
// do Systems/Windows/Windows 7/Drivers/x64 na stagingu.
func DismOfflineDriverCommands(bootWim, windowsRoot, driverDir string) [][]string {
	bw := strings.TrimSpace(bootWim)
	if bw == "" {
		bw = `X:\sources\boot.wim`
	}
	wr := strings.TrimSpace(windowsRoot)
	if wr == "" {
		wr = `W:\`
	}
	dd := strings.TrimSpace(driverDir)
	if dd == "" {
		dd = `D:\Drivers\x64`
	}
	mountDir := `C:\mnt\bootwim`
	return [][]string{
		{"dism", "/Get-WimInfo", "/WimFile:" + bw},
		{"dism", "/Mount-Wim", "/WimFile:" + bw, "/index:1", "/MountDir:" + mountDir},
		{"dism", "/Image:" + mountDir, "/Add-Driver", "/Driver:" + dd, "/Recurse", "/ForceUnsigned"},
		{"dism", "/Unmount-Wim", "/MountDir:" + mountDir, "/Commit"},
		{"dism", "/Mount-Wim", "/WimFile:" + bw, "/index:2", "/MountDir:" + mountDir},
		{"dism", "/Image:" + mountDir, "/Add-Driver", "/Driver:" + dd, "/Recurse", "/ForceUnsigned"},
		{"dism", "/Unmount-Wim", "/MountDir:" + mountDir, "/Commit"},
		{"dism", "/Image:" + wr, "/Add-Driver", "/Driver:" + dd, "/Recurse", "/ForceUnsigned"},
	}
}

// DismOfflineSHA2QueueCommands zwraca opcjonalny krok SHA-2 PRZED Add-Driver
// (kolejnosc sztywna): offline Add-Package KB4474419*.msu do targetu, jesli
// msuPath niepuste. Puste msuPath = no-op (warning u wykonawcy, nie fail).
// Bez unattenda: nie zmienia wyborow instalacji, tylko DriverPaths/offlineServicing.
func DismOfflineSHA2QueueCommands(windowsRoot, msuPath string) [][]string {
	wr := strings.TrimSpace(windowsRoot)
	if wr == "" {
		wr = `W:\`
	}
	msu := strings.TrimSpace(msuPath)
	if msu == "" {
		return nil
	}
	return [][]string{
		{"dism", "/Image:" + wr, "/Add-Package", "/PackagePath:" + msu},
	}
}

// Win7SHA2ThenDriverSequence sklada pelna kolejke: najpierw Add-Package
// SHA-2 (jesli msuPath podane), potem Add-Driver. Pusta paczka = same drivery.
func Win7SHA2ThenDriverSequence(bootWim, windowsRoot, driverDir, msuPath string) [][]string {
	seq := DismOfflineSHA2QueueCommands(windowsRoot, msuPath)
	return append(seq, DismOfflineDriverCommands(bootWim, windowsRoot, driverDir)...)
}

// Win7ACPIModOptIn opisuje warunkowy acpi.sys (mod): tylko po BSOD A5,
// z backup + rollback. enabled=false = domyslnie OFF, brak zmian.
func Win7ACPIModOptIn(enabled bool) (flag, note string) {
	if !enabled {
		return "acpi_mod=off", "ACPI_MOD OFF (domyslnie; wlacz tylko po BSOD A5)"
	}
	return "acpi_mod=on backup=acpi.sys.original rollback=yes", "ACPI_MOD opt-in ON (po BSOD A5): backup acpi.sys -> acpi.sys.original, rollback dostepny"
}

// Win7UefiSevenOptIn opisuje warunkowy UefiSeven: tylko czyste UEFI Class 3
// bez CSM, SecureBoot Off, backup bootmgfw.efi -> bootmgfw.original.efi.
// Na X470 z CSM Video=Legacy domyslnie OFF (enabled=false).
func Win7UefiSevenOptIn(enabled bool) (flag, note string) {
	if !enabled {
		return "uefiseven=off", "UEFISEVEN OFF (domyslnie; na X470 z CSM Video=Legacy zostaw OFF)"
	}
	return "uefiseven=on backup=bootmgfw.original.efi secureboot=off", "UEFISEVEN opt-in ON (Class 3 bez CSM, SecureBoot Off; backup bootmgfw.original.efi)"
}

// Win7HardwareWarnings zwraca ostrzezenia VMD/iGPU pokazywane tez w startup.cmd
// i README: VMD on = brak dysku, Xe/UHD730/770 i RDNA2 AM5 = brak driverow.
func Win7HardwareWarnings() []string {
	return []string{
		"Intel 11-14gen VMD On=brak dysku w Setup (wylacz VMD/RST w BIOS)",
		"Xe/UHD 730/770 i RDNA2 (AM5)=brak driverow pod Win7, wymagane dGPU (GTX 900/1000/1600, RTX 2000/3000, RX 400/500/Vega/5000/czesc 6000), inaczej 800x600 VGA",
		"SATA omija NVMe, CSM omija UefiSeven",
	}
}

// Win7ModernUnattendParams parametry generatora Autounattend.xml.
type Win7ModernUnattendParams struct {
	// UseAutounattend wlacza opcjonalny plik odpowiedzi dla sciezki UEFI.
	// false oznacza reczny Setup/OOBE bez Autounattend.xml.
	UseAutounattend bool
	// InputLocale np. "pl-PL". Puste -> "pl-PL".
	InputLocale string
	// AutoLogonUser puste -> "Administrator".
	AutoLogonUser string
	// DriverPath to wartosc DriverPaths, np. "D:\\Drivers\\x64".
	DriverPath string
}

func (p Win7ModernUnattendParams) locale() string {
	if strings.TrimSpace(p.InputLocale) == "" {
		return "pl-PL"
	}
	return strings.TrimSpace(p.InputLocale)
}

func (p Win7ModernUnattendParams) user() string {
	if strings.TrimSpace(p.AutoLogonUser) == "" {
		return "Administrator"
	}
	return strings.TrimSpace(p.AutoLogonUser)
}

func (p Win7ModernUnattendParams) driverPath() string {
	if strings.TrimSpace(p.DriverPath) == "" {
		return `D:\Drivers\x64`
	}
	return strings.TrimSpace(p.DriverPath)
}

// Win7ModernAutounattend generuje Autounattend.xml dla win7-uefi-x64-modern:
// oobeSystem: SkipMachineOOBE + SkipUserOOBE, ProtectYourPC=3, HideEULA,
// InputLocale pl-PL, AutoLogon + FirstLogonCommands -> SetupComplete.cmd,
// DriverPaths -> Drivers\x64. Tylko dla sciezki modern; vanilla nie uzywa.
func Win7ModernAutounattend(p Win7ModernUnattendParams) string {
	loc := p.locale()
	user := p.user()
	drv := p.driverPath()
	return `<?xml version="1.0" encoding="utf-8"?>` + "\r\n" +
		`<unattend xmlns="urn:schemas-microsoft-com:unattend">` + "\r\n" +
		`  <settings pass="windowsPE">` + "\r\n" +
		`    <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">` + "\r\n" +
		`      <DriverPaths>` + "\r\n" +
		`        <PathAndCredentials wcm:action="add" wcm:keyValue="usos-xhci" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">` + "\r\n" +
		`          <Path>` + drv + `</Path>` + "\r\n" +
		`        </PathAndCredentials>` + "\r\n" +
		`      </DriverPaths>` + "\r\n" +
		`      <UserData><AcceptEula>true</AcceptEula></UserData>` + "\r\n" +
		`    </component>` + "\r\n" +
		`    <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">` + "\r\n" +
		`      <InputLocale>` + loc + `</InputLocale>` + "\r\n" +
		`      <SystemLocale>` + loc + `</SystemLocale>` + "\r\n" +
		`      <UILanguage>` + loc + `</UILanguage>` + "\r\n" +
		`      <UserLocale>` + loc + `</UserLocale>` + "\r\n" +
		`    </component>` + "\r\n" +
		`  </settings>` + "\r\n" +
		`  <settings pass="oobeSystem">` + "\r\n" +
		`    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">` + "\r\n" +
		`      <OOBE><HideEULA>true</HideEULA><ProtectYourPC>3</ProtectYourPC><SkipMachineOOBE>true</SkipMachineOOBE><SkipUserOOBE>true</SkipUserOOBE></OOBE>` + "\r\n" +
		`      <AutoLogon><Username>` + user + `</Username><Enabled>true</Enabled><LogonCount>2</LogonCount></AutoLogon>` + "\r\n" +
		`      <FirstLogonCommands>` + "\r\n" +
		`        <SynchronousCommand wcm:action="add" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">` + "\r\n" +
		`          <Order>1</Order>` + "\r\n" +
		`          <CommandLine>cmd /c %WINDIR%\Setup\Scripts\SetupComplete.cmd</CommandLine>` + "\r\n" +
		`        </SynchronousCommand>` + "\r\n" +
		`      </FirstLogonCommands>` + "\r\n" +
		`    </component>` + "\r\n" +
		`  </settings>` + "\r\n" +
		`</unattend>` + "\r\n"
}

// Win7SetupCompleteScript zwraca zawartosc SetupComplete.cmd: fallback
// pnputil instalujacy XHCI z Drivers\x64, jesli OOBE przeszlo bez USB
// (martwe USB po instalacji). Idempotentny, loguje do %WINDIR%\Temp.
func Win7SetupCompleteScript(driverRelPath string) string {
	d := strings.TrimSpace(driverRelPath)
	if d == "" {
		d = `D:\Drivers\x64`
	}
	return "@echo off\r\n" +
		"rem USOS win7-uefi-x64-modern SetupComplete fallback XHCI\r\n" +
		"set LOG=%WINDIR%\\Temp\\usos-setupcomplete.log\r\n" +
		"echo [%DATE% %TIME%] SetupComplete start>>\"%LOG%\"\r\n" +
		"if exist \"" + d + "\" (\r\n" +
		"  pnputil -i -a \"" + d + "\\*.inf\">>\"%LOG%\" 2>&1\r\n" +
		"  echo [%DATE% %TIME%] pnputil exit=%ERRORLEVEL%>>\"%LOG%\"\r\n" +
		") else (\r\n" +
		"  echo [%DATE% %TIME%] driver path missing: " + d + ">>\"%LOG%\"\r\n" +
		")\r\n" +
		"echo [%DATE% %TIME%] SetupComplete OK>>\"%LOG%\"\r\n" +
		"exit /b 0\r\n"
}

// Win7WatchdogDecision implementuje watchdoga rollbacku: jesli brak
// 2. rebootu LUB brak SetupComplete OK -> restore BCD+NVRAM + domyslny
// wpis; USB zostaje do potwierdzenia. Zwraca restore=true gdy cofac.
func Win7WatchdogDecision(rebootCount int, setupCompleteOK bool) (restore bool, reason string) {
	if setupCompleteOK && rebootCount >= 2 {
		return false, "stage OK: 2x reboot + SetupComplete OK, USB do potwierdzenia"
	}
	if !setupCompleteOK {
		return true, "restore: brak SetupComplete OK, przywroc BCD+NVRAM i domyslny wpis"
	}
	return true, "restore: brak 2. rebootu, przywroc BCD+NVRAM i domyslny wpis"
}

// Win7StagingJournal wpis dziennika stagingu (audyt + podstawa rollbacku).
type Win7StagingJournal struct {
	BackupDir      string
	BackedUpFiles  []string
	NVRAMFile      string
	StagedEntryID  string
	OneShotOnly    bool
	BcdbootCommand []string
}

// NewWin7StagingJournal buduje wpis dziennika dla danego stagingu.
func NewWin7StagingJournal(backupDir, entryID, windowsDir, espVolume string) Win7StagingJournal {
	return Win7StagingJournal{
		BackupDir:      backupDir,
		BackedUpFiles:  EspBackupFileSet(),
		NVRAMFile:      NVRAMDumpFileName,
		StagedEntryID:  entryID,
		OneShotOnly:    true,
		BcdbootCommand: BcdbootUEFICommand(windowsDir, espVolume),
	}
}

// FormatWin7StagingJournal renderuje dziennik jako tekst.
func FormatWin7StagingJournal(j Win7StagingJournal) string {
	var b strings.Builder
	b.WriteString("win7-uefi-x64-modern staging journal\r\n")
	fmt.Fprintf(&b, "backup_dir=%s\r\n", j.BackupDir)
	fmt.Fprintf(&b, "nvram=%s\r\n", j.NVRAMFile)
	fmt.Fprintf(&b, "staged_entry=%s one_shot_bootnext=yes bootorder_untouched=yes\r\n", j.StagedEntryID)
	fmt.Fprintf(&b, "bcdboot=%s\r\n", strings.Join(j.BcdbootCommand, " "))
	b.WriteString("backed_up_files:\r\n")
	for _, f := range j.BackedUpFiles {
		b.WriteString("  " + f + "\r\n")
	}
	return b.String()
}

// win7StagingCapable to opcjonalny backend stagingu Win7 UEFI.
// Engine wykrywa go przez asercje interfejsu; brak implementacji = no-op,
// wiec istniejace mocki Backendu nadal przechodza. Wywolanie z Engine
// odbywa sie przez Engine.StageWin7UEFI (installer/internal/install/engine.go).
type win7StagingCapable interface {
	StageWin7UEFIModern(journal Win7StagingJournal) error
}
