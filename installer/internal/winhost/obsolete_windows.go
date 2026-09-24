//go:build windows

package winhost

import (
	"fmt"
	"time"

	"github.com/snakex21/universal-service-os/installer/internal/install"
	"github.com/snakex21/universal-service-os/installer/internal/obsolete"
)

// RemoveObsoleteESPFiles deletes the known leftovers of earlier experiments
// (obsolete.ESPFiles: exact path and SHA-256) from the revalidated ESP during
// update and repair. Unknown files, and known paths with other content, stay.
func (b Backend) RemoveObsoleteESPFiles(media install.MediaLayout) ([]obsolete.Result, error) {
	resolved, err := resolveFormattedMedia(media, 10*time.Second)
	if err != nil {
		return nil, fmt.Errorf("resolve formatted ESP for obsolete files: %w", err)
	}
	results, err := obsolete.RemoveKnown(resolved.ESP.VolumePath, obsolete.ESPFiles)
	if err != nil {
		return results, err
	}
	for _, result := range results {
		if result.Action == obsolete.ActionRemoved {
			if err := flushVolume(resolved.ESP.VolumePath); err != nil {
				return results, fmt.Errorf("flush ESP after removing obsolete files: %w", err)
			}
			break
		}
	}
	return results, nil
}
