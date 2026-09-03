package install

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

type DestructiveSession interface {
	CleanPartitionTable() error
	CreateGPTAndPartitions(plan layout.Plan) (MediaLayout, error)
	VerifyLayoutUnchanged(expected MediaLayout) (MediaLayout, error)
	Close() error
}

type Backend interface {
	BeginDestructive(expected domain.Disk) (DestructiveSession, domain.Disk, error)
	FormatESP(media MediaLayout) error
	FormatDATA(media MediaLayout) error
	FormatWORK(media MediaLayout) error
	EnsureWORKHidden(media MediaLayout) error
	CopyInstallPayload(media MediaLayout, progress func(done, total uint64)) error
	WriteIdentity(media MediaLayout, workBytes uint64) (DeviceINI, error)
	Verify(media MediaLayout, expected DeviceINI) (VerificationReport, error)
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
		return nil, fmt.Errorf("install backend is nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("operation logger is nil")
	}
	return &Engine{backend: backend, logger: logger}, nil
}

func (e *Engine) RunAsync(expected domain.Disk) <-chan Event {
	events := make(chan Event, 32)
	go func() {
		defer close(events)
		e.run(expected, events)
	}()
	return events
}

func (e *Engine) run(expected domain.Disk, events chan<- Event) {
	plan, err := layout.Build(expected.SizeBytes)
	if err != nil {
		e.finishWithError(events, fmt.Errorf("build partition layout: %w", err))
		return
	}
	if err := plan.ValidateSectorSize(expected.SectorBytes); err != nil {
		e.finishWithError(events, fmt.Errorf("validate partition layout: %w", err))
		return
	}

	e.log(events, fmt.Sprintf("Preflight: blokada woluminów i ponowna identyfikacja PhysicalDrive%d model=%q serial=%q size=%d", expected.Number, expected.DisplayName(), expected.Serial, expected.SizeBytes))
	session, current, err := e.backend.BeginDestructive(expected)
	if err != nil {
		e.finishWithError(events, fmt.Errorf("preflight lock/revalidation failed: %w", err))
		return
	}
	defer func() {
		if closeErr := session.Close(); closeErr != nil {
			e.log(events, "WARN zamknięcie sesji destrukcyjnej: "+closeErr.Error())
		}
	}()
	e.log(events, fmt.Sprintf("Preflight PASS: otwarty uchwyt PhysicalDrive%d ma zatwierdzony model, serial i pojemność", current.Number))

	if err := e.runSimpleStage(events, StageCleanPartitionTable, func() error {
		return session.CleanPartitionTable()
	}); err != nil {
		return
	}

	var media MediaLayout
	if err := e.runSimpleStage(events, StageCreateGPT, func() error {
		var createErr error
		media, createErr = session.CreateGPTAndPartitions(plan)
		return createErr
	}); err != nil {
		return
	}

	if err := e.runSimpleStage(events, StageFormatESP, func() error { return e.backend.FormatESP(media) }); err != nil {
		return
	}
	if err := e.runSimpleStage(events, StageFormatDATA, func() error { return e.backend.FormatDATA(media) }); err != nil {
		return
	}
	if err := e.runSimpleStage(events, StageFormatWORK, func() error {
		if err := e.backend.FormatWORK(media); err != nil {
			return err
		}
		if err := e.backend.EnsureWORKHidden(media); err != nil {
			return fmt.Errorf("hide WORK after format: %w", err)
		}
		readBack, err := session.VerifyLayoutUnchanged(media)
		if err != nil {
			return fmt.Errorf("post-format GPT read-back mismatch: %w", err)
		}
		media = readBack
		e.log(events, "POST-FORMAT READ-BACK PASS: PARTUUID-y, typy i atrybuty GPT (WORK bit 63 NoDriveLetter), offsety oraz rozmiary nie zmieniły się po formatowaniu")
		return nil
	}); err != nil {
		return
	}

	if err := e.runCopyStage(events, media); err != nil {
		return
	}

	var identity DeviceINI
	if err := e.runSimpleStage(events, StageWriteIdentity, func() error {
		var identityErr error
		identity, identityErr = e.backend.WriteIdentity(media, plan.WORK.SizeBytes)
		return identityErr
	}); err != nil {
		return
	}

	var report VerificationReport
	if err := e.runVerificationStage(events, &report, func() error {
		finalReadBack, readErr := session.VerifyLayoutUnchanged(media)
		if readErr != nil {
			report = VerificationReport{Items: []VerificationItem{{
				Name:     "Końcowy read-back GPT",
				Expected: "layout i PARTUUID-y bez zmian",
				Actual:   readErr.Error(),
				Match:    false,
			}}}
			return fmt.Errorf("final GPT read-back mismatch: %w", readErr)
		}
		media = finalReadBack
		var verifyErr error
		report, verifyErr = e.backend.Verify(media, identity)
		if verifyErr == nil && !report.OK() {
			verifyErr = fmt.Errorf("verification report contains mismatches")
		}
		return verifyErr
	}); err != nil {
		return
	}

	e.log(events, "Instalacja zakończona: wszystkie odczytane identyfikatory są zgodne")
	events <- Event{Kind: EventFinished, Verification: &report}
}

func (e *Engine) runSimpleStage(events chan<- Event, stageID StageID, operation func() error) error {
	caption := StageCaption(stageID)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateActive, ProgressKnown: false}
	if err := operation(); err != nil {
		wrapped := fmt.Errorf("%s: %w", caption, err)
		e.log(events, "FAIL "+wrapped.Error())
		events <- Event{Kind: EventStage, StageID: stageID, State: StateFailed, Err: wrapped}
		events <- Event{Kind: EventFinished, Err: wrapped}
		return wrapped
	}
	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateSucceeded, ProgressKnown: false}
	return nil
}

func (e *Engine) runVerificationStage(events chan<- Event, report *VerificationReport, operation func() error) error {
	stageID := StageVerify
	caption := StageCaption(stageID)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateActive, ProgressKnown: false}
	if err := operation(); err != nil {
		wrapped := fmt.Errorf("%s: %w", caption, err)
		e.log(events, "FAIL "+wrapped.Error())
		events <- Event{Kind: EventStage, StageID: stageID, State: StateFailed, Err: wrapped}
		events <- Event{Kind: EventFinished, Verification: report, Err: wrapped}
		return wrapped
	}
	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateSucceeded, ProgressKnown: false}
	return nil
}

func (e *Engine) runCopyStage(events chan<- Event, media MediaLayout) error {
	stageID := StageCopyESP
	caption := StageCaption(stageID)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateActive, ProgressKnown: true, Progress: 0}
	err := e.backend.CopyInstallPayload(media, func(done, total uint64) {
		progress := float64(0)
		if total > 0 {
			progress = float64(done) / float64(total)
			if progress > 1 {
				progress = 1
			}
		}
		events <- Event{Kind: EventStage, StageID: stageID, State: StateActive, ProgressKnown: true, Progress: progress}
	})
	if err != nil {
		wrapped := fmt.Errorf("%s: %w", caption, err)
		e.log(events, "FAIL "+wrapped.Error())
		events <- Event{Kind: EventStage, StageID: stageID, State: StateFailed, ProgressKnown: true, Err: wrapped}
		events <- Event{Kind: EventFinished, Err: wrapped}
		return wrapped
	}
	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: stageID, State: StateSucceeded, ProgressKnown: true, Progress: 1}
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
