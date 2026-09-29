package components

import (
	"fmt"
	"os"
	"path/filepath"
)

// LocalSums reads SHA256SUMS next to a picked file (the release folder layout),
// or returns nil when there is none.
func LocalSums(file string) (map[string]string, error) {
	path := filepath.Join(filepath.Dir(file), SumsAsset)
	f, err := os.Open(path)
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return ParseSums(f)
}

// VerifyLocal checks a zip the user already has ("I already have the file")
// the same way as a download: its SHA-256 must match the asset's entry in the
// compiled list and in SHA256SUMS. sums is the release's SHA256SUMS when it
// could be fetched (nil offline); a SHA256SUMS next to the file is used too.
// The file name does not matter, only its content.
func VerifyLocal(file, asset string, release Release, sums map[string]string) error {
	info, err := os.Stat(file)
	if err != nil {
		return err
	}
	if info.IsDir() {
		return fmt.Errorf("%s is a folder", file)
	}
	beside, err := LocalSums(file)
	if err != nil {
		return err
	}
	sum, err := HashFile(file)
	if err != nil {
		return err
	}
	if beside != nil {
		if err := Check(asset, sum, release.Pinned, beside); err != nil {
			return err
		}
	}
	if sums != nil || beside == nil {
		if err := Check(asset, sum, release.Pinned, sums); err != nil {
			return err
		}
	}
	return nil
}
