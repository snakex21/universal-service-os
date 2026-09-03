package layout

import "fmt"

const (
	GiB              = uint64(1024 * 1024 * 1024)
	MiB              = uint64(1024 * 1024)
	MinimumDiskBytes = 32 * GiB
	ESPBytes         = 1 * GiB
	WorkMinBytes     = 12 * GiB
	WorkMaxBytes     = 24 * GiB
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
		return Plan{}, fmt.Errorf("disk is too small: %d bytes; minimum is %d", diskBytes, MinimumDiskBytes)
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
