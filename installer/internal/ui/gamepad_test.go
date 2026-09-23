package ui

import (
	"testing"
	"time"
)

func TestStickDirRadialDeadzone(t *testing.T) {
	cases := []struct {
		x, y int16
		want navDir
	}{
		{0, 0, dirNone},
		{7000, 0, dirNone},    // inside the deadzone
		{5000, 5000, dirNone}, // 7071 long: a diagonal inside the circle stays dead
		{6000, 6000, dirUp},   // 8485 long: out; |y| == |x| resolves vertically
		{9000, 0, dirRight},
		{-9000, 1000, dirLeft},
		{1000, 20000, dirUp}, // XInput Y grows upwards
		{-2000, -20000, dirDown},
	}
	for _, c := range cases {
		if got := stickDir(c.x, c.y, leftThumbDeadzone, dirNone); got != c.want {
			t.Errorf("stickDir(%d,%d) = %d, want %d", c.x, c.y, got, c.want)
		}
	}
}

func TestStickDirHysteresis(t *testing.T) {
	// Falling slightly back inside the deadzone keeps the direction...
	if got := stickDir(7000, 0, leftThumbDeadzone, dirRight); got != dirRight {
		t.Fatalf("held right released too early: %d", got)
	}
	// ...but not below the release threshold.
	if got := stickDir(5000, 0, leftThumbDeadzone, dirRight); got != dirNone {
		t.Fatalf("held right not released: %d", got)
	}
	// A push that curves up to 50 degrees stays right; 65 degrees flips.
	if got := stickDir(12000, 14000, leftThumbDeadzone, dirRight); got != dirRight {
		t.Fatalf("50 degree curve flipped to %d", got)
	}
	if got := stickDir(8000, 17000, leftThumbDeadzone, dirRight); got != dirUp {
		t.Fatalf("65 degree push stayed %d", got)
	}
}

func TestStickAxis(t *testing.T) {
	if stickAxis(8000, rightThumbDeadzone) != 0 {
		t.Fatal("inside the deadzone must be 0")
	}
	if got := stickAxis(thumbMax, rightThumbDeadzone); got != 1 {
		t.Fatalf("full up = %v", got)
	}
	if got := stickAxis(-32768, rightThumbDeadzone); got != -1 {
		t.Fatalf("full down = %v", got)
	}
	half := stickAxis(int16(rightThumbDeadzone+(thumbMax-rightThumbDeadzone)/2), rightThumbDeadzone)
	if half < 0.24 || half > 0.26 {
		t.Fatalf("half travel = %v, want ~0.25 (squared curve)", half)
	}
}

func TestRepeaterTiming(t *testing.T) {
	var r repeater
	t0 := time.Unix(1000, 0)
	at := func(ms int) time.Time { return t0.Add(time.Duration(ms) * time.Millisecond) }
	fires := 0
	for ms := 0; ms <= 1000; ms += 10 {
		if r.update(dirDown, at(ms)) {
			fires++
		}
	}
	// t=0, then 400, 490, 580, 670, 760, 850, 940.
	if fires != 8 {
		t.Fatalf("held 1 s: %d moves, want 8", fires)
	}
	if r.update(dirNone, at(1010)) {
		t.Fatal("release fired")
	}
	if !r.update(dirDown, at(1020)) {
		t.Fatal("a new press must fire at once")
	}
	if !r.update(dirLeft, at(1030)) {
		t.Fatal("a direction change must fire at once")
	}
	// A stalled poll catches up with one move, not a burst.
	if !r.update(dirLeft, at(2000)) {
		t.Fatal("no repeat after a stall")
	}
	if r.update(dirLeft, at(2010)) {
		t.Fatal("burst after a stall")
	}
}

func kinds(events []padEvent) []padKind {
	out := make([]padKind, len(events))
	for i, e := range events {
		out[i] = e.kind
	}
	return out
}

