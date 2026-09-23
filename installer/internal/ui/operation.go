package ui

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

type operation int

const (
	opInstall operation = iota
	opUpdate
	opRepair
	opUninstall
)

func (o operation) name() string {
	switch o {
	case opUpdate:
		return i18n.T("installer.operation.update")
	case opRepair:
		return i18n.T("installer.operation.repair")
	case opUninstall:
		return i18n.T("installer.operation.uninstall")
	default:
		return i18n.T("installer.operation.install")
	}
}

func (o operation) stageKey() string {
	switch o {
	case opUpdate:
		return "update"
	case opRepair:
		return "repair"
	case opUninstall:
		return "uninstall"
	default:
		return "install"
	}
}

func (o operation) progressTitle() string {
	switch o {
	case opUpdate:
		return i18n.T("installer.update.title")
	case opRepair:
		return i18n.T("installer.repair.title")
	case opUninstall:
		return i18n.T("installer.uninstall.progress_title")
	default:
		return i18n.T("installer.install.progress_title")
	}
}

func (o operation) progressWarning() string {
	switch o {
	case opUpdate:
		return i18n.T("installer.update.progress_warning")
	case opRepair:
		return i18n.T("installer.repair.progress_warning")
	case opUninstall:
		return i18n.T("installer.uninstall.progress_warning")
	default:
		return i18n.T("installer.install.progress_warning")
	}
}

// stageDef is one step the operation's engine executes, in order.
type stageDef struct {
	ID       int
	Number   int
	Total    int
	Fallback string
}

// name translates a backend stage by operation and ID; the backend name is
// only shown if the catalog lacks the key (tests require every key).
func (o operation) stageName(s stageDef) string {
	key := fmt.Sprintf("installer.stage.%s.%d", o.stageKey(), s.ID)
	if _, ok := i18n.Lookup(i18n.Current(), key); !ok {
		return s.Fallback
	}
	return i18n.T(key)
}

// stages lists exactly the stages the operation's engine runs.
func (o operation) stages() []stageDef {
	var defs []stageDef
	switch o {
	case opInstall:
		for _, stage := range install.Stages() {
			defs = append(defs, stageDef{ID: int(stage.ID), Number: stage.Number, Total: install.StageCount, Fallback: stage.Name})
		}
	case opUpdate:
		for id := localupdate.StageID(1); id <= localupdate.StageCount; id++ {
			if stage, ok := localupdate.StageInfo(id); ok {
				defs = append(defs, stageDef{ID: int(stage.ID), Number: stage.Number, Total: localupdate.StageCount, Fallback: stage.Name})
			}
		}
	case opRepair:
		for id := repair.StageID(1); id <= repair.StageCount; id++ {
			if stage, ok := repair.StageInfo(id); ok {
				defs = append(defs, stageDef{ID: int(stage.ID), Number: stage.Number, Total: repair.StageCount, Fallback: stage.Name})
			}
		}
	case opUninstall:
		for id := uninstall.StageID(1); id <= uninstall.StageCount; id++ {
			if stage, ok := uninstall.StageInfo(id); ok {
				defs = append(defs, stageDef{ID: int(stage.ID), Number: stage.Number, Total: uninstall.StageCount, Fallback: stage.Name})
			}
		}
	}
	return defs
}

type eventKind int

const (
	eventStage eventKind = iota + 1
	eventLog
	eventFinished
)

type stageState int

const (
	statePending stageState = iota
	stateActive
	stateSucceeded
	stateFailed
)

// opEvent is the engine-independent progress event the progress screen uses.
type opEvent struct {
	kind          eventKind
	stageID       int
	state         stageState
	message       string
	progressKnown bool
	progress      float64
	err           error
	verification  *install.VerificationReport
}

func normalizeInstall(events <-chan install.Event) <-chan opEvent {
	out := make(chan opEvent, 32)
	go func() {
		defer close(out)
		for e := range events {
			ev := opEvent{stageID: int(e.StageID), message: e.Message, progressKnown: e.ProgressKnown, progress: e.Progress, err: e.Err, verification: e.Verification}
			switch e.Kind {
			case install.EventStage:
				ev.kind = eventStage
			case install.EventLog:
				ev.kind = eventLog
			case install.EventFinished:
				ev.kind = eventFinished
			}
			switch e.State {
			case install.StateActive:
				ev.state = stateActive
			case install.StateSucceeded:
				ev.state = stateSucceeded
			case install.StateFailed:
				ev.state = stateFailed
			}
			out <- ev
		}
	}()
	return out
}

