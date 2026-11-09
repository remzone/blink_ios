// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestProviderSubscriptionImportsEveryNode(t *testing.T) {
	links := []string{
		"vless://00000000-0000-4000-8000-000000000001@example.org:443?type=xhttp&security=tls&sni=example.org&mode=auto&concurrency=4&x-durev-prio=2&x-durev-block=regular&x-durev-sni-change=true#Country%20One",
		"vless://00000000-0000-4000-8000-000000000001@example.net:443?type=ws&security=tls&path=%2Fvpn&host=example.net&mux=true&muxConcurrency=8&x-durev-block=warp#Country%20Two",
	}
	plain := strings.Join(links, "\r\n")
	for _, source := range []string{plain, base64.StdEncoding.EncodeToString([]byte(plain))} {
		raw, err := ImportProfiles(source)
		if err != nil {
			t.Fatal(err)
		}
		var doc struct {
			Profiles []ImportedProfile
			Rejected []any
			Notice   string
		}
		if err = json.Unmarshal([]byte(raw), &doc); err != nil {
			t.Fatal(err)
		}
		if len(doc.Profiles) != 2 || len(doc.Rejected) != 0 || doc.Notice == "" {
			t.Fatal("provider nodes missing or ignored hints not disclosed")
		}
		for i, p := range doc.Profiles {
			if p.Source != links[i] {
				t.Fatal("original endpoint lost")
			}
			if _, err := decodeImported(mustProfileJSON(t, p)); err != nil {
				t.Fatal("saved node cannot be reopened")
			}
		}
	}
}
func mustProfileJSON(t *testing.T, p ImportedProfile) string {
	t.Helper()
	b, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}
