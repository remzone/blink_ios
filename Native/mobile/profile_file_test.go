// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
	"os"
	"strconv"
	"testing"
)

// Opt-in fixture stays outside Git; output contains counts, never credentials.
func TestPrivateImportFixture(t *testing.T) {
	path := os.Getenv("BLINK_TEST_IMPORT_FILE")
	if path == "" {
		t.Skip("private fixture opt-in")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("fixture unreadable")
	}
	imported, err := ImportProfiles(string(raw))
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		Profiles []ImportedProfile
		Rejected []any
	}
	if err = json.Unmarshal([]byte(imported), &result); err != nil {
		t.Fatal("invalid import result")
	}
	if expected := os.Getenv("BLINK_TEST_IMPORT_COUNT"); expected != "" {
		n, err := strconv.Atoi(expected)
		if err != nil || len(result.Profiles) != n || len(result.Rejected) != 0 {
			t.Fatalf("imported=%d rejected=%d; expected all nodes", len(result.Profiles), len(result.Rejected))
		}
	}
	for _, profile := range result.Profiles {
		encoded, err := json.Marshal(profile)
		if err != nil {
			t.Fatal("cannot save profile")
		}
		if _, err = decodeImported(string(encoded)); err != nil {
			t.Fatal("saved profile cannot be reopened")
		}
	}
	t.Logf("imported=%d rejected=%d", len(result.Profiles), len(result.Rejected))
}
