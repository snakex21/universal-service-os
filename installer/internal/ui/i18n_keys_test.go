package ui

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

var keyCall = regexp.MustCompile(`i18n\.(T|N)\(\s*"([^"]+)"`)

// Every key referenced from Go code must exist in the English catalog (and, by
// the i18n completeness test, in every other catalog).
func TestReferencedKeysExist(t *testing.T) {
	english, ok := i18n.Catalog(i18n.Fallback)
	if !ok {
		t.Fatal("English catalog missing")
	}
	var files []string
	for _, dir := range []string{".", "../domain", "../winhost", "../../cmd/usos-installer"} {
		matches, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil {
			t.Fatal(err)
		}
		files = append(files, matches...)
	}
	referenced := 0
	for _, file := range files {
		source, err := os.ReadFile(file)
		if err != nil {
			t.Fatal(err)
		}
		for _, match := range keyCall.FindAllStringSubmatch(string(source), -1) {
			referenced++
			key := match[2]
			if match[1] == "N" {
				if _, ok := english[key+".one"]; !ok {
					t.Errorf("%s: plural key %s has no .one form", file, key)
				}
				if _, ok := english[key+".other"]; !ok {
					t.Errorf("%s: plural key %s has no .other form", file, key)
				}
				continue
			}
			if _, ok := english[key]; !ok {
				t.Errorf("%s: missing key %s", file, key)
			}
		}
	}
	if referenced < 100 {
		t.Fatalf("only %d key references found; the scan is probably broken", referenced)
	}
}

func TestEveryStageHasATranslation(t *testing.T) {
	check := func(operation string, id int) {
		key := fmt.Sprintf("installer.stage.%s.%d", operation, id)
		for _, language := range i18n.Languages() {
			catalog, _ := i18n.Catalog(language.Code)
			if _, ok := catalog[key]; !ok {
				t.Errorf("%s: missing %s", language.Code, key)
			}
		}
	}
	for _, stage := range install.Stages() {
		check("install", int(stage.ID))
	}
	for id := localupdate.StageID(1); id <= localupdate.StageCount; id++ {
		if _, ok := localupdate.StageInfo(id); ok {
			check("update", int(id))
		}
	}
	for id := repair.StageID(1); id <= repair.StageCount; id++ {
		if _, ok := repair.StageInfo(id); ok {
			check("repair", int(id))
		}
	}
	for id := uninstall.StageID(1); id <= uninstall.StageCount; id++ {
		if _, ok := uninstall.StageInfo(id); ok {
			check("uninstall", int(id))
		}
	}
}
