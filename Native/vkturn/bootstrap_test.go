// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestBootstrapBoundedAndBoundToProfile(t *testing.T) {
	cfg := testConfig()
	c := &Client{ctx: context.Background(), config: cfg, state: "ready", authGate: make(chan struct{}, 1), username: "fixture-user", password: "fixture-secret", turnAddress: "relay.example.org:3478", credsUntil: time.Now().Add(9 * time.Minute)}
	c.authGate <- struct{}{}
	raw := c.ExportBootstrap()
	if raw == "" {
		t.Fatal("missing private handoff")
	}
	b, e := validateBootstrap(raw, cfg)
	if e != nil || b.ExpiresAt > time.Now().Unix()+90 {
		t.Fatal("invalid handoff lifetime")
	}
	changed := cfg
	changed.PeerPort++
	if _, e = validateBootstrap(raw, changed); e == nil {
		t.Fatal("handoff not bound to peer")
	}
	b.ExpiresAt = time.Now().Unix() - 1
	expired, _ := json.Marshal(b)
	if _, e = validateBootstrap(string(expired), cfg); e == nil {
		t.Fatal("expired handoff accepted")
	}
	c.state = "connecting"
	if c.ExportBootstrap() != "" {
		t.Fatal("export before transport ready")
	}
	if _, e = validateBootstrap(strings.Repeat("x", 32769), cfg); e == nil {
		t.Fatal("oversized handoff accepted")
	}
}
