package winmedia

import (
	"bufio"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// rulesPath wskazuje wspolna tabele regul. Ten sam plik czyta test po
// stronie firmware: src/image_probe/windows7_pe_rules_test.zig.
var rulesPath = filepath.Join("..", "..", "..", "src", "image_probe", "windows7_pe_rules.tsv")

// peRule to jeden wiersz wspolnej tabeli.
type peRule struct {
	line    string
	install Version
	boot    Version
	arch    int
	goClass Class
	zigMode string
}

// parsePERuleVersion rozbiera "6.1.7601" na Version. SPBuild nie jest czescia
// reguly, wiec w tabeli go nie ma i tutaj zostaje zerowy.
func parsePERuleVersion(t *testing.T, text string) Version {
	t.Helper()
	parts := strings.Split(text, ".")
	if len(parts) != 3 {
		t.Fatalf("zla wersja w tabeli regul: %q", text)
	}
	numbers := make([]int, 3)
	for i, part := range parts {
		value, err := strconv.Atoi(part)
		if err != nil {
			t.Fatalf("zla wersja w tabeli regul %q: %v", text, err)
		}
		numbers[i] = value
	}
	return Version{Major: numbers[0], Minor: numbers[1], Build: numbers[2]}
}

func loadPERules(t *testing.T) []peRule {
	t.Helper()
	file, err := os.Open(rulesPath)
	if err != nil {
		t.Fatalf("otwarcie wspolnej tabeli regul %s: %v", rulesPath, err)
	}
	defer file.Close()

	var rules []peRule
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := strings.TrimRight(scanner.Text(), "\r")
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fields := strings.Split(line, "\t")
		if len(fields) != 5 {
			t.Fatalf("wiersz tabeli regul musi miec 5 kolumn rozdzielonych TABem: %q", line)
		}
		var arch int
		switch fields[2] {
		case "x64":
			arch = ArchX64
		case "x86":
			arch = ArchX86
		default:
			t.Fatalf("nieznana architektura w tabeli regul: %q", fields[2])
		}
		switch fields[4] {
		case "original", "hybrid", "rejected":
		default:
			t.Fatalf("nieznany zig_mode w tabeli regul: %q", fields[4])
		}
		rules = append(rules, peRule{
			line:    line,
			install: parsePERuleVersion(t, fields[0]),
			boot:    parsePERuleVersion(t, fields[1]),
			arch:    arch,
			goClass: Class(fields[3]),
			zigMode: fields[4],
		})
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("odczyt wspolnej tabeli regul: %v", err)
	}
	// Obcieta albo pusta tabela nie moze przejsc jako "wszystko sie zgadza".
	if len(rules) < 8 {
		t.Fatalf("wspolna tabela regul ma tylko %d wierszy", len(rules))
	}
	return rules
}

// TestPERulesAgreeWithSharedTable sprawdza, ze winmedia.classify zwraca
// dokladnie to, co deklaruje kolumna go_class wspolnej tabeli. Test po
// stronie Zig sprawdza kolumne zig_mode na tym samym pliku, wiec obie
// implementacje moga sie rozjechac tylko przez swiadoma zmiane tabeli.
func TestPERulesAgreeWithSharedTable(t *testing.T) {
	for _, rule := range loadPERules(t) {
		got := classify(rule.install, true, rule.boot, true)
		if got != rule.goClass {
			t.Errorf("regula %q: classify zwrocilo %s, tabela mowi %s", rule.line, got, rule.goClass)
		}
	}
}

// TestPERulesReachClassifyMedia przepuszcza kazdy wiersz przez pelne
// ClassifyMedia (syntetyczny nosnik w tempdir), zeby zgodnosc dotyczyla
// wejscia uzywanego produkcyjnie, a nie tylko funkcji wewnetrznej.
func TestPERulesReachClassifyMedia(t *testing.T) {
	for _, rule := range loadPERules(t) {
		install := windowsImageXML(1, "install", rule.arch, rule.install.Major, rule.install.Minor, rule.install.Build, 0, "Ultimate")
		boot := windowsImageXML(2, "Microsoft Windows Setup", rule.arch, rule.boot.Major, rule.boot.Minor, rule.boot.Build, 0, "WindowsPE")
		root := writeMedia(t, mediaBlueprint{installXML: install, bootXML: boot, files: win7MediaFiles})
		media, err := ClassifyMedia(root)
		if err != nil {
			t.Fatalf("regula %q: ClassifyMedia: %v", rule.line, err)
		}
		if media.Class != rule.goClass {
			t.Errorf("regula %q: ClassifyMedia dalo %s, tabela mowi %s", rule.line, media.Class, rule.goClass)
		}
		if media.Arch != rule.arch {
			t.Errorf("regula %q: ClassifyMedia dalo arch %s", rule.line, ArchName(media.Arch))
		}
		// Rozmyslna roznica nr 2 z tabeli: Go klasyfikuje generacje takze dla
		// x86, ale x86 nigdy nie jest zdatne do UEFI - tam sciezka Zig nie
		// istnieje i dlatego ten sam wiersz ma zig_mode=rejected.
		if wantUEFI := rule.arch == ArchX64; media.UEFICapable != wantUEFI {
			t.Errorf("regula %q: UEFICapable=%t, oczekiwano %t", rule.line, media.UEFICapable, wantUEFI)
		}
		if rule.arch == ArchX86 && rule.zigMode != "rejected" {
			t.Errorf("regula %q: nosnik x86 musi miec zig_mode=rejected", rule.line)
		}
	}
}

// TestPERulesCoverBothWindows7Generations pilnuje, ze tabela nie straci
// ktorejs z klas, dla ktorych istnieje osobna sciezka startu.
func TestPERulesCoverBothWindows7Generations(t *testing.T) {
	seen := map[Class]map[string]bool{}
	for _, rule := range loadPERules(t) {
		if seen[rule.goClass] == nil {
			seen[rule.goClass] = map[string]bool{}
		}
		seen[rule.goClass][rule.zigMode] = true
	}
	// PE7 startuje przez zewnetrzny PE10 (original), PE10 startuje sam
	// (hybrid), a nosnik nie-Win7 nie wchodzi na sciezke Win7 w ogole.
	if !seen[ClassWin7PE7]["original"] {
		t.Error("tabela nie ma wiersza WIN7_PE7 -> original")
	}
	if !seen[ClassWin7PE10]["hybrid"] {
		t.Error("tabela nie ma wiersza WIN7_PE10 -> hybrid")
	}
	if seen[ClassWin7PE10]["rejected"] {
		t.Error("WIN7_PE10 nie moze byc odrzucane przez brame wersji")
	}
	for _, class := range []Class{ClassWin10, ClassUnknown} {
		if !seen[class]["rejected"] {
			t.Errorf("tabela nie ma wiersza %s -> rejected", class)
		}
		if seen[class]["original"] {
			t.Errorf("%s nie moze trafic na sciezke oryginalnego Windows 7", class)
		}
	}
}
