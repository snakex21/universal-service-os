package components

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Progress of one download. Total is 0 while unknown.
type Progress struct {
	Asset       string
	Done, Total int64
	BytesPerSec float64
	// Attempt counts from 1; above 1 the download resumed after a network error.
	Attempt int
}

// Downloader fetches release assets into Dir (a folder on the PC, never the
// stick). An interrupted download stays as <asset>.part and continues with an
// HTTP Range request on the next attempt, also after a later Retry.
type Downloader struct {
	Client  *http.Client
	Release Release
	Dir     string
	// Attempts per Fetch call (network errors); 0 means 4.
	Attempts   int
	RetryDelay time.Duration
	Log        func(string)
}

// DefaultDir is the download folder: %TEMP%\USOS-components\<tag>.
func DefaultDir(r Release) string {
	tag := r.Tag
	if tag == "" {
		tag = "dev"
	}
	return filepath.Join(os.TempDir(), "USOS-components", tag)
}

func (d *Downloader) client() *http.Client {
	if d.Client != nil {
		return d.Client
	}
	// No overall timeout (the WinPE donor is ~460 MB); stalls are caught by
	// the transport's header timeout and the idle watchdog in copyBody.
	return &http.Client{Transport: &http.Transport{Proxy: http.ProxyFromEnvironment, ResponseHeaderTimeout: 30 * time.Second, TLSHandshakeTimeout: 20 * time.Second}}
}

func (d *Downloader) log(format string, args ...any) {
	if d.Log != nil {
		d.Log(fmt.Sprintf(format, args...))
	}
}

// FetchSums downloads and parses the release's SHA256SUMS; attempts 0 means
// the Downloader's default.
func (d *Downloader) FetchSums(ctx context.Context, attempts int) (map[string]string, error) {
	if !d.Release.CanDownload() {
		return nil, errors.New("this installer build does not know its release (development build)")
	}
	if attempts <= 0 {
		attempts = d.attempts()
	}
	var lastErr error
	for attempt := 1; attempt <= attempts; attempt++ {
		if attempt > 1 && !d.sleep(ctx) {
			return nil, ctx.Err()
		}
		sums, err := d.fetchSumsOnce(ctx)
		if err == nil {
			return sums, nil
		}
		lastErr = err
		var status httpStatusError
		if errors.As(err, &status) && status.code == http.StatusNotFound {
			break
		}
	}
	return nil, lastErr
}

func (d *Downloader) fetchSumsOnce(ctx context.Context) (map[string]string, error) {
	url := d.Release.URL(SumsAsset)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := d.client().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, httpStatusError{url, resp.StatusCode}
	}
	return ParseSums(io.LimitReader(resp.Body, 1<<20))
}

type httpStatusError struct {
	url  string
	code int
}

func (e httpStatusError) Error() string { return fmt.Sprintf("%s: HTTP %d", e.url, e.code) }

func (d *Downloader) attempts() int {
	if d.Attempts > 0 {
		return d.Attempts
	}
	return 4
}

func (d *Downloader) sleep(ctx context.Context) bool {
	delay := d.RetryDelay
	if delay == 0 {
		delay = 3 * time.Second
	}
	select {
	case <-ctx.Done():
		return false
	case <-time.After(delay):
		return true
	}
}

// Fetch downloads asset (resuming a .part file), verifies it with Check
// against sums and the compiled list and returns the verified file. A file
// that fails verification is deleted.
func (d *Downloader) Fetch(ctx context.Context, asset string, sums map[string]string, progress func(Progress)) (string, error) {
	if err := os.MkdirAll(d.Dir, 0o755); err != nil {
		return "", err
	}
	final := filepath.Join(d.Dir, asset)
	if _, err := os.Stat(final); err == nil {
		// Downloaded earlier (same release): reuse only when it still verifies.
		if sum, err := HashFile(final); err == nil && Check(asset, sum, d.Release.Pinned, sums) == nil {
			d.log("[COMPONENTS] %s already downloaded and verified (%s)", asset, sum)
			return final, nil
		}
		_ = os.Remove(final)
	}
	part := final + ".part"
	var lastErr error
	for attempt := 1; attempt <= d.attempts(); attempt++ {
		if attempt > 1 {
			d.log("[COMPONENTS] %s: %v; retrying (attempt %d)", asset, lastErr, attempt)
			if !d.sleep(ctx) {
				return "", ctx.Err()
			}
		}
		complete, err := d.fetchOnce(ctx, asset, part, attempt, progress)
		if err == nil && complete {
			break
		}
		lastErr = err
		if ctx.Err() != nil {
			return "", ctx.Err()
		}
		var status httpStatusError
		if errors.As(err, &status) && status.code >= 400 && status.code < 500 && status.code != http.StatusRequestedRangeNotSatisfiable && status.code != http.StatusTooManyRequests {
			return "", err
		}
		if attempt == d.attempts() {
			return "", fmt.Errorf("download %s: %w (the partial file is kept; Retry resumes it)", asset, err)
		}
	}
	sum, err := HashFile(part)
	if err != nil {
		return "", err
	}
	if err := Check(asset, sum, d.Release.Pinned, sums); err != nil {
		_ = os.Remove(part)
		return "", err
	}
	if err := os.Rename(part, final); err != nil {
		return "", err
	}
	d.log("[COMPONENTS] %s downloaded, SHA-256 %s verified", asset, sum)
	return final, nil
}

