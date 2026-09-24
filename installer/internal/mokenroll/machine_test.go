package mokenroll

import (
	"bytes"
	"encoding/binary"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPrepareWaitWritesOnlyMokTimeout(t *testing.T) {
	der := testCert(t, "usos")
	fw := newFake()
	if _, err := PrepareWait(fw, der); err != nil {
		t.Fatal(err)
	}
	if len(fw.writes) != 1 || fw.writes[0] != VarMokTimeout {
		t.Fatalf("writes = %v, want only MokTimeout", fw.writes)
	}
	got, _, err := fw.Get(VarMokTimeout, ShimLockGUID)
	if err != nil || !bytes.Equal(got, []byte{0xff, 0xff, 0xff, 0xff}) {
		t.Fatalf("MokTimeout = % x, %v; want INT32 -1", got, err)
	}
	if _, _, err := fw.Get(VarMokNew, ShimLockGUID); err == nil {
		t.Fatal("PrepareWait must not write MokNew")
	}
	if !WaitPending(fw) {
		t.Fatal("WaitPending after PrepareWait")
	}
	st, _ := Check(fw, der)
	if !st.WaitPending || !strings.Contains(st.String(), "mokmanager_wait=true") {
		t.Fatalf("Check: %s", st)
	}
	if err := CancelWait(fw); err != nil || WaitPending(fw) {
		t.Fatalf("CancelWait: %v", err)
	}
}

func TestPrepareWaitSkipsWhenEnrolledAndNeedsUEFI(t *testing.T) {
	der := testCert(t, "usos")
	fw := newFake()
	fw.vars[fw.key(VarMokListRT, ShimLockGUID)] = X509SignatureList(der, ShimLockGUID)
	res, err := PrepareWait(fw, der)
	if err != nil || !res.AlreadyEnrolled || len(fw.writes) != 0 {
		t.Fatalf("res=%+v err=%v writes=%v", res, err, fw.writes)
	}
	legacy := newFake()
	legacy.uefi = false
	if _, err := PrepareWait(legacy, der); err != ErrNotUEFI {
		t.Fatalf("legacy: %v", err)
	}
}

func smbiosRaw(structures ...[]byte) []byte {
	var table []byte
	for _, s := range structures {
		table = append(table, s...)
	}
	header := make([]byte, 8)
	binary.LittleEndian.PutUint32(header[4:], uint32(len(table)))
	return append(header, table...)
}

func TestParseSMBIOSUUIDMatchesUSOSFormat(t *testing.T) {
	bios := append([]byte{0, 0x18, 0, 0, 1, 2, 0, 0}, make([]byte, 0x10)...)
	bios = append(bios, []byte("AMI\x00P3.20\x00\x00")...)
	system := []byte{1, 0x1B, 1, 0, 1, 2, 3, 0, 0x33, 0x22, 0x11, 0x00, 0x55, 0x44, 0x77, 0x66, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff, 6, 0, 0}
	system = append(system, []byte("ASUS\x00Ally\x001.0\x00\x00")...)
	end := []byte{127, 4, 2, 0, 0, 0}
	id, ok := ParseSMBIOSUUID(smbiosRaw(bios, system, end))
	// Same vector as src/gui/handheld.zig "SMBIOS type 1 UUID is read and
	// formatted like Windows".
	if !ok || id != "00112233-4455-6677-8899-AABBCCDDEEFF" {
		t.Fatalf("uuid = %q %v", id, ok)
	}
	unset := append([]byte{1, 0x1B, 1, 0, 1, 2, 3, 0}, bytes.Repeat([]byte{0xff}, 16)...)
	unset = append(unset, 6, 0, 0, 0, 0)
	if _, ok := ParseSMBIOSUUID(smbiosRaw(unset, end)); ok {
		t.Fatal("an all-FF UUID is unset")
	}
	if _, ok := ParseSMBIOSUUID([]byte{1, 2}); ok {
		t.Fatal("short table")
	}
}

func TestReportMarkerAndAssessment(t *testing.T) {
	dir := t.TempDir()
	id := "00112233-4455-6677-8899-AABBCCDDEEFF"
	logs := filepath.Join(dir, "EFI", "USOS", "Logs")
	if err := os.MkdirAll(logs, 0o755); err != nil {
		t.Fatal(err)
	}
	content := "; USOS Secure Boot state\r\nmachine_uuid=" + strings.ToLower(id) + "\r\nsecure_boot=off\r\nusos_key=saved\r\n"
	if err := os.WriteFile(filepath.Join(logs, ReportFileName(id)), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	rep, ok := ReadReport(dir, id)
	if !ok || rep.Key != "saved" || rep.SecureBoot != "off" {
		t.Fatalf("report = %+v %v", rep, ok)
	}
	if _, ok := ReadReport(dir, "11111111-2222-3333-4444-555555555555"); ok {
		t.Fatal("another machine's report must not match")
	}

	on := Status{UEFI: true, SecureBoot: Yes, Enrolled: Unknown}
	if a := Assess(on, false, false, nil); a.Card != CardNeeded || a.Enrolled {
		t.Fatalf("needed: %+v", a)
	}
	if a := Assess(on, true, false, nil); a.Card != CardPrepared {
		t.Fatalf("prepared: %+v", a)
	}
	if a := Assess(on, false, false, []Report{rep}); a.Card != CardNone || a.ConfirmedBy != "drive report" {
		t.Fatalf("report: %+v", a)
	}
	if a := Assess(on, false, true, nil); a.Card != CardNone || !a.Enrolled {
		t.Fatalf("marker: %+v", a)
	}
	if a := Assess(Status{UEFI: true, SecureBoot: Yes, Enrolled: Yes}, false, false, nil); a.Card != CardNone || a.ConfirmedBy != "MokListRT" {
		t.Fatalf("MokListRT: %+v", a)
	}
	if a := Assess(Status{UEFI: true, SecureBoot: No}, false, false, nil); a.Card != CardNone {
		t.Fatalf("SB off: %+v", a)
	}
	if a := Assess(Status{}, false, false, nil); a.Card != CardNone {
		t.Fatalf("legacy: %+v", a)
	}

	appdata := t.TempDir()
	if HasMarker(appdata, id) {
		t.Fatal("no marker yet")
	}
	if err := WriteMarker(appdata, id, "user"); err != nil || !HasMarker(appdata, id) {
		t.Fatalf("marker: %v", err)
	}
}

func TestMokTimeoutValue(t *testing.T) {
	if !bytes.Equal(MokTimeoutValue(30), []byte{30, 0, 0, 0}) || !bytes.Equal(MokTimeoutValue(NoCountdown), []byte{0xff, 0xff, 0xff, 0xff}) {
		t.Fatal("MokTimeout is a little-endian INT32")
	}
}
