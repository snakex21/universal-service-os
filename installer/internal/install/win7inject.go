package install

// Offline injekcja sterownikow USB 3.0 / NVMe oraz hotfixow NVMe+SHA-2
// do nosnika instalacyjnego Windows 7 (sources/boot.wim + sources/install.wim).
//
// To NIE jest drugi pipeline sterownikow. Zrodlem plikow jest ta sama
// biblioteka, ktora opisuje MEDIA_LAYOUT.md ("Windows 7 x64 - biblioteka
// driverow i kolejka SHA-2") i ktorej uzywa staging na target:
//
//	Systems/Windows/Windows 7/Drivers/x64/{USB_AMD,USB_Intel,USB_Generic,NVMe}/
//	Systems/Windows/Windows 7/Updates/                (pliki *.msu)
//
// Rozszerzenie wzgledem stagingu na target (win7staging.go) jest takie,
// ze te same katalogi wchodza teraz rowniez do WIM-ow na samym nosniku:
//
//	boot.wim    (WinPE, indeksy 1 i 2) : tylko /Add-Driver
//	                                     -> WinPE widzi klawiature, mysz i dysk
//	install.wim (obrazy docelowe)      : /Add-Package (SHA-2, potem NVMe),
//	                                     dopiero potem /Add-Driver
//
// Kolejnosc jest sztywna i taka sama jak w DismOfflineSHA2QueueCommands:
// SHA-2 Add-Package PRZED Add-Driver. Hotfixy NVMe (KB2990941, KB3087873)
// nie daja sie zainstalowac offline na wspolczesnym sprzecie bez SHA-2
// (KB4474419), dlatego KB4474419 jest zawsze pierwszy w kolejce.
//
// /ForceUnsigned jest uzywany zgodnie z konwencja repo (README_PL.txt
// biblioteki driverow i DismOfflineDriverCommands); ten plik jej nie
// zmienia i nie wprowadza jej nigdzie od siebie.
//
// Plik jest przenosny (kompiluje sie na kazdym GOOS): buduje komendy
// i wykonuje je przez wstrzykiwany CommandRunner. Testy nie uruchamiaja
// prawdziwego DISM.

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
)

// Nazwy podkatalogow biblioteki sterownikow (MEDIA_LAYOUT.md).
const (
	Win7DriverSetUSBAMD     = "USB_AMD"
	Win7DriverSetUSBIntel   = "USB_Intel"
	Win7DriverSetUSBGeneric = "USB_Generic"
	Win7DriverSetNVMe       = "NVMe"
)

// Win7DriverSetNames zwraca podkatalogi biblioteki w stalej kolejnosci.
// Pusty podkatalog to no-op (tak jak opisuje README_PL.txt biblioteki).
func Win7DriverSetNames() []string {
	return []string{Win7DriverSetUSBAMD, Win7DriverSetUSBIntel, Win7DriverSetUSBGeneric, Win7DriverSetNVMe}
}

// Win7DriverLibraryRelDir to wzgledna sciezka biblioteki sterownikow na
// DATA. Jedyna definicja tego ukladu w repo; winhost.Win7ModernDriverRelDir
// deleguje tutaj.
func Win7DriverLibraryRelDir() string {
	return filepath.Join("Systems", "Windows", "Windows 7", "Drivers", "x64")
}

// Win7UpdatesRelDir to wzgledna sciezka kolejki MSU na DATA.
func Win7UpdatesRelDir() string {
	return filepath.Join("Systems", "Windows", "Windows 7", "Updates")
}

// Win7Hotfix opisuje jeden pakiet MSU wymagany offline w install.wim.
type Win7Hotfix struct {
	// KB to identyfikator uzywany do dopasowania nazwy pliku (bez wersji).
	KB string
	// Purpose to powod, dla ktorego pakiet jest wymagany (do bledow i logu).
	Purpose string
}

