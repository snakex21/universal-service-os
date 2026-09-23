//go:build windows

package winhost

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

// The programs holding a volume are found in two steps. The file system
// reports which processes have the volume's root folder or the volume itself
// open (FileProcessIdsUsingFile; an Explorer window keeps the folder it shows
// open, which is what usually denies FSCTL_LOCK_VOLUME). The Restart Manager
// (rstrtmgr.dll, part of Windows since Vista) then gives those processes
// their display names in the Windows language ("Eksplorator Windows").
var (
	rstrtmgr                = windows.NewLazySystemDLL("rstrtmgr.dll")
	procRmStartSession      = rstrtmgr.NewProc("RmStartSession")
	procRmRegisterResources = rstrtmgr.NewProc("RmRegisterResources")
	procRmGetList           = rstrtmgr.NewProc("RmGetList")
	procRmEndSession        = rstrtmgr.NewProc("RmEndSession")

	ntdll                      = windows.NewLazySystemDLL("ntdll.dll")
	procNtQueryInformationFile = ntdll.NewProc("NtQueryInformationFile")
)

const (
	cchRmSessionKey           = 32
	cchRmMaxAppName           = 255
	cchRmMaxSvcName           = 63
	errorMoreData             = 234
	fileProcessIdsUsingFile   = 47
	statusInfoLengthMismatch  = 0xC0000004
	processQueryLimitedInfo   = 0x1000
	maxHolderProcessesToQuery = 4096
	maxHolderFolders          = 256
)

// rmUniqueProcess is RM_UNIQUE_PROCESS.
type rmUniqueProcess struct {
	ProcessID        uint32
	ProcessStartTime windows.Filetime
}

// rmProcessInfo is RM_PROCESS_INFO.
type rmProcessInfo struct {
	Process          rmUniqueProcess
	AppName          [cchRmMaxAppName + 1]uint16
	ServiceShortName [cchRmMaxSvcName + 1]uint16
	ApplicationType  uint32
	AppStatus        uint32
	TSSessionID      uint32
	Restartable      int32
}

