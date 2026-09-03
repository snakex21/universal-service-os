package domain

import (
	"strings"

	"github.com/snakex21/universal-service-os/installer/internal/layout"
)

func ApplyEligibility(d Disk) Disk {
	d.Eligible = false
	d.Reason = ""

	if d.InspectionError != "" {
		d.Reason = "nie udalo sie bezpiecznie odczytac urzadzenia: " + d.InspectionError
		return d
	}
	if d.SystemDisk {
		d.Reason = "dysk zawiera uruchomiony system Windows"
		return d
	}
	if strings.TrimSpace(d.Model) == "" {
		d.Reason = "urzadzenie nie zglasza pelnego modelu wymaganego do potwierdzenia"
		return d
	}
	if strings.TrimSpace(d.Serial) == "" {
		d.Reason = "urzadzenie nie zglasza numeru seryjnego wymaganego do rewalidacji"
		return d
	}
	if d.SpannedVolume {
		d.Reason = "dysk nalezy do woluminu rozlozonego na wiecej niz jednym dysku"
		return d
	}
	if !d.Removable {
		d.Reason = "urzadzenie nie zglasza flagi RemovableMedia"
		return d
	}
	if d.SizeBytes < layout.MinimumDiskBytes {
		d.Reason = "urzadzenie ma mniej niz wymagane 32 GiB"
		return d
	}

	d.Eligible = true
	return d
}
