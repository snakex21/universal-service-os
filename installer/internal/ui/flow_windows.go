//go:build windows

package ui

import (
	"strings"
	"time"
	"unicode"
	"unicode/utf8"
	"unsafe"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/mokenroll"
	"github.com/snakex21/universal-service-os/installer/internal/prefs"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
	"github.com/snakex21/universal-service-os/installer/internal/volumelock"
)

type DiskSource interface {
	ListDisks() ([]domain.Disk, error)
}

type InstalledUSOSSource interface {
	ListInstalledUSOS() ([]installed.Target, error)
}

// Operation runners; *install.Engine, *localupdate.Engine, *repair.Engine and
// *uninstall.Engine implement them. The UI never touches a disk itself.
type InstallRunner interface {
	RunAsync(domain.Disk) <-chan install.Event
}

type UpdateRunner interface {
	RunAsync(installed.Target) <-chan localupdate.Event
	RunAsyncConfirmedDowngrade(installed.Target) <-chan localupdate.Event
}

type RepairRunner interface {
	RunAsync(installed.Target) <-chan repair.Event
}

type UninstallRunner interface {
	RunAsync(installed.Target) <-chan uninstall.Event
}

// Config wires the installer window. StartupError, when set, shows only the
// startup error screen.
type Config struct {
	Disks     DiskSource
	Installed InstalledUSOSSource
	Install   InstallRunner
	Update    UpdateRunner
	Repair    RepairRunner
	Uninstall UninstallRunner

	// PrefsPath is where the language choice is saved; "" disables saving.
	PrefsPath    string
	StartupError string
	// VolumeInUse receives the Retry/Cancel prompt the progress screen shows
	// when a volume of the drive stays locked by another program.
	VolumeInUse *volumelock.Relay
	// MokFirmware is the UEFI variable store the "prepare key enrollment"
	// screen uses; nil means this computer's (mokenroll.System).
	MokFirmware mokenroll.Firmware

	// Test harness only (cmd/usos-installer-uidemo).
	ForceDPI         uint32
	ClientW, ClientH int32
	Script           func(*Driver)
}

type screen interface {
	draw(f *Flow, w *win, area rect)
	key(f *Flow, w *win, vk uintptr) bool
}

// refreshable screens get the header refresh control (and F5).
type refreshable interface {
	refresh()
	refreshing() bool
}

// localizable screens rebuild cached strings after a language change.
type localizable interface {
	relocalize()
}

type Flow struct {
	cfg        Config
	w          *win
	screen     screen
	busy       bool
	langOpen   bool
	langIndex  int
	langReveal bool // scroll the menu so langIndex is visible on the next frame
	langTyped  string
	langTypeAt time.Time
	toast      string
	toastUntil time.Time
	langAnchor rect
}

// Run creates the installer window and blocks until it is closed.
func Run(cfg Config) error {
	f := &Flow{cfg: cfg}
	w, err := newWin(i18n.T("installer.window.title"), f, windowOptions{forcedDPI: cfg.ForceDPI, clientW: cfg.ClientW, clientH: cfg.ClientH})
	if err != nil {
		return err
	}
	f.w = w
	if cfg.VolumeInUse != nil {
		cfg.VolumeInUse.Set(f.askVolumeInUse)
		defer cfg.VolumeInUse.Set(nil)
	}
	if cfg.StartupError != "" {
		f.show(&errorScreen{message: cfg.StartupError}, "startup.close")
	} else {
		f.showModes()
	}
	w.show()
	if cfg.Script != nil {
		w.scripted = true
		go cfg.Script(&Driver{f: f, w: w})
	}
	w.run()
	return nil
}

// show switches screens; focus names the widget that gets initial focus.
func (f *Flow) show(s screen, focus string) {
	f.w.resetScreen()
	f.langOpen = false
	f.toast = ""
	f.screen = s
	f.w.focus = focus
	f.w.invalidate()
}

func (f *Flow) canClose() bool { return !f.busy }

