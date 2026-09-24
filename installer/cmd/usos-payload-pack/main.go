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
	// Legacy BIOS menu font, icons (the Core slot is too small for them) and
	// the licenses of the boot UI fonts.
	{`zig-out/legacy-bios/bios-ui.bin`, `EFI/USOS/bios-ui.bin`},
	{`assets/fonts/README.md`, `EFI/USOS/licenses/fonts/README.md`},
	{`assets/fonts/LICENSE-Apache-2.0.txt`, `EFI/USOS/licenses/fonts/LICENSE-Apache-2.0.txt`},
	{`assets/fonts/LICENSE-OFL-1.1.txt`, `EFI/USOS/licenses/fonts/LICENSE-OFL-1.1.txt`},
	{`zig-out/test-assets/ntfs_x64.efi`, `EFI/USOS/ntfs_x64.efi`},
	{`zig-out/micro-linux/systemd-bootx64.efi`, `EFI/USOS/systemd-bootx64.efi`},
	{`zig-out/micro-linux/vmlinuz-virt`, `EFI/USOS/micro-linux/vmlinuz-virt`},
	{`zig-out/micro-linux/initramfs-usos`, `EFI/USOS/micro-linux/initramfs-usos`},
	{`zig-out/windows-native/wimboot`, `EFI/USOS/windows-native/wimboot`},
	{`zig-out/windows-native/support.cpio`, `EFI/USOS/windows-native/support.cpio`},
	{`zig-out/windows-native/win7-support.cpio`, `EFI/USOS/windows-native/win7-support.cpio`},
	{`zig-out/windows-native/vista-support.cpio`, `EFI/USOS/windows-native/vista-support.cpio`},
	{`zig-out/windows-native/modern-support.cpio`, `EFI/USOS/windows-native/modern-support.cpio`},
	{`zig-out/windows-native/int10.efi`, `EFI/USOS/windows-native/int10.efi`},
	{`zig-out/windows-native/int10.original.efi`, `EFI/USOS/windows-native/int10.original.efi`},
	{`zig-out/windows-native/UefiSeven.ini`, `EFI/USOS/windows-native/UefiSeven.ini`},
	{`zig-out/windows-native/uefiseven-LICENSE.txt`, `EFI/USOS/windows-native/uefiseven-LICENSE.txt`},
	{`zig-out/dos-native/memdisk`, `EFI/USOS/dos-native/memdisk`},
	{`zig-out/dos-native/COPYING`, `EFI/USOS/dos-native/COPYING`},
	{`zig-out/dos-native/source.zip`, `EFI/USOS/dos-native/source.zip`},
	{`zig-out/dos-native/manifest.json`, `EFI/USOS/dos-native/manifest.json`},
	{`zig-out/dos-native/ram-patch/PATCH9X.EXE`, `EFI/USOS/dos-native/ram-patch/PATCH9X.EXE`},
	{`zig-out/dos-native/ram-patch/CWSDPMI.EXE`, `EFI/USOS/dos-native/ram-patch/CWSDPMI.EXE`},
	{`zig-out/dos-native/ram-patch/CWSDPMI.TXT`, `EFI/USOS/dos-native/ram-patch/CWSDPMI.TXT`},
	{`zig-out/dos-native/ram-patch/LICENSE.TXT`, `EFI/USOS/dos-native/ram-patch/LICENSE.TXT`},
	{`zig-out/dos-native/ram-patch/README.TXT`, `EFI/USOS/dos-native/ram-patch/README.TXT`},
	{`zig-out/dos-native/ram-patch/NOTICE.TXT`, `EFI/USOS/dos-native/ram-patch/NOTICE.TXT`},
	{`zig-out/dos-native/ram-patch/source.zip`, `EFI/USOS/dos-native/ram-patch/source.zip`},
	{`zig-out/dos-native/ram-patch/manifest.json`, `EFI/USOS/dos-native/ram-patch/manifest.json`},
	{`zig-out/dos-native/ram-patch/INSTALL.BAT`, `EFI/USOS/dos-native/ram-patch/INSTALL.BAT`},
	{`zig-out/dos-native/ram-patch/REPAIR.BAT`, `EFI/USOS/dos-native/ram-patch/REPAIR.BAT`},
	{`zig-out/dos-native/msdos/HIMEMX.EXE`, `EFI/USOS/dos-native/msdos/HIMEMX.EXE`},
	{`zig-out/dos-native/msdos/HIMEMX.TXT`, `EFI/USOS/dos-native/msdos/HIMEMX.TXT`},
	{`zig-out/dos-native/msdos/HIMEMSRC.ZIP`, `EFI/USOS/dos-native/msdos/HIMEMSRC.ZIP`},
	{`zig-out/dos-native/msdos/LICENSE.TXT`, `EFI/USOS/dos-native/msdos/LICENSE.TXT`},
	{`zig-out/dos-native/msdos/manifest.json`, `EFI/USOS/dos-native/msdos/manifest.json`},
	{`zig-out/dos-native/msdos/INSTALL.BAT`, `EFI/USOS/dos-native/msdos/INSTALL.BAT`},
	{`zig-out/dos-native/msdos/LIVE.BAT`, `EFI/USOS/dos-native/msdos/LIVE.BAT`},
	{`zig-out/dos-native/msdos/PREPDOS.BAT`, `EFI/USOS/dos-native/msdos/PREPDOS.BAT`},
	{`zig-out/dos-native/msdos/COPYDOS.BAT`, `EFI/USOS/dos-native/msdos/COPYDOS.BAT`},
	{`zig-out/dos-native/msdos/UNPACK.BAT`, `EFI/USOS/dos-native/msdos/UNPACK.BAT`},
	{`zig-out/dos-native/msdos/W3START.BAT`, `EFI/USOS/dos-native/msdos/W3START.BAT`},
	{`zig-out/dos-native/msdos/WINMENU.BAT`, `EFI/USOS/dos-native/msdos/WINMENU.BAT`},
	{`zig-out/dos-native/msdos/W3CONFIG.SYS`, `EFI/USOS/dos-native/msdos/W3CONFIG.SYS`},
	{`zig-out/dos-native/msdos/W3AUTO.BAT`, `EFI/USOS/dos-native/msdos/W3AUTO.BAT`},
	{`zig-out/dos-native/msdos/REBOOT.COM`, `EFI/USOS/dos-native/msdos/REBOOT.COM`},
	{`zig-out/dos-native/freedos/BOOT16.BIN`, `EFI/USOS/dos-native/freedos/BOOT16.BIN`},
	{`zig-out/dos-native/freedos/KERNEL.SYS`, `EFI/USOS/dos-native/freedos/KERNEL.SYS`},
	{`zig-out/dos-native/freedos/COMMAND.COM`, `EFI/USOS/dos-native/freedos/COMMAND.COM`},
	{`zig-out/dos-native/freedos/DZ.EXE`, `EFI/USOS/dos-native/freedos/DZ.EXE`},
	{`zig-out/dos-native/freedos/DZ.DOS`, `EFI/USOS/dos-native/freedos/DZ.DOS`},
	{`zig-out/dos-native/freedos/FDAUTO.BAT`, `EFI/USOS/dos-native/freedos/FDAUTO.BAT`},
	{`zig-out/dos-native/freedos/FDCONFIG.SYS`, `EFI/USOS/dos-native/freedos/FDCONFIG.SYS`},
	{`zig-out/dos-native/freedos/TOOLS.BAT`, `EFI/USOS/dos-native/freedos/TOOLS.BAT`},
	{`zig-out/dos-native/freedos/README.TXT`, `EFI/USOS/dos-native/freedos/README.TXT`},
	{`zig-out/dos-native/freedos/REBOOT.COM`, `EFI/USOS/dos-native/freedos/REBOOT.COM`},
	{`zig-out/dos-native/freedos/DOSZIP.TXT`, `EFI/USOS/dos-native/freedos/DOSZIP.TXT`},
	{`zig-out/dos-native/freedos/COPYING`, `EFI/USOS/dos-native/freedos/COPYING`},
	{`zig-out/dos-native/freedos/kernel.zip`, `EFI/USOS/dos-native/freedos/kernel.zip`},
	{`zig-out/dos-native/freedos/freecom.zip`, `EFI/USOS/dos-native/freedos/freecom.zip`},
	{`zig-out/dos-native/freedos/doszip.zip`, `EFI/USOS/dos-native/freedos/doszip.zip`},
	{`zig-out/dos-native/freedos/manifest.json`, `EFI/USOS/dos-native/freedos/manifest.json`},
}

