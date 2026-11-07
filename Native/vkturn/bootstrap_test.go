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

func TestBootstrapRecognizesOfficialCallAliases(t *testing.T) {
	for _, from := range []string{"vk.com", "vk.ru", "www.vk.com", "www.vk.ru"} {
		for _, to := range []string{"vk.com", "vk.ru", "www.vk.com", "www.vk.ru"} {
			t.Run(from+"_to_"+to, func(t *testing.T) {
				cfg := testConfig()
				cfg.VKCallURL = "https://" + to + "/call/join/Same_ID-42="
				b := turnBootstrap{Username: "fixture-user", Password: "fixture-secret", Address: "relay.example.org:3478", PeerHost: cfg.PeerHost, PeerPort: cfg.PeerPort, CallURL: "https://" + from + "/call/join/Same_ID-42=", ExpiresAt: time.Now().Add(time.Minute).Unix()}
				raw, _ := json.Marshal(b)
				if _, err := validateBootstrap(string(raw), cfg); err != nil {
					t.Fatal("same call rejected across official aliases", err)
				}
				for _, bad := range []string{
					"https://vk.ru/call/join/DIFFERENT", "https://vk.com/call/join/same_ID-42=",
					"https://vk.ru.evil.example/call/join/Same_ID-42=", "https://evilvk.com/call/join/Same_ID-42=",
					"http://vk.ru/call/join/Same_ID-42=", "https://vk.ru:443/call/join/Same_ID-42=",
					"https://user@vk.ru/call/join/Same_ID-42=", "https://vk.ru/call/join/Same_ID-42=?extra=1",
					"https://vk.ru/call/join/Same_ID-42=#extra", "https://vk.ru/call/join/Same_ID-42%3D",
				} {
					b.CallURL = bad
					badRaw, _ := json.Marshal(b)
					if _, err := validateBootstrap(string(badRaw), cfg); err == nil {
						t.Fatal("different or untrusted call reused authorization")
					}
					// The configuration side must be validated too, rather than trusting the cache.
					cfg.VKCallURL = bad
					b.CallURL = "https://" + from + "/call/join/Same_ID-42="
					badRaw, _ = json.Marshal(b)
					if _, err := validateBootstrap(string(badRaw), cfg); err == nil {
						t.Fatal("untrusted config reused authorization")
					}
					cfg.VKCallURL = "https://" + to + "/call/join/Same_ID-42="
				}
			})
		}
	}
}
