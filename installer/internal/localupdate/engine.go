package localupdate

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/workboot"
)

type Backend interface {
	RevalidateInstalledUSOS(expected installed.Target) (installed.Target, error)
	RestoreLegacyBoot(expected installed.Target) (legacyboot.Audit, error)
	EnsureWORKVisible(media install.MediaLayout) error
	// MigrateWORKBootPath moves a pre-USOS-WORK EFI/BOOT chain on WORK to
	// EFI/USOS-WORK so firmware stops listing WORK as a boot option.
	MigrateWORKBootPath(media install.MediaLayout) (workboot.Migration, error)
	PayloadStatus(media install.MediaLayout) ([]PayloadFileStatus, error)
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
	StageLegacyBoot
	StageExposeWORK
	StageCopyPayload
	StageVerify
	StageCount = 5
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
	StageLegacyBoot:  {ID: StageLegacyBoot, Number: 2, Name: "Aktualizacja Legacy BIOS Stage 1 i Core"},
	StageExposeWORK:  {ID: StageExposeWORK, Number: 3, Name: "Przygotowanie WORK dla Windows Setup"},
	StageCopyPayload: {ID: StageCopyPayload, Number: 4, Name: "Aktualizacja plików i katalogu menu"},
	StageVerify:      {ID: StageVerify, Number: 5, Name: "Weryfikacja aktualizacji"},
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
	return e.runAsync(expected, false)
}

func (e *Engine) RunAsyncConfirmedDowngrade(expected installed.Target) <-chan Event {
	return e.runAsync(expected, true)
}

func (e *Engine) runAsync(expected installed.Target, allowDowngrade bool) <-chan Event {
	events := make(chan Event, 32)
	go func() {
		defer close(events)
		e.run(expected, allowDowngrade, events)
	}()
	return events
}

func (e *Engine) run(expected installed.Target, allowDowngrade bool, events chan<- Event) {
	var current installed.Target
	if err := e.runStage(events, StageRevalidate, func() error {
		var err error
		current, err = e.backend.RevalidateInstalledUSOS(expected)
		return err
	}); err != nil {
		return
	}
	payloadInfo, err := PayloadBuildInfo()
	if err != nil {
		e.finishWithError(events, fmt.Errorf("read installer payload build version: %w", err))
		return
	}
	e.log(events, fmt.Sprintf("VERSION media=%s installer=%s", current.BuildInfo.Display(), payloadInfo.Display()))
	if IsDowngrade(current.BuildInfo, payloadInfo) {
		if !allowDowngrade {
			e.finishWithError(events, fmt.Errorf("nośnik ma nowszą wersję (%s), instalator ma (%s) — cofnięcie wymaga wyraźnego potwierdzenia", current.BuildInfo.Display(), payloadInfo.Display()))
			return
		}
		e.log(events, fmt.Sprintf("DOWNGRADE CONFIRMED media=%s installer=%s", current.BuildInfo.Display(), payloadInfo.Display()))
	}

	if err := e.runStage(events, StageLegacyBoot, func() error {
		audit, restoreErr := e.backend.RestoreLegacyBoot(current)
		e.logLegacyAudit(events, audit)
		if restoreErr == nil {
			e.log(events, "LEGACY_BOOT GPT READBACK PASS: disk GUID, PARTUUID-y, typy, atrybuty, offsety i rozmiary bez zmian")
		}
		return restoreErr
	}); err != nil {
		return
	}
	if err := e.runStage(events, StageExposeWORK, func() error {
		migration, err := e.backend.MigrateWORKBootPath(current.Media)
		if err != nil {
			return fmt.Errorf("move WORK EFI/BOOT to EFI/%s: %w", workboot.Dir, err)
		}
		e.log(events, "WORK BOOT PATH MIGRATION "+migration.String())
		return e.backend.EnsureWORKVisible(current.Media)
	}); err != nil {
		return
	}
	if err := e.runCopy(events, current, payloadInfo.Display()); err != nil {
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

	e.log(events, "Aktualizacja zakończona: Legacy BIOS Stage 1/Core, pliki USOS i katalog menu odświeżone; obrazy systemów i dane użytkownika pozostały bez zmian")
	events <- Event{Kind: EventFinished, Verification: &report}
}

func (e *Engine) logLegacyAudit(events chan<- Event, audit legacyboot.Audit) {
	if audit.Stage1.BeforeSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT BEFORE component=stage1 sha256=%s expected=%s", audit.Stage1.BeforeSHA256, audit.Stage1.ExpectedSHA256))
	}
	if audit.Core.BeforeSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT BEFORE component=core sha256=%s expected=%s", audit.Core.BeforeSHA256, audit.Core.ExpectedSHA256))
	}
	if audit.CoreSlotZeroReadbackOK {
		e.log(events, "LEGACY_BOOT SLOT ZERO READBACK PASS: full 256 KiB Core slot is zero before new Core write")
	}
	if audit.Stage1.AfterSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT AFTER component=stage1 sha256=%s expected=%s changed=%s", audit.Stage1.AfterSHA256, audit.Stage1.ExpectedSHA256, yesNo(audit.Stage1.Changed)))
	}
	if audit.Core.AfterSHA256 != "" {
		e.log(events, fmt.Sprintf("LEGACY_BOOT AFTER component=core sha256=%s expected=%s changed=%s", audit.Core.AfterSHA256, audit.Core.ExpectedSHA256, yesNo(audit.Core.Changed)))
	}
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

