//go:build windows

// usos-installer-uidemo runs the real installer UI (internal/ui) against fake
// drive sources and scripted fake engines, and optionally walks every screen
// taking screenshots. It never opens a disk: it does not import winhost, and
// the fake engines only emit events. Used to verify the UI visually.
//
//	usos-installer-uidemo                         interactive, fake data
//	usos-installer-uidemo -shots DIR -dpi 144     screenshot tour at 150 %
package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/ui"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
	"github.com/snakex21/universal-service-os/installer/internal/volumelock"
)

func main() {
	shots := flag.String("shots", "", "take the screenshot tour into this directory and exit")
	dpi := flag.Uint("dpi", 0, "lay out at this DPI (96 = 100 %, 144 = 150 %)")
	lang := flag.String("lang", "pl", "UI language")
	suffix := flag.String("suffix", "", "screenshot file name suffix")
	width := flag.Int("w", 0, "client width in DIPs")
	height := flag.Int("h", 0, "client height in DIPs")
	startupError := flag.Bool("startup-error", false, "show the startup error screen")
	measure := flag.String("measure", "", "write first-frame timing and memory to this file and exit")
	langShots := flag.String("langshots", "", "comma-separated languages: shoot the home screen, the device list and the language menu in each, then exit")
	overflow := flag.String("overflow", "", "append every ellipsized or clipped string to this file")
	padTour := flag.Bool("pad", false, "with -shots: take the gamepad tour (hint bar, focus moves, Start guard) instead")
	flag.Parse()
	i18n.SetLanguage(*lang)

	started := time.Now()
	engines := newFakeEngines()
	cfg := ui.Config{
		Disks:       fakeDisks{},
		Installed:   fakeInstalled{},
		Install:     engines.install,
		Update:      engines.update,
		Repair:      engines.repair,
		Uninstall:   engines.uninstall,
		VolumeInUse: engines.volumeInUse,
		MokFirmware: &fakeMokFirmware{vars: map[string][]byte{}},
		ForceDPI:    uint32(*dpi),
		ClientW:     int32(*width),
		ClientH:     int32(*height),
	}
	if *startupError {
		cfg.StartupError = i18n.T("installer.startup.log_failed", `open operation log C:\USOS\USOS Installer.log: Access is denied.`)
	}
	if *measure != "" {
		cfg.Script = func(d *ui.Driver) {
			d.Idle()
			ws, private := d.Memory()
			_ = os.WriteFile(*measure, []byte(fmt.Sprintf("first_frame_ms=%d\nworking_set_kb=%d\nprivate_kb=%d\n", time.Since(started).Milliseconds(), ws, private)), 0o644)
			d.Close()
		}
	} else if *shots != "" {
		cfg.Script = func(d *ui.Driver) {
			if *overflow != "" {
				logOverflow(d, *overflow, *lang, *dpi)
			}
			var err error
			if *langShots != "" {
				err = languageTour(d, *shots, strings.Split(*langShots, ","), *suffix)
			} else if *padTour {
				err = gamepadTour(d, *shots, *suffix)
			} else {
				err = tour(d, engines, *shots, *suffix, *startupError, *lang)
			}
			if err != nil {
				fmt.Fprintln(os.Stderr, "TOUR FAILED:", err)
				_ = os.WriteFile(filepath.Join(*shots, "tour-error"+*suffix+".txt"), []byte(err.Error()), 0o644)
			}
			d.Close()
		}
	}
	if err := ui.Run(cfg); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// logOverflow records strings the UI had to ellipsize or clip, one line each
// (language, DPI, screen, need/have in px, text), for the layout check.
func logOverflow(d *ui.Driver, path, lang string, dpi uint) {
	seen := map[string]bool{}
	d.OnTextOverflow(func(screen, text string, need, have int32, wrapped bool) {
		kind := "width"
		if wrapped {
			kind = "height"
		}
		line := fmt.Sprintf("%s\t%d\t%s\t%s %d>%d\t%q\n", lang, dpi, screen, kind, need, have, text)
		if seen[line] {
			return
		}
		seen[line] = true
		if f, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
			_, _ = f.WriteString(line)
			_ = f.Close()
		}
	})
}