func (f *Flow) closeBlocked() {
	f.showToast(i18n.T("installer.close.blocked"))
	procMessageBeep.Call(0x30) // MB_ICONEXCLAMATION
}

func (f *Flow) languageChanged() {}

func (f *Flow) showToast(text string) {
	f.toast = text
	f.toastUntil = time.Now().Add(4 * time.Second)
	f.w.invalidate()
}

func (f *Flow) setLanguage(code string) {
	f.langOpen = false
	if code == i18n.Current() {
		return
	}
	i18n.SetLanguage(code)
	procSetWindowTextW.Call(uintptr(f.w.hwnd), uintptr(unsafe.Pointer(utf16Ptr(i18n.T("installer.window.title")))))
	if l, ok := f.screen.(localizable); ok {
		l.relocalize()
	}
	if f.cfg.PrefsPath != "" {
		if err := prefs.SaveLanguage(f.cfg.PrefsPath, i18n.Current()); err != nil {
			f.showToast(i18n.T("installer.language.save_failed", err.Error()))
		}
	}
	f.w.invalidate()
}

func (f *Flow) draw(w *win) {
	c := w.canvas
	client := rect{0, 0, c.width, c.height}
	c.fill(client, theme.Background)
	header, body := client.cutTop(w.px(56))
	var hints rect
	if w.pad.active {
		hints, body = body.cutBottom(w.px(padHintsH))
	}
	content := body.inset(w.px(pad), w.px(20))
	if w.pad.active {
		content.Bottom += w.px(8) // the hint bar has its own margin
	}
	if f.screen != nil {
		f.screen.draw(f, w, content)
	}
	f.drawHeader(w, header)
	if w.pad.active {
		f.drawPadHints(w, hints)
	}
	f.drawToast(w, client)
	if f.langOpen {
		f.drawLanguageMenu(w, client)
	}
}

func (f *Flow) drawHeader(w *win, r rect) {
	c := w.canvas
	c.fill(r, theme.Header)
	c.fill(rect{r.Left, r.Bottom - max(1, w.px(1)), r.Right, r.Bottom}, theme.Border)
	x := r.Left + w.px(20)
	logoSize := w.px(30)
	c.image(w.logoImage(logoSize), x, r.Top+(r.h()-logoSize)/2)
	x += logoSize + w.px(12)
	product := i18n.T("installer.header.product")
	pf := w.font(sizeLead, fwSemiBold)
	pw := c.textWidth(pf, product)
	c.text(pf, product, rect{x, r.Top, x + pw + 1, r.Bottom}, theme.Text, dtLeft|dtSingleLine|dtVCenter)
	x += pw + w.px(8)
	sub := i18n.T("installer.header.subtitle")
	c.text(w.font(sizeLead, fwNormal), sub, rect{x, r.Top, x + w.px(200), r.Bottom}, theme.Muted, dtLeft|dtSingleLine|dtVCenter)

	right := r.Right - w.px(16)
	btnH := w.px(34)
	top := r.Top + (r.h()-btnH)/2
	lang := buttonSpec{label: languageName(i18n.Current()), glyph: glyphChevronDown, style: buttonGhost, trailing: true, disabled: f.busy, onClick: f.toggleLanguageMenu}
	langW := w.buttonWidth(lang) + w.px(24)
	langRect := rect{right - langW, top, right, top + btnH}
	f.langAnchor = langRect
	f.drawLanguageButton(w, langRect, lang)
	right = langRect.Left - w.px(8)
	if rf, ok := f.screen.(refreshable); ok {
		spec := buttonSpec{label: i18n.T("installer.common.refresh"), glyph: glyphRefresh, style: buttonGhost, disabled: f.busy || rf.refreshing(), onClick: rf.refresh}
		width := w.buttonWidth(spec)
		w.button("header.refresh", rect{right - width, top, right, top + btnH}, spec)
	}
}