func TestPadNavEdges(t *testing.T) {
	var p padNav
	now := time.Unix(0, 0)
	// A held on the first sample (pad just connected) does not fire.
	if ev, _ := p.step(padSample{buttons: padA}, now); len(ev) != 0 {
		t.Fatalf("held button fired on connect: %v", ev)
	}
	if ev, _ := p.step(padSample{buttons: padA}, now.Add(20*time.Millisecond)); len(ev) != 0 {
		t.Fatalf("held button repeated: %v", ev)
	}
	p.step(padSample{}, now.Add(40*time.Millisecond))
	ev, _ := p.step(padSample{buttons: padA | padStart}, now.Add(60*time.Millisecond))
	if got := kinds(ev); len(got) != 2 || got[0] != padActivate || got[1] != padPrimary {
		t.Fatalf("A+Start = %v", got)
	}
	ev, _ = p.step(padSample{buttons: padB | padLB | padRB}, now.Add(80*time.Millisecond))
	if got := kinds(ev); len(got) != 3 || got[0] != padCancel || got[1] != padPrevSection || got[2] != padNextSection {
		t.Fatalf("B+LB+RB = %v", got)
	}
}

func TestPadNavDirections(t *testing.T) {
	var p padNav
	now := time.Unix(0, 0)
	p.step(padSample{}, now)
	ev, _ := p.step(padSample{ly: 20000}, now.Add(16*time.Millisecond))
	if len(ev) != 1 || ev[0].kind != padMove || ev[0].dir != dirUp {
		t.Fatalf("stick up = %v", ev)
	}
	// The D-pad overrides the stick.
	ev, _ = p.step(padSample{ly: 20000, buttons: padDpadRight}, now.Add(32*time.Millisecond))
	if len(ev) != 1 || ev[0].dir != dirRight {
		t.Fatalf("dpad right over stick up = %v", ev)
	}
	_, scroll := p.step(padSample{ry: -thumbMax}, now.Add(48*time.Millisecond))
	if scroll != -1 {
		t.Fatalf("right stick down scroll = %v", scroll)
	}
}

func TestSpatialPick(t *testing.T) {
	// The mode screen: a 2x2 card grid under a header with two buttons.
	install := rect{0, 100, 400, 240}
	update := rect{416, 100, 816, 240}
	repair := rect{0, 256, 400, 396}
	uninstall := rect{416, 256, 816, 396}
	refresh := rect{600, 10, 700, 44}
	lang := rect{710, 10, 816, 44}
	all := []rect{install, update, repair, uninstall, refresh, lang}
	cases := []struct {
		from rect
		dir  navDir
		want int
	}{
		{install, dirRight, 1},
		{install, dirDown, 2},
		{update, dirDown, 3},
		{uninstall, dirLeft, 2},
		{repair, dirUp, 0},
		{update, dirUp, 4}, // both header buttons are straight above: the first wins
		{install, dirLeft, -1},
		{repair, dirDown, -1},
	}
	for _, c := range cases {
		if got := spatialPick(c.from, all, c.dir); got != c.want {
			t.Errorf("from %v dir %d = %d, want %d", c.from, c.dir, got, c.want)
		}
	}
}

func TestSectionTarget(t *testing.T) {
	ids := []string{"list", "action.back", "action.next", "header.refresh", "header.lang"}
	if got := sectionTarget(ids, "list", 1); got != "action.back" {
		t.Fatalf("RB from list = %q", got)
	}
	if got := sectionTarget(ids, "action.next", 1); got != "header.refresh" {
		t.Fatalf("RB from actions = %q", got)
	}
	if got := sectionTarget(ids, "header.lang", 1); got != "list" {
		t.Fatalf("RB wraps = %q", got)
	}
	if got := sectionTarget(ids, "list", -1); got != "header.refresh" {
		t.Fatalf("LB from list = %q", got)
	}
	// The mode screen has no action bar: RB skips it.
	if got := sectionTarget([]string{"mode.install", "header.lang"}, "mode.install", 1); got != "header.lang" {
		t.Fatalf("RB without an action bar = %q", got)
	}
	if got := sectionTarget([]string{"log.toggle"}, "log.toggle", 1); got != "" {
		t.Fatalf("single section = %q", got)
	}
	if padSection("confirm.go") != sectionActions || padSection("confirm.input") != sectionBody {
		t.Fatal("confirm widgets misclassified")
	}
}
