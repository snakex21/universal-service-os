package install

import (
	"bufio"
	"fmt"
	"io"
	"strings"
)

type DeviceINI struct {
	Nonce        string
	DiskPTUUID   string
	ESPPartUUID  string
	DataPartUUID string
	WorkPartUUID string
	WorkLabel    string
	DataLabel    string
	WorkBytes    uint64
}

func (d DeviceINI) Validate() error {
	fields := map[string]string{
		"nonce":         d.Nonce,
		"disk_ptuuid":   d.DiskPTUUID,
		"esp_partuuid":  d.ESPPartUUID,
		"data_partuuid": d.DataPartUUID,
		"work_partuuid": d.WorkPartUUID,
		"work_label":    d.WorkLabel,
		"data_label":    d.DataLabel,
	}
	for name, value := range fields {
		if strings.TrimSpace(value) == "" {
			return fmt.Errorf("missing %s", name)
		}
	}
	if d.WorkBytes == 0 {
		return fmt.Errorf("missing work_bytes")
	}
	return nil
}

func (d DeviceINI) String() string {
	return fmt.Sprintf("[device]\r\nnonce=%s\r\ndisk_ptuuid=%s\r\nesp_partuuid=%s\r\ndata_partuuid=%s\r\nwork_partuuid=%s\r\nwork_label=%s\r\ndata_label=%s\r\nwork_bytes=%d\r\n",
		d.Nonce,
		d.DiskPTUUID,
		d.ESPPartUUID,
		d.DataPartUUID,
		d.WorkPartUUID,
		d.WorkLabel,
		d.DataLabel,
		d.WorkBytes,
	)
}

func ParseDeviceINI(r io.Reader) (DeviceINI, error) {
	var result DeviceINI
	scanner := bufio.NewScanner(r)
	section := ""
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		if section != "device" {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			return DeviceINI{}, fmt.Errorf("invalid line %q", line)
		}
		key = strings.ToLower(strings.TrimSpace(key))
		value = strings.TrimSpace(value)
		switch key {
		case "nonce":
			result.Nonce = value
		case "disk_ptuuid":
			result.DiskPTUUID = value
		case "esp_partuuid":
			result.ESPPartUUID = value
		case "data_partuuid":
			result.DataPartUUID = value
		case "work_partuuid":
			result.WorkPartUUID = value
		case "work_label":
			result.WorkLabel = value
		case "data_label":
			result.DataLabel = value
		case "work_bytes":
			var n uint64
			if _, err := fmt.Sscanf(value, "%d", &n); err != nil {
				return DeviceINI{}, fmt.Errorf("invalid work_bytes: %w", err)
			}
			result.WorkBytes = n
		}
	}
	if err := scanner.Err(); err != nil {
		return DeviceINI{}, err
	}
	if err := result.Validate(); err != nil {
		return DeviceINI{}, err
	}
	return result, nil
}
