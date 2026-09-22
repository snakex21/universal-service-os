package ui

import (
	"fmt"
	"strings"

	"fyne.io/fyne/v2"
	"fyne.io/fyne/v2/container"
	"fyne.io/fyne/v2/widget"
	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

type secondaryStage struct {
	ID     int
	Number int
	Total  int
	Name   string
}

type secondaryEvent struct {
	kind          int
	stageID       int
	state         int
	message       string
	progressKnown bool
	progress      float64
	err           error
	verification  *install.VerificationReport
}

const (
	secondaryEventStage = iota + 1
	secondaryEventLog
	secondaryEventFinished
)

const (
	secondaryPending = iota
	secondaryActive
	secondarySucceeded
	secondaryFailed
)

type SecondaryProgressScreen struct {
	title    string
	warning  string
	stages   map[int]*progressStageWidgets
	defs     []secondaryStage
	log      *widget.Entry
	content  fyne.CanvasObject
	onFinish func(*install.VerificationReport, error)
}

func newSecondaryProgressScreen(title, warning string, defs []secondaryStage, events <-chan secondaryEvent, onFinish func(*install.VerificationReport, error)) *SecondaryProgressScreen {
	s := &SecondaryProgressScreen{title: title, warning: warning, defs: defs, stages: make(map[int]*progressStageWidgets), onFinish: onFinish}
	s.log = widget.NewMultiLineEntry()
	s.log.Disable()
	s.log.SetPlaceHolder(i18n.T("installer.common.log"))
	s.content = s.buildContent()
	go s.consume(events)
	return s
}

func NewLocalUpdateProgressScreen(events <-chan localupdate.Event, onFinish func(*install.VerificationReport, error)) *SecondaryProgressScreen {
	defs := make([]secondaryStage, 0, localupdate.StageCount)
	for id := localupdate.StageID(1); id <= localupdate.StageCount; id++ {
		stage, ok := localupdate.StageInfo(id)
		if ok {
			defs = append(defs, secondaryStage{ID: int(stage.ID), Number: stage.Number, Total: localupdate.StageCount, Name: stageName("update", int(stage.ID), stage.Name)})
		}
	}
	normalized := make(chan secondaryEvent, 32)
	go func() {
		defer close(normalized)
		for event := range events {
			out := secondaryEvent{stageID: int(event.StageID), message: event.Message, progressKnown: event.ProgressKnown, progress: event.Progress, err: event.Err, verification: event.Verification}
			switch event.Kind {
			case localupdate.EventStage:
				out.kind = secondaryEventStage
			case localupdate.EventLog:
				out.kind = secondaryEventLog
			case localupdate.EventFinished:
				out.kind = secondaryEventFinished
			}
			switch event.State {
			case localupdate.StateActive:
				out.state = secondaryActive
			case localupdate.StateSucceeded:
				out.state = secondarySucceeded
			case localupdate.StateFailed:
				out.state = secondaryFailed
			default:
				out.state = secondaryPending
			}
			normalized <- out
		}
	}()
	return newSecondaryProgressScreen(
		i18n.T("installer.update.title"),
		i18n.T("installer.update.progress_warning"),
		defs,
		normalized,
		onFinish,
	)
}

func NewRepairProgressScreen(events <-chan repair.Event, onFinish func(*install.VerificationReport, error)) *SecondaryProgressScreen {
	defs := make([]secondaryStage, 0, repair.StageCount)
	for id := repair.StageID(1); id <= repair.StageCount; id++ {
		stage, ok := repair.StageInfo(id)
		if ok {
			defs = append(defs, secondaryStage{ID: int(stage.ID), Number: stage.Number, Total: repair.StageCount, Name: stageName("repair", int(stage.ID), stage.Name)})
		}
	}
	normalized := make(chan secondaryEvent, 24)
	go func() {
		defer close(normalized)
		for event := range events {
			out := secondaryEvent{stageID: int(event.StageID), message: event.Message, progressKnown: event.ProgressKnown, progress: event.Progress, err: event.Err, verification: event.Verification}
			switch event.Kind {
			case repair.EventStage:
				out.kind = secondaryEventStage
			case repair.EventLog:
				out.kind = secondaryEventLog
			case repair.EventFinished:
				out.kind = secondaryEventFinished
			}
			switch event.State {
			case repair.StateActive:
				out.state = secondaryActive
			case repair.StateSucceeded:
				out.state = secondarySucceeded
			case repair.StateFailed:
				out.state = secondaryFailed
			default:
				out.state = secondaryPending
			}
			normalized <- out
		}
	}()
	return newSecondaryProgressScreen(
		i18n.T("installer.repair.title"),
		i18n.T("installer.repair.progress_warning"),
		defs,
		normalized,
		onFinish,
	)
}

func NewUninstallProgressScreen(events <-chan uninstall.Event, onFinish func(*install.VerificationReport, error)) *SecondaryProgressScreen {
	defs := make([]secondaryStage, 0, uninstall.StageCount)
	for id := uninstall.StageID(1); id <= uninstall.StageCount; id++ {
		stage, ok := uninstall.StageInfo(id)
		if ok {
			defs = append(defs, secondaryStage{ID: int(stage.ID), Number: stage.Number, Total: uninstall.StageCount, Name: stageName("uninstall", int(stage.ID), stage.Name)})
		}
	}
	normalized := make(chan secondaryEvent, 16)
	go func() {
		defer close(normalized)
		for event := range events {
			var verification *install.VerificationReport
			if event.Verification != nil {
				verification = &install.VerificationReport{Items: append([]install.VerificationItem(nil), event.Verification.Items...)}
			}
			out := secondaryEvent{stageID: int(event.StageID), message: event.Message, err: event.Err, verification: verification}
			switch event.Kind {
			case uninstall.EventStage:
				out.kind = secondaryEventStage
			case uninstall.EventLog:
				out.kind = secondaryEventLog
			case uninstall.EventFinished:
				out.kind = secondaryEventFinished
			}
			switch event.State {
			case uninstall.StateActive:
				out.state = secondaryActive
			case uninstall.StateSucceeded:
				out.state = secondarySucceeded
			case uninstall.StateFailed:
				out.state = secondaryFailed
			default:
				out.state = secondaryPending
			}
			normalized <- out
		}
	}()
	return newSecondaryProgressScreen(
		i18n.T("installer.uninstall.progress_title"),
		i18n.T("installer.uninstall.progress_warning"),
		defs,
		normalized,
		onFinish,
	)
}

func (s *SecondaryProgressScreen) Content() fyne.CanvasObject { return s.content }

func (s *SecondaryProgressScreen) buildContent() fyne.CanvasObject {
	title := widget.NewLabelWithStyle(s.title, fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	warning := widget.NewLabel(s.warning)
	warning.Wrapping = fyne.TextWrapWord
	rows := make([]fyne.CanvasObject, 0, len(s.defs))
	for _, stage := range s.defs {
		number := widget.NewLabelWithStyle(fmt.Sprintf("%d/%d", stage.Number, stage.Total), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
		name := widget.NewLabel(stage.Name)
		status := widget.NewLabel(i18n.T("installer.common.pending"))
		status.Importance = widget.LowImportance
		bar := widget.NewProgressBar()
		bar.Hide()
		activity := widget.NewProgressBarInfinite()
		activity.Stop()
		activity.Hide()
		indicator := container.NewStack(bar, activity)
		rows = append(rows, container.NewGridWithColumns(4, number, name, status, indicator))
		s.stages[stage.ID] = &progressStageWidgets{status: status, bar: bar, activity: activity}
	}
	steps := container.NewVScroll(container.NewVBox(rows...))
	steps.SetMinSize(fyne.NewSize(1000, 300))
	logTitle := widget.NewLabelWithStyle(i18n.T("installer.common.log"), fyne.TextAlignLeading, fyne.TextStyle{Bold: true})
	logScroll := container.NewVScroll(s.log)
	logScroll.SetMinSize(fyne.NewSize(1000, 220))
	return container.NewBorder(
		container.NewVBox(title, warning, widget.NewSeparator()),
		nil,
		nil,
		nil,
		container.NewVSplit(steps, container.NewBorder(logTitle, nil, nil, nil, logScroll)),
	)
}

func (s *SecondaryProgressScreen) consume(events <-chan secondaryEvent) {
	for event := range events {
		event := event
		fyne.Do(func() { s.apply(event) })
	}
}

func (s *SecondaryProgressScreen) apply(event secondaryEvent) {
	switch event.kind {
	case secondaryEventLog:
		s.appendLog(event.message)
	case secondaryEventStage:
		row := s.stages[event.stageID]
		if row == nil {
			return
		}
		switch event.state {
		case secondaryActive:
			row.status.SetText(i18n.T("installer.common.active"))
			row.status.Importance = widget.MediumImportance
			if event.progressKnown {
				row.activity.Stop()
				row.activity.Hide()
				row.bar.SetValue(event.progress)
				row.bar.Show()
			} else {
				row.bar.Hide()
				row.activity.Show()
				row.activity.Start()
			}
		case secondarySucceeded:
			row.activity.Stop()
			row.activity.Hide()
			if event.progressKnown {
				row.bar.SetValue(1)
				row.bar.Show()
			}
			row.status.SetText(i18n.T("installer.common.done"))
			row.status.Importance = widget.SuccessImportance
		case secondaryFailed:
			row.activity.Stop()
			row.activity.Hide()
			row.bar.Hide()
			message := i18n.T("installer.common.error")
			if event.err != nil {
				message = i18n.T("installer.common.error_detail", event.err.Error())
			}
			row.status.SetText(message)
			row.status.Importance = widget.DangerImportance
		}
	case secondaryEventFinished:
		for _, row := range s.stages {
			row.activity.Stop()
		}
		if s.onFinish != nil {
			s.onFinish(event.verification, event.err)
		}
	}
}

func (s *SecondaryProgressScreen) appendLog(message string) {
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