// drawLanguageButton is a ghost button with a globe, the native language
// name and a chevron; Down/Enter/Space open the menu.
func (f *Flow) drawLanguageButton(w *win, r rect, b buttonSpec) {
	st := w.add(widget{id: "header.lang", r: r, focusable: true, disabled: b.disabled, onClick: b.onClick, onKey: func(vk uintptr) bool {
		if vk == vkDown {
			f.openLanguageMenu()
			return true
		}
		return false
	}})
	bg := theme.Header
	if st.hot || f.langOpen {
		bg = theme.PanelAlt
	}
	fg := theme.Text
	if b.disabled {
		fg = theme.DisabledText
	}
	radius := w.px(radiusButton)
	w.canvas.roundRect(r, radius, bg)
	w.canvas.roundBorder(r, radius, max(1, w.px(1)), theme.Border)
	if st.ring {
		w.focusRing(r, radius)
	}
	x := r.Left + w.px(12)
	w.glyph(glyphGlobe, rect{x, r.Top, x + w.px(16), r.Bottom}, 15, theme.Accent)
	x += w.px(24)
	w.canvas.text(w.semiFont(), b.label, rect{x, r.Top, r.Right - w.px(28), r.Bottom}, fg, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	chevron := glyphChevronDown
	if f.langOpen {
		chevron = glyphChevronUp
	}
	w.glyph(chevron, rect{r.Right - w.px(28), r.Top, r.Right - w.px(10), r.Bottom}, 11, theme.Muted)
}

func (f *Flow) toggleLanguageMenu() {
	if f.langOpen {
		f.langOpen = false
		return
	}
	f.openLanguageMenu()
}

func (f *Flow) openLanguageMenu() {
	if f.busy {
		return
	}
	f.langOpen = true
	f.langIndex = 0
	f.langReveal = true
	f.langTyped = ""
	for i, language := range i18n.Languages() {
		if language.Code == i18n.Current() {
			f.langIndex = i
		}
	}
	// Keys (arrows, type-to-jump) must reach the menu, not a focused EDIT.
	if getFocus() != f.w.hwnd {
		setFocus(f.w.hwnd)
	}
	f.w.invalidate()
}

// selectLanguageIndex moves the menu highlight and keeps it in view.
func (f *Flow) selectLanguageIndex(i int) {
	f.langIndex = max(0, min(i, len(i18n.Languages())-1))
	f.langReveal = true
}

// char implements type-to-jump in the open language menu: typed letters
// (a prefix typed within a second, or one letter repeated to cycle) select
// the next language whose native name starts with them (diacritics folded).
func (f *Flow) char(w *win, r rune) bool {
	if !f.langOpen || r < ' ' {
		return false
	}
	w.cues = true
	now := time.Now()
	if now.Sub(f.langTypeAt) > time.Second {
		f.langTyped = ""
	}
	f.langTypeAt = now
	f.langTyped += string(unicode.ToLower(r))
	prefix, start := f.langTyped, f.langIndex
	// One letter (or the same letter repeated) cycles through the matches;
	// a longer prefix refines the current match.
	if first, _ := utf8.DecodeRuneInString(prefix); strings.Count(prefix, string(first)) == utf8.RuneCountInString(prefix) {
		prefix, start = string(first), f.langIndex+1
	}
	languages := i18n.Languages()
	for k := 0; k < len(languages); k++ {
		i := (start + k) % len(languages)
		if languageMatches(languages[i], prefix) {
			f.selectLanguageIndex(i)
			break
		}
	}
	return true
}

func languageMatches(language i18n.Language, prefix string) bool {
	// Only the native name is shown, so only it is matched.
	return strings.HasPrefix(i18n.FoldName(language.Name), i18n.FoldName(prefix))
}

func (f *Flow) drawLanguageMenu(w *win, client rect) {
	anchor := widget{r: f.langAnchor}
	languages := i18n.Languages()
	c := w.canvas
	width := max(w.px(300), anchor.r.w())
	itemH := w.px(36)
	hint := i18n.T("installer.language.hint")
	hintH := c.measure(w.captionFont(), hint, width-w.px(32))
	top := anchor.r.Bottom + w.px(6)
	// The list scrolls when all languages do not fit above the window's
	// bottom edge; the hint always stays visible below it.
	content := int32(len(languages)) * itemH
	chrome := w.px(8) + w.px(8) + w.px(14) + hintH + w.px(16)
	listH := max(min(content, client.Bottom-w.px(12)-top-chrome), 3*itemH)
	height := listH + chrome
	panel := rect{anchor.r.Right - width, top, anchor.r.Right, top + height}
	w.overlay = panel
	// Clicking anywhere outside the menu closes it.
	w.add(widget{id: "lang.scrim", r: client, onClick: func() { f.langOpen = false }})
	w.add(widget{id: "lang.panel", r: panel})
	shadow := rect{panel.Left - w.px(2), panel.Top, panel.Right + w.px(2), panel.Bottom + w.px(4)}
	c.roundRectAlpha(shadow, w.px(12), color{0, 0, 0}, 0.35)
	c.roundRect(panel, w.px(10), theme.Panel)
	c.roundBorder(panel, w.px(10), max(1, w.px(1)), theme.BorderStrong)
	view := rect{panel.Left + w.px(6), panel.Top + w.px(8), panel.Right - w.px(6), panel.Top + w.px(8) + listH}
	if f.langReveal {
		f.langReveal = false
		st := w.scrolls["lang.scroll"]
		if st == nil {
			st = &scrollState{}
			w.scrolls["lang.scroll"] = st
		}
		itemTop := int32(f.langIndex) * itemH
		if itemTop < st.offset {
			st.offset = itemTop
		} else if itemTop+itemH > st.offset+listH {
			st.offset = itemTop + itemH - listH
		}
	}
	offset := w.beginScroll("lang.scroll", view)
	scrollbar := int32(0)
	if content > listH {
		scrollbar = w.px(12)
	}
	y := view.Top - offset
	for i, language := range languages {
		code := language.Code
		item := rect{view.Left, y, view.Right - scrollbar, y + itemH}
		y += itemH
		if item.Bottom <= view.Top || item.Top >= view.Bottom {
			continue
		}
		st := w.add(widget{id: "lang." + code, r: item, onClick: func() { f.setLanguage(code) }})
		if st.hot || (i == f.langIndex && w.cues) {
			c.roundRect(item, w.px(6), theme.PanelAlt)
		}
		if code == i18n.Current() {
			w.glyph(glyphCheck, rect{item.Left + w.px(8), item.Top, item.Left + w.px(28), item.Bottom}, 13, theme.Accent)
		}
		c.text(w.semiFont(), language.Name, rect{item.Left + w.px(36), item.Top, item.Right - w.px(10), item.Bottom}, theme.Text, dtLeft|dtSingleLine|dtVCenter|dtEndEllipsis)
	}
	w.endScroll("lang.scroll", view, content)
	y = view.Bottom + w.px(4)
	w.separator(panel.Left+w.px(12), panel.Right-w.px(12), y)
	y += w.px(10)
	c.text(w.captionFont(), hint, rect{panel.Left + w.px(16), y, panel.Right - w.px(16), y + hintH}, theme.Muted, dtLeft|dtWordBreak|dtEditControl)
}

func (f *Flow) drawToast(w *win, client rect) {
	if f.toast == "" {
		return
	}
	if time.Now().After(f.toastUntil) {
		f.toast = ""
		return
	}
	w.animate = true // keeps the timer running so the toast expires
	c := w.canvas
	width := min(client.w()-w.px(48), w.px(620))
	textW := width - w.px(56)
	th := c.measure(w.bodyFont(), f.toast, textW)
	h := th + w.px(24)
	r := rect{client.Left + (client.w()-width)/2, client.Bottom - h - w.px(24), 0, 0}
	r.Right, r.Bottom = r.Left+width, r.Top+h
	c.roundRectAlpha(rect{r.Left, r.Top + w.px(2), r.Right, r.Bottom + w.px(4)}, w.px(10), color{0, 0, 0}, 0.4)
	c.roundRect(r, w.px(10), theme.PanelAlt)
	c.roundBorder(r, w.px(10), max(1, w.px(1)), theme.Warning)
	w.glyph(glyphWarning, rect{r.Left + w.px(14), r.Top, r.Left + w.px(38), r.Bottom}, 16, theme.Warning)
	c.text(w.bodyFont(), f.toast, rect{r.Left + w.px(44), r.Top + w.px(12), r.Right - w.px(12), r.Bottom - w.px(12)}, theme.Text, dtLeft|dtWordBreak|dtEditControl)
}

func (f *Flow) key(w *win, vk uintptr, pre bool) bool {
	if pre {
		if !f.langOpen {
			return false
		}
		languages := i18n.Languages()
		switch vk {
		case vkEscape, vkTab:
			f.langOpen = false
		case vkUp:
			f.selectLanguageIndex(f.langIndex - 1)
		case vkDown:
			f.selectLanguageIndex(f.langIndex + 1)
		case vkPrior:
			f.selectLanguageIndex(f.langIndex - 8)
		case vkNext:
			f.selectLanguageIndex(f.langIndex + 8)
		case vkHome:
			f.selectLanguageIndex(0)
		case vkEnd:
			f.selectLanguageIndex(len(languages) - 1)
		case vkReturn, vkSpace:
			if f.langIndex >= 0 && f.langIndex < len(languages) {
				f.setLanguage(languages[f.langIndex].Code)
			}
		}
		return true // the open menu is modal
	}
	if vk == vkF5 {
		if rf, ok := f.screen.(refreshable); ok && !f.busy && !rf.refreshing() {
			rf.refresh()
			return true
		}
	}
	if f.screen != nil {
		return f.screen.key(f, w, vk)
	}
	return false
}

func languageName(code string) string {
	for _, language := range i18n.Languages() {
		if language.Code == code {
			return language.Name
		}
	}
	return code
}

// ---- navigation between screens -------------------------------------------

func (f *Flow) showModes() {
	f.busy = false
	f.show(newModeScreen(f), "mode.install")
}

func (f *Flow) showInstallDevices() {
	f.busy = false
	f.show(newDeviceScreen(f), "list")
}

func (f *Flow) showInstallConfirmation(disk domain.Disk) {
	f.show(newInstallConfirmation(f, disk), "confirm.input")
}

func (f *Flow) showInstallProgress(disk domain.Disk) {
	f.busy = true
	events := normalizeInstall(f.cfg.Install.RunAsync(disk))
	f.show(newProgressScreen(f, opInstall, events), "")
}

func (f *Flow) showInstalledDevices(op operation) {
	f.busy = false
	f.show(newInstalledScreen(f, op), "list")
}

func (f *Flow) showUpdateConfirmation(target installed.Target) {
	f.show(newUpdateConfirmation(f, target), "action.back")
}

func (f *Flow) showUpdateProgress(target installed.Target, allowDowngrade bool) {
	f.busy = true
	var events <-chan localupdate.Event
	if allowDowngrade {
		events = f.cfg.Update.RunAsyncConfirmedDowngrade(target)
	} else {
		events = f.cfg.Update.RunAsync(target)
	}
	f.show(newProgressScreen(f, opUpdate, normalizeUpdate(events)), "")
}

func (f *Flow) showRepairConfirmation(target installed.Target) {
	f.show(newRepairConfirmation(f, target), "action.primary")
}

func (f *Flow) showRepairProgress(target installed.Target) {
	f.busy = true
	f.show(newProgressScreen(f, opRepair, normalizeRepair(f.cfg.Repair.RunAsync(target))), "")
}

func (f *Flow) showUninstallConfirmation(target installed.Target) {
	f.show(newUninstallConfirmation(f, target), "confirm.input")
}

func (f *Flow) showUninstallProgress(target installed.Target) {
	f.busy = true
	f.show(newProgressScreen(f, opUninstall, normalizeUninstall(f.cfg.Uninstall.RunAsync(target))), "")
}

func (f *Flow) showFinal(op operation, report *install.VerificationReport, err error, log string) {
	f.busy = false
	f.show(newFinalScreen(f, op, report, err, log), "action.primary")
}
