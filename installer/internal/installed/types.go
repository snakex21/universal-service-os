package installed

import (
	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
)

type Target struct {
	Disk      domain.Disk
	Identity  install.DeviceINI
	Media     install.MediaLayout
	BuildInfo buildinfo.Info
}
