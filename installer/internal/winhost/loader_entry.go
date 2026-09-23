package winhost

import (
	"fmt"

	"github.com/snakex21/universal-service-os/installer/internal/i18n"
)

// MicroLinuxKernelOptions are the kernel options of the systemd-boot entry
// that starts the micro-Linux preparation from the UEFI menu (without
// usos.esp_partuuid).
//
// /dev/console is the serial port (the last console=), printk shows only
// emergencies, and fbcon takes the screen over lazily (no fbcon=nodefer): the
// "Starting..." splash the UEFI menu leaves on the framebuffer stays visible
// through the kernel boot until usos-fb-ui scans out its first frame.
const MicroLinuxKernelOptions = "console=tty0 console=ttyS0,115200 quiet loglevel=3 vt.global_cursor_default=0 rdinit=/usos-init"

// MicroLinuxLoaderEntry renders loader/entries/usos-micro-linux.conf.
// lang.cpio (written with the language files) adds /etc/usos/lang.bin so the
// preparation screens use the chosen language.
func MicroLinuxLoaderEntry(espPartUUID string) string {
	return fmt.Sprintf(
		"title USOS micro-Linux preparation\r\n"+
			"linux /EFI/USOS/micro-linux/vmlinuz-virt\r\n"+
			"initrd /EFI/USOS/micro-linux/initramfs-usos\r\n"+
			"initrd /%s\r\n"+
			"options %s usos.esp_partuuid=%s\r\n",
		i18n.LinuxLangPath, MicroLinuxKernelOptions, espPartUUID)
}