// languageTour shoots, per language, the home screen, the install device
// list with the USB stick selected, and (first language only) the language
// menu after type-to-jump.
func languageTour(d *ui.Driver, dir string, langs []string, suffix string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	d.Loaded()
	for i, lang := range langs {
		lang = strings.TrimSpace(lang)
		d.SetLanguage(lang)
		name := func(what string) string { return filepath.Join(dir, fmt.Sprintf("%s-%s%s.png", lang, what, suffix)) }
		d.Focus("mode.install")
		if err := d.Shot(name("home")); err != nil {
			return err
		}
		if i == 0 {
			if err := d.Activate("header.lang"); err != nil {
				return err
			}
			d.Type("f") // type-to-jump: first language starting with F
			if err := d.Shot(name("language-menu")); err != nil {
				return err
			}
			d.Key(0x1B)
		}
		if err := d.Activate("mode.install"); err != nil {
			return err
		}
		d.Loaded()
		if err := d.Activate("list.row.1"); err != nil {
			return err
		}
		d.Focus("list")
		if err := d.Shot(name("devices")); err != nil {
			return err
		}
		if err := d.Activate("action.back"); err != nil {
			return err
		}
		d.Loaded()
	}
	return nil
}

func tour(d *ui.Driver, e *fakeEngines, dir, suffix string, startupError bool, lang string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	n := 0
	shot := func(name string) error {
		n++
		return d.Shot(filepath.Join(dir, fmt.Sprintf("%02d-%s%s.png", n, name, suffix)))
	}
	step := func(errs ...error) error { return errors.Join(errs...) }
	if startupError {
		time.Sleep(200 * time.Millisecond)
		return shot("startup-error")
	}
	d.Loaded() // fake detection finishes
	outer, client := d.Size()
	_ = os.WriteFile(filepath.Join(dir, "window-size"+suffix+".txt"), []byte(fmt.Sprintf("outer=%dx%d client=%dx%d\n", outer[0], outer[1], client[0], client[1])), 0o644)
	// Mode screen, keyboard focus on the first card, hover on uninstall.
	d.Focus("mode.install")
	d.Hover("mode.uninstall")
	if err := shot("mode"); err != nil {
		return err
	}
	// Keyboard: Tab moves focus through the real message path, arrows move
	// through the card grid.
	d.Key(0x09) // Tab: install -> update
	d.Key(0x28) // Down: update -> uninstall
	if err := shot("mode-keyboard"); err != nil {
		return err
	}
	if err := step(d.Activate("header.lang")); err != nil {
		return err
	}
	d.Hover("lang.en")
	if err := shot("language-menu"); err != nil {
		return err
	}
	d.Key(0x1B) // Esc closes the menu
	d.SetLanguage("en")
	if err := shot("mode-english"); err != nil {
		return err
	}
	d.SetLanguage(lang)

	// Install: device list, select the eligible stick, then a rejected one.
	if err := d.Activate("mode.install"); err != nil {
		return err
	}
	d.Loaded()
	if err := shot("install-devices-empty-selection"); err != nil {
		return err
	}
	if err := d.Activate("list.row.2"); err != nil {
		return err
	}
	if err := shot("install-devices-rejected"); err != nil {
		return err
	}
	if err := d.Activate("list.row.1"); err != nil {
		return err
	}
	d.Focus("list")
	if err := shot("install-devices-selected"); err != nil {
		return err
	}
	if err := d.Activate("action.next"); err != nil {
		return err
	}
	d.Focus("confirm.input")
	d.Type("Kingston Data")
	if d.Enabled("confirm.go") {
		return fmt.Errorf("confirm button enabled for a partial model")
	}
	if err := shot("install-confirm-partial"); err != nil {
		return err
	}
	d.Type("Traveler 3.0")
	if !d.Enabled("confirm.go") {
		return fmt.Errorf("confirm button still disabled after the exact model")
	}
	if err := shot("install-confirm-ready"); err != nil {
		return err
	}
	if err := d.Activate("confirm.go"); err != nil {
		return err
	}
	<-e.installReached // copy stage at ~46 %
	d.Idle()
	if err := shot("install-progress"); err != nil {
		return err
	}
	d.Close() // must be refused while busy
	d.Idle()
	if !d.Busy() {
		return fmt.Errorf("window accepted close during an operation")
	}
	if err := step(d.Activate("log.toggle")); err != nil {
		return err
	}
	if err := shot("install-progress-log"); err != nil {
		return err
	}
	close(e.installHold)
	waitIdle(d)
	if err := shot("install-final-success"); err != nil {
		return err
	}
	// Secure Boot key enrollment (fake firmware: nothing reaches NVRAM).
	if err := d.Activate("final.mok"); err != nil {
		return err
	}
	if err := shot("install-mok"); err != nil {
		return err
	}
	d.Focus("mok.password")
	d.Type(" x")
	if d.Enabled("action.primary") {
		return fmt.Errorf("MOK prepare enabled for a password with a space")
	}
	if err := shot("install-mok-invalid"); err != nil {
		return err
	}
	d.Type("\b\busos") // valid again whether focus selected the text or not
	if err := d.Activate("action.primary"); err != nil {
		return err
	}
	waitIdle(d)
	if err := shot("install-mok-done"); err != nil {
		return err
	}
	if err := d.Activate("action.back"); err != nil {
		return err
	}

	// Update with a downgrade prompt, ending in a verification failure.
	if err := d.Activate("action.primary"); err != nil {
		return err
	}
	if err := d.Activate("mode.update"); err != nil {
		return err
	}
	d.Loaded()
	if err := d.Activate("list.row.1"); err != nil {
		return err
	}
	if err := shot("update-devices"); err != nil {
		return err
	}
	if err := d.Activate("action.next"); err != nil {
		return err
	}
	if d.Enabled("action.primary") {
		return fmt.Errorf("downgrade allowed without the confirmation tick")
	}
	if err := d.Activate("update.downgrade"); err != nil {
		return err
	}
	if err := shot("update-confirm-downgrade"); err != nil {
		return err
	}
	if err := d.Activate("action.primary"); err != nil {
		return err
	}
	for deadline := time.Now().Add(10 * time.Second); !d.Enabled("busy.retry"); time.Sleep(20 * time.Millisecond) {
		if time.Now().After(deadline) {
			return fmt.Errorf("volume-in-use prompt did not appear")
		}
	}
	d.Idle()
	if err := shot("update-volume-busy"); err != nil {
		return err
	}
	if err := d.Activate("busy.retry"); err != nil {
		return err
	}
	waitIdle(d)
	if err := shot("update-final-failed"); err != nil {
		return err
	}

	// Repair confirmation.
	if err := d.Activate("action.primary"); err != nil {
		return err
	}
	if err := d.Activate("mode.repair"); err != nil {
		return err
	}
	d.Loaded()
	if err := d.Activate("list.row.0"); err != nil {
		return err
	}
	if err := d.Activate("action.next"); err != nil {
		return err
	}
	if err := shot("repair-confirm"); err != nil {
		return err
	}
	if err := d.Activate("action.back"); err != nil {
		return err
	}
	if err := d.Activate("action.back"); err != nil {
		return err
	}

	// Uninstall confirmation and a failing uninstall progress screen.
	if err := d.Activate("mode.uninstall"); err != nil {
		return err
	}
	d.Loaded()
	if err := d.Activate("list.row.0"); err != nil {
		return err
	}
	if err := shot("uninstall-devices"); err != nil {
		return err
	}
	if err := d.Activate("action.next"); err != nil {
		return err
	}
	d.Focus("confirm.input")
	d.Type("Kingston DataTraveler Max")
	if err := shot("uninstall-confirm"); err != nil {
		return err
	}
	if err := d.Activate("confirm.go"); err != nil {
		return err
	}
	<-e.uninstallReached
	d.Idle()
	if err := shot("uninstall-progress"); err != nil {
		return err
	}
	close(e.uninstallHold)
	waitIdle(d)
	return shot("uninstall-final-error")
}

