package autoplay

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"

	"github.com/snakex21/universal-service-os/installer/internal/portable"
)

type fileJournal struct{ path string }

func applicationJournal() (fileJournal, error) {
	path, err := portable.Path("autoplay-journal.json")
	return fileJournal{path}, err
}

func (f fileJournal) read() (map[string]uint32, error) {
	values := map[string]uint32{}
	data, err := os.ReadFile(f.path)
	if errors.Is(err, os.ErrNotExist) {
		return values, nil
	}
	if err != nil {
		return nil, err
	}
	if err := json.Unmarshal(data, &values); err != nil {
		return nil, err
	}
	if values == nil {
		values = map[string]uint32{}
	}
	return values, nil
}

func (f fileJournal) get(name string) (uint32, bool, error) {
	values, err := f.read()
	if err != nil {
		return 0, false, err
	}
	value, exists := values[name]
	return value, exists, nil
}

func (f fileJournal) write(values map[string]uint32) error {
	if len(values) == 0 {
		err := os.Remove(f.path)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if err := os.MkdirAll(filepath.Dir(f.path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(values)
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(f.path), ".autoplay-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	_, writeErr := tmp.Write(data)
	if writeErr == nil {
		writeErr = tmp.Sync()
	}
	closeErr := tmp.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(tmp.Name(), f.path)
}

func (f fileJournal) set(name string, value uint32) error {
	values, err := f.read()
	if err != nil {
		return err
	}
	values[name] = value
	return f.write(values)
}

func (f fileJournal) remove(name string) error {
	values, err := f.read()
	if err != nil {
		return err
	}
	delete(values, name)
	return f.write(values)
}
