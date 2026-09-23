package winhost

import (
	"strings"
	"testing"
)

func TestMicroLinuxLoaderEntryKeys(t *testing.T) {
	entry := MicroLinuxLoaderEntry("0257e175-1685-4311-91aa-5a83d8eb41e5")
	lines := strings.Split(strings.TrimSuffix(entry, "\r\n"), "\r\n")
	keys := map[string][]string{}
	for _, line := range lines {
		// systemd-boot splits a line into key and value at the first space.
		key, value, ok := strings.Cut(line, " ")
		if !ok {
			t.Fatalf("line without a value: %q", line)
		}
		keys[key] = append(keys[key], value)
	}
	for key := range keys {
		switch key {
		case "title", "linux", "initrd", "options":
		default:
			t.Fatalf("unknown systemd-boot key %q in %q", key, entry)
		}
	}
	if len(keys["initrd"]) != 2 || keys["initrd"][1] != "/EFI/USOS/lang.cpio" {
		t.Fatalf("initrd lines = %q", keys["initrd"])
	}
	options := keys["options"]
	if len(options) != 1 {
		t.Fatalf("options lines = %q", options)
	}
	for _, want := range []string{"rdinit=/usos-init", "usos.esp_partuuid=0257e175-1685-4311-91aa-5a83d8eb41e5", "quiet", "console=ttyS0,115200"} {
		if !strings.Contains(options[0], want) {
			t.Fatalf("options %q lack %q", options[0], want)
		}
	}
	if strings.Contains(options[0], "fbcon=nodefer") {
		t.Fatalf("options %q force the fbcon takeover that blanks the splash", options[0])
	}
	// /dev/console must be the serial port (the last console= wins).
	if strings.LastIndex(options[0], "console=ttyS0") < strings.LastIndex(options[0], "console=tty0 ") {
		t.Fatalf("options %q put /dev/console on the screen", options[0])
	}
}