// Win7RequiredHotfixes zwraca kolejke MSU w SZTYWNEJ kolejnosci:
// najpierw SHA-2 (bez niego wspolczesnie podpisane pakiety i sterowniki
// sa odrzucane), potem dwa hotfixy NVMe.
func Win7RequiredHotfixes() []Win7Hotfix {
	return []Win7Hotfix{
		{KB: "KB4474419", Purpose: "obsluga podpisow SHA-2 (warunek wstepny pozostalych pakietow)"},
		{KB: "KB2990941", Purpose: "obsluga NVMe w Windows 7 SP1 x64"},
		{KB: "KB3087873", Purpose: "poprawka do obslugi NVMe (nastepca KB2990941)"},
	}
}

// MissingArtifact nazywa jeden brakujacy artefakt i miejsce, w ktorym
// injektor go szukal.
type MissingArtifact struct {
	// What to nazwa artefaktu, np. "KB2990941" albo "sterowniki USB3/NVMe".
	What string
	// ExpectedPath to katalog (albo wzorzec), w ktorym artefakt ma lezec.
	ExpectedPath string
	// Hint to konkretna instrukcja dla operatora.
	Hint string
}

// MissingArtifactsError to typowany blad braku binariow sterownikow albo
// pakietow MSU. Repo nie dostarcza tych plikow i injektor ich nie pobiera;
// blad jest zawsze opisowy i nazywa kazdy brak z osobna.
type MissingArtifactsError struct {
	// MediaRoot to root biblioteki (zwykle DATA nosnika USOS).
	MediaRoot string
	// Missing to lista brakow w kolejnosci wykrycia.
	Missing []MissingArtifact
}

func (e *MissingArtifactsError) Error() string {
	var b strings.Builder
	fmt.Fprintf(&b, "brak artefaktow wymaganych do injekcji Windows 7 (root=%s):", e.MediaRoot)
	for _, m := range e.Missing {
		fmt.Fprintf(&b, "\n  - %s: oczekiwano w %s (%s)", m.What, m.ExpectedPath, m.Hint)
	}
	return b.String()
}

// Is pozwala rozpoznac ten blad przez errors.Is(err, ErrMissingArtifacts).
func (e *MissingArtifactsError) Is(target error) bool { return target == ErrMissingArtifacts }

// ErrMissingArtifacts to wartownik dla MissingArtifactsError.
var ErrMissingArtifacts = errors.New("brak artefaktow sterownikow/hotfixow Windows 7")

// Win7InjectionSources to znalezione na dysku zrodla injekcji.
type Win7InjectionSources struct {
	// MediaRoot to root biblioteki, z ktorego czytano.
	MediaRoot string
	// DriverDirs to niepuste podkatalogi biblioteki (zawieraja *.inf),
	// w kolejnosci Win7DriverSetNames.
	DriverDirs []string
	// HotfixPaths to sciezki MSU w kolejnosci Win7RequiredHotfixes.
	HotfixPaths []string
	// SkippedDriverSets to podkatalogi puste albo nieobecne (no-op).
	SkippedDriverSets []string
}