// gamepadTour drives the UI with controller input only and checks that
// Start never commits an operation.
func gamepadTour(d *ui.Driver, dir, suffix string) error {
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	n := 0
	shot := func(name string) error {
		n++
		return d.Shot(filepath.Join(dir, fmt.Sprintf("pad-%02d-%s%s.png", n, name, suffix)))
	}
	press := func(buttons ...string) error {
		for _, b := range buttons {
			if err := d.Pad(b); err != nil {
				return err
			}
		}
		return nil
	}
	expect := func(id string) error {
		if got := d.Focused(); got != id {
			return fmt.Errorf("focus %q, want %q", got, id)
		}
		return nil
	}
	d.Loaded()
	// Home: install -> right (update) -> down (uninstall).
	if err := errors.Join(press("right", "down"), expect("mode.uninstall")); err != nil {
		return err
	}
	if err := shot("mode"); err != nil {
		return err
	}
	if err := errors.Join(press("left", "up"), expect("mode.install"), press("a")); err != nil {
		return err
	}
	d.Loaded()
	// Device list: rows first, then down past the last row to Back.
	if err := errors.Join(expect("list"), press("down", "down")); err != nil {
		return err
	}
	if err := shot("devices"); err != nil {
		return err
	}
	if err := errors.Join(press("rb"), expect("action.back"), press("lb"), expect("list")); err != nil {
		return err
	}
	// Start on the device list continues to the typed confirmation...
	if err := press("start"); err != nil {
		return err
	}
	if !d.Enabled("confirm.go") && d.Enabled("action.back") {
		// ...where Start only moves to the (still disabled) erase button:
		// nothing is focused or pressed while it is disabled.
		if err := errors.Join(press("start"), expect("confirm.input")); err != nil {
			return err
		}
	} else {
		return fmt.Errorf("Start did not reach the confirmation screen")
	}
	d.Type("Kingston DataTraveler 3.0")
	if err := errors.Join(press("start"), expect("confirm.go")); err != nil {
		return err
	}
	if d.Busy() {
		return fmt.Errorf("Start started the installation")
	}
	if err := shot("confirm-start-focuses"); err != nil {
		return err
	}
	// B backs out to the device list.
	if err := errors.Join(press("b"), expect("list")); err != nil {
		return err
	}
	return shot("back-to-devices")
}

