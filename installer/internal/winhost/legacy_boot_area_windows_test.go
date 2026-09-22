//go:build windows

package winhost

import (
	"bytes"
	"encoding/binary"
	"os"
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/legacyboot"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
	"golang.org/x/sys/windows"
)

func TestApplyLegacyBootAreaUsesFull256KiBSlotAndPreservesProtectiveMBR(t *testing.T) {
	boot, err := payload.LegacyBoot()
	if err != nil {
		t.Fatal(err)
	}
	if uint64(len(boot.Core)) != legacyboot.CoreSlotBytes {
		t.Fatalf("embedded Core slot=%d want=%d", len(boot.Core), legacyboot.CoreSlotBytes)
	}

	const diskBytes = uint64(2 * 1024 * 1024)
	file, err := os.CreateTemp(t.TempDir(), "legacy-raw-*.img")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := file.Truncate(int64(diskBytes)); err != nil {
		t.Fatal(err)
	}

	sectorBefore := make([]byte, legacyboot.SupportedSectorBytes)
	for i := 440; i < 446; i++ {
		sectorBefore[i] = byte(i - 439)
	}
	entry := sectorBefore[legacyboot.MBRPartitionOffset : legacyboot.MBRPartitionOffset+16]
	entry[4] = 0xEE
	binary.LittleEndian.PutUint32(entry[8:12], 1)
	binary.LittleEndian.PutUint32(entry[12:16], uint32(diskBytes/uint64(legacyboot.SupportedSectorBytes)-1))
	sectorBefore[legacyboot.MBRSignatureOffset] = 0x55
	sectorBefore[legacyboot.MBRSignatureOffset+1] = 0xAA
	if _, err := file.WriteAt(sectorBefore, 0); err != nil {
		t.Fatal(err)
	}

	oldSlot := bytes.Repeat([]byte{0xA5}, int(legacyboot.CoreSlotBytes))
	if _, err := file.WriteAt(oldSlot, int64(legacyboot.CoreLBA*uint64(legacyboot.SupportedSectorBytes))); err != nil {
		t.Fatal(err)
	}
	if err := file.Sync(); err != nil {
		t.Fatal(err)
	}

	handle := windows.Handle(file.Fd())
	audit, err := applyLegacyBootArea(
		handle,
		diskBytes,
		legacyboot.SupportedSectorBytes,
		34*uint64(legacyboot.SupportedSectorBytes),
		2048*uint64(legacyboot.SupportedSectorBytes),
		boot.Stage1,
		boot.Core,
	)
	if err != nil {
		t.Fatal(err)
	}
	if !audit.CoreSlotZeroReadbackOK {
		t.Fatal("Core slot zero read-back was not audited as PASS")
	}
	if !audit.Stage1.Changed || !audit.Core.Changed {
		t.Fatalf("expected Stage1 and Core slot to change: %+v", audit)
	}

	sectorAfter, err := readDiskExact(handle, 0, int(legacyboot.SupportedSectorBytes))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(sectorAfter[440:], sectorBefore[440:]) {
		t.Fatal("LBA0 bytes 440..511 changed")
	}
	if !bytes.Equal(sectorAfter[:legacyboot.Stage1CodeBytes], boot.Stage1) {
		t.Fatal("Stage1 read-back mismatch")
	}

	coreAfter, err := readDiskExact(handle, legacyboot.CoreLBA*uint64(legacyboot.SupportedSectorBytes), int(legacyboot.CoreSlotBytes))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(coreAfter, boot.Core) {
		t.Fatal("full 256 KiB Core slot read-back mismatch")
	}
}
