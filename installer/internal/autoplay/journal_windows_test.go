//go:build windows

package autoplay

import "testing"

func TestLegacyJournalCannotReceiveNewApplicationData(t *testing.T) {
	if err := (legacyJournalStore{}).SetDWORD(JournalKey, journalPending, 1); err == nil {
		t.Fatal("legacy registry journal accepted new application state")
	}
}
