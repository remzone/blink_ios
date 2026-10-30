// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
	"os"
	"testing"
	"time"
)

type denyAllSockets struct{}

func (denyAllSockets) Protect(int64) bool { return false }
func TestVKProfileAndDNSContractWithoutExternalTraffic(t *testing.T) {
	p := VKProfile{UUID: "00000000-0000-4000-8000-000000000001", PeerHost: "203.0.113.10", PeerPort: 56000, VKCallURL: "https://vk.com/call/join/TEST_ONLY", Streams: 1, ExpiresAt: time.Now().Unix() + 60}
	raw, _ := json.Marshal(p)
	if _, err := StartVK(string(raw), &fakeSink{}, denyAllSockets{}); err == nil {
		t.Fatal("missing explicit bootstrap DNS accepted")
	}
	p.DNSServer = "127.0.0.1" // Even DNS packets are refused before connect by protector.
	raw, _ = json.Marshal(p)
	e, err := StartVK(string(raw), &fakeSink{}, denyAllSockets{})
	if err != nil {
		t.Fatal(err)
	}
	if e.Status() != "connecting" {
		t.Fatalf("premature readiness: %s", e.Status())
	}
	e.Stop()
	if e.Status() != "stopped" {
		t.Fatal("transport retained after stop")
	}
	p.ExpiresAt = time.Now().Unix() - 1
	raw, _ = json.Marshal(p)
	if _, err = StartVK(string(raw), &fakeSink{}, denyAllSockets{}); err == nil {
		t.Fatal("expired subscription accepted")
	}
}

func TestCanonicalPanelFeedMapsToMobileProfile(t *testing.T) {
	raw, err := os.ReadFile("../../fixtures/vokop.subscription.v1.json")
	if err != nil {
		t.Fatal(err)
	}
	var feed struct {
		Schema    string `json:"schema"`
		ExpiresAt int64  `json:"expires_at"`
		Profiles  []struct {
			VLESS struct {
				UUID string `json:"uuid"`
			} `json:"vless"`
			TURN struct {
				PeerHost  string `json:"peer_host"`
				PeerPort  int    `json:"peer_port"`
				VKCallURL string `json:"vk_call_url"`
				Streams   int    `json:"streams"`
			} `json:"turn"`
		} `json:"profiles"`
	}
	if err = json.Unmarshal(raw, &feed); err != nil {
		t.Fatal(err)
	}
	if feed.Schema != "vokop.subscription.v1" || len(feed.Profiles) != 1 {
		t.Fatal("wrong shared contract fixture")
	}
	p := feed.Profiles[0]
	mobile := VKProfile{UUID: p.VLESS.UUID, PeerHost: p.TURN.PeerHost, PeerPort: p.TURN.PeerPort, VKCallURL: p.TURN.VKCallURL, Streams: p.TURN.Streams, ExpiresAt: feed.ExpiresAt, DNSServer: "1.1.1.1"}
	encoded, err := json.Marshal(mobile)
	if err != nil {
		t.Fatal(err)
	}
	var fields map[string]any
	if err = json.Unmarshal(encoded, &fields); err != nil {
		t.Fatal(err)
	}
	if fields["peerPort"] != float64(56000) || fields["dnsServer"] != "1.1.1.1" || !validUUID(mobile.UUID) {
		t.Fatal("feed/mobile mapping drift")
	}
	// Timestamp is deliberately historic fixture data, never a live subscription.
}
