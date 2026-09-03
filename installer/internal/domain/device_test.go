package domain

import "testing"

func TestIdentityMatchesApprovedHardwareIgnoresPhysicalDriveNumber(t *testing.T) {
	approved := Identity{Number: 9, Model: "Kingston DataTraveler 3.0", Serial: "ABC123", SizeBytes: 64}
	current := Identity{Number: 12, Model: "Kingston DataTraveler 3.0", Serial: "ABC123", SizeBytes: 64}
	if !approved.MatchesApprovedHardware(current) {
		t.Fatal("same model, serial and capacity should match even if PhysicalDrive number changed")
	}
}

func TestIdentityMatchesApprovedHardwareRejectsAnyHardwareDifference(t *testing.T) {
	approved := Identity{Model: "Model A", Serial: "SERIAL", SizeBytes: 64}
	tests := []Identity{
		{Model: "Model B", Serial: "SERIAL", SizeBytes: 64},
		{Model: "Model A", Serial: "OTHER", SizeBytes: 64},
		{Model: "Model A", Serial: "SERIAL", SizeBytes: 65},
	}
	for _, current := range tests {
		if approved.MatchesApprovedHardware(current) {
			t.Fatalf("unexpected match for %+v", current)
		}
	}
}
