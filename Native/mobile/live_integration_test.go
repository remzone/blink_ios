// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"bufio"
	"context"
	"github.com/xtls/xray-core/proxy/tun"
	"io"
	"net"
	"net/http"
	"net/netip"
	"os"
	"strings"
	"testing"
	"time"
)

type liveProtector struct{}

func (liveProtector) Protect(int64) bool { return true } // Desktop test has no OS VPN routes.

// Opt-in acceptance against an authorized live server, never run by default.
// BLINK_LIVE_PROFILE points to a private mobile.VKProfile JSON file.
func TestLivePacketStackToServer(t *testing.T) {
	path := os.Getenv("BLINK_LIVE_PROFILE")
	if path == "" {
		t.Skip("set BLINK_LIVE_PROFILE for live acceptance")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("cannot read private live profile")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 35*time.Second)
	defer cancel()
	toPeer := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	e, err := StartVK(string(raw), toPeer, liveProtector{})
	if err != nil {
		t.Fatal("engine start failed")
	}
	defer e.Stop()
	for e.Status() != "ready" && ctx.Err() == nil {
		if e.Status() == "captcha_required" {
			t.Skip("VK requires CAPTCHA; VK traversal not verified")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if e.Status() != "ready" {
		t.Fatal("transport did not become ready")
	}
	toEngine := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	peer, err := tun.NewStack(ctx, tun.StackOptions{Tun: &packetAdapter{sink: toEngine}, MTU: 1280, Addresses: []netip.Addr{netip.MustParseAddr("10.77.0.2")}}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer peer.Close()
	go func() {
		for {
			select {
			case p := <-toPeer.packets:
				peer.Input(p)
			case <-ctx.Done():
				return
			}
		}
	}()
	go func() {
		for {
			select {
			case p := <-toEngine.packets:
				_ = e.Input(p)
			case <-ctx.Done():
				return
			}
		}
	}()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip4", "example.com")
	if err != nil || len(ips) == 0 {
		t.Fatal("cannot resolve acceptance destination")
	}
	c, err := peer.DialTCP(ctx, netip.AddrPortFrom(ips[0].Unmap(), 80))
	if err != nil {
		t.Fatal("packet TCP connect failed")
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(15 * time.Second))
	if _, err = c.Write([]byte("GET / HTTP/1.1\r\nHost: example.com\r\nConnection: close\r\n\r\n")); err != nil {
		t.Fatal("HTTP write failed")
	}
	response, err := http.ReadResponse(bufio.NewReader(c), nil)
	if err != nil {
		t.Fatal("HTTP response failed")
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, 32768))
	if err != nil || response.StatusCode != 200 || !strings.Contains(string(body), "Example Domain") {
		t.Fatal("HTTP acceptance failed")
	}
	t.Log("PASS packet stack → Xray → transport → authenticated server → HTTP response; counters", e.StatsJSON())
}