// volumeHolders lists the display names of the programs that have the
// volume's root folder or one of its folders up to two levels deep open (an
// Explorer window keeps the folder it shows open). Best effort: failures
// yield fewer names, never an error. `mount` is a drive root ("J:\") or any
// folder. The volume device itself is not queried: its answer names every
// process with any handle on the device stack, not the holders.
func volumeHolders(mount string) []string {
	if mount == "" {
		return nil
	}
	pids := map[uint32]bool{}
	for _, folder := range holderFolders(strings.TrimSuffix(mount, `\`)+`\`, 2, maxHolderFolders) {
		for _, pid := range processesUsing(folder, windows.FILE_FLAG_BACKUP_SEMANTICS) {
			pids[pid] = true
		}
	}
	delete(pids, windows.GetCurrentProcessId())
	delete(pids, 0)
	if len(pids) == 0 {
		return nil
	}
	var list []uint32
	for pid := range pids {
		list = append(list, pid)
	}
	return processDisplayNames(list)
}

// holderFolders returns root and its folders breadth first, at most `depth`
// levels below root and `limit` folders in total.
func holderFolders(root string, depth, limit int) []string {
	folders := []string{root}
	level := []string{root}
	for d := 0; d < depth && len(folders) < limit; d++ {
		var next []string
		for _, dir := range level {
			entries, err := os.ReadDir(dir)
			if err != nil {
				continue
			}
			for _, entry := range entries {
				if !entry.IsDir() || entry.Type()&os.ModeSymlink != 0 {
					continue
				}
				if len(folders) >= limit {
					return folders
				}
				path := filepath.Join(dir, entry.Name())
				folders = append(folders, path)
				next = append(next, path)
			}
		}
		level = next
	}
	return folders
}

// processesUsing returns the IDs of the processes with `path` open.
func processesUsing(path string, flags uint32) []uint32 {
	namePtr, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return nil
	}
	handle, err := windows.CreateFile(namePtr, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE, nil, windows.OPEN_EXISTING, flags, 0)
	if err != nil {
		return nil
	}
	defer windows.CloseHandle(handle)
	size := 1024
	for size <= 8*maxHolderProcessesToQuery+16 {
		buffer := make([]byte, size)
		var iosb [2]uintptr
		status, _, _ := procNtQueryInformationFile.Call(uintptr(handle), uintptr(unsafe.Pointer(&iosb[0])), uintptr(unsafe.Pointer(&buffer[0])), uintptr(size), fileProcessIdsUsingFile)
		if uint32(status) == statusInfoLengthMismatch {
			size *= 2
			continue
		}
		if status != 0 {
			return nil
		}
		count := int(*(*uint32)(unsafe.Pointer(&buffer[0])))
		offset := int(unsafe.Sizeof(uintptr(0))) // ULONG count, then ULONG_PTR array (aligned)
		var pids []uint32
		for i := 0; i < count && offset+(i+1)*int(unsafe.Sizeof(uintptr(0))) <= size; i++ {
			pids = append(pids, uint32(*(*uintptr)(unsafe.Pointer(&buffer[offset+i*int(unsafe.Sizeof(uintptr(0)))]))))
		}
		return pids
	}
	return nil
}

// processDisplayNames asks the Restart Manager for the processes' display
// names; a process it cannot name is shown by its executable file name.
func processDisplayNames(pids []uint32) []string {
	seen := map[string]bool{}
	var names []string
	add := func(name string) {
		name = strings.TrimSpace(name)
		if name != "" && !seen[name] {
			seen[name] = true
			names = append(names, name)
		}
	}
	named := map[uint32]bool{}
	var processes []rmUniqueProcess
	images := map[uint32]string{}
	for _, pid := range pids {
		process, err := windows.OpenProcess(processQueryLimitedInfo, false, pid)
		if err != nil {
			continue
		}
		var creation, exit, kernel, user windows.Filetime
		if windows.GetProcessTimes(process, &creation, &exit, &kernel, &user) == nil {
			processes = append(processes, rmUniqueProcess{ProcessID: pid, ProcessStartTime: creation})
		}
		buffer := make([]uint16, windows.MAX_LONG_PATH)
		size := uint32(len(buffer))
		if windows.QueryFullProcessImageName(process, 0, &buffer[0], &size) == nil {
			images[pid] = filepath.Base(windows.UTF16ToString(buffer[:size]))
		}
		windows.CloseHandle(process)
	}
	for _, info := range restartManagerNames(processes) {
		named[info.Process.ProcessID] = true
		add(windows.UTF16ToString(info.AppName[:]))
	}
	for _, pid := range pids {
		if !named[pid] {
			add(images[pid])
		}
	}
	sort.Strings(names)
	return names
}

func restartManagerNames(processes []rmUniqueProcess) []rmProcessInfo {
	if len(processes) == 0 || procRmStartSession.Find() != nil {
		return nil
	}
	var session uint32
	key := make([]uint16, cchRmSessionKey+1)
	if r, _, _ := procRmStartSession.Call(uintptr(unsafe.Pointer(&session)), 0, uintptr(unsafe.Pointer(&key[0]))); r != 0 {
		return nil
	}
	defer procRmEndSession.Call(uintptr(session))
	if r, _, _ := procRmRegisterResources.Call(uintptr(session), 0, 0, uintptr(len(processes)), uintptr(unsafe.Pointer(&processes[0])), 0, 0); r != 0 {
		return nil
	}
	var needed, count, reasons uint32
	var infos []rmProcessInfo
	for attempt := 0; attempt < 4; attempt++ {
		count = uint32(len(infos))
		var first uintptr
		if len(infos) > 0 {
			first = uintptr(unsafe.Pointer(&infos[0]))
		}
		r, _, _ := procRmGetList.Call(uintptr(session), uintptr(unsafe.Pointer(&needed)), uintptr(unsafe.Pointer(&count)), first, uintptr(unsafe.Pointer(&reasons)))
		if r == 0 {
			return infos[:min(int(count), len(infos))]
		}
		if r != errorMoreData {
			return nil
		}
		infos = make([]rmProcessInfo, needed+2)
	}
	return nil
}
