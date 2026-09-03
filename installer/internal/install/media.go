package install

import "github.com/snakex21/universal-service-os/installer/internal/layout"

type PartitionRef struct {
	Number     uint32
	StartBytes uint64
	SizeBytes  uint64
	PartUUID   string
	VolumePath string
}

type MediaLayout struct {
	DiskNumber uint32
	DiskPTUUID string
	ESP        PartitionRef
	DATA       PartitionRef
	WORK       PartitionRef
}

type InstallRequest struct {
	DiskNumber                 uint32
	ExpectedModel              string
	ExpectedSerial             string
	ExpectedSize               uint64
	ExpectedIdentityDiskNumber uint32
	Plan                       layout.Plan
}
