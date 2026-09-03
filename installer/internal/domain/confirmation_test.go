package domain

import "testing"

func TestConfirmationRequiresExactFullModel(t *testing.T) {
	confirmation := BuildConfirmation(Disk{Number: 9, Model: "Kingston DataTraveler 3.0", Serial: "ABC", SizeBytes: 64 * 1024 * 1024 * 1024})
	if !confirmation.Accepts("Kingston DataTraveler 3.0") {
		t.Fatal("exact model was rejected")
	}
	for _, input := range []string{"kingston datatraveler 3.0", "Kingston DataTraveler 3.0 ", "Kingston DataTraveler"} {
		if confirmation.Accepts(input) {
			t.Fatalf("non-exact confirmation accepted: %q", input)
		}
	}
}
