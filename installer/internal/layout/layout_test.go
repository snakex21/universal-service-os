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
		{"48 GiB clamps to minimum", 48 * GiB, 12 * GiB},
		{"56 GiB is proportional", 56 * GiB, 14 * GiB},
		{"96 GiB stays at maximum", 96 * GiB, 16 * GiB},
		{"128 GiB stays at maximum", 128 * GiB, 16 * GiB},
		{"16 GB stick minimum gets small floor", 14_000_000_000, 6 * GiB},
		{"16 GB stick typical gets small floor", 15_376_000_000, 6 * GiB},
		{"32 GB stick is 3/8 of disk", 30_752_000_000, alignDown(30_752_000_000/8*3, MiB)},
		{"just below 32 GiB stays under legacy minimum", 32*GiB - MiB, alignDown((32*GiB-MiB)/8*3, MiB)},
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
	for _, size := range []uint64{MinimumDiskBytes - 512, 8_000_000_000, 12 * GiB} {
		if _, err := Build(size); err == nil {
			t.Fatalf("Build accepted %d bytes, below the 16 GB minimum", size)
		}
	}
}

// Capacities as reported by real sticks: vendors count 1 GB = 10^9 B and
// the usable size is a few percent below the label.
func TestBuildAcceptsVendorAdvertisedSticks(t *testing.T) {
	const win7ISO = 5_500_000_000 // larger than any Windows 7 multi-edition ISO
	sticks := []struct {
		name string
		size uint64
	}{
		{"16 GB low", 14_000_000_000},
		{"16 GB typical", 15_376_000_000},
		{"16 GB high", 16_008_609_792},
		{"32 GB low", 28_600_000_000},
		{"32 GB typical", 30_752_000_000},
		{"32 GB high", 31_000_000_000},
	}
	for _, st := range sticks {
		t.Run(st.name, func(t *testing.T) {
			plan, err := Build(st.size)
			if err != nil {
				t.Fatal(err)
			}
			// One Windows 7 ISO on DATA and its copy (+256 MiB) on WORK.
			if plan.DATA.SizeBytes < win7ISO {
				t.Fatalf("DATA %d B cannot hold a Windows 7 ISO", plan.DATA.SizeBytes)
			}
			if plan.WORK.SizeBytes < win7ISO+256*MiB {
				t.Fatalf("WORK %d B cannot hold a Windows 7 ISO copy", plan.WORK.SizeBytes)
			}
			if plan.WORK.StartBytes+plan.WORK.SizeBytes > plan.DiskBytes-TailReserveBytes {
				t.Fatal("WORK crosses reserved GPT tail area")
			}
			for _, sector := range []uint32{512, 4096} {
				if err := plan.ValidateSectorSize(sector); err != nil {
					t.Fatalf("sector %d: %v", sector, err)
				}
			}
		})
	}
}

// legacyWorkBytes is the WORK rule before small-stick support. Disks of
// 32 GiB and more must keep exactly this layout so existing media still
// match layout.Build during updates.
func legacyWorkBytes(diskBytes uint64) uint64 {
	work := diskBytes / 4
	if work < 12*GiB {
		return 12 * GiB
	}
	if work > 16*GiB {
		return 16 * GiB
	}
	return alignDown(work, MiB)
}

func TestLayoutUnchangedFrom32GiB(t *testing.T) {
	for _, size := range []uint64{32 * GiB, 32*GiB + 512, 34_359_738_368 + 7*MiB, 48 * GiB, 61_991_813_632, 64 * GiB, 128_043_712_512, 256 * GiB} {
		if got, want := WorkBytesForDisk(size), legacyWorkBytes(size); got != want {
			t.Fatalf("WorkBytesForDisk(%d)=%d, legacy layout %d", size, got, want)
		}
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
