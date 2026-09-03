package uninstall

import (
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

type Target = installed.Target

type MediaLayout struct {
	DiskNumber uint32
	DiskPTUUID string
	Data       install.PartitionRef
}

type VerificationReport struct {
	Items []install.VerificationItem
}

func (r VerificationReport) OK() bool {
	if len(r.Items) == 0 {
		return false
	}
	for _, item := range r.Items {
		if !item.Match {
			return false
		}
	}
	return true
}