// fetchOnce continues part from its current size. complete=true means the
// server delivered the whole remainder.
func (d *Downloader) fetchOnce(ctx context.Context, asset, part string, attempt int, progress func(Progress)) (bool, error) {
	var have int64
	if info, err := os.Stat(part); err == nil {
		have = info.Size()
	}
	url := d.Release.URL(asset)
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return false, err
	}
	if have > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(have, 10)+"-")
	}
	resp, err := d.client().Do(req)
	if err != nil {
		return false, err
	}
	defer resp.Body.Close()
	var total int64
	flags := os.O_CREATE | os.O_WRONLY
	switch resp.StatusCode {
	case http.StatusOK:
		have = 0 // no range support: start over
		flags |= os.O_TRUNC
		total = resp.ContentLength
	case http.StatusPartialContent:
		start, size, ok := parseContentRange(resp.Header.Get("Content-Range"))
		if !ok || start != have {
			return false, fmt.Errorf("%s: unexpected Content-Range %q", url, resp.Header.Get("Content-Range"))
		}
		total = size
		flags |= os.O_APPEND
	case http.StatusRequestedRangeNotSatisfiable:
		// The .part already holds everything (or is longer than the file):
		// let verification decide; a bad file is deleted and fetched anew.
		if _, size, ok := parseContentRange(resp.Header.Get("Content-Range")); ok && size == have {
			return true, nil
		}
		_ = os.Remove(part)
		return false, httpStatusError{url, resp.StatusCode}
	default:
		return false, httpStatusError{url, resp.StatusCode}
	}
	if total < 0 {
		total = 0
	}
	file, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return false, err
	}
	written, copyErr := copyWithProgress(ctx, file, resp.Body, func(done int64, rate float64) {
		if progress != nil {
			progress(Progress{Asset: asset, Done: have + done, Total: total, BytesPerSec: rate, Attempt: attempt})
		}
	})
	closeErr := file.Close()
	if copyErr != nil {
		return false, copyErr
	}
	if closeErr != nil {
		return false, closeErr
	}
	if total > 0 && have+written != total {
		return false, fmt.Errorf("%s: connection closed at %d of %d bytes", url, have+written, total)
	}
	return true, nil
}

// parseContentRange reads "bytes START-END/SIZE" or "bytes */SIZE".
func parseContentRange(value string) (start, size int64, ok bool) {
	value = strings.TrimSpace(value)
	if !strings.HasPrefix(value, "bytes ") {
		return 0, 0, false
	}
	span, sizeText, found := strings.Cut(strings.TrimPrefix(value, "bytes "), "/")
	if !found {
		return 0, 0, false
	}
	size, err := strconv.ParseInt(sizeText, 10, 64)
	if err != nil {
		return 0, 0, false
	}
	if span == "*" {
		return 0, size, true
	}
	first, _, found := strings.Cut(span, "-")
	if !found {
		return 0, 0, false
	}
	start, err = strconv.ParseInt(first, 10, 64)
	return start, size, err == nil
}

// idleTimeout aborts a download that receives nothing for this long, so a
// dead connection turns into a resumable error instead of a hang.
var idleTimeout = 45 * time.Second

func copyWithProgress(ctx context.Context, dst io.Writer, src io.Reader, report func(done int64, rate float64)) (int64, error) {
	buf := make([]byte, 256<<10)
	var done int64
	started := time.Now()
	windowStart, windowBytes := started, int64(0)
	rate := 0.0
	lastReport := time.Time{}
	type result struct {
		n   int
		err error
	}
	for {
		if err := ctx.Err(); err != nil {
			return done, err
		}
		ch := make(chan result, 1)
		go func() {
			n, err := src.Read(buf)
			ch <- result{n, err}
		}()
		var r result
		select {
		case r = <-ch:
		case <-ctx.Done():
			return done, ctx.Err()
		case <-time.After(idleTimeout):
			return done, fmt.Errorf("no data for %s", idleTimeout)
		}
		if r.n > 0 {
			if _, err := dst.Write(buf[:r.n]); err != nil {
				return done, err
			}
			done += int64(r.n)
			windowBytes += int64(r.n)
			now := time.Now()
			if elapsed := now.Sub(windowStart); elapsed >= 500*time.Millisecond {
				current := float64(windowBytes) / elapsed.Seconds()
				if rate == 0 {
					rate = current
				} else {
					rate = 0.6*rate + 0.4*current
				}
				windowStart, windowBytes = now, 0
			}
			if now.Sub(lastReport) >= 100*time.Millisecond {
				lastReport = now
				report(done, rate)
			}
		}
		if r.err == io.EOF {
			report(done, rate)
			return done, nil
		}
		if r.err != nil {
			return done, r.err
		}
	}
}
