//go:build windows

package winhost

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
)

func (b Backend) Verify(media install.MediaLayout, expected install.DeviceINI) (install.VerificationReport, error) {
	return b.verify(media, expected, true)
}

func (b Backend) VerifyRepair(media install.MediaLayout, expected install.DeviceINI) (install.VerificationReport, error) {
	return b.verify(media, expected, false)
}

func (b Backend) verify(media install.MediaLayout, expected install.DeviceINI, verifyDataPayload bool) (install.VerificationReport, error) {
	report := install.VerificationReport{}
	add := func(name, want, actual string) {
		report.Items = append(report.Items, install.VerificationItem{
			Name:     name,
			Expected: want,
			Actual:   actual,
			Match:    want == actual,
		})
	}

	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		report.Items = append(report.Items, install.VerificationItem{
			Name:     "Woluminy po formatowaniu",
			Expected: "ESP FAT32 USOS_ESP; DATA NTFS USOS_DATA; WORK NTFS USOS_WORK",
			Actual:   err.Error(),
			Match:    false,
		})
		return report, nil
	}

	iniPath := filepath.Join(resolved.ESP.VolumePath, "EFI", "USOS", "usos-device.ini")
	file, err := os.Open(iniPath)
	if err != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "usos-device.ini", Expected: "plik możliwy do odczytu", Actual: err.Error(), Match: false})
		return report, nil
	}
	actualINI, parseErr := install.ParseDeviceINI(file)
	closeErr := file.Close()
	if parseErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "usos-device.ini", Expected: "poprawny format", Actual: parseErr.Error(), Match: false})
		return report, nil
	}
	if closeErr != nil {
		return report, fmt.Errorf("close usos-device.ini during verification: %w", closeErr)
	}

	add("Disk GPT UUID", actualINI.DiskPTUUID, media.DiskPTUUID)
	add("ESP PARTUUID", actualINI.ESPPartUUID, media.ESP.PartUUID)
	add("DATA PARTUUID", actualINI.DataPartUUID, media.DATA.PartUUID)
	add("WORK PARTUUID", actualINI.WorkPartUUID, media.WORK.PartUUID)
	add("WORK rozmiar", strconv.FormatUint(actualINI.WorkBytes, 10), strconv.FormatUint(media.WORK.SizeBytes, 10))
	add("WORK etykieta w usos-device.ini", expected.WorkLabel, actualINI.WorkLabel)
	add("DATA etykieta w usos-device.ini", expected.DataLabel, actualINI.DataLabel)
	add("Nonce w usos-device.ini", expected.Nonce, actualINI.Nonce)

	markerNonce, markerErr := readMarkerNonce(filepath.Join(resolved.WORK.VolumePath, ".usos-work"))
	if markerErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: ".usos-work nonce", Expected: actualINI.Nonce, Actual: markerErr.Error(), Match: false})
	} else {
		add(".usos-work nonce", actualINI.Nonce, markerNonce)
	}

	bundle, bundleErr := payload.Embedded()
	if bundleErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Payload ESP", Expected: "zgodny z payloadem w EXE", Actual: bundleErr.Error(), Match: false})
	} else if verifyErr := bundle.Verify(resolved.ESP.VolumePath); verifyErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Payload ESP", Expected: "SHA-256 zgodne z payloadem w EXE", Actual: verifyErr.Error(), Match: false})
	} else {
		report.Items = append(report.Items, install.VerificationItem{Name: "Payload ESP", Expected: "SHA-256 zgodne z payloadem w EXE", Actual: "SHA-256 zgodne z payloadem w EXE", Match: true})
	}

	loaderState := filepath.Join(resolved.ESP.VolumePath, "EFI", "USOS", "install-state.ini")
	state, stateErr := os.ReadFile(loaderState)
	if stateErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "install-state.ini", Expected: "phase=pending", Actual: stateErr.Error(), Match: false})
	} else {
		actualState := string(state)
		if actualState == "phase=pending\r\n" {
			actualState = "phase=pending"
		}
		add("install-state.ini", "phase=pending", actualState)
	}

	verifyMountVisibility(&report, resolved)
	if verifyDataPayload {
		b.verifyDataPayload(&report, resolved)
	}
	return report, nil
}

func verifyMountVisibility(report *install.VerificationReport, resolved install.MediaLayout) {
	dataVolume, dataErr := findVolumeByExtent(resolved.DiskNumber, resolved.DATA.StartBytes, resolved.DATA.SizeBytes)
	if dataErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "DATA widoczne dla użytkownika", Expected: "ma literę dysku", Actual: dataErr.Error(), Match: false})
	} else {
		actual := "brak litery dysku"
		match := hasDriveLetter(dataVolume.Info.MountPaths)
		if match {
			actual = "ma literę dysku"
		}
		report.Items = append(report.Items, install.VerificationItem{Name: "DATA widoczne dla użytkownika", Expected: "ma literę dysku", Actual: actual, Match: match})
	}

	workVolume, workErr := findVolumeByExtent(resolved.DiskNumber, resolved.WORK.StartBytes, resolved.WORK.SizeBytes)
	if workErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "WORK ukryte w Eksploratorze", Expected: "brak litery dysku", Actual: workErr.Error(), Match: false})
	} else {
		match := !hasDriveLetter(workVolume.Info.MountPaths)
		actual := "brak litery dysku"
		if !match {
			actual = "ma przypisaną literę dysku"
		}
		report.Items = append(report.Items, install.VerificationItem{Name: "WORK ukryte w Eksploratorze", Expected: "brak litery dysku", Actual: actual, Match: match})
	}
}

