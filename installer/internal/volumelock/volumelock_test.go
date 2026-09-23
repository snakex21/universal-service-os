package volumelock

import (
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// fakeLocker is busy for the first `busy` attempts, then locks. It records
// that a dismount only ever happens after a successful lock.
type fakeLocker struct {
	busy, calls, dismounts int
	other                  error
	holderCalls            int
}

func (f *fakeLocker) lock() (string, error) {
	f.calls++
	if f.other != nil {
		return "", f.other
	}
	if f.calls <= f.busy {
		return "", fmt.Errorf("FSCTL_LOCK_VOLUME J:: Access is denied.: %w", ErrBusy)
	}
	f.dismounts++ // lock succeeded -> dismount is safe
	return "handle", nil
}

func (f *fakeLocker) holders() []string { f.holderCalls++; return []string{"Windows Explorer"} }

func target(f *fakeLocker) Target[string] {
	return Target[string]{Volume: `\\?\Volume{1}\`, Mount: `J:\`, Lock: f.lock, Holders: f.holders}
}

func recordSleep(slept *[]time.Duration) func(time.Duration) {
	return func(d time.Duration) { *slept = append(*slept, d) }
}

func TestDefaultPolicyIsFiveAttemptsOverFifteenSeconds(t *testing.T) {
	var total time.Duration
	for _, d := range DefaultDelays {
		total += d
	}
	if len(DefaultDelays)+1 != 5 || total != 15*time.Second {
		t.Fatalf("attempts=%d total=%s", len(DefaultDelays)+1, total)
	}
}

func TestSucceedsFirstTimeWithoutSleeping(t *testing.T) {
	f := &fakeLocker{}
	var slept []time.Duration
	v, err := Acquire(target(f), Options{Sleep: recordSleep(&slept)})
	if err != nil || v != "handle" || f.calls != 1 || len(slept) != 0 || f.holderCalls != 0 {
		t.Fatalf("v=%q err=%v calls=%d slept=%v holders=%d", v, err, f.calls, slept, f.holderCalls)
	}
}

func TestTransientHolderIsRetriedWithBackoff(t *testing.T) {
	f := &fakeLocker{busy: 1} // the "invisible holder, one retry" case
	var slept []time.Duration
	var logs []string
	v, err := Acquire(target(f), Options{Sleep: recordSleep(&slept), Log: func(s string) { logs = append(logs, s) }})
	if err != nil || v != "handle" || f.calls != 2 || len(slept) != 1 || slept[0] != time.Second {
		t.Fatalf("v=%q err=%v calls=%d slept=%v", v, err, f.calls, slept)
	}
	if f.dismounts != 1 || !strings.Contains(strings.Join(logs, "\n"), "acquired on attempt 2") {
		t.Fatalf("dismounts=%d logs=%v", f.dismounts, logs)
	}
}

func TestPersistentHolderFailsAfterFiveAttemptsWithoutDismount(t *testing.T) {
	f := &fakeLocker{busy: 1000}
	var slept []time.Duration
	_, err := Acquire(target(f), Options{Sleep: recordSleep(&slept)})
	var busy *InUseError
	if !errors.As(err, &busy) || !errors.Is(err, ErrBusy) {
		t.Fatalf("err=%v", err)
	}
	if f.calls != 5 || busy.Attempts != 5 || fmt.Sprint(slept) != fmt.Sprint(DefaultDelays) {
		t.Fatalf("calls=%d attempts=%d slept=%v", f.calls, busy.Attempts, slept)
	}
	if f.dismounts != 0 {
		t.Fatal("a busy volume must never be dismounted")
	}
	if len(busy.Holders) != 1 || busy.Holders[0] != "Windows Explorer" || busy.Mount != `J:\` {
		t.Fatalf("holders=%v mount=%q", busy.Holders, busy.Mount)
	}
	if !strings.Contains(busy.Error(), "Windows Explorer") || !strings.Contains(busy.Error(), "5 attempts") {
		t.Fatal(busy.Error())
	}
}

func TestRetryAfterPromptStartsANewRound(t *testing.T) {
	f := &fakeLocker{busy: 7} // round 1: 5 busy; round 2: 2 busy, then success
	var slept []time.Duration
	prompts := 0
	v, err := Acquire(target(f), Options{Sleep: recordSleep(&slept), Prompt: func(e *InUseError) bool {
		prompts++
		if e.Attempts != 5 || len(e.Holders) != 1 {
			t.Errorf("prompt got attempts=%d holders=%v", e.Attempts, e.Holders)
		}
		return true
	}})
	if err != nil || v != "handle" || prompts != 1 || f.calls != 8 || f.dismounts != 1 {
		t.Fatalf("v=%q err=%v prompts=%d calls=%d dismounts=%d", v, err, prompts, f.calls, f.dismounts)
	}
	if len(slept) != 4+2 {
		t.Fatalf("slept=%v", slept)
	}
}

func TestCancelAtPromptReturnsInUseError(t *testing.T) {
	f := &fakeLocker{busy: 1000}
	prompts := 0
	_, err := Acquire(target(f), Options{Sleep: func(time.Duration) {}, Prompt: func(*InUseError) bool { prompts++; return prompts < 2 }})
	var busy *InUseError
	if !errors.As(err, &busy) || prompts != 2 || f.calls != 10 || busy.Attempts != 10 {
		t.Fatalf("err=%v prompts=%d calls=%d", err, prompts, f.calls)
	}
}

func TestOtherErrorsAreNotRetried(t *testing.T) {
	f := &fakeLocker{other: errors.New("open volume: The device is not ready.")}
	_, err := Acquire(target(f), Options{Sleep: func(time.Duration) { t.Fatal("slept") }, Prompt: func(*InUseError) bool { t.Fatal("prompted"); return false }})
	var busy *InUseError
	if err == nil || errors.As(err, &busy) || f.calls != 1 {
		t.Fatalf("err=%v calls=%d", err, f.calls)
	}
}

func TestRelayWithoutPromptCancels(t *testing.T) {
	var r Relay
	if r.Ask(&InUseError{}) {
		t.Fatal("empty relay must cancel")
	}
	r.Set(func(*InUseError) bool { return true })
	if !r.Ask(&InUseError{}) {
		t.Fatal("installed prompt not used")
	}
	var nilRelay *Relay
	if nilRelay.Ask(&InUseError{}) {
		t.Fatal("nil relay must cancel")
	}
}

func TestLocalizedMessageNamesHolders(t *testing.T) {
	previous := i18n.Current()
	defer i18n.SetLanguage(previous)
	i18n.SetLanguage("pl")
	e := &InUseError{Holders: []string{"Eksplorator Windows"}}
	if got := e.Message(); got != "Nośnik jest używany przez: Eksplorator Windows. Zamknij okna z tym nośnikiem i kliknij Ponów." {
		t.Fatal(got)
	}
	if (&InUseError{}).Message() == e.Message() {
		t.Fatal("unknown-holder message missing")
	}
}
