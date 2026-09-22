//go:build windows

package winhost

import (
	"bytes"
	"fmt"
	"io"
	"math"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
	"golang.org/x/sys/windows"
)

func (s *destructiveSession) WriteLegacyBoot(media install.MediaLayout) (legacyboot.Audit, error) {
	if s.closed {
		return legacyboot.Audit{}, fmt.Errorf("destructive session is closed")
	}
	if !s.created {
		return legacyboot.Audit{}, fmt.Errorf("refusing Legacy boot write before GPT creation")
	}
	boot, err := payload.LegacyBoot()
	if err != nil {
		return legacyboot.Audit{}, err
	}
	actual, err := readDriveLayout(s.disk)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read GPT before Legacy boot write: %w", err)
	}
	verified, err := verifyMediaLayout(media, actual)
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("GPT changed before Legacy boot write: %w", err)
	}
	return applyLegacyBootArea(s.disk, s.diskBytes, s.sectorBytes, actual.Header.StartingUsableOffset, verified.ESP.StartBytes, boot.Stage1, boot.Core)
}

func (s *destructiveSession) VerifyLegacyBoot(media install.MediaLayout) error {
	if s.closed {
		return fmt.Errorf("destructive session is closed")
	}
	boot, err := payload.LegacyBoot()
	if err != nil {
		return err
	}
	actual, err := readDriveLayout(s.disk)
	if err != nil {
		return fmt.Errorf("read GPT during Legacy boot verification: %w", err)
	}
	verified, err := verifyMediaLayout(media, actual)
	if err != nil {
		return fmt.Errorf("GPT changed during Legacy boot verification: %w", err)
	}
	return verifyLegacyBootArea(s.disk, s.diskBytes, s.sectorBytes, actual.Header.StartingUsableOffset, verified.ESP.StartBytes, boot.Stage1, boot.Core)
}

func applyLegacyBootArea(handle windows.Handle, diskBytes uint64, sectorBytes uint32, startingUsableOffset, espStartBytes uint64, desiredStage1, desiredCore []byte) (legacyboot.Audit, error) {
	if len(desiredStage1) != legacyboot.Stage1CodeBytes {
		return legacyboot.Audit{}, fmt.Errorf("desired Stage 1 length=%d, want %d", len(desiredStage1), legacyboot.Stage1CodeBytes)
	}
	if uint64(len(desiredCore)) != legacyboot.CoreSlotBytes {
		return legacyboot.Audit{}, fmt.Errorf("desired Core slot length=%d, want %d", len(desiredCore), legacyboot.CoreSlotBytes)
	}
	if err := legacyboot.ValidateCoreSlot(desiredCore); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("refusing invalid Legacy Core slot: %w", err)
	}
	region, err := legacyboot.ComputeRegion(startingUsableOffset, espStartBytes, sectorBytes)
	if err != nil {
		return legacyboot.Audit{}, err
	}

	sectorBefore, err := readDiskExact(handle, 0, int(sectorBytes))
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read complete LBA0 before Legacy write: %w", err)
	}
	if err := legacyboot.ValidateProtectiveMBR(sectorBefore, diskBytes, sectorBytes); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("refusing Legacy LBA0 write: %w", err)
	}
	coreBefore, err := readDiskExact(handle, region.CoreStartBytes, int(region.CoreSizeBytes))
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read Legacy Core region before write: %w", err)
	}

	// The entire fixed 256 KiB slot is zeroed first. This removes stale bytes
	// from older/smaller Core versions. Stage 1 is still untouched at this point.
	zeroSlot := legacyboot.ZeroBytes(int(region.CoreSizeBytes))
	if err := writeDiskExact(handle, region.CoreStartBytes, zeroSlot); err != nil {
		return legacyboot.MakeAudit(sectorBefore[:legacyboot.Stage1CodeBytes], sectorBefore[:legacyboot.Stage1CodeBytes], desiredStage1, coreBefore, coreBefore, desiredCore), fmt.Errorf("zero Legacy Core slot: %w", err)
	}
	if err := windows.FlushFileBuffers(handle); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("flush zeroed Legacy Core slot: %w", err)
	}
	zeroReadback, err := readDiskExact(handle, region.CoreStartBytes, int(region.CoreSizeBytes))
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read back zeroed Legacy Core slot: %w", err)
	}
	if !bytes.Equal(zeroReadback, zeroSlot) {
		return legacyboot.MakeAudit(sectorBefore[:legacyboot.Stage1CodeBytes], sectorBefore[:legacyboot.Stage1CodeBytes], desiredStage1, coreBefore, zeroReadback, desiredCore), fmt.Errorf("Legacy Core slot zero read-back mismatch")
	}

	// Core is written before Stage 1. If it fails, LBA0 remains untouched and
	// no new Stage 1 is left pointing at an incomplete Core.
	if err := writeDiskExact(handle, region.CoreStartBytes, desiredCore); err != nil {
		return legacyboot.MakeAudit(sectorBefore[:legacyboot.Stage1CodeBytes], sectorBefore[:legacyboot.Stage1CodeBytes], desiredStage1, coreBefore, zeroReadback, desiredCore), fmt.Errorf("write Legacy Core slot: %w", err)
	}
	if err := windows.FlushFileBuffers(handle); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("flush Legacy Core slot write: %w", err)
	}
	coreAfter, err := readDiskExact(handle, region.CoreStartBytes, int(region.CoreSizeBytes))
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read back complete Legacy Core slot: %w", err)
	}
	if !bytes.Equal(coreAfter, desiredCore) {
		return legacyboot.MakeAudit(sectorBefore[:legacyboot.Stage1CodeBytes], sectorBefore[:legacyboot.Stage1CodeBytes], desiredStage1, coreBefore, coreAfter, desiredCore), fmt.Errorf("complete Legacy Core slot read-back mismatch")
	}

	expectedSector, err := legacyboot.ExpectedSectorWithStage1(sectorBefore, desiredStage1)
	if err != nil {
		return legacyboot.Audit{}, err
	}
	if err := writeDiskExact(handle, 0, expectedSector); err != nil {
		return legacyboot.MakeAudit(sectorBefore[:legacyboot.Stage1CodeBytes], sectorBefore[:legacyboot.Stage1CodeBytes], desiredStage1, coreBefore, coreAfter, desiredCore), fmt.Errorf("write complete LBA0 with preserved Protective MBR: %w", err)
	}
	if err := windows.FlushFileBuffers(handle); err != nil {
		return legacyboot.Audit{}, fmt.Errorf("flush LBA0 Legacy Stage 1 write: %w", err)
	}
	sectorAfter, err := readDiskExact(handle, 0, int(sectorBytes))
	if err != nil {
		return legacyboot.Audit{}, fmt.Errorf("read back complete LBA0 after Legacy write: %w", err)
	}
	audit := legacyboot.MakeAudit(sectorBefore[:legacyboot.Stage1CodeBytes], sectorAfter[:legacyboot.Stage1CodeBytes], desiredStage1, coreBefore, coreAfter, desiredCore)
	audit.CoreSlotZeroReadbackOK = true
	if !bytes.Equal(sectorAfter, expectedSector) {
		return audit, fmt.Errorf("complete LBA0 read-back mismatch")
	}
	if err := legacyboot.ValidateProtectiveMBR(sectorAfter, diskBytes, sectorBytes); err != nil {
		return audit, fmt.Errorf("Protective MBR changed after Stage 1 write: %w", err)
	}
	if audit.Stage1.AfterSHA256 != audit.Stage1.ExpectedSHA256 || audit.Core.AfterSHA256 != audit.Core.ExpectedSHA256 {
		return audit, fmt.Errorf("Legacy boot SHA-256 mismatch after write")
	}
	return audit, nil
}

