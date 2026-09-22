package install

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeWin7Library tworzy w tmp biblioteke driverow/updates wedlug
// MEDIA_LAYOUT.md. driverSets to podkatalogi, ktore maja dostac *.inf;
// kbs to identyfikatory KB, dla ktorych powstanie plik *.msu.
func writeWin7Library(t *testing.T, driverSets, kbs []string) string {
	t.Helper()
	root := t.TempDir()
	for _, name := range Win7DriverSetNames() {
		dir := filepath.Join(root, Win7DriverLibraryRelDir(), name)
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
		if err := os.WriteFile(filepath.Join(dir, ".gitkeep"), nil, 0o644); err != nil {
			t.Fatalf("write gitkeep: %v", err)
		}
	}
	for _, name := range driverSets {
		path := filepath.Join(root, Win7DriverLibraryRelDir(), name, "usbxhci.inf")
		if err := os.WriteFile(path, []byte("; inf"), 0o644); err != nil {
			t.Fatalf("write inf: %v", err)
		}
	}
	updates := filepath.Join(root, Win7UpdatesRelDir())
	if err := os.MkdirAll(updates, 0o755); err != nil {
		t.Fatalf("mkdir updates: %v", err)
	}
	for _, kb := range kbs {
		name := fmt.Sprintf("windows6.1-%s-v3-x64_deadbeef.msu", strings.ToLower(kb))
		if err := os.WriteFile(filepath.Join(updates, name), []byte("msu"), 0o644); err != nil {
			t.Fatalf("write msu: %v", err)
		}
	}
	return root
}

func allRequiredKBs() []string {
	kbs := make([]string, 0, len(Win7RequiredHotfixes()))
	for _, h := range Win7RequiredHotfixes() {
		kbs = append(kbs, h.KB)
	}
	return kbs
}

func TestWin7RequiredHotfixesPutSHA2First(t *testing.T) {
	hotfixes := Win7RequiredHotfixes()
	want := []string{"KB4474419", "KB2990941", "KB3087873"}
	if len(hotfixes) != len(want) {
		t.Fatalf("hotfixes=%d, want %d", len(hotfixes), len(want))
	}
	for i, kb := range want {
		if hotfixes[i].KB != kb {
			t.Fatalf("hotfix[%d]=%s, want %s (SHA-2 musi byc pierwszy)", i, hotfixes[i].KB, kb)
		}
	}
}

func TestDiscoverWin7InjectionSources(t *testing.T) {
	tests := []struct {
		name        string
		driverSets  []string
		kbs         []string
		wantDrivers int
		wantMissing []string
	}{
		{
			name:        "komplet",
			driverSets:  []string{Win7DriverSetUSBGeneric, Win7DriverSetNVMe},
			kbs:         allRequiredKBs(),
			wantDrivers: 2,
		},
		{
			name:        "same puste katalogi driverow",
			driverSets:  nil,
			kbs:         allRequiredKBs(),
			wantMissing: []string{"sterowniki USB 3.0"},
		},
		{
			name:        "brak hotfixow NVMe",
			driverSets:  []string{Win7DriverSetUSBGeneric},
			kbs:         []string{"KB4474419"},
			wantDrivers: 1,
			wantMissing: []string{"KB2990941", "KB3087873"},
		},
		{
			name:        "brak wszystkiego",
			driverSets:  nil,
			kbs:         nil,
			wantMissing: []string{"sterowniki USB 3.0", "KB4474419", "KB2990941", "KB3087873"},
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			root := writeWin7Library(t, tc.driverSets, tc.kbs)
			sources, err := DiscoverWin7InjectionSources(root)
			if len(tc.wantMissing) == 0 {
				if err != nil {
					t.Fatalf("discover: %v", err)
				}
				if len(sources.DriverDirs) != tc.wantDrivers {
					t.Fatalf("driverDirs=%d, want %d", len(sources.DriverDirs), tc.wantDrivers)
				}
				if len(sources.HotfixPaths) != len(Win7RequiredHotfixes()) {
					t.Fatalf("hotfixPaths=%d, want %d", len(sources.HotfixPaths), len(Win7RequiredHotfixes()))
				}
				return
			}
			if err == nil {
				t.Fatalf("oczekiwano MissingArtifactsError, dostalem nil")
			}
			if !errors.Is(err, ErrMissingArtifacts) {
				t.Fatalf("errors.Is(err, ErrMissingArtifacts) = false: %v", err)
			}
			var missing *MissingArtifactsError
			if !errors.As(err, &missing) {
				t.Fatalf("errors.As na *MissingArtifactsError = false: %v", err)
			}
			for _, want := range tc.wantMissing {
				if !strings.Contains(err.Error(), want) {
					t.Fatalf("blad nie nazywa %q: %v", want, err)
				}
			}
			// Blad musi mowic, GDZIE artefakt jest oczekiwany.
			for _, m := range missing.Missing {
				if strings.TrimSpace(m.ExpectedPath) == "" || strings.TrimSpace(m.Hint) == "" {
					t.Fatalf("brak sciezki/podpowiedzi dla %q", m.What)
				}
			}
		})
	}
}

