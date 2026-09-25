//go:build windows

package winhost

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/localupdate"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
)

type dynamicPayloadFile struct {
	path string
	data []byte
}

func (b Backend) CopyESPPayload(media install.MediaLayout, progress func(done, total uint64)) error {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return fmt.Errorf("resolve formatted ESP: %w", err)
	}
	return copyESPPayloadResolved(resolved, progress)
}

func (b Backend) PayloadStatus(media install.MediaLayout) ([]localupdate.PayloadFileStatus, error) {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("resolve formatted ESP for payload status: %w", err)
	}
	bundle, err := payload.Embedded()
	if err != nil {
		return nil, err
	}
	manifest, err := bundle.Manifest()
	if err != nil {
		return nil, err
	}
	statuses := make([]localupdate.PayloadFileStatus, 0, len(manifest))
	for _, expected := range manifest {
		path := filepath.Join(resolved.ESP.VolumePath, filepath.FromSlash(expected.Path))
		actual, hashErr := hashFileSHA256(path)
		if hashErr != nil {
			if !os.IsNotExist(hashErr) {
				return nil, fmt.Errorf("hash current payload file %s: %w", path, hashErr)
			}
			actual = ""
		}
		statuses = append(statuses, localupdate.PayloadFileStatus{
			Path:           expected.Path,
			ActualSHA256:   actual,
			ExpectedSHA256: expected.SHA256,
		})
	}
	return statuses, nil
}

func (b Backend) CopyInstallPayload(media install.MediaLayout, progress func(done, total uint64)) error {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return fmt.Errorf("resolve formatted install media: %w", err)
	}
	espTotal, err := espPayloadTotal(resolved)
	if err != nil {
		return err
	}
	readme, err := payload.README()
	if err != nil {
		return err
	}
	installerPath, installerSize, err := b.installerExecutable()
	if err != nil {
		return err
	}
	total := espTotal + dataGuidesTotalBytes() + uint64(len(readme)) + installerSize
	var globalDone uint64
	if progress != nil {
		progress(0, total)
	}
	if err := copyESPPayloadResolved(resolved, func(done, _ uint64) {
		globalDone = done
		if progress != nil {
			progress(globalDone, total)
		}
	}); err != nil {
		return err
	}
	if globalDone != espTotal {
		return fmt.Errorf("ESP payload progress mismatch: got %d want %d", globalDone, espTotal)
	}

	if err := ensureDataDirectories(resolved.DATA.VolumePath); err != nil {
		return err
	}
	// PE10 donor for Vista/Windows 7: managed folder, legacy move, record, attributes.
	if _, err := ensureWinpeDonor(resolved.DATA.VolumePath, resolved.ESP.VolumePath); err != nil {
		return fmt.Errorf("prepare the WinPE donor (Programs\\USOS\\WinPE): %w", err)
	}
	for _, guide := range dataGuides {
		guidePath := filepath.Join(resolved.DATA.VolumePath, guide.relativePath)
		if err := writeFileSync(guidePath, guide.contents); err != nil {
			return fmt.Errorf("write DATA guide %s: %w", guide.relativePath, err)
		}
		if err := verifyFileMatchesBytes(guidePath, guide.contents); err != nil {
			return fmt.Errorf("verify DATA guide %s: %w", guide.relativePath, err)
		}
		globalDone += uint64(len(guide.contents))
		if progress != nil {
			progress(globalDone, total)
		}
	}
	if err := ensureXPSettingsFile(resolved.DATA.VolumePath); err != nil {
		return err
	}
	if err := syncDataCatalog(resolved); err != nil {
		return fmt.Errorf("synchronize DATA catalog metadata to ESP: %w", err)
	}
	if err := ensureWimBootTemplate(resolved.DATA.VolumePath); err != nil {
		return fmt.Errorf("prepare WIMBoot template: %w", err)
	}
	if err := ensureVHDBootTemplates(resolved.DATA.VolumePath); err != nil {
		return fmt.Errorf("prepare VHDBoot templates: %w", err)
	}

	readmePath := dataProgramFile(resolved.DATA.VolumePath, "README.md")
	if err := writeFileSync(readmePath, readme); err != nil {
		return fmt.Errorf("write DATA README: %w", err)
	}
	if err := verifyFileMatchesBytes(readmePath, readme); err != nil {
		return fmt.Errorf("verify DATA README: %w", err)
	}
	globalDone += uint64(len(readme))
	if progress != nil {
		progress(globalDone, total)
	}

	destination := dataProgramFile(resolved.DATA.VolumePath, "USOS Installer.exe")
	copied, sourceHash, err := copyFileSyncHash(installerPath, destination, func(written uint64) {
		if progress != nil {
			progress(globalDone+written, total)
		}
	})
	if err != nil {
		return fmt.Errorf("copy USOS Installer.exe to DATA: %w", err)
	}
	if copied != installerSize {
		return fmt.Errorf("installer copy size mismatch: copied %d want %d", copied, installerSize)
	}
	destinationHash, err := hashFileSHA256(destination)
	if err != nil {
		return fmt.Errorf("hash copied USOS Installer.exe: %w", err)
	}
	if destinationHash != sourceHash {
		return fmt.Errorf("USOS Installer.exe SHA-256 mismatch after copy: source=%s destination=%s", sourceHash, destinationHash)
	}
	globalDone += copied
	if globalDone != total {
		return fmt.Errorf("install payload progress accounting mismatch: copied %d of %d", globalDone, total)
	}
	if progress != nil {
		progress(globalDone, total)
	}
	return nil
}

