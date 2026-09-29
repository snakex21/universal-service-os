package components

import (
	"context"
	"errors"
	"fmt"
)

// Source is where a component comes from.
type Source int

const (
	SourceDownload Source = iota // from the installer's GitHub release
	SourceLocal                  // "I already have the file"
	SourceSkip
)

// Choice is the user's decision for one component.
type Choice struct {
	ID        ID
	Source    Source
	LocalPath string
	// StoreOnly keeps the verified zip on DATA (Programs\USOS\XP) instead
	// of installing it: the second XP language when both were chosen.
	StoreOnly bool
}

// Installer puts a verified component zip onto the stick (winhost: the WinPE
// donor code of install/update/repair and install-xp-package.ps1).
type Installer interface {
	InstallComponent(id ID, zipPath string, storeOnly bool, log func(string)) error
}

// Phase of one component in a run.
type Phase int

const (
	PhaseWaiting Phase = iota
	PhaseChecksums
	PhaseDownload
	PhaseVerify
	PhaseInstall
	PhaseDone
	PhaseSkipped
	PhaseFailed
)

// Event reports progress; Progress is set during PhaseDownload.
type Event struct {
	ID       ID
	Phase    Phase
	Progress Progress
	Err      error
}

// Runner gets, verifies and installs the chosen components one by one.
type Runner struct {
	Release    Release
	Downloader *Downloader
	Installer  Installer
	Log        func(string)
}

func (r *Runner) log(format string, args ...any) {
	if r.Log != nil {
		r.Log(fmt.Sprintf(format, args...))
	}
}

// Run processes choices in order and returns the error of each (nil = done
// or skipped). A failure of one component does not stop the others.
func (r *Runner) Run(ctx context.Context, choices []Choice, emit func(Event)) map[ID]error {
	if emit == nil {
		emit = func(Event) {}
	}
	results := map[ID]error{}
	var sums map[string]string
	var sumsErr error
	sumsTried := false
	// getSums fetches the release's SHA256SUMS once it is needed; a download
	// requires it (and retries a failed fetch), a local file only uses it
	// when it is reachable (one quick attempt).
	getSums := func(required bool) (map[string]string, error) {
		if sums != nil {
			return sums, nil
		}
		if !sumsTried || required {
			sumsTried = true
			if r.Downloader == nil || !r.Release.CanDownload() {
				sumsErr = errors.New("this installer build does not know its release")
			} else {
				attempts := 0
				if !required {
					attempts = 1
				}
				sums, sumsErr = r.Downloader.FetchSums(ctx, attempts)
			}
			if sumsErr != nil {
				r.log("[COMPONENTS] SHA256SUMS of %s not available: %v", r.Release.Tag, sumsErr)
			} else {
				r.log("[COMPONENTS] SHA256SUMS of %s: %d entries", r.Release.Tag, len(sums))
			}
		}
		if required && sums == nil {
			return nil, fmt.Errorf("SHA256SUMS: %w", sumsErr)
		}
		return sums, nil
	}
	for _, choice := range choices {
		id := choice.ID
		asset := r.Release.Asset(id)
		if choice.Source == SourceSkip {
			r.log("[COMPONENTS] %s skipped", id)
			emit(Event{ID: id, Phase: PhaseSkipped})
			results[id] = nil
			continue
		}
		fail := func(err error) {
			r.log("[COMPONENTS] %s FAILED: %v", id, err)
			emit(Event{ID: id, Phase: PhaseFailed, Err: err})
			results[id] = err
		}
		if asset == "" {
			fail(errors.New("this installer build has no version, so the asset name is unknown"))
			continue
		}
		var zipPath string
		switch choice.Source {
		case SourceDownload:
			emit(Event{ID: id, Phase: PhaseChecksums})
			list, err := getSums(true)
			if err != nil {
				fail(err)
				continue
			}
			emit(Event{ID: id, Phase: PhaseDownload})
			zipPath, err = r.Downloader.Fetch(ctx, asset, list, func(p Progress) { emit(Event{ID: id, Phase: PhaseDownload, Progress: p}) })
			if err != nil {
				fail(err)
				continue
			}
		case SourceLocal:
			emit(Event{ID: id, Phase: PhaseVerify})
			// Offline is fine: the compiled list (and a SHA256SUMS next to
			// the file) still verify it.
			list, _ := getSums(false)
			if err := VerifyLocal(choice.LocalPath, asset, r.Release, list); err != nil {
				fail(err)
				continue
			}
			r.log("[COMPONENTS] %s: local file %s verified", id, choice.LocalPath)
			zipPath = choice.LocalPath
		}
		emit(Event{ID: id, Phase: PhaseInstall})
		if err := r.Installer.InstallComponent(id, zipPath, choice.StoreOnly, r.Log); err != nil {
			fail(err)
			continue
		}
		r.log("[COMPONENTS] %s installed", id)
		emit(Event{ID: id, Phase: PhaseDone})
		results[id] = nil
	}
	return results
}
