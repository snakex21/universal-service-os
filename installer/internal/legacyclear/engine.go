package legacyclear

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
)

type Backend interface {
	RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error)
	ClearInstalledLegacyBoot(expected installed.Target) (legacyboot.Audit, error)
	VerifyInstalledLegacyBootCleared(expected installed.Target) error
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
	StageClear
	StageVerify
	StageCount = 3
)

type State uint8

const (
	StatePending State = iota
	StateActive
	StateSucceeded
	StateFailed
)

type Event struct {
	Kind    EventKind
	StageID StageID
	State   State
	Message string
	Err     error
}

type Stage struct {
	ID     StageID
	Number int
	Name   string
}

var stages = map[StageID]Stage{
	StageRevalidate: {ID: StageRevalidate, Number: 1, Name: "Ponowna walidacja nośnika USOS"},
	StageClear:      {ID: StageClear, Number: 2, Name: "Wyłączenie Legacy BIOS Stage 1 i Core"},
	StageVerify:     {ID: StageVerify, Number: 3, Name: "Weryfikacja GPT i wyzerowanego obszaru Legacy"},
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
		return nil, fmt.Errorf("legacy clear backend is nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("operation logger is nil")
	}
	return &Engine{backend: backend, logger: logger}, nil
}

func (e *Engine) RunAsync(expected installed.Target) <-chan Event {
	events := make(chan Event, 16)
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
	if err := e.runStage(events, StageClear, func() error {
		audit, clearErr := e.backend.ClearInstalledLegacyBoot(current)
		e.logAudit(events, audit)
		if clearErr == nil {
			e.log(events, "LEGACY_CLEAR GPT READBACK PASS: disk GUID, PARTUUID-y, typy, atrybuty, offsety i rozmiary bez zmian")
		}
		return clearErr
	}); err != nil {
		return
	}
	if err := e.runStage(events, StageVerify, func() error {
		return e.backend.VerifyInstalledLegacyBootCleared(current)
	}); err != nil {
		return
	}
	e.log(events, "Legacy BIOS wyłączone: bajty LBA0 0-439 i Core wyzerowane; Protective MBR, GPT, ESP, DATA i WORK pozostawione bez zmian")
	events <- Event{Kind: EventFinished}
}

func (e *Engine) runStage(events chan<- Event, stageID StageID, operation func() error) error {
	stage, _ := StageInfo(stageID)
	caption := fmt.Sprintf("%d/%d — %s", stage.Number, StageCount, stage.Name)
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

func (e *Engine) logAudit(events chan<- Event, audit legacyboot.Audit) {
	if audit.Stage1.BeforeSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_CLEAR BEFORE component=stage1 sha256=%s expected_zero=%s", audit.Stage1.BeforeSHA256, audit.Stage1.ExpectedSHA256))
	}
	if audit.Core.BeforeSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_CLEAR BEFORE component=core sha256=%s expected_zero=%s", audit.Core.BeforeSHA256, audit.Core.ExpectedSHA256))
	}
	if audit.Stage1.AfterSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_CLEAR AFTER component=stage1 sha256=%s expected_zero=%s changed=%s", audit.Stage1.AfterSHA256, audit.Stage1.ExpectedSHA256, yesNo(audit.Stage1.Changed)))
	}
	if audit.Core.AfterSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_CLEAR AFTER component=core sha256=%s expected_zero=%s changed=%s", audit.Core.AfterSHA256, audit.Core.ExpectedSHA256, yesNo(audit.Core.Changed)))
	}
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}

func (e *Engine) log(events chan<- Event, message string) {
	if err := e.logger.WriteLine(message); err != nil {
		events <- Event{Kind: EventLog, Message: message + " [błąd zapisu logu: " + err.Error() + "]"}
		return
	}
	events <- Event{Kind: EventLog, Message: message}
}
