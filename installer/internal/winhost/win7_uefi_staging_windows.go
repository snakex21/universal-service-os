//go:build windows

package winhost

// Wykonawca bezpiecznego stagingu win7-uefi-x64-modern na dysk SATA.
//
// Kolejnosc (staging ZAWSZE z WinPE10, tylko Win7 x64, GPT+FAT32 ESP, Secure Boot OFF):
//  1. Backup ESP:\EFI\Microsoft\Boot\{BCD,BCD.LOG*,bootmgfw.efi} do backupDir
//     + dump NVRAM (bcdedit /enum firmware) + journal PRZED zapisem.
//  2. Staging jako one-shot BootNext + timeout, bez ruszania BootOrder.
//  3. bcdboot W:\Windows /s S: /f UEFI dopiero po verify apply-image
//     (verify musi przejsc przed wywolaniem StageWin7UEFIModern).
//  4. Watchdog: brak 2. rebootu / SetupComplete OK -> restore BCD+NVRAM +
//     domyslny wpis; USB zostaje do potwierdzenia.
//
// Wywolanie z engine: install.Engine.StageWin7UEFI(events, kind, journal)
// wykrywa ten backend przez interfejs StageWin7UEFIModern(journal).

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

// Win7StagingParams parametry wykonawcze stagingu na dysk SATA.
type Win7StagingParams struct {
	// ESPRoot to zamontowany root ESP dysku docelowego, np. "S:".
	ESPRoot string
	// WindowsDir to katalog Windows po apply-image, np. `W:\Windows`.
	WindowsDir string
	// ESPVolume to wolumen dla /s, np. "S:".
	ESPVolume string
	// BackupDir to katalog kopii BCD+NVRAM+journal (np. na USB).
	BackupDir string
	// StagedEntryID to identyfikator wpisu BCD stagingu.
	StagedEntryID string
	// BootTimeoutSec to timeout one-shot startu (domyslnie 10).
	BootTimeoutSec int
	// SetupCompleteOK i RebootCount to wejscie watchdoga.
	SetupCompleteOK bool
	RebootCount     int
}

func (p Win7StagingParams) journal() install.Win7StagingJournal {
	return install.NewWin7StagingJournal(p.BackupDir, p.StagedEntryID, p.WindowsDir, p.ESPVolume)
}

// StageWin7UEFIModern implementuje opcjonalny hook wykrywany przez
// install.Engine.StageWin7UEFI. Backend pendrive USOS bez tego hooka
// to no-op (engine loguje i kontynuuje).
func (b Backend) StageWin7UEFIModern(journal install.Win7StagingJournal) error {
	return StageWin7UEFIModernOnDisk(Win7StagingParams{
		BackupDir:     journal.BackupDir,
		StagedEntryID: journal.StagedEntryID,
		WindowsDir:    firstArg(journal.BcdbootCommand, `W:\Windows`),
		ESPVolume:     "S:",
	})
}

// StageWin7UEFIModernOnDisk wykonuje backup -> bcdboot -> one-shot BootNext.
func StageWin7UEFIModernOnDisk(p Win7StagingParams) error {
	espRoot := p.ESPRoot
	if espRoot == "" {
		espRoot = p.ESPVolume
	}
	if espRoot == "" {
		espRoot = "S:"
	}
	if p.BackupDir == "" {
		return fmt.Errorf("win7 staging: pusty BackupDir (backup BCD jest obowiazkowy)")
	}
	if err := BackupESPBootFiles(espRoot, p.BackupDir); err != nil {
		return err
	}
	if err := DumpFirmwareNVRAM(p.BackupDir); err != nil {
		return err
	}
	j := p.journal()
	if err := os.WriteFile(filepath.Join(p.BackupDir, install.StagingJournalFileName), []byte(install.FormatWin7StagingJournal(j)), 0o644); err != nil {
		return fmt.Errorf("win7 staging: zapis journal: %w", err)
	}
	// bcdboot dopiero po verify apply-image: wywolujacy ma to zagwarantowac.
	bcdboot := install.BcdbootUEFICommand(p.WindowsDir, p.ESPVolume)
	if out, err := exec.Command(bcdboot[0], bcdboot[1:]...).CombinedOutput(); err != nil {
		return fmt.Errorf("win7 staging: %v: %w: %s", bcdboot, err, string(out))
	}
	entry := p.StagedEntryID
	if entry == "" {
		entry = "{new-win7-staging}"
	}
	timeout := p.BootTimeoutSec
	if timeout <= 0 {
		timeout = 10
	}
	winCmds, _ := install.OneShotBootNextCommands(entry, timeout)
	for _, c := range winCmds {
		if out, err := exec.Command(c[0], c[1:]...).CombinedOutput(); err != nil {
			return fmt.Errorf("win7 staging one-shot: %v: %w: %s", c, err, string(out))
		}
	}
	return nil
}

