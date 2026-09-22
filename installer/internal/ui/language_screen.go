package ui

import (
	"fmt"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// LanguageScreen is the first step: it selects the installer language, which
// is also the only language written to the USOS drive.
type LanguageScreen struct {
	detected   string
	onChanged  func()
	onContinue func()
}

func NewLanguageScreen(detected string, onChanged, onContinue func()) *LanguageScreen {
	return &LanguageScreen{detected: detected, onChanged: onChanged, onContinue: onContinue}
}

func (s *LanguageScreen) Content() fyne.CanvasObject {
	languages := i18n.Languages()
	names := make([]string, len(languages))
	selected := ""
	for i, language := range languages {
		names[i] = language.Name
		if language.Code == i18n.Current() {
			selected = language.Name
		}
	}
	title := widget.NewLabelWithStyle(i18n.T("installer.language.title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	description := widget.NewLabel(i18n.T("installer.language.description"))
	description.Wrapping = fyne.TextWrapWord
	detected := widget.NewLabel(i18n.T("installer.language.detected", languageName(s.detected)))
	choices := widget.NewRadioGroup(names, nil)
	choices.SetSelected(selected)
	choices.OnChanged = func(name string) {
		for _, language := range languages {
			if language.Name == name && language.Code != i18n.Current() {
				i18n.SetLanguage(language.Code)
				if s.onChanged != nil {
					s.onChanged()
				}
				return
			}
		}
	}
	next := widget.NewButton(i18n.T("installer.common.next"), func() {
		if s.onContinue != nil {
			s.onContinue()
		}
	})
	next.Importance = widget.HighImportance
	return container.NewBorder(
		container.NewVBox(title, description, detected, widget.NewSeparator()),
		container.NewHBox(next),
		nil,
		nil,
		container.NewVScroll(choices),
	)
}

func languageName(code string) string {
	for _, language := range i18n.Languages() {
		if language.Code == code {
			return language.Name
		}
	}
	return code
}

// stageName translates a backend stage by operation and ID; the backend name
// is only shown if the catalog lacks the key (tests require every key).
func stageName(operation string, id int, fallback string) string {
	key := fmt.Sprintf("installer.stage.%s.%d", operation, id)
	if _, ok := i18n.Lookup(i18n.Current(), key); !ok {
		return fallback
	}
	return i18n.T(key)
}
