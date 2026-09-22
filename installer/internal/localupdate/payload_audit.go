package localupdate

import (
	"fmt"
	"sort"
	"strings"
)

const bootManagerPayloadPath = "EFI/BOOT/BOOTX64.EFI"

type PayloadFileStatus struct {
	Path           string
	ActualSHA256   string
	ExpectedSHA256 string
}

func auditPayloadBefore(statuses []PayloadFileStatus, log func(string)) (map[string]PayloadFileStatus, error) {
	ordered, err := normalizePayloadStatuses(statuses)
	if err != nil {
		return nil, err
	}
	byPath := make(map[string]PayloadFileStatus, len(ordered))
	for _, status := range ordered {
		key := strings.ToLower(status.Path)
		byPath[key] = status
		log(fmt.Sprintf(
			"PAYLOAD BEFORE path=%s sha256=%s expected=%s",
			status.Path,
			hashForLog(status.ActualSHA256),
			strings.ToUpper(status.ExpectedSHA256),
		))
	}
	return byPath, nil
}

func auditPayloadAfter(before map[string]PayloadFileStatus, statuses []PayloadFileStatus, payloadBuildID string, log func(string)) error {
	ordered, err := normalizePayloadStatuses(statuses)
	if err != nil {
		return err
	}
	if len(ordered) != len(before) {
		return fmt.Errorf("payload file count changed during update: before=%d after=%d", len(before), len(ordered))
	}

	seen := make(map[string]bool, len(ordered))
	for _, status := range ordered {
		key := strings.ToLower(status.Path)
		previous, ok := before[key]
		if !ok {
			return fmt.Errorf("payload file appeared during update: %s", status.Path)
		}
		seen[key] = true
		if !strings.EqualFold(previous.ExpectedSHA256, status.ExpectedSHA256) {
			return fmt.Errorf("embedded payload identity changed during update for %s: before=%s after=%s", status.Path, previous.ExpectedSHA256, status.ExpectedSHA256)
		}
		if status.ActualSHA256 == "" || !strings.EqualFold(status.ActualSHA256, status.ExpectedSHA256) {
			return fmt.Errorf("payload SHA-256 mismatch after write for %s: got=%s want=%s", status.Path, hashForLog(status.ActualSHA256), strings.ToUpper(status.ExpectedSHA256))
		}
		changed := !strings.EqualFold(previous.ActualSHA256, status.ActualSHA256)
		log(fmt.Sprintf(
			"PAYLOAD AFTER path=%s sha256=%s expected=%s changed=%s build=%s",
			status.Path,
			strings.ToUpper(status.ActualSHA256),
			strings.ToUpper(status.ExpectedSHA256),
			yesNo(changed),
			payloadBuildID,
		))
		if strings.EqualFold(status.Path, bootManagerPayloadPath) {
			log(fmt.Sprintf(
				"BOOTMANAGER AFTER path=EFI\\BOOT\\BOOTX64.EFI sha256=%s expected=%s changed=%s build=%s",
				strings.ToUpper(status.ActualSHA256),
				strings.ToUpper(status.ExpectedSHA256),
				yesNo(changed),
				payloadBuildID,
			))
		}
	}
	for key := range before {
		if !seen[key] {
			return fmt.Errorf("payload file disappeared during update: %s", before[key].Path)
		}
	}
	return nil
}

func normalizePayloadStatuses(statuses []PayloadFileStatus) ([]PayloadFileStatus, error) {
	if len(statuses) == 0 {
		return nil, fmt.Errorf("embedded payload contains no files")
	}
	ordered := append([]PayloadFileStatus(nil), statuses...)
	sort.Slice(ordered, func(i, j int) bool {
		return strings.ToLower(ordered[i].Path) < strings.ToLower(ordered[j].Path)
	})
	seen := make(map[string]bool, len(ordered))
	for _, status := range ordered {
		if strings.TrimSpace(status.Path) == "" {
			return nil, fmt.Errorf("payload status has empty path")
		}
		if strings.TrimSpace(status.ExpectedSHA256) == "" {
			return nil, fmt.Errorf("payload status has no expected SHA-256 for %s", status.Path)
		}
		key := strings.ToLower(status.Path)
		if seen[key] {
			return nil, fmt.Errorf("duplicate payload status path: %s", status.Path)
		}
		seen[key] = true
	}
	return ordered, nil
}

func hashForLog(hash string) string {
	if hash == "" {
		return "MISSING"
	}
	return strings.ToUpper(hash)
}

func yesNo(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}