// BackupESPBootFiles kopiuje ESP:\EFI\Microsoft\Boot\{BCD,BCD.LOG*,bootmgfw.efi}
// do backupDir. Nie modyfikuje BootOrder.
func BackupESPBootFiles(espRoot, backupDir string) error {
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return fmt.Errorf("win7 staging: mkdir backup: %w", err)
	}
	srcDir := filepath.Join(espRoot, "EFI", "Microsoft", "Boot")
	dstDir := filepath.Join(backupDir, "ESP-EFI-Microsoft-Boot")
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		return fmt.Errorf("win7 staging: mkdir backup boot: %w", err)
	}
	for _, name := range install.EspBackupFileSet() {
		base := filepath.Base(name)
		data, err := os.ReadFile(filepath.Join(srcDir, base))
		if err != nil {
			// BCD.LOG* moga nie istniec na czystym ESP: pomijamy brakujace LOG,
			// ale BCD i bootmgfw.efi sa obowiazkowe.
			if base == "BCD" || base == "bootmgfw.efi" {
				return fmt.Errorf("win7 staging: backup %s: %w", base, err)
			}
			continue
		}
		if err := os.WriteFile(filepath.Join(dstDir, base), data, 0o644); err != nil {
			return fmt.Errorf("win7 staging: zapis kopii %s: %w", base, err)
		}
	}
	return nil
}

// DumpFirmwareNVRAM zapisuje dump bcdedit /enum firmware do backupDir
// (odczyt, bez modyfikacji BootOrder).
func DumpFirmwareNVRAM(backupDir string) error {
	win, _ := install.FirmwareDumpCommands()
	out, err := exec.Command(win[0], win[1:]...).CombinedOutput()
	if err != nil {
		return fmt.Errorf("win7 staging: dump NVRAM: %w: %s", err, string(out))
	}
	if err := os.MkdirAll(backupDir, 0o755); err != nil {
		return fmt.Errorf("win7 staging: mkdir backup: %w", err)
	}
	if err := os.WriteFile(filepath.Join(backupDir, install.NVRAMDumpFileName), out, 0o644); err != nil {
		return fmt.Errorf("win7 staging: zapis dump NVRAM: %w", err)
	}
	return nil
}

// CheckWin7StagingWatchdog ocenia watchdoga: restore=true oznacza przywrocenie
// BCD+NVRAM + domyslny wpis; USB zostaje do potwierdzenia.
func CheckWin7StagingWatchdog(rebootCount int, setupCompleteOK bool) (restore bool, reason string) {
	return install.Win7WatchdogDecision(rebootCount, setupCompleteOK)
}

// RestoreWin7StagingBackup przywraca BCD+bootmgfw.efi z backupDir na ESP
// i ustawia domyslny wpis rozruchowy. BootOrder pozostaje nietknieta poza
// przywroceniem domyslnego wpisu; jednorazowy BootNext wygasa sam.
func RestoreWin7StagingBackup(espRoot, backupDir, defaultEntryID string) error {
	srcDir := filepath.Join(backupDir, "ESP-EFI-Microsoft-Boot")
	dstDir := filepath.Join(espRoot, "EFI", "Microsoft", "Boot")
	for _, name := range install.EspBackupFileSet() {
		base := filepath.Base(name)
		src := filepath.Join(srcDir, base)
		data, err := os.ReadFile(src)
		if err != nil {
			if base == "BCD" || base == "bootmgfw.efi" {
				return fmt.Errorf("win7 rollback: brak kopii %s: %w", base, err)
			}
			continue
		}
		if err := os.WriteFile(filepath.Join(dstDir, base), data, 0o644); err != nil {
			return fmt.Errorf("win7 rollback: restore %s: %w", base, err)
		}
	}
	entry := defaultEntryID
	if entry == "" {
		entry = "{default}"
	}
	if out, err := exec.Command("bcdedit", "/set", "{fwbootmgr}", "displayorder", entry, "/addfirst").CombinedOutput(); err != nil {
		return fmt.Errorf("win7 rollback: domyslny wpis: %w: %s", err, string(out))
	}
	return nil
}

func firstArg(cmd []string, fallback string) string {
	if len(cmd) >= 2 {
		return cmd[1]
	}
	return fallback
}
