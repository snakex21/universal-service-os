package ui

import (
	"fmt"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
)

type progressStageWidgets struct {
	status   *widget.Label
	bar      *widget.ProgressBar
	activity *widget.ProgressBarInfinite
}

type ProgressScreen struct {
	stages   map[install.StageID]*progressStageWidgets
	log      *widget.Entry
	content  fyne.CanvasObject
	onFinish func(*install.VerificationReport, error)
}

func NewProgressScreen(events <-chan install.Event, onFinish func(*install.VerificationReport, error)) *ProgressScreen {
	s := &ProgressScreen{
		stages:   make(map[install.StageID]*progressStageWidgets),
		onFinish: onFinish,
	}
	s.log = widget.NewMultiLineEntry()
	s.log.Disable()
	s.log.SetPlaceHolder(i18n.T("installer.common.log"))
	s.content = s.buildContent()
	go s.consume(events)
	return s
}

func (s *ProgressScreen) Content() fyne.CanvasObject {
	return s.content
}

func (s *ProgressScreen) buildContent() fyne.CanvasObject {
	title := widget.NewLabelWithStyle(i18n.T("installer.install.progress_title"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	warning := widget.NewLabel(i18n.T("installer.install.progress_warning"))
	warning.Wrapping = fyne.TextWrapWord
	warning.Importance = widget.DangerImportance

	rows := make([]fyne.CanvasObject, 0, install.StageCount)
	for _, stage := range install.Stages() {
		number := widget.NewLabelWithStyle(fmt.Sprintf("%d/%d", stage.Number, install.StageCount), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
		name := widget.NewLabel(stageName("install", int(stage.ID), stage.Name))
		status := widget.NewLabel(i18n.T("installer.common.pending"))
		status.Importance = widget.LowImportance
		bar := widget.NewProgressBar()
		bar.SetValue(0)
		bar.Hide()
		activity := widget.NewProgressBarInfinite()
		activity.Stop()
		activity.Hide()
		indicator := container.NewStack(bar, activity)
		indicator.Resize(fyne.NewSize(280, indicator.MinSize().Height))
		row := container.NewGridWithColumns(4, number, name, status, indicator)
		rows = append(rows, row)
		s.stages[stage.ID] = &progressStageWidgets{status: status, bar: bar, activity: activity}
	}
	steps := container.NewVBox(rows...)
	stepsScroll := container.NewVScroll(steps)
	stepsScroll.SetMinSize(fyne.NewSize(1000, 360))

	logTitle := widget.NewLabelWithStyle(i18n.T("installer.common.log"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	logScroll := container.NewVScroll(s.log)
	logScroll.SetMinSize(fyne.NewSize(1000, 220))

	return container.NewBorder(
		container.NewVBox(title, warning, widget.NewSeparator()),
		nil,
		nil,
		nil,
		container.NewVSplit(stepsScroll, container.NewBorder(logTitle, nil, nil, nil, logScroll)),
	)
}

func (s *ProgressScreen) consume(events <-chan install.Event) {
	for event := range events {
		event := event
		fyne.Do(func() {
			s.apply(event)
		})
	}
}

func (s *ProgressScreen) apply(event install.Event) {
	switch event.Kind {
	case install.EventLog:
		s.appendLog(event.Message)
	case install.EventStage:
		s.applyStage(event)
	case install.EventFinished:
		for _, row := range s.stages {
			row.activity.Stop()
		}
		if s.onFinish != nil {
			s.onFinish(event.Verification, event.Err)
		}
	}
}

func (s *ProgressScreen) applyStage(event install.Event) {
	row := s.stages[event.StageID]
	if row == nil {
		return
	}
	switch event.State {
	case install.StateActive:
		row.status.SetText(i18n.T("installer.common.active"))
		row.status.Importance = widget.MediumImportance
		if event.ProgressKnown {
			row.activity.Stop()
			row.activity.Hide()
			row.bar.SetValue(event.Progress)
			row.bar.Show()
		} else {
			row.bar.Hide()
			row.activity.Show()
			row.activity.Start()
		}
	case install.StateSucceeded:
		row.activity.Stop()
		row.activity.Hide()
		if event.ProgressKnown {
			row.bar.SetValue(1)
			row.bar.Show()
		} else {
			row.bar.Hide()
		}
		row.status.SetText(i18n.T("installer.common.done"))
		row.status.Importance = widget.SuccessImportance
	case install.StateFailed:
		row.activity.Stop()
		row.activity.Hide()
		row.bar.Hide()
		message := i18n.T("installer.common.error")
		if event.Err != nil {
			message = i18n.T("installer.common.error_detail", event.Err.Error())
		}
		row.status.SetText(message)
		row.status.Importance = widget.DangerImportance
	}
}

func (s *ProgressScreen) appendLog(message string) {
	message = strings.TrimSpace(message)
	if message == "" {
		return
	}
	if s.log.Text == "" {
		s.log.SetText(message)
	} else {
		s.log.SetText(s.log.Text + "\n" + message)
	}
	s.log.CursorRow = len(strings.Split(s.log.Text, "\n")) - 1
}
