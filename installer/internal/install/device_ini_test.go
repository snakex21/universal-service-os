package install

import (
	"strings"
	"testing"
)

func TestDeviceINIRoundTrip(t *testing.T) {
	want := DeviceINI{
		Nonce:        "abc123",
		DiskPTUUID:   "disk-guid",
		ESPPartUUID:  "esp-guid",
		DataPartUUID: "data-guid",
		WorkPartUUID: "work-guid",
		WorkLabel:    "USOS_WORK",
		DataLabel:    "USOS_DATA",
		WorkBytes:    16 * 1024 * 1024 * 1024,
	}

	got, err := ParseDeviceINI(strings.NewReader(want.String()))
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("round trip mismatch: got %#v want %#v", got, want)
	}
}

func TestDeviceINIRequiresIdentity(t *testing.T) {
	_, err := ParseDeviceINI(strings.NewReader("[device]\nnonce=x\n"))
	if err == nil {
		t.Fatal("accepted incomplete device identity")
	}
}
