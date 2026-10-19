package layout

import "fmt"

const (
	GiB = uint64(1024 * 1024 * 1024)
	MiB = uint64(1024 * 1024)
	// MinimumDiskBytes is a decimal threshold so that sticks sold as
	// "16 GB" (vendors count 1 GB = 10^9 B; real capacity is typically
	// 14.4-16.0e9 B, i.e. 13.4-14.9 GiB) are accepted. At this size the
	// small-stick layout gives ESP 1 GiB, WORK 6 GiB and DATA ~6 GiB: room
	// for USOS plus one Windows 7/Vista/XP-class ISO and its WORK copy.
	MinimumDiskBytes = 14_000_000_000
	ESPBytes         = 1 * GiB
	// LegacyLayoutBytes is the disk size from which the original layout
	// (WORK = disk/4 clamped to 12..16 GiB) applies unchanged. Media already
	// installed on such disks must keep matching layout.Build exactly (the
	// Linux updater rejects a GPT that differs from Build).
	LegacyLayoutBytes = 32 * GiB
	WorkMinBytes      = 12 * GiB
	// WorkSmallMinBytes is the WORK floor below LegacyLayoutBytes: one Windows
	// 7 ISO (up to ~5.1 GiB for the largest multi-edition images) + 256 MiB.
	WorkSmallMinBytes = 6 * GiB
	// WORK holds one guarded copy of the selected Windows Setup ISO (BIOS
	// Windows PE path for 7/Vista/10, 8.1/2012 R2 on BIOS, and the generic
	// ISO chainload fallback) plus WinPE drivers; the BIOS path requires
	// source + 256 MiB. XP/2000/NT/9x stage on the target disk, Vista/7 PE10
	// and native Win10/11/8.1 UEFI do not use WORK. The largest supported
	// ISO (Windows 11 25H2, 7.8 GiB via Chainload) leaves ~8 GiB headroom.
	WorkMaxBytes     = 16 * GiB
	AlignmentBytes   = 1 * MiB
	HeadReserveBytes = 1 * MiB
	TailReserveBytes = 1 * MiB
)

type Partition struct {
	StartBytes uint64
	SizeBytes  uint64
}

type Plan struct {
	DiskBytes         uint64
	ESP               Partition
	DATA              Partition
	WORK              Partition
	ReservedHeadBytes uint64
	ReservedTailBytes uint64
}

func WorkBytesForDisk(diskBytes uint64) uint64 {
	if diskBytes < LegacyLayoutBytes {
		// Small sticks: WORK = 3/8 of the disk, at least 6 GiB. The ratio
		// meets the legacy 12 GiB exactly at 32 GiB, so the size is
		// continuous across the boundary.
		work := diskBytes / 8 * 3
		if work < WorkSmallMinBytes {
			return WorkSmallMinBytes
		}
		if work > WorkMinBytes {
			return WorkMinBytes
		}
		return alignDown(work, AlignmentBytes)
	}
	work := diskBytes / 4
	if work < WorkMinBytes {
		return WorkMinBytes
	}
	if work > WorkMaxBytes {
		return WorkMaxBytes
	}
	return alignDown(work, AlignmentBytes)
}

func Build(diskBytes uint64) (Plan, error) {
	if diskBytes < MinimumDiskBytes {
		return Plan{}, fmt.Errorf("disk is too small: %d bytes (%.1f GB); minimum is %d bytes (a stick sold as 16 GB)", diskBytes, float64(diskBytes)/1e9, MinimumDiskBytes)
	}

	usableEnd := alignDown(diskBytes-TailReserveBytes, AlignmentBytes)
	espStart := alignUp(HeadReserveBytes, AlignmentBytes)
	espEnd := espStart + ESPBytes
	workSize := WorkBytesForDisk(diskBytes)
	if usableEnd <= workSize {
		return Plan{}, fmt.Errorf("disk cannot fit WORK after GPT tail reserve")
	}
	workStart := alignDown(usableEnd-workSize, AlignmentBytes)
	dataStart := alignUp(espEnd, AlignmentBytes)
	if workStart <= dataStart {
		return Plan{}, fmt.Errorf("disk cannot fit ESP, DATA and WORK")
	}

	return Plan{
		DiskBytes: diskBytes,
		ESP: Partition{
			StartBytes: espStart,
			SizeBytes:  ESPBytes,
		},
		DATA: Partition{
			StartBytes: dataStart,
			SizeBytes:  workStart - dataStart,
		},
		WORK: Partition{
			StartBytes: workStart,
			SizeBytes:  usableEnd - workStart,
		},
		ReservedHeadBytes: espStart,
		ReservedTailBytes: diskBytes - usableEnd,
	}, nil
}

func (p Plan) ValidateSectorSize(bytesPerSector uint32) error {
	if bytesPerSector == 0 {
		return fmt.Errorf("logical sector size is zero")
	}
	sector := uint64(bytesPerSector)
	values := []uint64{
		p.ESP.StartBytes,
		p.ESP.SizeBytes,
		p.DATA.StartBytes,
		p.DATA.SizeBytes,
		p.WORK.StartBytes,
		p.WORK.SizeBytes,
	}
	for _, value := range values {
		if value%sector != 0 {
			return fmt.Errorf("layout value %d is not aligned to logical sector size %d", value, sector)
		}
	}
	return nil
}

func alignUp(value, alignment uint64) uint64 {
	if alignment == 0 || value%alignment == 0 {
		return value
	}
	return value + alignment - value%alignment
}

func alignDown(value, alignment uint64) uint64 {
	if alignment == 0 {
		return value
	}
	return value - value%alignment
}