func (e *Engine) runCopy(events chan<- Event, current installed.Target, payloadBuildID string) error {
	stage, _ := StageInfo(StageCopyPayload)
	caption := fmt.Sprintf("%d/%d - %s", stage.Number, StageCount, stage.Name)
	e.log(events, "START "+caption)
	events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateActive, ProgressKnown: true}

	beforeStatuses, err := e.backend.PayloadStatus(current.Media)
	if err != nil {
		return e.failCopy(events, caption, fmt.Errorf("read payload SHA-256 before update: %w", err))
	}
	before, err := auditPayloadBefore(beforeStatuses, func(message string) { e.log(events, message) })
	if err != nil {
		return e.failCopy(events, caption, fmt.Errorf("validate payload audit before update: %w", err))
	}

	err = e.backend.CopyInstallPayload(current.Media, func(done, total uint64) {
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
		return e.failCopy(events, caption, err)
	}

	afterStatuses, err := e.backend.PayloadStatus(current.Media)
	if err != nil {
		return e.failCopy(events, caption, fmt.Errorf("read payload SHA-256 after update: %w", err))
	}
	if err := auditPayloadAfter(before, afterStatuses, payloadBuildID, func(message string) { e.log(events, message) }); err != nil {
		return e.failCopy(events, caption, err)
	}

	e.log(events, "PASS "+caption)
	events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateSucceeded, ProgressKnown: true, Progress: 1}
	return nil
}

func (e *Engine) finishWithError(events chan<- Event, err error) {
	e.log(events, "FAIL "+err.Error())
	events <- Event{Kind: EventFinished, Err: err}
}

func (e *Engine) failCopy(events chan<- Event, caption string, err error) error {
	wrapped := fmt.Errorf("%s: %w", caption, err)
	e.log(events, "FAIL "+wrapped.Error())
	events <- Event{Kind: EventStage, StageID: StageCopyPayload, State: StateFailed, ProgressKnown: true, Err: wrapped}
	events <- Event{Kind: EventFinished, Err: wrapped}
	return wrapped
}

func (e *Engine) log(events chan<- Event, message string) {
	if err := e.logger.WriteLine(message); err != nil {
		events <- Event{Kind: EventLog, Message: message + " [błąd zapisu logu: " + err.Error() + "]"}
		return
	}
	events <- Event{Kind: EventLog, Message: message}
}