func waitIdle(d *ui.Driver) {
	for i := 0; i < 200 && d.Busy(); i++ {
		time.Sleep(25 * time.Millisecond)
	}
	d.Idle()
}

// ---- fake drives ----------------------------------------------------------

const gib = uint64(1) << 30

func stick(number uint32, model, serial string, size uint64, bus uint32, removable bool, volumes ...domain.Volume) domain.Disk {
	return domain.Disk{Number: number, Model: model, Serial: serial, SizeBytes: size, SectorBytes: 512, Removable: removable, BusType: bus, Volumes: volumes}
}

func allDisks() []domain.Disk {
	disks := []domain.Disk{
		stick(1, "Kingston DataTraveler 3.0", "E0D55EA574D9F3A0", 61991813632, domain.BusUSB, true,
			domain.Volume{GUIDPath: `\\?\Volume{1}`, MountPaths: []string{"E:\\"}, Label: "KINGSTON", FileSystem: "exFAT", UsedBytes: 12 * gib, TotalBytes: 57 * gib, RootEntries: []string{"Obrazy", "Programy", "notatki.txt", "System Volume Information"}}),
		stick(2, "Kingston DataTraveler Max", "0019E06B9C7BF3B1", 128*1000*1000*1000, domain.BusUSB, true),
		stick(3, "SanDisk Ultra Fit", "4C530001230711111402", 16*1000*1000*1000, domain.BusUSB, true,
			domain.Volume{GUIDPath: `\\?\Volume{3}`, MountPaths: []string{"F:\\"}, Label: "SANDISK", FileSystem: "FAT32", UsedBytes: 2 * gib, TotalBytes: 14 * gib, RootEntries: []string{"DCIM"}}),
		stick(0, "Samsung SSD 970 EVO Plus 1TB", "S4EWNX0R123456", 1000*1000*1000*1000, domain.BusNVMe, false,
			domain.Volume{GUIDPath: `\\?\Volume{0}`, MountPaths: []string{"C:\\"}, Label: "Windows", FileSystem: "NTFS", UsedBytes: 412 * gib, TotalBytes: 930 * gib, RootEntries: []string{"Program Files", "Users", "Windows"}}),
		stick(4, "WD Elements 25A2", "575833314142", 2000*1000*1000*1000, domain.BusUSB, false,
			domain.Volume{GUIDPath: `\\?\Volume{4}`, MountPaths: []string{"G:\\"}, Label: "Backup", FileSystem: "NTFS", UsedBytes: 1200 * gib, TotalBytes: 1862 * gib, RootEntries: []string{"Kopie", "Zdjęcia"}}),
		stick(5, "SanDisk Extreme Pro", "AA010203040506070809", 256*1000*1000*1000, domain.BusUSB, true),
	}
	disks[3].SystemDisk = true
	sort.Slice(disks, func(i, j int) bool { return disks[i].Number < disks[j].Number })
	for i := range disks {
		disks[i] = domain.ApplyEligibility(disks[i])
	}
	return disks
}

type fakeDisks struct{}

func (fakeDisks) ListDisks() ([]domain.Disk, error) {
	time.Sleep(150 * time.Millisecond)
	return allDisks(), nil
}

type fakeInstalled struct{}

