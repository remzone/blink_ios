// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"bufio"
	"context"
	"crypto/tls"
	"github.com/xtls/xray-core/proxy/tun"
 corelog "github.com/xtls/xray-core/common/log"
	"golang.org/x/net/dns/dnsmessage"
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
	standard := os.Getenv("BLINK_LIVE_STANDARD_PROFILE")
	if standard != "" {
		path = standard
	}
	if path == "" {
		t.Skip("set BLINK_LIVE_PROFILE for live acceptance")
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal("cannot read private live profile")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 70*time.Second)
	defer cancel()
	toPeer := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	var e *Engine
	if standard != "" {
		profile, parseErr := ImportProfile(strings.TrimSpace(string(raw)))
		if parseErr != nil {
			t.Fatal("standard profile import failed")
		}
		e, err = StartProfile(profile, toPeer, liveProtector{})
	} else {
		e, err = StartVK(string(raw), toPeer, liveProtector{})
	}
	if err != nil {
		t.Fatal("engine start failed:", err)
	}
	defer e.Stop()
 if os.Getenv("BLINK_LIVE_TRACE")=="1"{corelog.RegisterHandler(&liveFailureClassifier{t:t})}
	for e.Status() != "ready" && e.Status() != "running" && ctx.Err() == nil {
		if e.Status() == "captcha_required" {
			t.Skip("VK requires CAPTCHA; VK traversal not verified")
		}
		time.Sleep(50 * time.Millisecond)
	}
	if e.Status() != "ready" && e.Status() != "running" {
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
	// Keep the same engine alive beyond the reported five-second failure window.
	time.Sleep(6 * time.Second)
	for _, target := range []struct {
		host, path string
		status     int
	}{
		{"www.cloudflare.com", "/cdn-cgi/trace", 200},
		{"www.google.com", "/generate_204", 204},
	} {
		socket, err := peer.DialUDP()
		if err != nil {
			t.Fatal("DNS packet socket failed")
		}
		_ = socket.SetDeadline(time.Now().Add(10 * time.Second))
		name, _ := dnsmessage.NewName(target.host + ".")
		query := dnsmessage.Message{Header: dnsmessage.Header{ID: 123, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
		packet, _ := query.Pack()
		_, err = socket.WriteTo(packet, &net.UDPAddr{IP: net.IPv4(1, 1, 1, 1), Port: 53})
		if err != nil {
			socket.Close()
			t.Fatal("DNS query write failed")
		}
		buffer := make([]byte, 4096)
		n, _, err := socket.ReadFrom(buffer)
		socket.Close()
		if err != nil {
			t.Fatal("DNS over packet stack and proxy TCP failed")
		}
		var answer dnsmessage.Message
		if answer.Unpack(buffer[:n]) != nil || answer.RCode != dnsmessage.RCodeSuccess {
			t.Fatal("Invalid DNS proxy response")
		}
		var destination netip.Addr
		for _, resource := range answer.Answers {
			if a, ok := resource.Body.(*dnsmessage.AResource); ok {
				destination = netip.AddrFrom4(a.A)
				break
			}
		}
		if !destination.IsValid() {
			t.Fatal("Proxy DNS returned no IPv4 endpoint")
		}
		t.Log("PASS proxy DNS", target.host)
		conn, err := peer.DialTCP(ctx, netip.AddrPortFrom(destination, 443))
		if err != nil {
			t.Fatal("HTTPS packet TCP connect failed")
		}
		_ = conn.SetDeadline(time.Now().Add(15 * time.Second))
		secure := tls.Client(conn, &tls.Config{ServerName: target.host, MinVersion: tls.VersionTLS12})
		if err = secure.HandshakeContext(ctx); err != nil {
			secure.Close()
			t.Fatal("Verified TLS through packet stack failed")
		}
		request, _ := http.NewRequest("GET", "https://"+target.host+target.path, nil)
		request.Close = true
		if request.Write(secure) != nil {
			secure.Close()
			t.Fatal("HTTPS request write failed")
		}
		response, err := http.ReadResponse(bufio.NewReader(secure), request)
		if err != nil {
			secure.Close()
			t.Fatal("HTTPS response failed")
		}
		body, err := io.ReadAll(io.LimitReader(response.Body, 8192))
		response.Body.Close()
		secure.Close()
		if err != nil || response.StatusCode != target.status {
			t.Fatalf("HTTPS acceptance failed for %s, status %d", target.host, response.StatusCode)
		}
		if target.path == "/cdn-cgi/trace" && !strings.Contains(string(body), "ip=") {
			t.Fatal("IP response missing")
		}
		t.Log("PASS verified HTTPS", target.host, "status", response.StatusCode)
	}

}

// Opt-in live diagnostics: emit fixed categories, never the formatted error text.
type liveFailureClassifier struct{t *testing.T}
func(*liveFailureClassifier)Severity()corelog.Severity{return corelog.Severity_Info}
func(l *liveFailureClassifier)Handle(message corelog.Message){
 general,ok:=message.(*corelog.GeneralMessage);if !ok{return}
 err,ok:=general.Content.(error);if !ok{return}
 text:=strings.ToLower(err.Error())
 for _,category:=range []string{"reality verification failed","invalid connection","failed to process outbound","failed to dial","connection refused","i/o timeout","tls handshake","eof"}{
  if strings.Contains(text,category){l.t.Log("core failure category:",category);return}
 }
}
