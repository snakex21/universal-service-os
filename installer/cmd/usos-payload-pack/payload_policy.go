package main

import (
	"path/filepath"
	"strings"
)

// rootCertificate is the USOS Secure Boot certificate at the ESP root (the
// short path for MokManager's "Enroll key from disk"); a copy of
// EFI/USOS/ENROLL_THIS_KEY_IN_MOKMANAGER.cer.
const rootCertificate = "USOS-KEY.cer"

func shouldBundleMediaFile(relative string) bool {
	path := strings.Trim(filepath.ToSlash(relative), "/")
	return path == "EFI" || strings.HasPrefix(path, "EFI/") || path == "UI" || strings.HasPrefix(path, "UI/") || path == rootCertificate
}