func (fakeInstalled) ListInstalledUSOS() ([]installed.Target, error) {
	time.Sleep(120 * time.Millisecond)
	disks := allDisks()
	current, err := localupdate.PayloadBuildInfo()
	if err != nil {
		current = buildinfo.Info{ID: "260922-2302", Epoch: 1790000000}
	}
	sha := strings.Repeat("ab", 32)
	newer := buildinfo.Info{ID: "261001-0915", Epoch: current.Epoch + 8*86400, SourceSHA256: sha}
	older := buildinfo.Info{ID: "260915-1740", Epoch: current.Epoch - 7*86400, SourceSHA256: sha}
	target := func(d domain.Disk, info buildinfo.Info) installed.Target {
		d.Volumes = []domain.Volume{
			{GUIDPath: `\\?\Volume{e}`, Label: "USOS_ESP", FileSystem: "FAT32", UsedBytes: 160 << 20, TotalBytes: 1 * gib, RootEntries: []string{"EFI"}},
			{GUIDPath: `\\?\Volume{d}`, MountPaths: []string{"H:\\"}, Label: "USOS_DATA", FileSystem: "NTFS", UsedBytes: 38 * gib, TotalBytes: 100 * gib, RootEntries: []string{"Programs", "Systems", "Utilities"}},
		}
		return installed.Target{Disk: d, BuildInfo: info}
	}
	byNumber := map[uint32]domain.Disk{}
	for _, d := range disks {
		byNumber[d.Number] = d
	}
	return []installed.Target{target(byNumber[2], older), target(byNumber[5], newer)}, nil
}

// ---- fake engines: scripted events only ----------------------------------

type fakeEngines struct {
	install          *fakeInstall
	update           *fakeUpdate
	repair           *fakeRepair
	uninstall        *fakeUninstall
	installHold      chan struct{}
	installReached   chan struct{}
	uninstallHold    chan struct{}
	uninstallReached chan struct{}
	volumeInUse      *volumelock.Relay
}

func newFakeEngines() *fakeEngines {
	e := &fakeEngines{installHold: make(chan struct{}), installReached: make(chan struct{}), uninstallHold: make(chan struct{}), uninstallReached: make(chan struct{})}
	e.install = &fakeInstall{e}
	e.volumeInUse = &volumelock.Relay{}
	e.update = &fakeUpdate{e}
	e.repair = &fakeRepair{}
	e.uninstall = &fakeUninstall{e}
	return e
}

func pause() { time.Sleep(40 * time.Millisecond) }

type fakeInstall struct{ e *fakeEngines }

func (f *fakeInstall) RunAsync(disk domain.Disk) <-chan install.Event {
	ch := make(chan install.Event, 16)
	go func() {
		defer close(ch)
		ch <- install.Event{Kind: install.EventLog, Message: fmt.Sprintf("DEMO target PhysicalDrive%d model=%q", disk.Number, disk.DisplayName())}
		for _, stage := range install.Stages() {
			ch <- install.Event{Kind: install.EventLog, Message: "START " + install.StageCaption(stage.ID)}
			ch <- install.Event{Kind: install.EventStage, StageID: stage.ID, State: install.StateActive, ProgressKnown: stage.Measurable}
			if stage.Measurable {
				for p := 0.0; p <= 0.46; p += 0.02 {
					ch <- install.Event{Kind: install.EventStage, StageID: stage.ID, State: install.StateActive, ProgressKnown: true, Progress: p}
					ch <- install.Event{Kind: install.EventLog, Message: fmt.Sprintf("COPY %.0f%% EFI/USOS/micro-linux/initramfs-usos", p*100)}
				}
				close(f.e.installReached)
				<-f.e.installHold
			}
			pause()
			ch <- install.Event{Kind: install.EventStage, StageID: stage.ID, State: install.StateSucceeded, ProgressKnown: stage.Measurable, Progress: 1}
			ch <- install.Event{Kind: install.EventLog, Message: "DONE " + install.StageCaption(stage.ID)}
		}
		report := install.VerificationReport{Items: []install.VerificationItem{
			{Name: "GPT", Expected: "ESP 1 GiB, DATA, WORK 16 GiB", Actual: "ESP 1 GiB, DATA, WORK 16 GiB", Match: true},
			{Name: "BOOTX64.EFI", Expected: "sha256 3f9a…c201", Actual: "sha256 3f9a…c201", Match: true},
			{Name: "usos-device.ini", Expected: "disk GUID 31c644bf-74dd-4807-9cb2-46745adeadd4", Actual: "disk GUID 31c644bf-74dd-4807-9cb2-46745adeadd4", Match: true},
			{Name: "Legacy BIOS", Expected: "Stage 1 i Core zgodne z payloadem instalatora", Actual: "Stage 1 i Core zgodne z payloadem instalatora", Match: true},
			{Name: "lang.bin", Expected: "pl, 23 108 B", Actual: "pl, 23 108 B", Match: true},
		}}
		ch <- install.Event{Kind: install.EventFinished, Verification: &report}
	}()
	return ch
}