func verifyLegacyBootArea(handle windows.Handle, diskBytes uint64, sectorBytes uint32, startingUsableOffset, espStartBytes uint64, expectedStage1, expectedCore []byte) error {
	region, err := legacyboot.ComputeRegion(startingUsableOffset, espStartBytes, sectorBytes)
	if err != nil {
		return err
	}
	sector, err := readDiskExact(handle, 0, int(sectorBytes))
	if err != nil {
		return err
	}
	if err := legacyboot.ValidateProtectiveMBR(sector, diskBytes, sectorBytes); err != nil {
		return err
	}
	if !bytes.Equal(sector[:legacyboot.Stage1CodeBytes], expectedStage1) {
		return fmt.Errorf("Legacy Stage 1 does not match embedded payload")
	}
	core, err := readDiskExact(handle, region.CoreStartBytes, int(region.CoreSizeBytes))
	if err != nil {
		return err
	}
	if !bytes.Equal(core, expectedCore) {
		return fmt.Errorf("Legacy Core does not match embedded payload")
	}
	return nil
}

func verifyLegacyBootClearedArea(handle windows.Handle, diskBytes uint64, sectorBytes uint32, startingUsableOffset, espStartBytes uint64) error {
	return verifyLegacyBootArea(
		handle,
		diskBytes,
		sectorBytes,
		startingUsableOffset,
		espStartBytes,
		legacyboot.ZeroBytes(legacyboot.Stage1CodeBytes),
		legacyboot.ZeroBytes(int(legacyboot.CoreSlotBytes)),
	)
}

func readDiskExact(handle windows.Handle, offset uint64, size int) ([]byte, error) {
	if size < 0 || offset > math.MaxInt64 {
		return nil, fmt.Errorf("invalid raw read offset=%d size=%d", offset, size)
	}
	position, err := windows.Seek(handle, int64(offset), io.SeekStart)
	if err != nil {
		return nil, err
	}
	if position != int64(offset) {
		return nil, fmt.Errorf("raw read seek reached %d, want %d", position, offset)
	}
	buffer := make([]byte, size)
	for done := 0; done < len(buffer); {
		var read uint32
		if err := windows.ReadFile(handle, buffer[done:], &read, nil); err != nil {
			return nil, err
		}
		if read == 0 {
			return nil, io.ErrUnexpectedEOF
		}
		done += int(read)
	}
	return buffer, nil
}

func writeDiskExact(handle windows.Handle, offset uint64, data []byte) error {
	if offset > math.MaxInt64 {
		return fmt.Errorf("invalid raw write offset=%d", offset)
	}
	position, err := windows.Seek(handle, int64(offset), io.SeekStart)
	if err != nil {
		return err
	}
	if position != int64(offset) {
		return fmt.Errorf("raw write seek reached %d, want %d", position, offset)
	}
	for done := 0; done < len(data); {
		var written uint32
		if err := windows.WriteFile(handle, data[done:], &written, nil); err != nil {
			return err
		}
		if written == 0 {
			return io.ErrShortWrite
		}
		done += int(written)
	}
	return nil
}
