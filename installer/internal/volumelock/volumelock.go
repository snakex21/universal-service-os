// Package volumelock retries taking an exclusive volume lock that another
// program is blocking (typically an Explorer window open on the USB drive),
// names the programs holding the volume, and lets the user retry or cancel.
//
// The platform code supplies one lock attempt. Its safety semantics stay
// unchanged: a volume is dismounted only after its lock succeeded (exclusive
// access, no other open handles); a busy volume is never force-dismounted.
package volumelock

import (
	"errors"
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// DefaultDelays are the pauses between automatic attempts: 5 attempts over
// 15 seconds. A holder that closes its handle on its own (an indexer, an
// antivirus scan, an Explorer thumbnail) is usually gone within a few seconds.
var DefaultDelays = []time.Duration{time.Second, 2 * time.Second, 4 * time.Second, 8 * time.Second}

// ErrBusy marks a lock attempt that failed because another program has the
// volume open. The platform code wraps its access-denied/sharing error in it.
var ErrBusy = errors.New("volume is in use by another program")

// InUseError is returned when the volume stayed busy after the automatic
// retries and the user did not choose to try again.
type InUseError struct {
	Volume   string   // volume GUID path
	Mount    string   // drive letter path ("J:\"), empty if none
	Holders  []string // program names from the Restart Manager, may be empty
	Attempts int
	Err      error // the last lock error
}

func (e *InUseError) Error() string {
	where := e.Volume
	if e.Mount != "" {
		where = e.Mount + " (" + e.Volume + ")"
	}
	holders := "unknown program"
	if len(e.Holders) > 0 {
		holders = strings.Join(e.Holders, ", ")
	}
	return fmt.Sprintf("volume %s is in use by: %s; exclusive lock denied after %d attempts: %v", where, holders, e.Attempts, e.Err)
}

func (e *InUseError) Unwrap() error { return e.Err }

// Message is the localized explanation shown with the Retry/Cancel choice.
func (e *InUseError) Message() string {
	if len(e.Holders) == 0 {
		return i18n.T("installer.volume_busy.unknown")
	}
	return i18n.T("installer.volume_busy.message", strings.Join(e.Holders, ", "))
}

// Prompt shows e to the user and reports whether to try again (Retry) or
// stop (Cancel). It blocks until the user decides.
type Prompt func(e *InUseError) bool

// Relay lets the UI install its prompt after the engines holding the
// backend were created. The zero value has no prompt: busy volumes fail.
type Relay struct {
	mu     sync.Mutex
	prompt Prompt
}

func (r *Relay) Set(p Prompt) {
	r.mu.Lock()
	r.prompt = p
	r.mu.Unlock()
}

// Ask forwards to the installed prompt; without one it answers Cancel.
func (r *Relay) Ask(e *InUseError) bool {
	if r == nil {
		return false
	}
	r.mu.Lock()
	p := r.prompt
	r.mu.Unlock()
	return p != nil && p(e)
}

// Target is one volume and the platform operations on it.
type Target[T any] struct {
	Volume  string
	Mount   string
	Lock    func() (T, error) // one attempt: open, lock, and only then dismount
	Holders func() []string   // programs with the volume open (best effort)
}

// Options are the retry policy and hooks; zero values mean defaults.
type Options struct {
	Delays []time.Duration     // nil: DefaultDelays; attempts = len(Delays)+1
	Sleep  func(time.Duration) // nil: time.Sleep
	Prompt Prompt              // nil: fail after the automatic attempts
	Log    func(string)        // nil: no log
}

// Acquire runs t.Lock until it succeeds, fails for another reason than
// ErrBusy, or the volume stays busy through every automatic attempt and the
// user cancels (or no prompt is installed). Retry starts a new round.
func Acquire[T any](t Target[T], o Options) (T, error) {
	delays := o.Delays
	if delays == nil {
		delays = DefaultDelays
	}
	sleep := o.Sleep
	if sleep == nil {
		sleep = time.Sleep
	}
	log := o.Log
	if log == nil {
		log = func(string) {}
	}
	name := t.Mount
	if name == "" {
		name = t.Volume
	}
	attempts := 0
	for {
		var last error
		for i := 0; ; i++ {
			v, err := t.Lock()
			attempts++
			if err == nil {
				if attempts > 1 {
					log(fmt.Sprintf("VOLUME LOCK %s acquired on attempt %d", name, attempts))
				}
				return v, nil
			}
			if !errors.Is(err, ErrBusy) {
				var zero T
				return zero, err
			}
			last = err
			if i == len(delays) {
				break
			}
			log(fmt.Sprintf("VOLUME LOCK %s busy (attempt %d): %v; retrying in %s", name, attempts, err, delays[i]))
			sleep(delays[i])
		}
		e := &InUseError{Volume: t.Volume, Mount: t.Mount, Attempts: attempts, Err: last}
		if t.Holders != nil {
			e.Holders = t.Holders()
		}
		log("VOLUME LOCK " + e.Error())
		if o.Prompt == nil || !o.Prompt(e) {
			log("VOLUME LOCK " + name + " cancelled")
			var zero T
			return zero, e
		}
		log("VOLUME LOCK " + name + " retry requested by the user")
	}
}
