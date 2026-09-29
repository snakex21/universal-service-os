//go:build windows

package main

import (
	"archive/zip"
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/components"
	"github.com/snakex21/universal-service-os/installer/internal/install"
)

// fakeComponents stands in for winhost: the drive starts without the WinPE
// donor and the XP package; "installing" only marks them present.
type fakeComponents struct {
	mu     sync.Mutex
	status components.Status
}

func (f *fakeComponents) ComponentStatus(install.MediaLayout) (components.Status, error) {
	time.Sleep(150 * time.Millisecond)
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.status, nil
}

func (f *fakeComponents) InstallComponent(_ install.MediaLayout, id components.ID, _ string, storeOnly bool, log func(string)) error {
	time.Sleep(300 * time.Millisecond)
	f.mu.Lock()
	defer f.mu.Unlock()
	switch {
	case id == components.WinPE:
		f.status.WinPE, f.status.WinPEName = true, "PE10_x64_19041_USOS.iso"
	case !storeOnly:
		f.status.XPLang, f.status.XPCurrent = id.XPLang(), true
	}
	log("demo: installed " + string(id))
	return nil
}

// fakeRelease serves small fake component zips from a local server, slowly
// enough for the download progress to show. Nothing leaves this PC.
func fakeRelease() *components.Release {
	const version, tag = "1.0.0", "v1.0.0-demo"
	assets := map[string][]byte{}
	var sums, pinned strings.Builder
	for _, id := range components.All {
		var buf bytes.Buffer
		z := zip.NewWriter(&buf)
		w, _ := z.CreateHeader(&zip.FileHeader{Name: "demo/" + string(id) + ".bin", Method: zip.Store})
		w.Write(bytes.Repeat([]byte(id), 3<<20/len(id)))
		z.Close()
		name := components.AssetName(id, version)
		assets[name] = buf.Bytes()
		sum := sha256.Sum256(buf.Bytes())
		fmt.Fprintf(&sums, "%s *%s\n", hex.EncodeToString(sum[:]), name)
		fmt.Fprintf(&pinned, "%s=%s;", name, hex.EncodeToString(sum[:]))
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		name := strings.TrimPrefix(r.URL.Path, "/"+tag+"/")
		if name == components.SumsAsset {
			fmt.Fprint(w, sums.String())
			return
		}
		data, ok := assets[name]
		if !ok {
			http.NotFound(w, r)
			return
		}
		w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		for i := 0; i < len(data); i += 64 << 10 {
			w.Write(data[i:min(i+64<<10, len(data))])
			w.(http.Flusher).Flush()
			time.Sleep(40 * time.Millisecond) // ~1.6 MB/s
		}
	}))
	release := &components.Release{BaseURL: server.URL, Tag: tag, Version: version, Pinned: components.ParsePinned(pinned.String())}
	// Always show the download (no files cached by an earlier demo run).
	_ = os.RemoveAll(components.DefaultDir(*release))
	return release
}
