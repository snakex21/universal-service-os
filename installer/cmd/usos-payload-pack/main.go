package main

import (
	"archive/zip"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

type payloadFile struct {
	Source string
	Target string
}

var payloadFiles = []payloadFile{
	{`zig-out/test-assets/ntfs_x64.efi`, `EFI/USOS/ntfs_x64.efi`},
	{`zig-out/micro-linux/systemd-bootx64.efi`, `EFI/USOS/systemd-bootx64.efi`},
	{`zig-out/micro-linux/vmlinuz-virt`, `EFI/USOS/micro-linux/vmlinuz-virt`},
	{`zig-out/micro-linux/initramfs-usos`, `EFI/USOS/micro-linux/initramfs-usos`},
}

var payloadDirectories = []payloadFile{
	{`zig-out/usb`, ``},
}

func main() {
	root := flag.String("root", "..", "Universal Service OS repository root")
	out := flag.String("out", filepath.FromSlash("internal/payload/assets/payload.zip"), "output ZIP")
	flag.Parse()
	if err := pack(filepath.Clean(*root), filepath.Clean(*out)); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func pack(root, out string) error {
	if err := os.MkdirAll(filepath.Dir(out), 0o755); err != nil {
		return fmt.Errorf("create payload output directory: %w", err)
	}
	temp := out + ".new"
	_ = os.Remove(temp)
	file, err := os.Create(temp)
	if err != nil {
		return fmt.Errorf("create payload archive: %w", err)
	}
	zw := zip.NewWriter(file)
	ok := false
	defer func() {
		if !ok {
			_ = zw.Close()
			_ = file.Close()
			_ = os.Remove(temp)
		}
	}()

	for _, item := range payloadFiles {
		source := filepath.Join(root, filepath.FromSlash(item.Source))
		if err := addFile(zw, source, item.Target); err != nil {
			return err
		}
	}

	for _, item := range payloadDirectories {
		sourceRoot := filepath.Join(root, filepath.FromSlash(item.Source))
		if err := filepath.WalkDir(sourceRoot, func(source string, entry os.DirEntry, walkErr error) error {
			if walkErr != nil {
				return walkErr
			}
			if entry.IsDir() {
				return nil
			}
			relative, err := filepath.Rel(sourceRoot, source)
			if err != nil {
				return fmt.Errorf("relative payload path %s: %w", source, err)
			}
			target := filepath.ToSlash(filepath.Join(item.Target, relative))
			return addFile(zw, source, target)
		}); err != nil {
			return fmt.Errorf("required payload directory %s: %w", sourceRoot, err)
		}
	}
	if err := zw.Close(); err != nil {
		return fmt.Errorf("close payload archive: %w", err)
	}
	if err := file.Close(); err != nil {
		return fmt.Errorf("close payload file: %w", err)
	}
	if err := os.Rename(temp, out); err != nil {
		return fmt.Errorf("publish payload archive: %w", err)
	}
	ok = true
	return nil
}

func addFile(zw *zip.Writer, source, target string) error {
	info, err := os.Stat(source)
	if err != nil {
		return fmt.Errorf("required payload file %s: %w", source, err)
	}
	if !info.Mode().IsRegular() || info.Size() == 0 {
		return fmt.Errorf("required payload file is empty or not regular: %s", source)
	}
	header, err := zip.FileInfoHeader(info)
	if err != nil {
		return fmt.Errorf("payload header %s: %w", source, err)
	}
	header.Name = filepath.ToSlash(target)
	header.Method = zip.Deflate
	writer, err := zw.CreateHeader(header)
	if err != nil {
		return fmt.Errorf("payload archive entry %s: %w", target, err)
	}
	input, err := os.Open(source)
	if err != nil {
		return fmt.Errorf("open payload %s: %w", source, err)
	}
	_, copyErr := io.Copy(writer, input)
	closeErr := input.Close()
	if copyErr != nil {
		return fmt.Errorf("copy payload %s: %w", source, copyErr)
	}
	if closeErr != nil {
		return fmt.Errorf("close payload %s: %w", source, closeErr)
	}
	return nil
}
