package localupdate

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type Backend interface {
	RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error)
	EnsureWORKHidden(media install.MediaLayout) error
	CopyInstallPayload(media install.MediaLayout, progress func(done, total uint64)) error
	Verify(media install.MediaLayout, expected install.DeviceINI) (install.VerificationReport, error)
}

type LineLogger interface {
	WriteLine(message string) error
}

type EventKind uint8

const (
	EventStage EventKind = iota + 1
	EventLog
	EventFinished
)

type StageID uint8

const (
	StageRevalidate StageID = iota + 1
	StageHideWORK
	StageCopyPayload
	StageVerify
	StageCount = 4
)

type State uint8

const (
	StatePending State = iota
	StateActive
	StateSucceeded
	StateFailed
)

type Event struct {
	Kind          EventKind
	StageID       StageID
	State         State
	Message       string
	ProgressKnown bool
	Progress      float64
	Err           error
	Verification  *install.VerificationReport
}

type Stage struct {
	ID     StageID
	Number int
	Name   string
}

var stages = map[StageID]Stage{
	StageRevalidate:  {ID: StageRevalidate, Number: 1, Name: "Ponowna walidacja nośnika USOS"},
	StageHideWORK:    {ID: StageHideWORK, Number: 2, Name: "Ukrywanie partycji WORK"},
	StageCopyPayload: {ID: StageCopyPayload, Number: 3, Name: "Aktualizacja plików i katalogu menu"},
	StageVerify:      {ID: StageVerify, Number: 4, Name: "Weryfikacja aktualizacji"},
}

func StageInfo(id StageID) (Stage, bool) {
	stage, ok := stages[id]
	return stage, ok
}

type Engine struct {
	backend Backend
	logger  LineLogger
}

func NewEngine(backend Backend, logger LineLogger) (*Engine, error) {
	if backend == nil {
		return nil, fmt.Errorf("local update backend is nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("operation logger is nil")
	}
	return &Engine{backend: backend, logger: logger}, nil
}

func (e *Engine) RunAsync(expected installed.Target) <-chan Event {
	events := make(chan Event, 32)
	go func() {
		defer close(events)
		e.run(expected, events)
	}()
	return events
}

func (e *Engine) run(expected installed.Target, events chan<- Event) {
	var current installed.Target
	if err := e.runStage(events, StageRevalidate, func() error {
		var err error
		current, err = e.backend.RevalidateInstalledUSOS(expected)
		return err
	}); err != nil {
		return
	}
	if err := e.runStage(events, StageHideWORK, func() error {
		return e.backend.EnsureWORKHidden(current.Media)
	}); err != nil {
		return
	}
	if err := e.runCopy(events, current); err != nil {
		return
	}

	var report install.VerificationReport
	if err := e.runStage(events, StageVerify, func() error {
		var err error
		report, err = e.backend.Verify(current.Media, current.Identity)
		if err == nil && !report.OK() {
			err = fmt.Errorf("verification report contains mismatches")
		}
		return err
	}); err != nil {
		if len(report.Items) > 0 {
			events <- Event{Kind: EventFinished, Verification: &report, Err: err}
		}
		return
	}

	e.log(events, "Aktualizacja zakończona: pliki USOS i katalog menu odświeżone, obrazy systemów i dane użytkownika pozostały bez zmian")
	events <- Event{Kind: EventFinished, Verification: &report}
}

func (e *Engine) runStage(events chan<- Event, stageID StageID, operation func() error) error {
	stage, _ := StageInfo(stageID)
	caption := fmt.Sprintf("%d/%d - %s", stage.Number, StageCount, stage.Name)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateActive}
	if err := operation(); err != nil {
		wrapped := fmt.Errorf("%s: %w", caption, err)
		e.log(events, "FAIL "+wrapped.Error())
		events <- Event{Kind: EventStage, StageID: stageID, State: StateFailed, Err: wrapped}
		events <- Event{Kind: EventFinished, Err: wrapped}
		return wrapped
	}
	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateSucceeded}
	return nil
}

func (e *Engine) runCopy(events chan<- Event, current installed.Target) error {
	stage, _ := StageInfo(StageCopyPayload)
	caption := fmt.Sprintf("%d/%d - %s", stage.Number, StageCount, stage.Name)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateActive, ProgressKnown: true}
	err := e.backend.CopyInstallPayload(current.Media, func(done, total uint64) {
		progress := float64(0)
		if total > 0 {
			progress = float64(done) / float64(total)
			if progress > 1 {
				progress = 1
			}
		}
		events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateActive, ProgressKnown: true, Progress: progress}
	})
	if err != nil {
		wrapped := fmt.Errorf("%s: %w", caption, err)
		e.log(events, "FAIL "+wrapped.Error())
		events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateFailed, ProgressKnown: true, Err: wrapped}
		events <- Event{Kind: EventFinished, Err: wrapped}
		return wrapped
	}
	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateSucceeded, ProgressKnown: true, Progress: 1}
	return nil
}

func (e *Engine) log(events chan<- Event, message string) {
	if err := e.logger.WriteLine(message); err != nil {
		events <- Event{Kind: EventLog, Message: message + " [błąd zapisu logu: " + err.Error() + "]"}
		return
	}
	events <- Event{Kind: EventLog, Message: message}
}
