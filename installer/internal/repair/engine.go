package repair

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/obsolete"
)

type Backend interface {
	RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error)
	CopyESPPayload(media install.MediaLayout, progress func(done, total uint64)) error
	RemoveObsoleteESPFiles(media install.MediaLayout) ([]obsolete.Result, error)
	// RecordWinpeDonor records the PE10 donor of DATA\Programs\USOS\WinPE in
	// EFI\USOS\winpe-donor.ini, as install and update do, and returns a log
	// line describing the donor state.
	RecordWinpeDonor(media install.MediaLayout) (string, error)
	RestoreLegacyBoot(expected installed.Target) (legacyboot.Audit, error)
	VerifyRepair(media install.MediaLayout, expected install.DeviceINI) (install.VerificationReport, error)
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
	StageCopyESP
	StageLegacyBoot
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
	StageRevalidate: {ID: StageRevalidate, Number: 1, Name: "Ponowna walidacja nośnika USOS"},
	StageCopyESP:    {ID: StageCopyESP, Number: 2, Name: "Odtwarzanie plików ESP"},
	StageLegacyBoot: {ID: StageLegacyBoot, Number: 3, Name: "Odtwarzanie Legacy BIOS Stage 1 i Core"},
	StageVerify:     {ID: StageVerify, Number: 4, Name: "Weryfikacja"},
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
		return nil, fmt.Errorf("repair backend is nil")
	}
	if logger == nil {
		return nil, fmt.Errorf("operation logger is nil")
	}
	return &Engine{backend: backend, logger: logger}, nil
}

func (e *Engine) RunAsync(expected installed.Target) <-chan Event {
	events := make(chan Event, 24)
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
	if err := e.runCopy(events, current); err != nil {
		return
	}
	if err := e.runStage(events, StageLegacyBoot, func() error {
		audit, err := e.backend.RestoreLegacyBoot(current)
		e.logLegacyAudit(events, audit)
		return err
	}); err != nil {
		return
	}
	var report install.VerificationReport
	if err := e.runStage(events, StageVerify, func() error {
		var err error
		report, err = e.backend.VerifyRepair(current.Media, current.Identity)
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
	e.log(events, "Naprawa zakończona: ESP oraz Legacy BIOS Stage 1/Core odtworzone, dawca WinPE zapisany, GPT, WORK i pliki DATA niezmienione")
	events <- Event{Kind: EventFinished, Verification: &report}
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

func (e *Engine) runCopy(events chan<- Event, current installed.Target) error {
	stage, _ := StageInfo(StageCopyESP)
	caption := fmt.Sprintf("%d/%d — %s", stage.Number, StageCount, stage.Name)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: StageCopyESP, State: StateActive, ProgressKnown: true}
	err := e.backend.CopyESPPayload(current.Media, func(done, total uint64) {
		progress := float64(0)
		if total > 0 {
			progress = float64(done) / float64(total)
			if progress > 1 {
				progress = 1
			}
		}
		events <- Event{Kind: EventStage, StageID: StageCopyESP, State: StateActive, ProgressKnown: true, Progress: progress}
	})
	if err == nil {
		var removed []obsolete.Result
		removed, err = e.backend.RemoveObsoleteESPFiles(current.Media)
		for _, result := range removed {
			e.log(events, result.String())
		}
		if err != nil {
			err = fmt.Errorf("remove obsolete ESP files: %w", err)
		}
	}
	if err == nil {
		var donor string
		donor, err = e.backend.RecordWinpeDonor(current.Media)
		if donor != "" {
			e.log(events, "WINPE_DONOR "+donor)
		}
		if err != nil {
			err = fmt.Errorf("record the WinPE donor (Programs\\USOS\\WinPE): %w", err)
		}
	}
	if err != nil {
		wrapped := fmt.Errorf("%s: %w", caption, err)
		e.log(events, "FAIL "+wrapped.Error())
		events <- Event{Kind: EventStage, StageID: StageCopyESP, State: StateFailed, ProgressKnown: true, Err: wrapped}
		events <- Event{Kind: EventFinished, Err: wrapped}
		return wrapped
	}
	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: StageCopyESP, State: StateSucceeded, ProgressKnown: true, Progress: 1}
	return nil
}

func (e *Engine) logLegacyAudit(events chan<- Event, audit legacyboot.Audit) {
	if audit.Stage1.BeforeSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT BEFORE component=stage1 sha256=%s expected=%s", audit.Stage1.BeforeSHA256, audit.Stage1.ExpectedSHA256))
	}
	if audit.Core.BeforeSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT BEFORE component=core sha256=%s expected=%s", audit.Core.BeforeSHA256, audit.Core.ExpectedSHA256))
	}
	if audit.Stage1.AfterSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT AFTER component=stage1 sha256=%s expected=%s changed=%s", audit.Stage1.AfterSHA256, audit.Stage1.ExpectedSHA256, repairYesNo(audit.Stage1.Changed)))
	}
	if audit.Core.AfterSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT AFTER component=core sha256=%s expected=%s changed=%s", audit.Core.AfterSHA256, audit.Core.ExpectedSHA256, repairYesNo(audit.Core.Changed)))
	}
}

func repairYesNo(value bool) string {
	if value { return "yes" }
	return "no"
}

func (e *Engine) log(events chan<- Event, message string) {
	if err := e.logger.WriteLine(message); err != nil {
		events <- Event{Kind: EventLog, Message: message + " [błąd zapisu logu: " + err.Error() + "]"}
		return
	}
	events <- Event{Kind: EventLog, Message: message}
}
