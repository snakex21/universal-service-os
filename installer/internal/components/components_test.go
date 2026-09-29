package components

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

const testVersion = "9.9.9"

func sum(data []byte) string {
	h := sha256.Sum256(data)
	return hex.EncodeToString(h[:])
}

// fakeRelease serves /<tag>/<asset> and /<tag>/SHA256SUMS like GitHub.
type fakeRelease struct {
	mu     sync.Mutex
	assets map[string][]byte
	sums   string
	// cutFirst: the first full request of an asset stops after half.
	cutFirst map[string]bool
	requests []string
}

func (f *fakeRelease) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	f.requests = append(f.requests, r.URL.Path+" range="+r.Header.Get("Range"))
	name := strings.TrimPrefix(r.URL.Path, "/v"+testVersion+"-rc9/")
	if name == SumsAsset {
		f.mu.Unlock()
		fmt.Fprint(w, f.sums)
		return
	}
	data, ok := f.assets[name]
	cut := f.cutFirst[name] && r.Header.Get("Range") == ""
	if cut {
		f.cutFirst[name] = false
	}
	f.mu.Unlock()
	if !ok {
		http.NotFound(w, r)
		return
	}
	if cut {
		w.Header().Set("Content-Length", fmt.Sprint(len(data)))
		w.WriteHeader(http.StatusOK)
		w.Write(data[:len(data)/2])
		w.(http.Flusher).Flush()
		panic(http.ErrAbortHandler) // connection drops mid-download
	}
	http.ServeContent(w, r, name, time.Time{}, bytes.NewReader(data))
}