var payloadDirectories = []payloadFile{
	{`zig-out/usb`, ``},
}

func main() {
	root := flag.String("root", "..", "Universal Service OS repository root")
	out := flag.String("out", filepath.FromSlash("internal/payload/assets/payload.zip"), "output ZIP")
	verifyFreshOnly := flag.Bool("verify-fresh-only", false, "fail unless the existing payload ZIP is at least as new as every source file that feeds it")
	flag.Parse()
	cleanRoot := filepath.Clean(*root)
	cleanOut := filepath.Clean(*out)
	var err error
	if *verifyFreshOnly {
		err = verifyFresh(cleanRoot, cleanOut)
	} else {
		err = pack(cleanRoot, cleanOut)
		if err == nil {
			err = verifyFresh(cleanRoot, cleanOut)
		}
	}
	if err != nil {
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
			if !shouldBundleMediaFile(relative) {
				return nil
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

func verifyFresh(root, out string) error {
	sources, err := payloadSourceFiles(root)
	if err != nil {
		return err
	}
	return verifyFreshSources(out, sources)
}

func verifyFreshSources(out string, sources []string) error {
	payloadInfo, err := os.Stat(out)
	if err != nil {
		return fmt.Errorf("stat payload ZIP for freshness: %w", err)
	}
	if !payloadInfo.Mode().IsRegular() || payloadInfo.Size() == 0 {
		return fmt.Errorf("payload ZIP is empty or not regular: %s", out)
	}
	for _, source := range sources {
		info, err := os.Stat(source)
		if err != nil {
			return fmt.Errorf("stat payload source %s: %w", source, err)
		}
		if info.ModTime().After(payloadInfo.ModTime()) {
			return fmt.Errorf("STALE payload.zip: source is newer than archive: %s source=%s payload=%s", source, info.ModTime().UTC().Format("2006-01-02T15:04:05.999999999Z"), payloadInfo.ModTime().UTC().Format("2006-01-02T15:04:05.999999999Z"))
		}
	}
	return nil
}

func payloadSourceFiles(root string) ([]string, error) {
	result := make([]string, 0, len(payloadFiles)+32)
	for _, item := range payloadFiles {
		source := filepath.Join(root, filepath.FromSlash(item.Source))
		info, err := os.Stat(source)
		if err != nil {
			return nil, fmt.Errorf("required payload source %s: %w", source, err)
		}
		if !info.Mode().IsRegular() || info.Size() == 0 {
			return nil, fmt.Errorf("required payload source is empty or not regular: %s", source)
		}
		result = append(result, source)
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
				return err
			}
			if shouldBundleMediaFile(relative) {
				result = append(result, source)
			}
			return nil
		}); err != nil {
			return nil, fmt.Errorf("enumerate payload directory %s: %w", sourceRoot, err)
		}
	}
	return result, nil
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