func TestDiscoverIgnoresPlaceholderOnlyDirs(t *testing.T) {
	root := writeWin7Library(t, []string{Win7DriverSetNVMe}, allRequiredKBs())
	sources, err := DiscoverWin7InjectionSources(root)
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	if len(sources.SkippedDriverSets) != 3 {
		t.Fatalf("skipped=%v, want 3 puste katalogi = no-op", sources.SkippedDriverSets)
	}
	if len(sources.DriverDirs) != 1 || filepath.Base(sources.DriverDirs[0]) != Win7DriverSetNVMe {
		t.Fatalf("driverDirs=%v, want tylko NVMe", sources.DriverDirs)
	}
}

func TestPlanWin7Injection(t *testing.T) {
	root := writeWin7Library(t, []string{Win7DriverSetUSBGeneric, Win7DriverSetNVMe}, allRequiredKBs())
	sources, err := DiscoverWin7InjectionSources(root)
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	plan, err := PlanWin7Injection(Win7InjectionRequest{
		BootWIM:    `L:\sources\boot.wim`,
		InstallWIM: `L:\sources\install.wim`,
		MountDir:   `C:\mnt\w7`,
		Sources:    sources,
	})
	if err != nil {
		t.Fatalf("plan: %v", err)
	}

	var lines []string
	for _, c := range plan.Commands() {
		lines = append(lines, strings.Join(c, " "))
	}
	joined := strings.Join(lines, "\n")

	tests := []struct {
		name string
		want string
	}{
		{"boot.wim index 1", `/Mount-Wim /WimFile:L:\sources\boot.wim /index:1`},
		{"boot.wim index 2", `/Mount-Wim /WimFile:L:\sources\boot.wim /index:2`},
		{"install.wim index 1", `/Mount-Wim /WimFile:L:\sources\install.wim /index:1`},
		{"add-driver z /Recurse /ForceUnsigned", `/Add-Driver /Driver:`},
		{"commit", `/Unmount-Wim /MountDir:C:\mnt\w7 /Commit`},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if !strings.Contains(joined, tc.want) {
				t.Fatalf("plan nie zawiera %q:\n%s", tc.want, joined)
			}
		})
	}

	// boot.wim NIE dostaje pakietow MSU.
	bootSection := joined[:strings.Index(joined, `/WimFile:L:\sources\install.wim`)]
	if strings.Contains(bootSection, "/Add-Package") {
		t.Fatalf("boot.wim nie moze dostawac /Add-Package:\n%s", bootSection)
	}
	// install.wim: kazdy /Add-Package przed pierwszym /Add-Driver tej sekcji.
	installSection := joined[strings.Index(joined, `/WimFile:L:\sources\install.wim`):]
	firstDriver := strings.Index(installSection, "/Add-Driver")
	lastPackage := strings.LastIndex(installSection, "/Add-Package")
	if firstDriver < 0 || lastPackage < 0 || lastPackage > firstDriver {
		t.Fatalf("kolejnosc SHA-2/NVMe Add-Package PRZED Add-Driver zlamana:\n%s", installSection)
	}
	// SHA-2 jako pierwszy pakiet.
	firstPackageLine := ""
	for _, line := range strings.Split(installSection, "\n") {
		if strings.Contains(line, "/Add-Package") {
			firstPackageLine = line
			break
		}
	}
	if !strings.Contains(strings.ToLower(firstPackageLine), "kb4474419") {
		t.Fatalf("pierwszy Add-Package = %q, oczekiwano KB4474419", firstPackageLine)
	}
}

