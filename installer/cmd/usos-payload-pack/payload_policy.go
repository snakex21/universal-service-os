package main

import (
	"path/filepath"
	"strings"
)

func shouldBundleMediaFile(relative string) bool {
	path := strings.Trim(filepath.ToSlash(relative), "/")
	return path == "EFI" || strings.HasPrefix(path, "EFI/") || path == "UI" || strings.HasPrefix(path, "UI/")
}
