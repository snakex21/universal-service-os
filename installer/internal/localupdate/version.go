package localupdate

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/buildinfo"
	"github.com/snakex21/universal-service-os/installer/internal/payload"
)

func PayloadBuildInfo() (buildinfo.Info, error) {
	bundle, err := payload.Embedded()
	if err != nil {
		return buildinfo.Info{}, err
	}
	info, err := bundle.BuildInfo()
	if err != nil {
		return buildinfo.Info{}, err
	}
	if !info.Valid() {
		return buildinfo.Info{}, fmt.Errorf("embedded payload build info is invalid: %q", info.Display())
	}
	linked := buildinfo.Current()
	if linked.Valid() && (linked.ID != info.ID || linked.Epoch != info.Epoch || linked.SourceSHA256 != info.SourceSHA256) {
		return buildinfo.Info{}, fmt.Errorf("installer build identity does not match embedded payload: installer=%s payload=%s", linked.Display(), info.Display())
	}
	return info, nil
}

func IsDowngrade(installedInfo, payloadInfo buildinfo.Info) bool {
	return installedInfo.Valid() && payloadInfo.Valid() && buildinfo.Compare(installedInfo, payloadInfo) > 0
}
