package winhost

import (
	"path/filepath"
	"testing"
)

func TestRequiredDataDirectoriesCoverEveryVisibleProfile(t *testing.T) {
	want := []string{
		filepath.Join("Systems", "Windows", "Windows 11", "Images"),
		filepath.Join("Systems", "Windows", "Windows 10", "Images"),
		filepath.Join("Systems", "Windows", "Windows XP", "Images"),
		filepath.Join("Systems", "Windows", "Windows 3.11", "Images"),
		filepath.Join("Systems", "Linux", "Ubuntu", "Images"),
		filepath.Join("Systems", "Linux", "Ubuntu", "Unattended"),
		filepath.Join("Systems", "Betas", "Windows Whistler", "Images"),
		filepath.Join("Systems", "Betas", "Windows Longhorn", "Unattended"),
		filepath.Join("Systems", "DOS", "MS-DOS", "Images"),
		"Utilities",
		filepath.Join("Programs", "USOS"),
	}
	for _, path := range want {
		if !containsDataDirectory(path) {
			t.Fatalf("required DATA directories do not contain %q", path)
		}
	}
}

func TestWindows311DoesNotCreateUnattendedDirectory(t *testing.T) {
	path := filepath.Join("Systems", "Windows", "Windows 3.11", "Unattended")
	if containsDataDirectory(path) {
		t.Fatalf("Windows 3.11 unexpectedly has an unattended directory")
	}
}

func TestDataProfileCountsStayInSyncWithCatalog(t *testing.T) {
	if len(windowsProfiles) != 14 {
		t.Fatalf("windows profile count=%d, want 14", len(windowsProfiles))
	}
	if len(linuxProfiles) != 9 {
		t.Fatalf("linux profile count=%d, want 9", len(linuxProfiles))
	}
	if len(betaProfiles) != 6 {
		t.Fatalf("beta profile count=%d, want 6", len(betaProfiles))
	}
	if len(dosProfiles) != 6 {
		t.Fatalf("DOS profile count=%d, want 6", len(dosProfiles))
	}
}

func TestUtilitiesAreUserDefinedInsteadOfPrecreatedCategories(t *testing.T) {
	legacy := filepath.Join("Utilities", "Memory Tests", "Images")
	if containsDataDirectory(legacy) {
		t.Fatalf("legacy fixed utility category is still precreated: %q", legacy)
	}
	if !containsDataDirectory("Utilities") {
		t.Fatal("Utilities root is missing")
	}
}

func TestDataProgramFile(t *testing.T) {
	root := filepath.Join("X:", "")
	got := dataProgramFile(root, "USOS Installer.exe")
	want := filepath.Join(root, "Programs", "USOS", "USOS Installer.exe")
	if got != want {
		t.Fatalf("dataProgramFile = %q, want %q", got, want)
	}
}

func containsDataDirectory(want string) bool {
	for _, path := range requiredDataDirectories {
		if path == want {
			return true
		}
	}
	return false
}
