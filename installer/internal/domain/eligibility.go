package domain

import (
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

func ApplyEligibility(d Disk) Disk {
	d.Eligible = false
	d.Reason = ""

	if d.InspectionError != "" {
		d.Reason = i18n.T("installer.reason.inspection_failed", d.InspectionError)
		return d
	}
	if d.SystemDisk {
		d.Reason = i18n.T("installer.reason.system_disk")
		return d
	}
	if strings.TrimSpace(d.Model) == "" {
		d.Reason = i18n.T("installer.reason.no_model")
		return d
	}
	if strings.TrimSpace(d.Serial) == "" {
		d.Reason = i18n.T("installer.reason.no_serial")
		return d
	}
	if d.SpannedVolume {
		d.Reason = i18n.T("installer.reason.spanned_volume")
		return d
	}
	if !d.Removable {
		d.Reason = i18n.T("installer.reason.not_removable")
		return d
	}
	if d.SizeBytes < layout.MinimumDiskBytes {
		d.Reason = i18n.T("installer.reason.too_small")
		return d
	}

	d.Eligible = true
	return d
}