func makeZip(t *testing.T, files map[string]string) []byte {
	t.Helper()
	var buf bytes.Buffer
	z := zip.NewWriter(&buf)
	for name, content := range files {
		w, err := z.Create(name)
		if err != nil {
			t.Fatal(err)
		}
		w.Write([]byte(content))
	}
	if err := z.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

type fakeInstaller struct {
	installed map[ID]string
	stored    map[ID]string
}

func (f *fakeInstaller) InstallComponent(id ID, zipPath string, storeOnly bool, log func(string)) error {
	data, err := os.ReadFile(zipPath)
	if err != nil {
		return err
	}
	if storeOnly {
		f.stored[id] = sum(data)
	} else {
		f.installed[id] = sum(data)
	}
	return nil
}

type fixture struct {
	server    *httptest.Server
	fake      *fakeRelease
	release   Release
	winpe, xp []byte
	dir       string
}

func newFixture(t *testing.T) *fixture {
	t.Helper()
	winpe := makeZip(t, map[string]string{"Programs/USOS/WinPE/PE10_x64_19041_USOS.iso": strings.Repeat("donor", 50000), "README.txt": "r"})
	xp := makeZip(t, map[string]string{"EFI/USOS-XP/manifest.json": "{}", "install-xp-package.ps1": "#"})
	winpeName, xpName := AssetName(WinPE, testVersion), AssetName(XPPL, testVersion)
	fake := &fakeRelease{
		assets:   map[string][]byte{winpeName: winpe, xpName: xp},
		sums:     sum(winpe) + " *" + winpeName + "\n" + sum(xp) + " *" + xpName + "\n",
		cutFirst: map[string]bool{},
	}
	server := httptest.NewServer(fake)
	t.Cleanup(server.Close)
	release := Release{BaseURL: server.URL, Tag: "v" + testVersion + "-rc9", Version: testVersion,
		Pinned: ParsePinned(winpeName + "=" + sum(winpe) + ";" + xpName + "=" + sum(xp))}
	return &fixture{server: server, fake: fake, release: release, winpe: winpe, xp: xp, dir: t.TempDir()}
}

func (fx *fixture) runner(installer Installer) *Runner {
	return &Runner{Release: fx.release, Installer: installer,
		Downloader: &Downloader{Client: fx.server.Client(), Release: fx.release, Dir: fx.dir, RetryDelay: time.Millisecond}}
}

func TestDownloadGoodHashInstalls(t *testing.T) {
	fx := newFixture(t)
	inst := &fakeInstaller{installed: map[ID]string{}, stored: map[ID]string{}}
	var sawProgress bool
	results := fx.runner(inst).Run(context.Background(), []Choice{{ID: WinPE}, {ID: XPPL}}, func(e Event) {
		if e.Phase == PhaseDownload && e.Progress.Total > 0 && e.Progress.Done > 0 {
			sawProgress = true
		}
	})
	for id, err := range results {
		if err != nil {
			t.Fatalf("%s: %v", id, err)
		}
	}
	if inst.installed[WinPE] != sum(fx.winpe) || inst.installed[XPPL] != sum(fx.xp) {
		t.Fatalf("installed %v", inst.installed)
	}
	if !sawProgress {
		t.Fatal("no download progress reported")
	}
	// Downloaded to the PC folder, no .part left.
	if _, err := os.Stat(filepath.Join(fx.dir, AssetName(WinPE, testVersion))); err != nil {
		t.Fatal(err)
	}
	if parts, _ := filepath.Glob(filepath.Join(fx.dir, "*.part")); len(parts) != 0 {
		t.Fatalf("leftover %v", parts)
	}
}

func TestDownloadBadHashIsRejected(t *testing.T) {
	cases := map[string]func(fx *fixture){
		// The release asset was replaced and SHA256SUMS updated to match:
		// only the compiled list catches it.
		"tampered release": func(fx *fixture) {
			name := AssetName(WinPE, testVersion)
			evil := append([]byte(nil), fx.winpe...)
			evil[len(evil)/2] ^= 0xff
			fx.fake.assets[name] = evil
			fx.fake.sums = sum(evil) + " *" + name + "\n"
		},
		// SHA256SUMS disagrees with the file (corrupted upload).
		"sums mismatch": func(fx *fixture) {
			fx.fake.sums = strings.Repeat("0", 64) + " *" + AssetName(WinPE, testVersion) + "\n"
		},
		// The installer's compiled list does not know the asset.
		"not pinned": func(fx *fixture) {
			fx.release.Pinned = ParsePinned(AssetName(XPPL, testVersion) + "=" + sum(fx.xp))
		},
	}
	for name, mutate := range cases {
		t.Run(name, func(t *testing.T) {
			fx := newFixture(t)
			mutate(fx)
			inst := &fakeInstaller{installed: map[ID]string{}, stored: map[ID]string{}}
			results := fx.runner(inst).Run(context.Background(), []Choice{{ID: WinPE}}, nil)
			err := results[WinPE]
			if err == nil || !(errors.Is(err, ErrHashMismatch) || errors.Is(err, ErrUnverifiable)) {
				t.Fatalf("want a verification error, got %v", err)
			}
			if len(inst.installed) != 0 {
				t.Fatal("a bad file was installed")
			}
			if files, _ := filepath.Glob(filepath.Join(fx.dir, "*")); len(files) != 0 {
				t.Fatalf("rejected download kept: %v", files)
			}
		})
	}
}

func TestDownloadResumesAfterNetworkError(t *testing.T) {
	fx := newFixture(t)
	name := AssetName(WinPE, testVersion)
	fx.fake.cutFirst[name] = true
	inst := &fakeInstaller{installed: map[ID]string{}, stored: map[ID]string{}}
	results := fx.runner(inst).Run(context.Background(), []Choice{{ID: WinPE}}, nil)
	if results[WinPE] != nil {
		t.Fatal(results[WinPE])
	}
	if inst.installed[WinPE] != sum(fx.winpe) {
		t.Fatal("resumed file differs")
	}
	resumed := false
	for _, r := range fx.fake.requests {
		if strings.Contains(r, name) && strings.Contains(r, fmt.Sprintf("range=bytes=%d-", len(fx.winpe)/2)) {
			resumed = true
		}
	}
	if !resumed {
		t.Fatalf("no Range request after the cut: %v", fx.fake.requests)
	}
}

func TestDownloadRetryAfterGivingUpResumesPart(t *testing.T) {
	fx := newFixture(t)
	name := AssetName(WinPE, testVersion)
	fx.fake.cutFirst[name] = true
	d := &Downloader{Client: fx.server.Client(), Release: fx.release, Dir: fx.dir, Attempts: 1, RetryDelay: time.Millisecond}
	sums := map[string]string{name: sum(fx.winpe)}
	if _, err := d.Fetch(context.Background(), name, sums, nil); err == nil {
		t.Fatal("first attempt should fail")
	}
	part, err := os.Stat(filepath.Join(fx.dir, name+".part"))
	if err != nil || part.Size() != int64(len(fx.winpe)/2) {
		t.Fatalf("partial file not kept: %v", err)
	}
	// The user presses Retry.
	path, err := d.Fetch(context.Background(), name, sums, nil)
	if err != nil {
		t.Fatal(err)
	}
	if got, _ := HashFile(path); got != sum(fx.winpe) {
		t.Fatal("wrong content after resume")
	}
}

func TestOfflinePick(t *testing.T) {
	fx := newFixture(t)
	fx.server.Close() // offline
	inst := &fakeInstaller{installed: map[ID]string{}, stored: map[ID]string{}}
	folder := t.TempDir()
	good := filepath.Join(folder, "renamed-by-user.zip")
	os.WriteFile(good, fx.xp, 0o644)
	results := fx.runner(inst).Run(context.Background(), []Choice{{ID: XPPL, Source: SourceLocal, LocalPath: good}}, nil)
	if results[XPPL] != nil || inst.installed[XPPL] != sum(fx.xp) {
		t.Fatalf("good local file: %v", results[XPPL])
	}

	// The wrong file (the EN package picked for PL, or a damaged zip) fails.
	bad := filepath.Join(t.TempDir(), AssetName(XPPL, testVersion))
	os.WriteFile(bad, append([]byte("x"), fx.xp...), 0o644)
	inst = &fakeInstaller{installed: map[ID]string{}, stored: map[ID]string{}}
	results = fx.runner(inst).Run(context.Background(), []Choice{{ID: XPPL, Source: SourceLocal, LocalPath: bad}, {ID: WinPE, Source: SourceSkip}}, nil)
	if !errors.Is(results[XPPL], ErrHashMismatch) || len(inst.installed) != 0 {
		t.Fatalf("bad local file: %v", results[XPPL])
	}

	// A SHA256SUMS next to the file must agree as well.
	os.WriteFile(filepath.Join(folder, SumsAsset), []byte(strings.Repeat("1", 64)+" *"+AssetName(XPPL, testVersion)+"\n"), 0o644)
	if err := VerifyLocal(good, AssetName(XPPL, testVersion), fx.release, nil); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("SHA256SUMS beside the file ignored: %v", err)
	}

	// A development build (no compiled list) offline cannot verify.
	dev := fx.release
	dev.Pinned = nil
	os.Remove(filepath.Join(folder, SumsAsset))
	if err := VerifyLocal(good, AssetName(XPPL, testVersion), dev, nil); !errors.Is(err, ErrUnverifiable) {
		t.Fatalf("unverifiable file accepted: %v", err)
	}
}

