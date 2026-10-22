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
	if isPrivateKeyMaterial(path) {
		return false
	}
	return path == "EFI" || strings.HasPrefix(path, "EFI/") || path == "UI" || strings.HasPrefix(path, "UI/") || path == rootCertificate
}

// isPrivateKeyMaterial reports signing secrets that must never reach a USOS
// drive: the portable key folder (data/signing), the USOS private key and
// PKCS#12 bundles. (Other *.KEY files, e.g. DOS W101.KEY, are not keys.)
func isPrivateKeyMaterial(path string) bool {
	lower := strings.ToLower(strings.Trim(filepath.ToSlash(path), "/"))
	for _, seg := range strings.Split(lower, "/") {
		if seg == "signing" {
			return true
		}
	}
	if strings.HasSuffix(lower, "/usos-secure-boot.key") || lower == "usos-secure-boot.key" {
		return true
	}
	for _, ext := range []string{".pfx", ".p12"} {
		if strings.HasSuffix(lower, ext) {
			return true
		}
	}
	return false
}
