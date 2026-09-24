package winhost

import (
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func TestRequiredDataDirectoriesCoverEveryVisibleProfile(t *testing.T) {
	want := []string{
		filepath.Join("Systems", "Windows", "Windows 11", "Images"),
		filepath.Join("Systems", "Windows", "Windows 10", "Images"),
		filepath.Join("Systems", "Windows", "Windows XP", "Images"),
		filepath.Join("Systems", "Windows", "Windows 3.11", "Images"),
		filepath.Join("Systems", "Windows", "Windows 3.1", "Images"),
		filepath.Join("Systems", "Linux", "Ubuntu", "Images"),
		filepath.Join("Systems", "Linux", "Ubuntu", "Unattended"),
		filepath.Join("Systems", "Betas", "Windows Whistler", "Images"),
		filepath.Join("Systems", "Betas", "Windows Longhorn", "Unattended"),
		filepath.Join("Systems", "DOS", "MS-DOS", "Images"),
		filepath.Join("Systems", "DOS", "MS-DOS", "Programs"),
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
	if len(windowsProfiles) != 15 {
		t.Fatalf("windows profile count=%d, want 15", len(windowsProfiles))
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

func TestRequiredDataDirectoriesContainDriversTree(t *testing.T) {
	want := []string{
		"Drivers",
		filepath.Join("Drivers", "UEFI"),
		filepath.Join("Drivers", "Windows 3.1"),
		filepath.Join("Drivers", "Windows 98 SE"),
		filepath.Join("Drivers", "Windows NT 4.0"),
	}
	nt := map[string]bool{}
	for _, name := range []string{"Windows 11", "Windows 10", "Windows 8.1", "Windows 8", "Windows 7", "Windows Vista", "Windows XP", "Windows 2000"} {
		nt[name] = true
	}
	for _, profile := range windowsProfiles {
		if profile.ntSetup != nt[profile.name] {
			t.Errorf("%s: ntSetup=%v", profile.name, profile.ntSetup)
		}
		root := filepath.Join("Drivers", profile.name)
		want = append(want, root)
		for _, class := range []string{"Storage", "USB", "Other"} {
			path := filepath.Join(root, class)
			if nt[profile.name] {
				want = append(want, path)
			} else if containsDataDirectory(path) {
				t.Errorf("non-NT-setup profile has %q", path)
			}
		}
	}
	for _, path := range want {
		if !containsDataDirectory(path) {
			t.Errorf("required DATA directories do not contain %q", path)
		}
	}
}

// Install and update both run ensureDataDirectories; running it again over a
// DATA tree with user drivers must keep every user file.
func TestEnsureDataDirectoriesKeepsUserDrivers(t *testing.T) {
	root := t.TempDir()
	if err := ensureDataDirectories(root); err != nil {
		t.Fatal(err)
	}
	userFiles := []string{
		filepath.Join("Drivers", "UEFI", "Touch", "touch.efi"),
		filepath.Join("Drivers", "UEFI", "Touch", "driver.ini"),
		filepath.Join("Drivers", "Windows 11", "Storage", "vmd", "iaStorVD.inf"),
		filepath.Join("Drivers", "Windows XP", "loose.inf"),
		filepath.Join("Drivers", "My notes.txt"),
	}
	for _, file := range userFiles {
		path := filepath.Join(root, file)
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte("user "+file), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := ensureDataDirectories(root); err != nil {
		t.Fatal(err)
	}
	for _, file := range userFiles {
		data, err := os.ReadFile(filepath.Join(root, file))
		if err != nil || string(data) != "user "+file {
			t.Fatalf("user file %s changed after the second run: %q %v", file, data, err)
		}
	}
	for _, directory := range requiredDataDirectories {
		if info, err := os.Stat(filepath.Join(root, directory)); err != nil || !info.IsDir() {
			t.Fatalf("DATA directory %s missing: %v", directory, err)
		}
	}
}

// Nothing on the install/update path may delete under DATA\Drivers: the only
// removals in winhost are the ESP catalog and the Programs\USOS templates,
// and CopyInstallPayload creates the layout only through ensureDataDirectories.
func TestInstallPathNeverRemovesDrivers(t *testing.T) {
	files, err := filepath.Glob("*.go")
	if err != nil {
		t.Fatal(err)
	}
	removal := regexp.MustCompile(`os\.(Remove|RemoveAll)\(`)
	for _, file := range files {
		if strings.HasSuffix(file, "_test.go") {
			continue
		}
		source, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(source), "\n") {
			if removal.MatchString(line) && strings.Contains(line, "Drivers") {
				t.Errorf("%s:%d removes under Drivers: %s", file, i+1, strings.TrimSpace(line))
			}
		}
	}
	payloadSource, err := os.ReadFile("payload_windows.go")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(payloadSource), "ensureDataDirectories(resolved.DATA.VolumePath)") {
		t.Fatal("CopyInstallPayload no longer creates the DATA layout through ensureDataDirectories")
	}
}
