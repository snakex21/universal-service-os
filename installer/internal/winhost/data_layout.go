package winhost

import "path/filepath"

type dataProfile struct {
	id         string
	name       string
	unattended bool
}

var windowsProfiles = []dataProfile{
	{"windows-11", "Windows 11", true},
	{"windows-10", "Windows 10", true},
	{"windows-8-1", "Windows 8.1", true},
	{"windows-8", "Windows 8", true},
	{"windows-7", "Windows 7", true},
	{"windows-vista", "Windows Vista", true},
	{"windows-xp", "Windows XP", true},
	{"windows-2000", "Windows 2000", true},
	{"windows-nt-4", "Windows NT 4.0", true},
	{"windows-me", "Windows Me", true},
	{"windows-98-se", "Windows 98 SE", true},
	{"windows-98", "Windows 98", true},
	{"windows-95", "Windows 95", true},
	{"windows-3-11", "Windows 3.11", false},
	{"windows-3-1", "Windows 3.1", false},
}

var linuxProfiles = []dataProfile{
	{"ubuntu", "Ubuntu", true},
	{"debian", "Debian", true},
	{"fedora", "Fedora", true},
	{"linux-mint", "Linux Mint", true},
	{"arch-linux", "Arch Linux", true},
	{"opensuse", "openSUSE", true},
	{"manjaro", "Manjaro", true},
	{"kali-linux", "Kali Linux", true},
	{"other-linux", "Other Linux", true},
}

var betaProfiles = []dataProfile{
	{"windows-whistler", "Windows Whistler", true},
	{"windows-longhorn", "Windows Longhorn", true},
	{"windows-neptune", "Windows Neptune", true},
	{"windows-chicago", "Windows Chicago", true},
	{"windows-memphis", "Windows Memphis", true},
	{"windows-nashville", "Windows Nashville", true},
}

var dosProfiles = []dataProfile{
	{"freedos", "FreeDOS", false},
	{"ms-dos", "MS-DOS", false},
	{"pc-dos", "PC DOS", false},
	{"dr-dos", "DR-DOS", false},
	{"opendos", "OpenDOS", false},
	{"other-dos", "Other DOS", false},
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
	return directories
}

func dataProgramFile(dataRoot, name string) string {
	return filepath.Join(dataRoot, "Programs", "USOS", name)
}