func normalizeUpdate(events <-chan localupdate.Event) <-chan opEvent {
	out := make(chan opEvent, 32)
	go func() {
		defer close(out)
		for e := range events {
			ev := opEvent{stageID: int(e.StageID), message: e.Message, progressKnown: e.ProgressKnown, progress: e.Progress, err: e.Err, verification: e.Verification}
			switch e.Kind {
			case localupdate.EventStage:
				ev.kind = eventStage
			case localupdate.EventLog:
				ev.kind = eventLog
			case localupdate.EventFinished:
				ev.kind = eventFinished
			}
			switch e.State {
			case localupdate.StateActive:
				ev.state = stateActive
			case localupdate.StateSucceeded:
				ev.state = stateSucceeded
			case localupdate.StateFailed:
				ev.state = stateFailed
			}
			out <- ev
		}
	}()
	return out
}

func normalizeRepair(events <-chan repair.Event) <-chan opEvent {
	out := make(chan opEvent, 32)
	go func() {
		defer close(out)
		for e := range events {
			ev := opEvent{stageID: int(e.StageID), message: e.Message, progressKnown: e.ProgressKnown, progress: e.Progress, err: e.Err, verification: e.Verification}
			switch e.Kind {
			case repair.EventStage:
				ev.kind = eventStage
			case repair.EventLog:
				ev.kind = eventLog
			case repair.EventFinished:
				ev.kind = eventFinished
			}
			switch e.State {
			case repair.StateActive:
				ev.state = stateActive
			case repair.StateSucceeded:
				ev.state = stateSucceeded
			case repair.StateFailed:
				ev.state = stateFailed
			}
			out <- ev
		}
	}()
	return out
}

func normalizeUninstall(events <-chan uninstall.Event) <-chan opEvent {
	out := make(chan opEvent, 32)
	go func() {
		defer close(out)
		for e := range events {
			var verification *install.VerificationReport
			if e.Verification != nil {
				verification = &install.VerificationReport{Items: append([]install.VerificationItem(nil), e.Verification.Items...)}
			}
			ev := opEvent{stageID: int(e.StageID), message: e.Message, err: e.Err, verification: verification}
			switch e.Kind {
			case uninstall.EventStage:
				ev.kind = eventStage
			case uninstall.EventLog:
				ev.kind = eventLog
			case uninstall.EventFinished:
				ev.kind = eventFinished
			}
			switch e.State {
			case uninstall.StateActive:
				ev.state = stateActive
			case uninstall.StateSucceeded:
				ev.state = stateSucceeded
			case uninstall.StateFailed:
				ev.state = stateFailed
			}
			out <- ev
		}
	}()
	return out
}

// progressModel tracks stage states; it is UI-independent so it can be tested.
type progressModel struct {
	defs     []stageDef
	states   map[int]stageState
	progress map[int]float64
	known    map[int]bool
	errs     map[int]error
	finished bool
}

func newProgressModel(defs []stageDef) *progressModel {
	return &progressModel{defs: defs, states: map[int]stageState{}, progress: map[int]float64{}, known: map[int]bool{}, errs: map[int]error{}}
}

func (m *progressModel) apply(e opEvent) {
	switch e.kind {
	case eventStage:
		m.states[e.stageID] = e.state
		m.known[e.stageID] = e.progressKnown
		switch e.state {
		case stateActive:
			if e.progressKnown {
				m.progress[e.stageID] = e.progress
			}
		case stateSucceeded:
			m.progress[e.stageID] = 1
		case stateFailed:
			m.errs[e.stageID] = e.err
		}
	case eventFinished:
		m.finished = true
	}
}

// overall is the fraction of the operation done: finished stages plus the
// measured part of the active stage.
func (m *progressModel) overall() float64 {
	if len(m.defs) == 0 {
		return 0
	}
	done := 0.0
	for _, d := range m.defs {
		switch m.states[d.ID] {
		case stateSucceeded:
			done++
		case stateActive:
			if m.known[d.ID] {
				done += m.progress[d.ID]
			}
		}
	}
	return done / float64(len(m.defs))
}

// current returns the active (or failed) stage, if any.
func (m *progressModel) current() (stageDef, stageState, bool) {
	for _, d := range m.defs {
		if s := m.states[d.ID]; s == stateActive || s == stateFailed {
			return d, s, true
		}
	}
	return stageDef{}, statePending, false
}
