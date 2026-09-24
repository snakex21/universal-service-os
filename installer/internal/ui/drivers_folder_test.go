package ui

import (
	"testing"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/installed"
)

func TestDataDriversFolder(t *testing.T) {
	esp := domain.Volume{GUIDPath: `\\?\Volume{e}\`, MountPaths: []string{`S:\`}, Label: "USOS_ESP"}
	data := domain.Volume{GUIDPath: `\\?\Volume{d}\`, MountPaths: []string{`C:\mnt\usos\`, `h:\`}, Label: "USOS_DATA"}
	target := installed.Target{
		Disk:  domain.Disk{Number: 7, Volumes: []domain.Volume{esp, data}},
		Media: install.MediaLayout{DATA: install.PartitionRef{VolumePath: `\\?\VOLUME{D}`}},
	}
	if got, ok := dataDriversFolder(target); !ok || got != `H:\Drivers` {
		t.Fatalf("by GUID: %q %v", got, ok)
	}
	// No GUID path known: the DATA label decides.
	target.Media = install.MediaLayout{}
	if got, ok := dataDriversFolder(target); !ok || got != `H:\Drivers` {
		t.Fatalf("by label: %q %v", got, ok)
	}
	if got, ok := driversFolderForDisk([]installed.Target{{Disk: domain.Disk{Number: 3}}, target}, 7); !ok || got != `H:\Drivers` {
		t.Fatalf("by disk: %q %v", got, ok)
	}
	if _, ok := driversFolderForDisk([]installed.Target{target}, 8); ok {
		t.Fatal("another disk matched")
	}
	// DATA without a drive letter: unknown, the button stays disabled.
	target.Disk.Volumes[1].MountPaths = []string{`C:\mnt\usos\`}
	if got, ok := dataDriversFolder(target); ok {
		t.Fatalf("folder mount accepted: %q", got)
	}
	target.Disk.Volumes = []domain.Volume{esp}
	if _, ok := dataDriversFolder(target); ok {
		t.Fatal("ESP taken as DATA")
	}
}
