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
	{`zig-out/usb/EFI/BOOT/BOOTX64.EFI`, `EFI/BOOT/BOOTX64.EFI`},
	{`zig-out/usb/EFI/BOOT/BOOTAA64.EFI`, `EFI/BOOT/BOOTAA64.EFI`},
	{`zig-out/test-assets/ntfs_x64.efi`, `EFI/USOS/ntfs_x64.efi`},
	{`zig-out/micro-linux/systemd-bootx64.efi`, `EFI/USOS/systemd-bootx64.efi`},
	{`zig-out/micro-linux/vmlinuz-virt`, `EFI/USOS/micro-linux/vmlinuz-virt`},
	{`zig-out/micro-linux/initramfs-usos`, `EFI/USOS/micro-linux/initramfs-usos`},
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
		header.Name = item.Target
		header.Method = zip.Deflate
		writer, err := zw.CreateHeader(header)
		if err != nil {
			return fmt.Errorf("payload archive entry %s: %w", item.Target, err)
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
