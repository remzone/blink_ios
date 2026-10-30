// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
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
