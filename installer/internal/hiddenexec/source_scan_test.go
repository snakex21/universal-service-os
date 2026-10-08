package hiddenexec

import (
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

var bareCommand = regexp.MustCompile(`(^|[^A-Za-z0-9_])exec\.Command(Context)?\(`)

// Installer code must start helper programs through this package (or set
// CREATE_NO_WINDOW itself), otherwise their console windows flash over the
// installer. Dev tools under cmd/ other than the installer are not checked.
func TestInstallerCodeStartsChildrenHidden(t *testing.T) {
	allowed := map[string]string{
		"hiddenexec/hiddenexec.go":     "the helper itself",
		"mokenroll/machine_windows.go": "sets CREATE_NO_WINDOW itself",
	}
	roots := []string{"..", filepath.Join("..", "..", "cmd", "usos-installer")}
	checked := 0
	for _, root := range roots {
		err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
			if err != nil {
				return err
			}
			if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
				return nil
			}
			rel := filepath.ToSlash(path)
			rel = strings.TrimPrefix(rel, "../")
			source, err := os.ReadFile(path)
			if err != nil {
				return err
			}
			checked++
			if !bareCommand.Match(source) {
				return nil
			}
			if _, ok := allowed[rel]; ok {
				if rel == "mokenroll/machine_windows.go" && !strings.Contains(string(source), "0x08000000") {
					t.Errorf("%s no longer sets CREATE_NO_WINDOW", rel)
				}
				return nil
			}
			t.Errorf("%s starts a process with exec.Command; use hiddenexec.Command", rel)
			return nil
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	if checked < 50 {
		t.Fatalf("only %d files scanned; the scan is probably broken", checked)
	}
}
