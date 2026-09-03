//go:build windows

package winhost

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
)

func (Backend) WriteIdentity(media install.MediaLayout, workBytes uint64) (install.DeviceINI, error) {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return install.DeviceINI{}, fmt.Errorf("resolve formatted media before identity write: %w", err)
	}
	if resolved.WORK.SizeBytes != workBytes {
		return install.DeviceINI{}, fmt.Errorf("WORK size mismatch before identity write: read-back=%d planned=%d", resolved.WORK.SizeBytes, workBytes)
	}

	nonce, err := randomNonce()
	if err != nil {
		return install.DeviceINI{}, err
	}
	identity := install.DeviceINI{
		Nonce:        nonce,
		DiskPTUUID:   resolved.DiskPTUUID,
		ESPPartUUID:  resolved.ESP.PartUUID,
		DataPartUUID: resolved.DATA.PartUUID,
		WorkPartUUID: resolved.WORK.PartUUID,
		WorkLabel:    "USOS_WORK",
		DataLabel:    "USOS_DATA",
		WorkBytes:    resolved.WORK.SizeBytes,
	}
	if err := identity.Validate(); err != nil {
		return install.DeviceINI{}, err
	}

	if err := ensureWorkHasNoRegularFiles(resolved.WORK.VolumePath); err != nil {
		return install.DeviceINI{}, err
	}
	markerPath := filepath.Join(resolved.WORK.VolumePath, ".usos-work")
	marker := []byte("nonce=" + nonce + "\r\n")
	if err := writeFileSync(markerPath, marker); err != nil {
		return install.DeviceINI{}, fmt.Errorf("write .usos-work: %w", err)
	}
	if err := verifyOnlyWorkMarker(resolved.WORK.VolumePath, nonce); err != nil {
		return install.DeviceINI{}, err
	}

	iniPath := filepath.Join(resolved.ESP.VolumePath, "EFI", "USOS", "usos-device.ini")
	if err := writeFileSync(iniPath, []byte(identity.String())); err != nil {
		return install.DeviceINI{}, fmt.Errorf("write usos-device.ini: %w", err)
	}
	file, err := os.Open(iniPath)
	if err != nil {
		return install.DeviceINI{}, fmt.Errorf("read back usos-device.ini: %w", err)
	}
	readBack, parseErr := install.ParseDeviceINI(file)
	closeErr := file.Close()
	if parseErr != nil {
		return install.DeviceINI{}, fmt.Errorf("parse written usos-device.ini: %w", parseErr)
	}
	if closeErr != nil {
		return install.DeviceINI{}, fmt.Errorf("close written usos-device.ini: %w", closeErr)
	}
	if readBack != identity {
		return install.DeviceINI{}, fmt.Errorf("usos-device.ini read-back mismatch: wrote %+v read %+v", identity, readBack)
	}
	return identity, nil
}

func randomNonce() (string, error) {
	var raw [16]byte
	if _, err := rand.Read(raw[:]); err != nil {
		return "", fmt.Errorf("generate device nonce: %w", err)
	}
	return hex.EncodeToString(raw[:]), nil
}

func ensureWorkHasNoRegularFiles(root string) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return fmt.Errorf("inspect freshly formatted WORK root: %w", err)
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		return fmt.Errorf("WORK contains regular file before .usos-work marker: %s", entry.Name())
	}
	return nil
}

func verifyOnlyWorkMarker(root, expectedNonce string) error {
	entries, err := os.ReadDir(root)
	if err != nil {
		return fmt.Errorf("inspect WORK after marker write: %w", err)
	}
	regular := make([]string, 0, 1)
	for _, entry := range entries {
		if !entry.IsDir() {
			regular = append(regular, entry.Name())
		}
	}
	if len(regular) != 1 || regular[0] != ".usos-work" {
		return fmt.Errorf(".usos-work is not the first and only regular WORK file: got %v", regular)
	}
	actual, err := readMarkerNonce(filepath.Join(root, ".usos-work"))
	if err != nil {
		return err
	}
	if actual != expectedNonce {
		return fmt.Errorf(".usos-work nonce mismatch after write: got %q want %q", actual, expectedNonce)
	}
	return nil
}

func readMarkerNonce(path string) (string, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return "", fmt.Errorf("read marker %s: %w", path, err)
	}
	for _, line := range strings.Split(strings.ReplaceAll(string(data), "\r\n", "\n"), "\n") {
		key, value, ok := strings.Cut(strings.TrimSpace(line), "=")
		if ok && strings.EqualFold(strings.TrimSpace(key), "nonce") {
			value = strings.TrimSpace(value)
			if value == "" {
				return "", fmt.Errorf("marker nonce is empty: %s", path)
			}
			return value, nil
		}
	}
	return "", fmt.Errorf("marker has no nonce: %s", path)
}