func hasDriveLetter(paths []string) bool {
	for _, path := range paths {
		if len(path) >= 3 && path[1] == ':' && (path[2] == '\\' || path[2] == '/') {
			return true
		}
	}
	return false
}

func (b Backend) verifyDataPayload(report *install.VerificationReport, resolved install.MediaLayout) {
	for _, directory := range requiredDataDirectories {
		path := filepath.Join(resolved.DATA.VolumePath, directory)
		info, err := os.Stat(path)
		actual := "katalog istnieje"
		match := err == nil && info.IsDir()
		if err != nil {
			actual = err.Error()
		} else if !info.IsDir() {
			actual = "ścieżka nie jest katalogiem"
		}
		report.Items = append(report.Items, install.VerificationItem{Name: "DATA\\" + directory, Expected: "katalog istnieje", Actual: actual, Match: match})
	}
	for _, guide := range dataGuides {
		path := filepath.Join(resolved.DATA.VolumePath, guide.relativePath)
		wantHashRaw := sha256.Sum256(guide.contents)
		wantHash := hex.EncodeToString(wantHashRaw[:])
		actualHash, err := hashFileSHA256(path)
		if err != nil {
			report.Items = append(report.Items, install.VerificationItem{Name: "DATA\\" + guide.relativePath, Expected: wantHash, Actual: err.Error(), Match: false})
			continue
		}
		report.Items = append(report.Items, install.VerificationItem{Name: "DATA\\" + guide.relativePath + " SHA-256", Expected: wantHash, Actual: actualHash, Match: wantHash == actualHash})
	}
	if catalogErr := verifyDataCatalogMatches(resolved); catalogErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Katalog menu ESP", Expected: "zgodny z zawartością DATA", Actual: catalogErr.Error(), Match: false})
	} else {
		report.Items = append(report.Items, install.VerificationItem{Name: "Katalog menu ESP", Expected: "zgodny z zawartością DATA", Actual: "zgodny z zawartością DATA", Match: true})
	}
	if templateErr := verifyWimBootTemplate(resolved.DATA.VolumePath); templateErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Szablon WIMBoot", Expected: "gotowy, gdy DATA zawiera WIM", Actual: templateErr.Error(), Match: false})
	} else {
		report.Items = append(report.Items, install.VerificationItem{Name: "Szablon WIMBoot", Expected: "gotowy, gdy DATA zawiera WIM", Actual: "gotowy / nie jest wymagany", Match: true})
	}
	if templateErr := verifyVHDBootTemplates(resolved.DATA.VolumePath); templateErr != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Szablony VHDBoot", Expected: "gotowe, gdy DATA zawiera VHD/VHDX", Actual: templateErr.Error(), Match: false})
	} else {
		report.Items = append(report.Items, install.VerificationItem{Name: "Szablony VHDBoot", Expected: "gotowe, gdy DATA zawiera VHD/VHDX", Actual: "gotowe / nie są wymagane", Match: true})
	}

	readme, err := payload.README()
	if err != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\README.md", Expected: "SHA-256 zgodne z README w EXE", Actual: err.Error(), Match: false})
	} else {
		wantHashRaw := sha256.Sum256(readme)
		wantHash := hex.EncodeToString(wantHashRaw[:])
		actualHash, hashErr := hashFileSHA256(dataProgramFile(resolved.DATA.VolumePath, "README.md"))
		if hashErr != nil {
			report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\README.md", Expected: wantHash, Actual: hashErr.Error(), Match: false})
		} else {
			report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\README.md SHA-256", Expected: wantHash, Actual: actualHash, Match: wantHash == actualHash})
		}
	}

	installerPath, _, err := b.installerExecutable()
	if err != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\USOS Installer.exe", Expected: "SHA-256 zgodne z uruchomionym instalatorem", Actual: err.Error(), Match: false})
		return
	}
	wantHash, err := hashFileSHA256(installerPath)
	if err != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\USOS Installer.exe", Expected: "SHA-256 zgodne z uruchomionym instalatorem", Actual: err.Error(), Match: false})
		return
	}
	actualHash, err := hashFileSHA256(dataProgramFile(resolved.DATA.VolumePath, "USOS Installer.exe"))
	if err != nil {
		report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\USOS Installer.exe SHA-256", Expected: wantHash, Actual: err.Error(), Match: false})
		return
	}
	report.Items = append(report.Items, install.VerificationItem{Name: "Programs\\USOS\\USOS Installer.exe SHA-256", Expected: wantHash, Actual: actualHash, Match: wantHash == actualHash})
}
