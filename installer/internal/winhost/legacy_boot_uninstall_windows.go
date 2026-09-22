//go:build windows

package winhost

import (
	"bytes"
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
)

func (s *destructiveSession) ClearLegacyBoot(media install.MediaLayout) (legacyboot.Audit, error) {
	if s.closed {
		return legacyboot.Audit{}, fmt.Errorf("destructive session is closed")
	}
	if s.cleaned {
		return legacyboot.Audit{}, fmt.Errorf("refusing Legacy boot clear after GPT deletion")
	}
	actual, err := readDriveLayout(s.disk)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read GPT before Legacy boot clear: %w", err)
	}
	verified, err := verifyMediaLayout(media, actual)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("GPT changed before Legacy boot clear: %w", err)
	}
	region, err := legacyboot.ComputeRegion(actual.Header.StartingUsableOffset, verified.ESP.StartBytes, s.sectorBytes)
	if err != nil {
		return legacyboot.Audit{}, err
	}
	zeroStage1 := legacyboot.ZeroBytes(legacyboot.Stage1CodeBytes)
	zeroCore := legacyboot.ZeroBytes(int(legacyboot.CoreSlotBytes))
	audit, err := applyLegacyBootArea(s.disk, s.diskBytes, s.sectorBytes, actual.Header.StartingUsableOffset, verified.ESP.StartBytes, zeroStage1, zeroCore)
	if err != nil {
		return audit, err
	}
	finalLayout, err := readDriveLayout(s.disk)
	if err != nil {
		return audit, fmt.Errorf("read GPT after Legacy boot clear: %w", err)
	}
	if _, err := verifyMediaLayout(media, finalLayout); err != nil {
		return audit, fmt.Errorf("GPT changed while clearing Legacy boot area: %w", err)
	}
	s.legacyCleared = true
	s.legacyCoreStart = region.CoreStartBytes
	s.legacyCoreLength = region.CoreSizeBytes
	return audit, nil
}

func (s *destructiveSession) VerifyLegacyBootCleared() error {
	if s.closed {
		return fmt.Errorf("destructive session is closed")
	}
	if !s.legacyCleared {
		return fmt.Errorf("Legacy boot area was not cleared in this session")
	}
	sector, err := readDiskExact(s.disk, 0, int(s.sectorBytes))
	if err != nil {
		return fmt.Errorf("read LBA0 during uninstall Legacy verification: %w", err)
	}
	if err := legacyboot.ValidateProtectiveMBR(sector, s.diskBytes, s.sectorBytes); err != nil {
		return fmt.Errorf("Protective MBR invalid after uninstall: %w", err)
	}
	if !bytes.Equal(sector[:legacyboot.Stage1CodeBytes], legacyboot.ZeroBytes(legacyboot.Stage1CodeBytes)) {
		return fmt.Errorf("Legacy Stage 1 bytes are not zero after uninstall")
	}
	core, err := readDiskExact(s.disk, s.legacyCoreStart, int(s.legacyCoreLength))
	if err != nil {
		return fmt.Errorf("read Legacy Core region after uninstall: %w", err)
	}
	if !bytes.Equal(core, legacyboot.ZeroBytes(len(core))) {
		return fmt.Errorf("Legacy Core region is not zero after uninstall")
	}
	return nil
}
