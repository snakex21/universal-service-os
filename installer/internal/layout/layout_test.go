package layout

import "testing"

func TestWorkBytesForDisk(t *testing.T) {
	tests := []struct {
		name string
		disk uint64
		want uint64
	}{
		{"32 GiB clamps to minimum", 32 * GiB, 12 * GiB},
		{"64 GiB is proportional", 64 * GiB, 16 * GiB},
		{"96 GiB reaches maximum", 96 * GiB, 24 * GiB},
		{"128 GiB stays at maximum", 128 * GiB, 24 * GiB},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := WorkBytesForDisk(tt.disk); got != tt.want {
				t.Fatalf("WorkBytesForDisk(%d)=%d, want %d", tt.disk, got, tt.want)
			}
		})
	}
}

func TestBuildRejectsBelowMinimum(t *testing.T) {
	if _, err := Build(31 * GiB); err == nil {
		t.Fatal("Build accepted disk below 32 GiB")
	}
}

func TestBuildLeavesGPTHeadAndTailReserve(t *testing.T) {
	plan, err := Build(64 * GiB)
	if err != nil {
		t.Fatal(err)
	}
	if plan.ESP.StartBytes < HeadReserveBytes {
		t.Fatalf("ESP starts too early: %d", plan.ESP.StartBytes)
	}
	if plan.ReservedTailBytes < TailReserveBytes {
		t.Fatalf("tail reserve too small: %d", plan.ReservedTailBytes)
	}
	if plan.DATA.StartBytes != plan.ESP.StartBytes+plan.ESP.SizeBytes {
		t.Fatal("DATA does not immediately follow ESP at aligned boundary")
	}
	if plan.WORK.StartBytes != plan.DATA.StartBytes+plan.DATA.SizeBytes {
		t.Fatal("WORK does not immediately follow DATA")
	}
	if plan.WORK.SizeBytes != 16*GiB {
		t.Fatalf("WORK size=%d, want %d", plan.WORK.SizeBytes, 16*GiB)
	}
	if plan.WORK.StartBytes+plan.WORK.SizeBytes > plan.DiskBytes-plan.ReservedTailBytes {
		t.Fatal("WORK crosses reserved GPT tail area")
	}
}

func TestBuildIsSectorAligned(t *testing.T) {
	plan, err := Build(61_991_813_632)
	if err != nil {
		t.Fatal(err)
	}
	for _, sector := range []uint32{512, 4096} {
		if err := plan.ValidateSectorSize(sector); err != nil {
			t.Fatalf("sector %d: %v", sector, err)
		}
	}
}