// DiscoverWin7InjectionSources przeszukuje biblioteke pod mediaRoot
// (katalog zawierajacy Systems/...). Zwraca *MissingArtifactsError, gdy
// nie ma ANI jednego katalogu sterownikow z plikiem *.inf albo brakuje
// ktoregokolwiek z wymaganych MSU. Niczego nie pobiera i nie tworzy.
func DiscoverWin7InjectionSources(mediaRoot string) (Win7InjectionSources, error) {
	sources := Win7InjectionSources{MediaRoot: mediaRoot}
	missing := &MissingArtifactsError{MediaRoot: mediaRoot}

	driverRoot := filepath.Join(mediaRoot, Win7DriverLibraryRelDir())
	for _, name := range Win7DriverSetNames() {
		dir := filepath.Join(driverRoot, name)
		has, err := dirHasINF(dir)
		if err != nil {
			return sources, err
		}
		if has {
			sources.DriverDirs = append(sources.DriverDirs, dir)
			continue
		}
		sources.SkippedDriverSets = append(sources.SkippedDriverSets, name)
	}
	if len(sources.DriverDirs) == 0 {
		missing.Missing = append(missing.Missing, MissingArtifact{
			What:         "sterowniki USB 3.0 (XHCI/UASP) i NVMe",
			ExpectedPath: filepath.Join(driverRoot, "{"+strings.Join(Win7DriverSetNames(), ",")+"}") + string(filepath.Separator) + "*.inf",
			Hint:         "rozpakuj komplety INF+SYS+CAT do odpowiednich podkatalogow; repo nie dostarcza binariow sterownikow",
		})
	}

	updatesDir := filepath.Join(mediaRoot, Win7UpdatesRelDir())
	entries, err := readDirNames(updatesDir)
	if err != nil {
		return sources, err
	}
	for _, hotfix := range Win7RequiredHotfixes() {
		path, ok := findMSU(updatesDir, entries, hotfix.KB)
		if !ok {
			missing.Missing = append(missing.Missing, MissingArtifact{
				What:         hotfix.KB,
				ExpectedPath: filepath.Join(updatesDir, "*"+strings.ToLower(hotfix.KB)+"*.msu"),
				Hint:         hotfix.Purpose + "; pobierz MSU z Microsoft Update Catalog i wloz do tego katalogu",
			})
			continue
		}
		sources.HotfixPaths = append(sources.HotfixPaths, path)
	}

	if len(missing.Missing) > 0 {
		return sources, missing
	}
	return sources, nil
}

// dirHasINF mowi, czy katalog zawiera przynajmniej jeden plik *.inf
// (rekurencyjnie; DISM i tak dostaje /Recurse). Brak katalogu to nie blad,
// tylko no-op zgodnie z README_PL.txt biblioteki.
func dirHasINF(dir string) (bool, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("odczyt katalogu sterownikow %s: %w", dir, err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			nested, err := dirHasINF(filepath.Join(dir, entry.Name()))
			if err != nil {
				return false, err
			}
			if nested {
				return true, nil
			}
			continue
		}
		if strings.EqualFold(filepath.Ext(entry.Name()), ".inf") {
			return true, nil
		}
	}
	return false, nil
}

// readDirNames zwraca posortowane nazwy plikow katalogu; brak katalogu to
// pusta lista (braki MSU raportuje wywolujacy jako MissingArtifact).
func readDirNames(dir string) ([]string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("odczyt katalogu aktualizacji %s: %w", dir, err)
	}
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		names = append(names, entry.Name())
	}
	sort.Strings(names)
	return names, nil
}

// findMSU dopasowuje plik *.msu po identyfikatorze KB (bez rozrozniania
// wielkosci liter, dowolna wersja w nazwie: windows6.1-kb4474419-v3-x64_*.msu).
func findMSU(dir string, names []string, kb string) (string, bool) {
	needle := strings.ToLower(strings.TrimSpace(kb))
	for _, name := range names {
		lower := strings.ToLower(name)
		if strings.HasSuffix(lower, ".msu") && strings.Contains(lower, needle) {
			return filepath.Join(dir, name), true
		}
	}
	return "", false
}

// Win7InjectionRequest opisuje, co i gdzie wstrzyknac.
type Win7InjectionRequest struct {
	// BootWIM to sciezka sources/boot.wim nosnika.
	BootWIM string
	// InstallWIM to sciezka sources/install.wim nosnika.
	InstallWIM string
	// BootImageIndexes to indeksy WinPE; puste = {1, 2}
	// (1 = Windows PE, 2 = Windows Setup).
	BootImageIndexes []int
	// InstallImageIndexes to indeksy obrazow docelowych; puste = {1}.
	InstallImageIndexes []int
	// MountDir to katalog roboczy montowania WIM.
	MountDir string
	// Sources to wynik DiscoverWin7InjectionSources.
	Sources Win7InjectionSources
}