func espPayloadTotal(media install.MediaLayout) (uint64, error) {
	bundle, dynamic, total, err := prepareESPPayload(media)
	_ = bundle
	_ = dynamic
	return total, err
}

func prepareESPPayload(media install.MediaLayout) (payload.Bundle, []dynamicPayloadFile, uint64, error) {
	bundle, err := payload.Embedded()
	if err != nil {
		return payload.Bundle{}, nil, 0, err
	}
	staticBytes, err := bundle.TotalBytes()
	if err != nil {
		return payload.Bundle{}, nil, 0, err
	}
	loaderConf := []byte("default usos-micro-linux.conf\r\ntimeout 0\r\neditor no\r\n")
	loaderEntry := []byte(MicroLinuxLoaderEntry(media.ESP.PartUUID))
	installState := []byte("phase=pending\r\n")
	dynamic := []dynamicPayloadFile{
		{path: filepath.Join("loader", "loader.conf"), data: loaderConf},
		{path: filepath.Join("loader", "entries", "usos-micro-linux.conf"), data: loaderEntry},
		{path: filepath.Join("EFI", "USOS", "install-state.ini"), data: installState},
	}
	// Only the language chosen in this installer goes onto the drive; the EFI
	// and helpers keep English built in for anything missing here.
	languageFiles, err := i18n.DeviceFiles(i18n.Current())
	if err != nil {
		return payload.Bundle{}, nil, 0, fmt.Errorf("prepare language files: %w", err)
	}
	for _, file := range languageFiles {
		data := file.Data
		if file.Path == i18n.SettingsPath {
			// Update/repair: keep the drive's other settings (wheel_invert,
			// touch_rotation, ...) and only set the language.
			if existing, err := os.ReadFile(filepath.Join(media.ESP.VolumePath, filepath.FromSlash(file.Path))); err == nil {
				data = i18n.MergeSettingsINI(existing, i18n.Current())
			}
		}
		dynamic = append(dynamic, dynamicPayloadFile{path: filepath.FromSlash(file.Path), data: data})
	}
	total := staticBytes
	for _, file := range dynamic {
		total += uint64(len(file.data))
	}
	return bundle, dynamic, total, nil
}

