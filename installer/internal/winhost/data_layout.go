package winhost

import (
	"fmt"
	"os"
	"path/filepath"
)

type dataProfile struct {
	id         string
	name       string
	unattended bool
	// ntSetup marks the NT setup-based Windows versions (2000 and newer)
	// whose DATA\Drivers\<name> folder is split into Storage, USB and Other.
	ntSetup bool
}

var windowsProfiles = []dataProfile{
	{"windows-11", "Windows 11", true, true},
	{"windows-10", "Windows 10", true, true},
	{"windows-8-1", "Windows 8.1", true, true},
	{"windows-8", "Windows 8", true, true},
	{"windows-7", "Windows 7", true, true},
	{"windows-vista", "Windows Vista", true, true},
	{"windows-xp", "Windows XP", true, true},
	{"windows-2000", "Windows 2000", true, true},
	{"windows-nt-4", "Windows NT 4.0", true, false},
	{"windows-me", "Windows Me", true, false},
	{"windows-98-se", "Windows 98 SE", true, false},
	{"windows-98", "Windows 98", true, false},
	{"windows-95", "Windows 95", true, false},
	{"windows-3-11", "Windows 3.11", false, false},
	{"windows-3-1", "Windows 3.1", false, false},
	// Windows Server (src/catalog/windows_server.zig); 2003/2000 Server
	// come with the NT5 staging.
	{"windows-server-2025", "Windows Server 2025", true, true},
	{"windows-server-2022", "Windows Server 2022", true, true},
	{"windows-server-2019", "Windows Server 2019", true, true},
	{"windows-server-2016", "Windows Server 2016", true, true},
	{"windows-server-2012-r2", "Windows Server 2012 R2", true, true},
	{"windows-server-2012", "Windows Server 2012", true, true},
	{"windows-server-2008-r2", "Windows Server 2008 R2", true, true},
	{"windows-server-2008", "Windows Server 2008", true, true},
}

var linuxProfiles = []dataProfile{
	{"ubuntu", "Ubuntu", true, false},
	{"debian", "Debian", true, false},
	{"fedora", "Fedora", true, false},
	{"linux-mint", "Linux Mint", true, false},
	{"arch-linux", "Arch Linux", true, false},
	{"opensuse", "openSUSE", true, false},
	{"manjaro", "Manjaro", true, false},
	{"kali-linux", "Kali Linux", true, false},
	{"other-linux", "Other Linux", true, false},
}

var betaProfiles = []dataProfile{
	{"windows-whistler", "Windows Whistler", true, false},
	{"windows-longhorn", "Windows Longhorn", true, false},
	{"windows-neptune", "Windows Neptune", true, false},
	{"windows-chicago", "Windows Chicago", true, false},
	{"windows-memphis", "Windows Memphis", true, false},
	{"windows-nashville", "Windows Nashville", true, false},
}

var dosProfiles = []dataProfile{
	{"freedos", "FreeDOS", false, false},
	{"ms-dos", "MS-DOS", false, false},
	{"pc-dos", "PC DOS", false, false},
	{"dr-dos", "DR-DOS", false, false},
	{"opendos", "OpenDOS", false, false},
	{"other-dos", "Other DOS", false, false},
}

var requiredDataDirectories = buildRequiredDataDirectories()

func buildRequiredDataDirectories() []string {
	directories := make([]string, 0, 80)
	appendProfiles := func(categoryRoot string, profiles []dataProfile) {
		for _, profile := range profiles {
			root := filepath.Join(categoryRoot, profile.name)
			directories = append(directories, filepath.Join(root, "Images"))
			if profile.unattended {
				directories = append(directories, filepath.Join(root, "Unattended"))
			}
		}
	}
	appendProfiles(filepath.Join("Systems", "Windows"), windowsProfiles)
	appendProfiles(filepath.Join("Systems", "Linux"), linuxProfiles)
	appendProfiles(filepath.Join("Systems", "Betas"), betaProfiles)
	appendProfiles(filepath.Join("Systems", "DOS"), dosProfiles)
	directories = append(directories, "Utilities", "Programs", filepath.Join("Programs", "USOS"))
	directories = append(directories, filepath.Join("Systems", "DOS", "MS-DOS", "Programs"))
	directories = append(directories, filepath.Join("Utilities", "FreeDOS", "Programs"))
	directories = append(directories, filepath.Join("Systems", "Windows", "Windows 7", "Drivers", "x64"))
	directories = append(directories, driverDataDirectories()...)
	return directories
}

// driverClasses are the per-OS driver folders of the NT setup-based
// Windows versions: Storage and USB are loaded in Windows Setup and injected
// into the installed system, Other only into the installed system.
var driverClasses = []string{"Storage", "USB", "Other"}

// driverDataDirectories is the DATA\Drivers tree: UEFI drivers for the USOS
// menu and one folder per Windows profile for INF driver packages.
func driverDataDirectories() []string {
	directories := []string{"Drivers", filepath.Join("Drivers", "UEFI")}
	for _, profile := range windowsProfiles {
		root := filepath.Join("Drivers", profile.name)
		directories = append(directories, root)
		if profile.ntSetup {
			for _, class := range driverClasses {
				directories = append(directories, filepath.Join(root, class))
			}
		}
	}
	return directories
}

// ensureDataDirectories creates the DATA layout under root. It only ever
// creates missing directories (install and update both call it), so user
// files, e.g. drivers under DATA\Drivers, are never touched.
func ensureDataDirectories(root string) error {
	for _, directory := range requiredDataDirectories {
		if err := os.MkdirAll(filepath.Join(root, directory), 0o755); err != nil {
			return fmt.Errorf("create DATA directory %s: %w", directory, err)
		}
	}
	return nil
}

func dataProgramFile(dataRoot, name string) string {
	return filepath.Join(dataRoot, "Programs", "USOS", name)
}