func (r Win7InjectionRequest) bootIndexes() []int {
	if len(r.BootImageIndexes) > 0 {
		return r.BootImageIndexes
	}
	return []int{1, 2}
}

func (r Win7InjectionRequest) installIndexes() []int {
	if len(r.InstallImageIndexes) > 0 {
		return r.InstallImageIndexes
	}
	return []int{1}
}

func (r Win7InjectionRequest) mountDir() string {
	if strings.TrimSpace(r.MountDir) != "" {
		return r.MountDir
	}
	return `C:\mnt\usos-win7-wim`
}

// Win7InjectionStep to jeden krok planu: komenda plus opis do logu
// i informacja, czy po bledzie trzeba odmontowac obraz z /Discard.
type Win7InjectionStep struct {
	// Command to argv (bez powloki).
	Command []string
	// Description to jednolinijkowy opis do logu/UI.
	Description string
	// MountedDir jest niepuste, gdy w momencie tego kroku obraz jest
	// zamontowany pod tym katalogiem (podstawa rollbacku /Discard).
	MountedDir string
}

// Win7InjectionPlan to pelna, deterministyczna sekwencja krokow.
type Win7InjectionPlan struct {
	Steps []Win7InjectionStep
}

// Commands zwraca same komendy (wygodne w testach i logach).
func (p Win7InjectionPlan) Commands() [][]string {
	out := make([][]string, 0, len(p.Steps))
	for _, step := range p.Steps {
		out = append(out, step.Command)
	}
	return out
}

// PlanWin7Injection buduje plan injekcji. Zwraca blad, gdy brakuje sciezek
// WIM albo gdy zrodla sa puste (wtedy wczesniej powinien paść
// *MissingArtifactsError z DiscoverWin7InjectionSources).
func PlanWin7Injection(req Win7InjectionRequest) (Win7InjectionPlan, error) {
	var plan Win7InjectionPlan
	if strings.TrimSpace(req.BootWIM) == "" {
		return plan, fmt.Errorf("injekcja win7: pusta sciezka sources/boot.wim")
	}
	if strings.TrimSpace(req.InstallWIM) == "" {
		return plan, fmt.Errorf("injekcja win7: pusta sciezka sources/install.wim")
	}
	if len(req.Sources.DriverDirs) == 0 {
		return plan, fmt.Errorf("injekcja win7: pusta lista katalogow sterownikow (uruchom DiscoverWin7InjectionSources)")
	}
	if len(req.Sources.HotfixPaths) != len(Win7RequiredHotfixes()) {
		return plan, fmt.Errorf("injekcja win7: kolejka MSU ma %d z %d wymaganych pakietow",
			len(req.Sources.HotfixPaths), len(Win7RequiredHotfixes()))
	}

	mount := req.mountDir()

	// boot.wim: WinPE potrzebuje tylko sterownikow (klawiatura, mysz, dysk).
	// Pakiety MSU nie wchodza do WinPE - nie ma tam stosu serwisowania Win7.
	for _, index := range req.bootIndexes() {
		plan.Steps = append(plan.Steps, mountStep(req.BootWIM, index, mount))
		plan.Steps = append(plan.Steps, driverSteps(mount, req.Sources.DriverDirs, fmt.Sprintf("boot.wim:%d", index))...)
		plan.Steps = append(plan.Steps, commitStep(mount, fmt.Sprintf("boot.wim:%d", index)))
	}

	// install.wim: najpierw kolejka MSU (SHA-2, potem NVMe), potem sterowniki.
	hotfixes := Win7RequiredHotfixes()
	for _, index := range req.installIndexes() {
		label := fmt.Sprintf("install.wim:%d", index)
		plan.Steps = append(plan.Steps, mountStep(req.InstallWIM, index, mount))
		for i, path := range req.Sources.HotfixPaths {
			plan.Steps = append(plan.Steps, Win7InjectionStep{
				Command:     []string{"dism", "/Image:" + mount, "/Add-Package", "/PackagePath:" + path},
				Description: fmt.Sprintf("%s: Add-Package %s (%s)", label, hotfixes[i].KB, hotfixes[i].Purpose),
				MountedDir:  mount,
			})
		}
		plan.Steps = append(plan.Steps, driverSteps(mount, req.Sources.DriverDirs, label)...)
		plan.Steps = append(plan.Steps, commitStep(mount, label))
	}
	return plan, nil
}

