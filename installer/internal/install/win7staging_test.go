package install

import (
	"strings"
	"testing"
)

func TestClassifyWin7Target(t *testing.T) {
	if got := ClassifyWin7Target("x64", "uefi"); got != Win7UEFIX64Modern {
		t.Fatalf("x64/uefi = %d, want modern", got)
	}
	if got := ClassifyWin7Target("x86", "uefi"); got != Win7BIOSVanilla {
		t.Fatalf("x86/uefi = %d, want vanilla", got)
	}
	if got := ClassifyWin7Target("x64", "bios"); got != Win7BIOSVanilla {
		t.Fatalf("x64/bios = %d, want vanilla", got)
	}
}

func TestBcdbootAfterVerifyCommand(t *testing.T) {
	cmd := BcdbootUEFICommand(`W:\Windows`, "S:")
	want := []string{"bcdboot", `W:\Windows`, "/s", "S:", "/f", "UEFI"}
	if strings.Join(cmd, " ") != strings.Join(want, " ") {
		t.Fatalf("bcdboot=%v, want %v", cmd, want)
	}
}

func TestOneShotKeepsBootOrderUntouched(t *testing.T) {
	win, linux := OneShotBootNextCommands("{abc}", 10)
	joined := ""
	for _, c := range win {
		joined += strings.Join(c, " ") + "\n"
	}
	for _, c := range linux {
		joined += strings.Join(c, " ") + "\n"
	}
	if strings.Contains(strings.ToLower(joined), "bootorder") {
		t.Fatalf("one-shot must not touch BootOrder: %q", joined)
	}
	if !strings.Contains(joined, "bootsequence") || !strings.Contains(joined, "efibootmgr -n") {
		t.Fatalf("one-shot missing BootNext/bootsequence: %q", joined)
	}
}

func TestEspBackupSetCoversBCDAndBootmgfw(t *testing.T) {
	set := strings.Join(EspBackupFileSet(), "\n")
	for _, want := range []string{"BCD", "bootmgfw.efi", "BCD.LOG"} {
		if !strings.Contains(set, want) {
			t.Fatalf("backup set missing %q: %q", want, set)
		}
	}
}

func TestModernUnattendHasOOBESkipsAndFirstLogon(t *testing.T) {
	xml := Win7ModernAutounattend(Win7ModernUnattendParams{})
	for _, want := range []string{"SkipMachineOOBE", "SkipUserOOBE", "ProtectYourPC>3<", "HideEULA", "pl-PL", "FirstLogonCommands", "SetupComplete.cmd", "DriverPaths"} {
		if !strings.Contains(xml, want) {
			t.Fatalf("unattend missing %q", want)
		}
	}
}

func TestSetupCompleteFallsBackToPnputil(t *testing.T) {
	s := Win7SetupCompleteScript(`D:\Drivers\x64`)
	if !strings.Contains(s, "pnputil") {
		t.Fatalf("SetupComplete.cmd must call pnputil")
	}
}

func TestWatchdogRestoresOnMissingSecondReboot(t *testing.T) {
	if restore, _ := Win7WatchdogDecision(1, true); !restore {
		t.Fatalf("1 reboot should trigger restore")
	}
	if restore, _ := Win7WatchdogDecision(2, false); !restore {
		t.Fatalf("missing SetupComplete OK should trigger restore")
	}
	if restore, _ := Win7WatchdogDecision(2, true); restore {
		t.Fatalf("2 reboots + OK should not restore")
	}
}

func TestDismOfflineCoversBootWim12AndImage(t *testing.T) {
	cmds := DismOfflineDriverCommands("", "", "")
	joined := ""
	for _, c := range cmds {
		joined += strings.Join(c, " ") + "\n"
	}
	for _, want := range []string{"/index:1", "/index:2", "/Add-Driver", "/Recurse", "/ForceUnsigned"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("dism missing %q: %q", want, joined)
		}
	}
}