func TestParseAndCheck(t *testing.T) {
	a, b := strings.Repeat("a", 64), strings.Repeat("b", 64)
	pinned := ParsePinned("X.zip=" + a + ";Y.zip=" + strings.ToUpper(b) + ";junk;Z.zip=short")
	if len(pinned) != 2 || pinned["Y.zip"] != b {
		t.Fatalf("pinned %v", pinned)
	}
	sums, err := ParseSums(strings.NewReader(a + " *X.zip\n" + b + "  LICENSES/Y.txt\n"))
	if err != nil || sums["X.zip"] != a || sums["LICENSES/Y.txt"] != b {
		t.Fatalf("sums %v %v", sums, err)
	}
	if _, err := ParseSums(strings.NewReader("nonsense\n")); err == nil {
		t.Fatal("malformed SHA256SUMS accepted")
	}
	if Check("X.zip", a, pinned, sums) != nil {
		t.Fatal("good file rejected")
	}
	if Check("X.zip", b, pinned, map[string]string{"X.zip": b}) == nil {
		t.Fatal("compiled list ignored")
	}
	if Check("X.zip", a, nil, nil) == nil {
		t.Fatal("unverified file accepted")
	}
}

func TestReleaseURLAndAssets(t *testing.T) {
	r := Release{BaseURL: ReleaseBaseURL, Tag: "v1.0.0-rc2", Version: "1.0.0"}
	if got := r.URL(r.Asset(XPEN)); got != "https://github.com/snakex21/universal-service-os/releases/download/v1.0.0-rc2/USOS-1.0.0-XP-package-EN.zip" {
		t.Fatal(got)
	}
	if r.Asset(WinPE) != "USOS-1.0.0-WinPE-PE10-donor.zip" {
		t.Fatal(r.Asset(WinPE))
	}
	if PreferredXP("pl") != XPPL || PreferredXP("de") != XPEN {
		t.Fatal("preferred XP language")
	}
}

func TestUnpackAndInspect(t *testing.T) {
	esp, data := t.TempDir(), t.TempDir()
	if s := Inspect(esp, data); s.WinPE || s.XPLang != "" || s.Complete() {
		t.Fatalf("empty stick: %+v", s)
	}
	zipPath := filepath.Join(t.TempDir(), "w.zip")
	os.WriteFile(zipPath, makeZip(t, map[string]string{"Programs/USOS/WinPE/PE10_x64_19041_USOS.iso": "iso", "README.txt": "r"}), 0o644)
	name, err := ExtractWinPEDonor(zipPath, data)
	if err != nil || name != "PE10_x64_19041_USOS.iso" {
		t.Fatal(name, err)
	}
	if _, err := ExtractWinPEDonor(zipPath, data); err == nil {
		t.Fatal("existing donor overwritten")
	}
	base := []byte("micro-linux")
	os.MkdirAll(filepath.Join(esp, "EFI", "USOS", "micro-linux"), 0o755)
	os.WriteFile(filepath.Join(esp, "EFI", "USOS", "micro-linux", "initramfs-usos"), base, 0o644)
	os.MkdirAll(filepath.Join(esp, "EFI", "USOS-XP"), 0o755)
	os.WriteFile(filepath.Join(esp, "EFI", "USOS-XP", "manifest.json"), []byte(`{"release":true,"release_lang":"pl","base_initramfs_sha256":"`+sum(base)+`"}`), 0o644)
	s := Inspect(esp, data)
	if !s.WinPE || !s.Present(XPPL) || s.Present(XPEN) || !s.Complete() {
		t.Fatalf("installed stick: %+v", s)
	}
	os.WriteFile(filepath.Join(esp, "EFI", "USOS", "micro-linux", "initramfs-usos"), []byte("updated"), 0o644)
	if s := Inspect(esp, data); s.XPCurrent || s.Complete() {
		t.Fatalf("stale XP package counted as current: %+v", s)
	}

	evil := filepath.Join(t.TempDir(), "evil.zip")
	os.WriteFile(evil, makeZip(t, map[string]string{"../escape.txt": "x"}), 0o644)
	if err := ExtractAll(evil, t.TempDir()); err == nil {
		t.Fatal("zip-slip entry accepted")
	}
}

