// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestTuningRejectsInvalidOptionsBeforeSockets(t *testing.T) {
	for _, tuning := range []Tuning{{Preset: "srtp"}, {MTU: 575}, {MTU: 1201}, {PaceKiB: -1}, {PaceKiB: 4097}, {Preset: "custom", Window: 15, IntervalMS: 20}, {Preset: "custom", Window: 32, IntervalMS: 101}, {Preset: "balanced", Window: 64}, {Congestion: true}} {
		cfg := testConfig()
		cfg.Tuning = tuning
		if c, err := Start(context.Background(), cfg, allow); err == nil {
			c.Close()
			t.Fatal("invalid options accepted")
		}
	}
	for _, tuning := range []Tuning{{}, {Preset: "balanced"}, {Preset: "conservative", MTU: 576, PaceKiB: 64}, {Preset: "custom", Window: 16, IntervalMS: 10, Congestion: true}} {
		if err := tuning.validate(); err != nil {
			t.Fatal(err)
		}
	}
	for _, address := range []string{"relay.example.org:3478", "127.0.0.1:443", "[2001:db8::1]:3478"} {
		if !validTURNOverride(address) {
			t.Fatal("valid relay rejected")
		}
	}
	for _, address := range []string{"https://relay.example.org:443", "user:password@relay.example.org:3478", "relay:0", "relay:65536", "relay:3478/path", "relay.example.org", "relay:3478\n"} {
		if validTURNOverride(address) {
			t.Fatal("invalid relay accepted")
		}
	}
}
func TestUplinkPacingPreservesBytesAndCancellation(t *testing.T) {
	for _, action := range []string{"cancel", "close"} {
		t.Run(action, func(t *testing.T) {
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			left, right := net.Pipe()
			defer right.Close()
			paced := Tuning{PaceKiB: 16}.paced(ctx, left)
			defer paced.Close()
			payload := make([]byte, 8192)
			received := make(chan error, 1)
			go func() { buf := make([]byte, len(payload)); _, err := io.ReadFull(right, buf); received <- err }()
			if n, err := paced.Write(payload); err != nil || n != len(payload) {
				t.Fatal("first payload failed")
			}
			if err := <-received; err != nil {
				t.Fatal(err)
			}
			done := make(chan error, 1)
			go func() { _, err := paced.Write([]byte("next")); done <- err }()
			select {
			case <-done:
				t.Fatal("second write was not paced")
			case <-time.After(20 * time.Millisecond):
			}
			if action == "cancel" {
				cancel()
			} else {
				paced.Close()
			}
			select {
			case err := <-done:
				if err == nil {
					t.Fatal("canceled write succeeded")
				}
			case <-time.After(time.Second):
				t.Fatal("paced writer leaked")
			}
		})
	}
}
func TestPacedWriteWaitsForRateBudget(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	left, right := net.Pipe()
	defer right.Close()
	paced := Tuning{PaceKiB: 16}.paced(ctx, left)
	defer paced.Close()
	go io.Copy(io.Discard, right)
	started := time.Now()
	if _, err := paced.Write(make([]byte, 4096)); err != nil {
		t.Fatal(err)
	}
	if _, err := paced.Write([]byte{1}); err != nil {
		t.Fatal(err)
	}
	if time.Since(started) < 200*time.Millisecond {
		t.Fatal("rate budget not enforced")
	}
}
func TestManualRelayUsedForResolution(t *testing.T) {
	c := &Client{config: Config{TURNServer: "127.0.0.1:3478"}, resolver: net.DefaultResolver}
	got, err := c.resolveTURN(context.Background(), "invalid automatic address")
	if err != nil || got != "127.0.0.1:3478" {
		t.Fatal("override not used")
	}
}