type fakeUpdate struct{ e *fakeEngines }

func (f *fakeUpdate) RunAsync(t installed.Target) <-chan localupdate.Event { return f.run(t) }
func (f *fakeUpdate) RunAsyncConfirmedDowngrade(t installed.Target) <-chan localupdate.Event {
	return f.run(t)
}

func (f *fakeUpdate) run(installed.Target) <-chan localupdate.Event {
	ch := make(chan localupdate.Event, 16)
	go func() {
		defer close(ch)
		for id := localupdate.StageID(1); id <= localupdate.StageCount; id++ {
			ch <- localupdate.Event{Kind: localupdate.EventStage, StageID: id, State: localupdate.StateActive}
			pause()
			if id == 2 {
				// An Explorer window keeps the ESP open: the Retry/Cancel card.
				busy := &volumelock.InUseError{Volume: `\\?\Volume{0257e175-1685-4311-91aa-5a83d8eb41e5}\`, Mount: `J:\`, Holders: []string{"Eksplorator Windows"}, Attempts: 5, Err: volumelock.ErrBusy}
				if !f.e.volumeInUse.Ask(busy) {
					err := fmt.Errorf("lock target volumes: %w", busy)
					ch <- localupdate.Event{Kind: localupdate.EventStage, StageID: id, State: localupdate.StateFailed, Err: err}
					ch <- localupdate.Event{Kind: localupdate.EventFinished, Err: err}
					return
				}
			}
			if id == localupdate.StageVerify {
				report := install.VerificationReport{Items: []install.VerificationItem{
					{Name: "BOOTX64.EFI", Expected: "sha256 3f9a…c201", Actual: "sha256 3f9a…c201", Match: true},
					{Name: "EFI/USOS/lang.bin", Expected: "sha256 77b0…19ee", Actual: "sha256 0000…0000 (plik wyzerowany)", Match: false},
				}}
				err := errors.New("5/5 - Weryfikacja aktualizacji: verification report contains mismatches")
				ch <- localupdate.Event{Kind: localupdate.EventStage, StageID: id, State: localupdate.StateFailed, Err: err}
				ch <- localupdate.Event{Kind: localupdate.EventFinished, Verification: &report, Err: err}
				return
			}
			ch <- localupdate.Event{Kind: localupdate.EventStage, StageID: id, State: localupdate.StateSucceeded}
		}
	}()
	return ch
}

type fakeRepair struct{}

func (fakeRepair) RunAsync(installed.Target) <-chan repair.Event {
	ch := make(chan repair.Event, 4)
	go func() {
		defer close(ch)
		ch <- repair.Event{Kind: repair.EventFinished, Err: errors.New("demo: repair is not simulated")}
	}()
	return ch
}

type fakeUninstall struct{ e *fakeEngines }

func (f *fakeUninstall) RunAsync(installed.Target) <-chan uninstall.Event {
	ch := make(chan uninstall.Event, 16)
	go func() {
		defer close(ch)
		for id := uninstall.StageID(1); id <= uninstall.StageCount; id++ {
			ch <- uninstall.Event{Kind: uninstall.EventLog, Message: fmt.Sprintf("START stage %d", id)}
			ch <- uninstall.Event{Kind: uninstall.EventStage, StageID: id, State: uninstall.StateActive}
			if id == uninstall.StageFormatExFAT {
				close(f.e.uninstallReached)
				<-f.e.uninstallHold
				err := errors.New("4/5 - Formatowanie exFAT: Format-Volume: The device is not ready")
				ch <- uninstall.Event{Kind: uninstall.EventLog, Message: "FAIL " + err.Error()}
				ch <- uninstall.Event{Kind: uninstall.EventStage, StageID: id, State: uninstall.StateFailed, Err: err}
				ch <- uninstall.Event{Kind: uninstall.EventFinished, Err: err}
				return
			}
			pause()
			ch <- uninstall.Event{Kind: uninstall.EventStage, StageID: id, State: uninstall.StateSucceeded}
		}
	}()
	return ch
}