func TestPlanWin7InjectionRejectsIncompleteInput(t *testing.T) {
	full, err := DiscoverWin7InjectionSources(writeWin7Library(t, []string{Win7DriverSetNVMe}, allRequiredKBs()))
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	tests := []struct {
		name string
		req  Win7InjectionRequest
	}{
		{"brak boot.wim", Win7InjectionRequest{InstallWIM: "i.wim", Sources: full}},
		{"brak install.wim", Win7InjectionRequest{BootWIM: "b.wim", Sources: full}},
		{"brak driverow", Win7InjectionRequest{BootWIM: "b.wim", InstallWIM: "i.wim",
			Sources: Win7InjectionSources{HotfixPaths: full.HotfixPaths}}},
		{"niepelna kolejka MSU", Win7InjectionRequest{BootWIM: "b.wim", InstallWIM: "i.wim",
			Sources: Win7InjectionSources{DriverDirs: full.DriverDirs, HotfixPaths: full.HotfixPaths[:1]}}},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := PlanWin7Injection(tc.req); err == nil {
				t.Fatalf("oczekiwano bledu dla %q", tc.name)
			}
		})
	}
}

// fakeRunner zbiera wywolania i zwraca blad dla komendy pasujacej do failOn.
type fakeRunner struct {
	calls  []string
	failOn string
}

func (f *fakeRunner) run(name string, args ...string) ([]byte, error) {
	line := strings.Join(append([]string{name}, args...), " ")
	f.calls = append(f.calls, line)
	if f.failOn != "" && strings.Contains(line, f.failOn) {
		return []byte("dism error 0x80070032"), errors.New("exit status 50")
	}
	return []byte("ok"), nil
}

func TestWin7InjectorApply(t *testing.T) {
	root := writeWin7Library(t, []string{Win7DriverSetUSBGeneric}, allRequiredKBs())
	sources, err := DiscoverWin7InjectionSources(root)
	if err != nil {
		t.Fatalf("discover: %v", err)
	}
	plan, err := PlanWin7Injection(Win7InjectionRequest{
		BootWIM: `L:\sources\boot.wim`, InstallWIM: `L:\sources\install.wim`,
		MountDir: `C:\mnt\w7`, Sources: sources,
	})
	if err != nil {
		t.Fatalf("plan: %v", err)
	}

	tests := []struct {
		name         string
		failOn       string
		wantErr      bool
		wantDiscard  bool
		wantAllSteps bool
	}{
		{name: "wszystko przechodzi", wantAllSteps: true},
		{name: "blad Add-Package konczy sie /Discard", failOn: "/Add-Package", wantErr: true, wantDiscard: true},
		{name: "blad Mount-Wim bez /Discard", failOn: "/Mount-Wim", wantErr: true},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			runner := &fakeRunner{failOn: tc.failOn}
			err := Win7Injector{Run: runner.run}.Apply(plan)
			if tc.wantErr != (err != nil) {
				t.Fatalf("err=%v, wantErr=%t", err, tc.wantErr)
			}
			joined := strings.Join(runner.calls, "\n")
			if tc.wantDiscard != strings.Contains(joined, "/Discard") {
				t.Fatalf("/Discard obecny=%t, want %t:\n%s", strings.Contains(joined, "/Discard"), tc.wantDiscard, joined)
			}
			if tc.wantAllSteps && len(runner.calls) != len(plan.Steps) {
				t.Fatalf("wykonano %d krokow, want %d", len(runner.calls), len(plan.Steps))
			}
		})
	}
}

func TestWin7InjectorRequiresRunner(t *testing.T) {
	if err := (Win7Injector{}).Apply(Win7InjectionPlan{}); err == nil {
		t.Fatal("oczekiwano bledu przy braku CommandRunner")
	}
}
