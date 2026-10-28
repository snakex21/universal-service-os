package portable

import (
	"bufio"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// isolate points %APPDATA% (os.UserConfigDir) at a temp folder so tests
// never read or write the real profile, and returns that folder.
func isolate(t *testing.T) string {
	t.Helper()
	appdata := t.TempDir()
	t.Setenv("APPDATA", appdata)
	t.Setenv("XDG_CONFIG_HOME", appdata)
	base, err := os.UserConfigDir()
	if err != nil {
		t.Fatal(err)
	}
	return base
}

func TestDataDirIsBesideExecutable(t *testing.T) {
	isolate(t)
	root := t.TempDir()
	st := resolveIn(root, LegacyDir())
	if st.err != nil {
		t.Fatal(st.err)
	}
	if want := filepath.Join(root, "data"); st.dir != want {
		t.Fatalf("%s != %s", st.dir, want)
	}
}

func TestGoRunBinaryAnchorsToWorkingDirectory(t *testing.T) {
	wd, _ := os.Getwd()
	goRun := filepath.Join(os.Getenv("SystemDrive")+string(filepath.Separator), "T", "go-build123", "b001", "exe", "usos-efisign.exe")
	if !isGoRunBinary(goRun) || anchorDir(goRun) != wd {
		t.Fatalf("go run binary not anchored to %s", wd)
	}
	for _, exe := range []string{
		filepath.Join("C:", "USOS", "USOS Installer.exe"),
		filepath.Join("C:", "T", "go-build123", "b001", "portable.test.exe"),
		filepath.Join("D:", "exe", "x.exe"),
	} {
		if isGoRunBinary(exe) || anchorDir(exe) != filepath.Dir(exe) {
			t.Fatalf("%s treated as go run binary", exe)
		}
	}
}

func TestInitKeepsTemporaryFilesInApplicationFolderAndCleansThem(t *testing.T) {
	isolate(t)
	t.Setenv("PSModuleAnalysisCachePath", "")
	t.Setenv("TMPDIR", t.TempDir())
	t.Setenv("TEMP", t.TempDir())
	t.Setenv("TMP", t.TempDir())
	root := t.TempDir()
	st := resolveIn(root, LegacyDir())
	if st.err != nil {
		t.Fatal(st.err)
	}
	if err := applyEnv(st.dir); err != nil {
		t.Fatal(err)
	}
	work := filepath.Join(root, "data", "tmp")
	if os.Getenv("TEMP") != work || os.Getenv("TMP") != work {
		t.Fatal("temporary work escaped application folder")
	}
	if os.Getenv("PSModuleAnalysisCachePath") != filepath.Join(root, "data", "powershell-module-cache") {
		t.Fatal("PowerShell cache escaped application folder")
	}
	f, err := os.CreateTemp("", "portable-test-")
	if err != nil {
		t.Fatal(err)
	}
	f.Close()
	if filepath.Dir(f.Name()) != work {
		t.Fatal(f.Name())
	}
	// Cleanup on exit removes data\tmp only.
	if err := os.WriteFile(filepath.Join(root, "data", "installer.ini"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	saved := resolved
	resolved = st
	mu.Unlock()
	defer func() { mu.Lock(); resolved = saved; mu.Unlock() }()
	if err := Cleanup(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(work); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("data\\tmp survived cleanup: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "data", "installer.ini")); err != nil {
		t.Fatal("cleanup removed state outside data\\tmp")
	}
}

func TestUnwritableApplicationFolderFailsWithoutProfileFallback(t *testing.T) {
	appdata := isolate(t)
	root := t.TempDir()
	// A file named "data" makes the portable folder impossible to create.
	if err := os.WriteFile(filepath.Join(root, "data"), []byte("occupied"), 0o644); err != nil {
		t.Fatal(err)
	}
	st := resolveIn(root, LegacyDir())
	if !errors.Is(st.err, ErrNotWritable) {
		t.Fatalf("expected ErrNotWritable, got %v", st.err)
	}
	if !strings.Contains(st.err.Error(), filepath.Join(root, "data")) {
		t.Fatalf("error does not name the folder: %v", st.err)
	}
	if _, err := os.Stat(filepath.Join(appdata, LegacyDirName)); !errors.Is(err, os.ErrNotExist) {
		t.Fatal("something was created under %APPDATA%")
	}
}

func TestLegacyStateIsCopiedOnceWithoutTouchingOldFiles(t *testing.T) {
	appdata := isolate(t)
	legacy := filepath.Join(appdata, LegacyDirName)
	signing := filepath.Join(legacy, SigningDirName)
	if err := os.MkdirAll(signing, 0o700); err != nil {
		t.Fatal(err)
	}
	files := map[string]string{
		filepath.Join(legacy, "installer.ini"):         "[ui]\nlanguage=pl\n",
		filepath.Join(legacy, "mok-enrolled-0123ABCD"): "",
		filepath.Join(legacy, "unrelated.txt"):         "x",
		filepath.Join(signing, "usos-secure-boot.key"): "TEST KEY",
	}
	for p, c := range files {
		if err := os.WriteFile(p, []byte(c), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	root := t.TempDir()
	st := resolveIn(root, LegacyDir())
	if st.err != nil || len(st.migrateErrs) != 0 {
		t.Fatal(st.err, st.migrateErrs)
	}
	data := filepath.Join(root, "data")
	got, err := os.ReadFile(filepath.Join(data, "installer.ini"))
	if err != nil || string(got) != "[ui]\nlanguage=pl\n" {
		t.Fatalf("prefs not migrated: %q %v", got, err)
	}
	if _, err := os.Stat(filepath.Join(data, "mok-enrolled-0123ABCD")); err != nil {
		t.Fatal("marker not migrated")
	}
	// The generic copy skips unrelated files and the signing folder (the
	// key has its own verified copy in internal/efisign).
	for _, name := range []string{"unrelated.txt", SigningDirName} {
		if _, err := os.Lstat(filepath.Join(data, name)); err == nil {
			t.Fatalf("%s copied into data", name)
		}
	}
	for p, c := range files {
		if b, err := os.ReadFile(p); err != nil || string(b) != c {
			t.Fatalf("legacy file %s changed: %v", p, err)
		}
	}
	// Second start: the portable copy wins, nothing is copied again.
	if err := os.WriteFile(filepath.Join(data, "installer.ini"), []byte("[ui]\nlanguage=en\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	st = resolveIn(root, LegacyDir())
	if len(st.migrated) != 0 {
		t.Fatalf("migrated again: %v", st.migrated)
	}
	if b, _ := os.ReadFile(filepath.Join(data, "installer.ini")); string(b) != "[ui]\nlanguage=en\n" {
		t.Fatal("portable prefs overwritten by legacy copy")
	}
}

func TestCopyNewNeverOverwrites(t *testing.T) {
	dir := t.TempDir()
	src, dst := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	_ = os.WriteFile(src, []byte("new"), 0o600)
	_ = os.WriteFile(dst, []byte("old"), 0o600)
	if err := CopyNew(src, dst, 0o600); err == nil {
		t.Fatal("existing file overwritten")
	}
	if b, _ := os.ReadFile(dst); string(b) != "old" {
		t.Fatal("existing file changed")
	}
}

// installerRoot is installer\ (this file is installer\internal\portable).
func installerRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

// TestNoProfileOrTempDirectoryUse: no installer code resolves AppData,
// LocalAppData or the system %TEMP% itself. The only exception is the
// read-only legacy reader (legacy.go). os.MkdirTemp("")/CreateTemp("") are
// fine: Init points TEMP/TMP at data\tmp.
func TestNoProfileOrTempDirectoryUse(t *testing.T) {
	forbidden := []string{
		"os.UserConfigDir(", "os.UserCacheDir(", "os.UserHomeDir(", "os.TempDir(",
		`"APPDATA"`, `"LOCALAPPDATA"`, `"USERPROFILE"`,
		`Getenv("TEMP")`, `Getenv("TMP")`, `FOLDERID_RoamingAppData`, `FOLDERID_LocalAppData`,
	}
	allowed := map[string]bool{filepath.Join("internal", "portable", "legacy.go"): true}
	root := installerRoot(t)
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if name := d.Name(); name == "data" || name == "testdata" || strings.HasPrefix(name, ".") {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		rel, _ := filepath.Rel(root, path)
		if allowed[rel] {
			return nil
		}
		f, err := os.Open(path)
		if err != nil {
			return err
		}
		defer f.Close()
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 1<<20), 16<<20)
		for n := 1; sc.Scan(); n++ {
			line := sc.Text()
			if strings.HasPrefix(strings.TrimSpace(line), "//") {
				continue
			}
			for _, bad := range forbidden {
				if strings.Contains(line, bad) {
					t.Errorf("%s:%d uses %s (portable: keep state in data\\ beside the EXE)", rel, n, bad)
				}
			}
		}
		return sc.Err()
	})
	if err != nil {
		t.Fatal(err)
	}
}

// TestGitIgnoresPortableData: data\ (with data\signing) never enters git.
func TestGitIgnoresPortableData(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(installerRoot(t), "..", ".gitignore"))
	if err != nil {
		t.Fatal(err)
	}
	lines := map[string]bool{}
	for _, l := range strings.Split(strings.ReplaceAll(string(b), "\r", ""), "\n") {
		lines[strings.TrimSpace(l)] = true
	}
	for _, want := range []string{"installer/data/", "/data/"} {
		if !lines[want] {
			t.Errorf(".gitignore lacks %q", want)
		}
	}
}
