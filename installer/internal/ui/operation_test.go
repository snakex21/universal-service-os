package ui

import (
	"errors"
	"math"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/repair"
	"github.com/snakex21/universal-service-os/installer/internal/uninstall"
)

// The progress screen lists exactly the stages each engine runs.
func TestStagesMatchEngines(t *testing.T) {
	want := map[operation]int{opInstall: install.StageCount, opUpdate: localupdate.StageCount, opRepair: repair.StageCount, opUninstall: uninstall.StageCount}
	for op, n := range want {
		defs := op.stages()
		if len(defs) != n {
			t.Fatalf("%s: %d stages, want %d", op.stageKey(), len(defs), n)
		}
		for i, d := range defs {
			if d.Number != i+1 || d.Total != n {
				t.Fatalf("%s: stage %d numbered %d/%d", op.stageKey(), i, d.Number, d.Total)
			}
		}
	}
}

func TestProgressModelOverall(t *testing.T) {
	m := newProgressModel(opUninstall.stages())
	if m.overall() != 0 {
		t.Fatal("fresh model must be at 0")
	}
	m.apply(opEvent{kind: eventStage, stageID: 1, state: stateActive})
	m.apply(opEvent{kind: eventStage, stageID: 1, state: stateSucceeded})
	m.apply(opEvent{kind: eventStage, stageID: 2, state: stateActive, progressKnown: true, progress: 0.5})
	if got := m.overall(); math.Abs(got-1.5/5) > 1e-9 {
		t.Fatalf("overall = %v", got)
	}
	if d, st, ok := m.current(); !ok || d.ID != 2 || st != stateActive {
		t.Fatalf("current = %v %v %v", d, st, ok)
	}
	m.apply(opEvent{kind: eventStage, stageID: 2, state: stateFailed, err: errors.New("boom")})
	if _, st, _ := m.current(); st != stateFailed || m.errs[2] == nil {
		t.Fatal("failed stage not tracked")
	}
}

func TestNormalizeUninstallCopiesReport(t *testing.T) {
	in := make(chan uninstall.Event, 2)
	report := &uninstall.VerificationReport{Items: []install.VerificationItem{{Name: "GPT", Match: true}}}
	in <- uninstall.Event{Kind: uninstall.EventFinished, Verification: report}
	close(in)
	out := <-normalizeUninstall(in)
	if out.kind != eventFinished || out.verification == nil || len(out.verification.Items) != 1 {
		t.Fatalf("got %+v", out)
	}
}

func TestRectHelpers(t *testing.T) {
	r := rect{0, 0, 100, 50}
	top, rest := r.cutTop(10)
	if top != (rect{0, 0, 100, 10}) || rest != (rect{0, 10, 100, 50}) {
		t.Fatal("cutTop")
	}
	if !r.intersect(rect{90, 40, 200, 200}).contains(95, 45) || !r.intersect(rect{200, 200, 300, 300}).empty() {
		t.Fatal("intersect")
	}
	if got := r.centered(20, 10); got != (rect{40, 20, 60, 30}) {
		t.Fatalf("centered = %v", got)
	}
}
