//go:build windows

package winhost

import (
	"fmt"

	"golang.org/x/sys/windows"
)

func volumeNames() ([]string, error) {
	const volumeNameChars = 1024
	buffer := make([]uint16, volumeNameChars)
	r1, _, callErr := procFindFirstVolumeW.Call(ptrToFirst(buffer), volumeNameChars)
	if windows.Handle(r1) == windows.InvalidHandle {
		return nil, fmt.Errorf("FindFirstVolumeW: %w", callErr)
	}
	searchHandle := windows.Handle(r1)
	defer procFindVolumeClose.Call(uintptr(searchHandle))

	var result []string
	for {
		result = append(result, windows.UTF16ToString(buffer))
		for i := range buffer {
			buffer[i] = 0
		}
		r1, _, callErr = procFindNextVolumeW.Call(uintptr(searchHandle), ptrToFirst(buffer), volumeNameChars)
		if r1 != 0 {
			continue
		}
		if callErr == windows.ERROR_NO_MORE_FILES {
			break
		}
		return nil, fmt.Errorf("FindNextVolumeW: %w", callErr)
	}
	return result, nil
}
