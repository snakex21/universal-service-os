//go:build windows

package winhost

import (
	"fmt"
	"sort"

	"github.com/snakex21/universal-service-os/installer/internal/domain"
)

type Enumerator struct{}

func (Enumerator) ListDisks() ([]domain.Disk, error) {
	numbers, err := physicalDiskNumbers()
	if err != nil {
		return nil, err
	}
	volumes, err := enumerateVolumes()
	if err != nil {
		return nil, err
	}
	systemDisks, err := systemDiskNumbers()
	if err != nil {
		return nil, fmt.Errorf("identify Windows system disk: %w", err)
	}

	volumesByDisk := make(map[uint32][]domain.Volume)
	for _, volume := range volumes {
		for _, number := range volume.DiskNumbers {
			volumesByDisk[number] = append(volumesByDisk[number], volume.Info)
		}
	}

	result := make([]domain.Disk, 0, len(numbers))
	for _, number := range numbers {
		disk, inspectErr := inspectPhysicalDisk(number)
		if inspectErr != nil {
			disk = domain.Disk{
				Number:          number,
				InspectionError: inspectErr.Error(),
			}
		}
		_, disk.SystemDisk = systemDisks[number]
		disk.Volumes = append([]domain.Volume(nil), volumesByDisk[number]...)
		sort.Slice(disk.Volumes, func(i, j int) bool {
			return disk.Volumes[i].GUIDPath < disk.Volumes[j].GUIDPath
		})
		result = append(result, domain.ApplyEligibility(disk))
	}

	sort.Slice(result, func(i, j int) bool { return result[i].Number < result[j].Number })
	return result, nil
}
