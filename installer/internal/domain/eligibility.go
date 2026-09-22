package domain

import (
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

func ApplyEligibility(d Disk) Disk {
	d.Eligible = false
	d.Reason = ""

	if d.InspectionError != "" {
		d.Reason = "nie udało się bezpiecznie odczytać urządzenia: " + d.InspectionError
		return d
	}
	if d.SystemDisk {
		d.Reason = "dysk zawiera uruchomiony system Windows"
		return d
	}
	if strings.TrimSpace(d.Model) == "" {
		d.Reason = "urządzenie nie zgłasza pełnego modelu wymaganego do potwierdzenia"
		return d
	}
	if strings.TrimSpace(d.Serial) == "" {
		d.Reason = "urządzenie nie zgłasza numeru seryjnego wymaganego do rewalidacji"
		return d
	}
	if d.SpannedVolume {
		d.Reason = "dysk należy do woluminu rozłożonego na więcej niż jednym dysku"
		return d
	}
	if !d.Removable {
		d.Reason = "urządzenie nie zgłasza flagi RemovableMedia"
		return d
	}
	if d.SizeBytes < layout.MinimumDiskBytes {
		d.Reason = "urządzenie ma mniej niż wymagane 32 GB"
		return d
	}

	d.Eligible = true
	return d
}