func writeTemp(t *testing.T, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), name)
	if err := os.WriteFile(path, data, 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

// The all-in-one installer: zips appended to the exe install without any
// network, verified against the compiled hash list.
func TestEmbeddedBundleInstallsOffline(t *testing.T) {
	fx := newFixture(t)
	fx.server.Close() // no network at all
	exe := writeTemp(t, "installer.exe", []byte("MZ fake installer image"))
	winpe := writeTemp(t, AssetName(WinPE, testVersion), fx.winpe)
	xp := writeTemp(t, AssetName(XPPL, testVersion), fx.xp)
	allInOne := filepath.Join(t.TempDir(), "USOS-Installer.exe")
	if err := WriteBundle(allInOne, exe, []string{winpe, xp}); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenBundle(exe); !errors.Is(err, ErrNoBundle) {
		t.Fatalf("plain exe: %v", err)
	}
	bundle, err := OpenBundle(allInOne)
	if err != nil || !bundle.Has(AssetName(WinPE, testVersion)) || bundle.Has(AssetName(XPEN, testVersion)) {
		t.Fatalf("bundle %+v %v", bundle, err)
	}
	// The PE image itself is untouched at the start of the file.
	if data, _ := os.ReadFile(allInOne); !bytes.HasPrefix(data, []byte("MZ fake installer image")) {
		t.Fatal("exe prefix changed")
	}
	r := fx.runner(&fakeInstaller{installed: map[ID]string{}, stored: map[ID]string{}})
	inst := r.Installer.(*fakeInstaller)
	r.Bundle = bundle
	results := r.Run(context.Background(), []Choice{{ID: WinPE, Source: SourceEmbedded}, {ID: XPPL, Source: SourceEmbedded}, {ID: XPEN, Source: SourceEmbedded, StoreOnly: true}}, nil)
	if results[WinPE] != nil || results[XPPL] != nil || inst.installed[WinPE] != sum(fx.winpe) || inst.installed[XPPL] != sum(fx.xp) {
		t.Fatalf("embedded install: %v %v", results, inst.installed)
	}
	if results[XPEN] == nil {
		t.Fatal("a component missing from the bundle was reported as installed")
	}
	if files, _ := filepath.Glob(filepath.Join(fx.dir, "*")); len(files) != 0 {
		t.Fatalf("extracted copies left in the temp folder: %v", files)
	}
}

func TestEmbeddedBundleTamperedOrUnpinned(t *testing.T) {
	fx := newFixture(t)
	exe := writeTemp(t, "installer.exe", []byte("MZ"))
	evil := append([]byte(nil), fx.winpe...)
	evil[10] ^= 0xff
	allInOne := filepath.Join(t.TempDir(), "USOS-Installer.exe")
	if err := WriteBundle(allInOne, exe, []string{writeTemp(t, AssetName(WinPE, testVersion), evil)}); err != nil {
		t.Fatal(err)
	}
	bundle, err := OpenBundle(allInOne)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := bundle.Extract(AssetName(WinPE, testVersion), fx.dir, fx.release.Pinned); !errors.Is(err, ErrHashMismatch) {
		t.Fatalf("tampered overlay: %v", err)
	}
	if _, err := bundle.Extract(AssetName(WinPE, testVersion), fx.dir, nil); !errors.Is(err, ErrUnverifiable) {
		t.Fatalf("no compiled list: %v", err)
	}
	if files, _ := filepath.Glob(filepath.Join(fx.dir, "*")); len(files) != 0 {
		t.Fatalf("rejected copy kept: %v", files)
	}
	// A cut-off download of the all-in-one has no valid trailer.
	data, _ := os.ReadFile(allInOne)
	cut := writeTemp(t, "cut.exe", data[:len(data)-5])
	if _, err := OpenBundle(cut); err == nil {
		t.Fatal("truncated bundle accepted")
	}
}
