package buildinfo

import (
	"bufio"
	"fmt"
	"io"
	"strconv"
	"strings"
)

var (
	ID           = "DEV"
	EpochText    = "0"
	SourceSHA256 = "DEV"
)

type Info struct {
	ID           string
	Epoch        int64
	SourceSHA256 string
}

func Current() Info {
	epoch, _ := strconv.ParseInt(strings.TrimSpace(EpochText), 10, 64)
	return Info{
		ID:           strings.TrimSpace(ID),
		Epoch:        epoch,
		SourceSHA256: strings.ToLower(strings.TrimSpace(SourceSHA256)),
	}
}

func (i Info) Valid() bool {
	return i.ID != "" && i.ID != "DEV" && i.Epoch > 0 && len(i.SourceSHA256) == 64
}

func (i Info) Display() string {
	if strings.TrimSpace(i.ID) == "" {
		return "nieznana"
	}
	return i.ID
}

func Compare(a, b Info) int {
	if a.Epoch < b.Epoch {
		return -1
	}
	if a.Epoch > b.Epoch {
		return 1
	}
	if a.ID < b.ID {
		return -1
	}
	if a.ID > b.ID {
		return 1
	}
	return 0
}

func Parse(r io.Reader) (Info, error) {
	var info Info
	section := ""
	scanner := bufio.NewScanner(r)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, ";") || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			section = strings.ToLower(strings.TrimSpace(line[1 : len(line)-1]))
			continue
		}
		if section != "build" {
			continue
		}
		parts := strings.SplitN(line, "=", 2)
		if len(parts) != 2 {
			return Info{}, fmt.Errorf("invalid build-info line %q", line)
		}
		key := strings.ToLower(strings.TrimSpace(parts[0]))
		value := strings.TrimSpace(parts[1])
		switch key {
		case "id":
			info.ID = value
		case "epoch":
			epoch, err := strconv.ParseInt(value, 10, 64)
			if err != nil || epoch <= 0 {
				return Info{}, fmt.Errorf("invalid build epoch %q", value)
			}
			info.Epoch = epoch
		case "source_sha256":
			info.SourceSHA256 = strings.ToLower(value)
		}
	}
	if err := scanner.Err(); err != nil {
		return Info{}, err
	}
	if info.ID == "" || info.Epoch <= 0 || len(info.SourceSHA256) != 64 {
		return Info{}, fmt.Errorf("incomplete build-info")
	}
	return info, nil
}