func mountStep(wim string, index int, mount string) Win7InjectionStep {
	return Win7InjectionStep{
		Command: []string{"dism", "/Mount-Wim", "/WimFile:" + wim,
			"/index:" + strconv.Itoa(index), "/MountDir:" + mount},
		Description: fmt.Sprintf("Mount-Wim %s index %d", filepath.Base(wim), index),
	}
}

func driverSteps(mount string, dirs []string, label string) []Win7InjectionStep {
	steps := make([]Win7InjectionStep, 0, len(dirs))
	for _, dir := range dirs {
		steps = append(steps, Win7InjectionStep{
			Command: []string{"dism", "/Image:" + mount, "/Add-Driver",
				"/Driver:" + dir, "/Recurse", "/ForceUnsigned"},
			Description: fmt.Sprintf("%s: Add-Driver %s", label, filepath.Base(dir)),
			MountedDir:  mount,
		})
	}
	return steps
}

func commitStep(mount, label string) Win7InjectionStep {
	return Win7InjectionStep{
		Command:     []string{"dism", "/Unmount-Wim", "/MountDir:" + mount, "/Commit"},
		Description: label + ": Unmount-Wim /Commit",
		MountedDir:  mount,
	}
}

// Win7DiscardCommand zwraca komende awaryjnego odmontowania bez zapisu.
func Win7DiscardCommand(mountDir string) []string {
	return []string{"dism", "/Unmount-Wim", "/MountDir:" + mountDir, "/Discard"}
}

// CommandRunner wykonuje pojedyncza komende i zwraca jej wyjscie.
// Wstrzykiwany, zeby testy nie uruchamialy prawdziwego DISM.
type CommandRunner func(name string, args ...string) ([]byte, error)

// Win7Injector wykonuje plan injekcji.
type Win7Injector struct {
	// Run jest obowiazkowy; nil = blad (nigdy ciche exec).
	Run CommandRunner
	// Log jest opcjonalny.
	Log func(line string)
}

// Apply wykonuje kroki po kolei. Po bledzie w trakcie zamontowanego obrazu
// probuje /Discard, zeby nie zostawic zamontowanego WIM-a, i zwraca
// oryginalny blad (blad rollbacku jest do niego dolaczany).
func (i Win7Injector) Apply(plan Win7InjectionPlan) error {
	if i.Run == nil {
		return fmt.Errorf("injekcja win7: brak CommandRunner")
	}
	for _, step := range plan.Steps {
		i.log("START " + step.Description)
		out, err := i.Run(step.Command[0], step.Command[1:]...)
		if err == nil {
			i.log("PASS " + step.Description)
			continue
		}
		wrapped := fmt.Errorf("injekcja win7: %s: %v: %w: %s",
			step.Description, step.Command, err, strings.TrimSpace(string(out)))
		if step.MountedDir != "" {
			discard := Win7DiscardCommand(step.MountedDir)
			if dOut, dErr := i.Run(discard[0], discard[1:]...); dErr != nil {
				return fmt.Errorf("%w (dodatkowo rollback %v: %v: %s)", wrapped, discard, dErr, strings.TrimSpace(string(dOut)))
			}
			i.log("ROLLBACK Unmount-Wim /Discard " + step.MountedDir)
		}
		return wrapped
	}
	return nil
}

func (i Win7Injector) log(line string) {
	if i.Log != nil {
		i.Log(line)
	}
}