func copyESPPayloadResolved(media install.MediaLayout, progress func(done, total uint64)) error {
	bundle, dynamic, total, err := prepareESPPayload(media)
	if err != nil {
		return err
	}
	var done uint64
	if progress != nil {
		progress(0, total)
	}
	if err := bundle.Extract(media.ESP.VolumePath, func(staticDone, _ uint64) {
		done = staticDone
		if progress != nil {
			progress(done, total)
		}
	}); err != nil {
		return err
	}
	if err := bundle.Verify(media.ESP.VolumePath); err != nil {
		return fmt.Errorf("verify copied embedded payload: %w", err)
	}
	for _, file := range dynamic {
		path := filepath.Join(media.ESP.VolumePath, file.path)
		if err := writeFileSync(path, file.data); err != nil {
			return err
		}
		actual, err := os.ReadFile(path)
		if err != nil {
			return fmt.Errorf("read back payload file %s: %w", path, err)
		}
		if string(actual) != string(file.data) {
			return fmt.Errorf("payload file read-back mismatch: %s", path)
		}
		done += uint64(len(file.data))
		if progress != nil {
			progress(done, total)
		}
	}
	if done != total {
		return fmt.Errorf("ESP payload progress accounting mismatch: copied %d of %d", done, total)
	}
	return nil
}

func (b Backend) installerExecutable() (string, uint64, error) {
	path := b.InstallerExecutable
	if path == "" {
		var err error
		path, err = os.Executable()
		if err != nil {
			return "", 0, fmt.Errorf("locate running installer executable: %w", err)
		}
	}
	path, err := filepath.Abs(path)
	if err != nil {
		return "", 0, fmt.Errorf("resolve installer executable path: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", 0, fmt.Errorf("stat installer executable %s: %w", path, err)
	}
	if !info.Mode().IsRegular() || info.Size() <= 0 {
		return "", 0, fmt.Errorf("installer executable is not a non-empty regular file: %s", path)
	}
	return path, uint64(info.Size()), nil
}

func copyFileSyncHash(source, destination string, progress func(written uint64)) (uint64, string, error) {
	input, err := os.Open(source)
	if err != nil {
		return 0, "", err
	}
	defer input.Close()
	if err := os.MkdirAll(filepath.Dir(destination), 0o755); err != nil {
		return 0, "", err
	}
	output, err := os.OpenFile(destination, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return 0, "", err
	}
	ok := false
	defer func() {
		if !ok {
			_ = output.Close()
		}
	}()
	hash := sha256.New()
	buffer := make([]byte, 1024*1024)
	var writtenTotal uint64
	for {
		n, readErr := input.Read(buffer)
		if n > 0 {
			written, writeErr := output.Write(buffer[:n])
			if writeErr != nil {
				return writtenTotal, "", writeErr
			}
			if written != n {
				return writtenTotal, "", fmt.Errorf("short write: wrote %d of %d", written, n)
			}
			if _, err := hash.Write(buffer[:n]); err != nil {
				return writtenTotal, "", err
			}
			writtenTotal += uint64(n)
			if progress != nil {
				progress(writtenTotal)
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return writtenTotal, "", readErr
		}
	}
	if err := output.Sync(); err != nil {
		return writtenTotal, "", err
	}
	if err := output.Close(); err != nil {
		return writtenTotal, "", err
	}
	ok = true
	return writtenTotal, hex.EncodeToString(hash.Sum(nil)), nil
}

func hashFileSHA256(path string) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func verifyFileMatchesBytes(path string, expected []byte) error {
	actualHash, err := hashFileSHA256(path)
	if err != nil {
		return err
	}
	expectedHash := sha256.Sum256(expected)
	want := hex.EncodeToString(expectedHash[:])
	if actualHash != want {
		return fmt.Errorf("SHA-256 mismatch: got %s want %s", actualHash, want)
	}
	return nil
}

func writeFileSync(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return fmt.Errorf("create directory for %s: %w", path, err)
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o644)
	if err != nil {
		return fmt.Errorf("create file %s: %w", path, err)
	}
	if _, err := file.Write(data); err != nil {
		_ = file.Close()
		return fmt.Errorf("write file %s: %w", path, err)
	}
	if err := file.Sync(); err != nil {
		_ = file.Close()
		return fmt.Errorf("flush file %s: %w", path, err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close file %s: %w", path, err)
	}
	return nil
}
