package uninstall

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
)

type DestructiveSession interface {
	CleanPartitionTable() error
	CreateSingleDataPartition() (MediaLayout, error)
	VerifyUninstallLayoutUnchanged(expected MediaLayout) (MediaLayout, error)
	Close() error
}

type Backend interface {
	BeginUSOSDestructive(expected Target) (DestructiveSession, domain.Disk, error)
	FormatExFAT(media MediaLayout) error
	VerifyUninstall(media MediaLayout) (VerificationReport, error)
}

type LineLogger interface {
	WriteLine(message string) error
}

type Engine struct {
	backend Backend
	logger  LineLogger
}

func NewEngine(backend Backend, logger LineLogger) (*Engine, error) {
	if backend == nil {
		return nil, fmt.Errorf("uninstall backend is nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("operation logger is nil")
	}
	return &Engine{backend: backend, logger: logger}, nil
}

func (e *Engine) RunAsync(expected Target) <-chan Event {
	events := make(chan Event, 16)
	go func() {
		defer close(events)
		e.run(expected, events)
	}()
	return events
}

func (e *Engine) run(expected Target, events chan<- Event) {
	e.log(events, fmt.Sprintf("Preflight uninstall: blokada i ponowna walidacja USOS PhysicalDrive%d model=%q serial=%q", expected.Disk.Number, expected.Disk.DisplayName(), expected.Disk.Serial))
	session, current, err := e.backend.BeginUSOSDestructive(expected)
	if err != nil {
		e.finishWithError(events, fmt.Errorf("uninstall preflight failed: %w", err))
		return
	}
	defer func() {
		if closeErr := session.Close(); closeErr != nil {
			e.log(events, "WARN zamknięcie sesji destrukcyjnej: "+closeErr.Error())
		}
	}()
	e.log(events, fmt.Sprintf("Preflight PASS: PhysicalDrive%d nadal jest zatwierdzonym nośnikiem USOS", current.Number))

	if err := e.runStage(events, StageClean, session.CleanPartitionTable); err != nil {
		return
	}

	var media MediaLayout
	if err := e.runStage(events, StageCreateSinglePartition, func() error {
		var createErr error
		media, createErr = session.CreateSingleDataPartition()
		return createErr
	}); err != nil {
		return
	}

	if err := e.runStage(events, StageFormatExFAT, func() error {
		if err := e.backend.FormatExFAT(media); err != nil {
			return err
		}
		readBack, err := session.VerifyUninstallLayoutUnchanged(media)
		if err != nil {
			return fmt.Errorf("post-format GPT read-back mismatch: %w", err)
		}
		media = readBack
		return nil
	}); err != nil {
		return
	}

	var report VerificationReport
	if err := e.runStage(events, StageVerify, func() error {
		readBack, err := session.VerifyUninstallLayoutUnchanged(media)
		if err != nil {
			return fmt.Errorf("final GPT read-back mismatch: %w", err)
		}
		media = readBack
		report, err = e.backend.VerifyUninstall(media)
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

	e.log(events, "Deinstalacja zakończona: nośnik ma jedną partycję exFAT i nie zawiera układu USOS")
	events <- Event{Kind: EventFinished, Verification: &report}
}

func (e *Engine) runStage(events chan<- Event, stageID StageID, operation func() error) error {
	caption := StageCaption(stageID)
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

func (e *Engine) finishWithError(events chan<- Event, err error) {
	e.log(events, "FAIL "+err.Error())
	events <- Event{Kind: EventFinished, Err: err}
}

func (e *Engine) log(events chan<- Event, message string) {
	if err := e.logger.WriteLine(message); err != nil {
		events <- Event{Kind: EventLog, Message: message + " [błąd zapisu logu: " + err.Error() + "]"}
		return
	}
	events <- Event{Kind: EventLog, Message: message}
}
