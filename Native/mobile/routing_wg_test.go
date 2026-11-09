package mobile

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	cnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/crypto/curve25519"
	wc "golang.zx2c4.com/wireguard/conn"
	wd "golang.zx2c4.com/wireguard/device"
	wt "golang.zx2c4.com/wireguard/tun"
	"io"
	"net"
	"net/netip"
	"sync/atomic"
	"testing"
	"time"
)

type routingWGInbound struct{ stack tun.Stack }

func (s *routingWGInbound) WritePacket(p []byte) bool {
	s.stack.Input(append([]byte(nil), p...))
	return true
}

type routingWGOutbound struct{ packets *wgPacketDevice }

func (s *routingWGOutbound) WritePacket(p []byte) bool {
	s.packets.Input(append([]byte(nil), p...))
	return true
}

type routingEcho struct{ count atomic.Int64 }

func (h *routingEcho) HandleConnection(c cnet.Conn, _ cnet.Destination) {
	h.count.Add(1)
	go func() { defer c.Close(); io.Copy(c, c) }()
}
func TestSelectiveWireGuardPacketRoundTrip(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	privateClient, privateServer := make([]byte, 32), make([]byte, 32)
	rand.Read(privateClient)
	rand.Read(privateServer)
	publicClient, _ := curve25519.X25519(privateClient, curve25519.Basepoint)
	publicServer, _ := curve25519.X25519(privateServer, curve25519.Basepoint)
	port := freeVKPort(t)
	sink := &routingWGInbound{}
	packets := newWGPacketDevice(&packetAdapter{sink: sink}, 1280)
	handler := &routingEcho{}
	serverStack, e := tun.NewStack(ctx, tun.StackOptions{Tun: &packetAdapter{sink: &routingWGOutbound{packets}}, MTU: 1280, Addresses: []netip.Addr{netip.MustParseAddr("10.88.0.1")}}, handler)
	if e != nil {
		t.Fatal(e)
	}
	sink.stack = serverStack
	defer serverStack.Close()
	server := wd.NewDevice(&standardWGTUN{wgPacketDevice: packets, events: make(chan wt.Event)}, wc.NewDefaultBind(), &wd.Logger{Verbosef: func(string, ...any) {}, Errorf: func(string, ...any) {}})
	defer server.Close()
	if e = server.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.88.0.2/32\n", hex.EncodeToString(privateServer), port, hex.EncodeToString(publicClient))); e != nil {
		t.Fatal(e)
	}
	if e = server.Up(); e != nil {
		t.Fatal(e)
	}
	source := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.88.0.2/32\nMTU = 1280\n[Peer]\nPublicKey = %s\nEndpoint = 127.0.0.1:%d\nAllowedIPs = 0.0.0.0/0\n", base64.StdEncoding.EncodeToString(privateClient), base64.StdEncoding.EncodeToString(publicServer), port)
	imported, e := ImportProfile(source)
	if e != nil {
		t.Fatal(e)
	}
	policy, _ := json.Marshal(RoutingPolicy{Schema: "blink.routing.v1", Mode: "selected", Revision: 1, IPs: []string{"198.51.100.0/24"}})
	writer := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	engine, e := StartProfileRouted(imported, string(policy), writer, &allowWG{})
	if e != nil {
		t.Fatal(e)
	}
	defer engine.Stop()
	peer := routingPeer(t, ctx, engine, writer)
	defer peer.Close()
	c, e := peer.DialTCP(ctx, netip.MustParseAddrPort("198.51.100.12:80"))
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.SetDeadline(time.Now().Add(8 * time.Second))
	c.Write([]byte("wireguard"))
	b := make([]byte, 9)
	if _, e = io.ReadFull(c, b); e != nil || string(b) != "wireguard" {
		t.Fatal("selected WireGuard TCP failed", e)
	}
	physical := ""
	addresses, _ := net.InterfaceAddrs()
	for _, address := range addresses {
		if p, e := netip.ParsePrefix(address.String()); e == nil && p.Addr().Is4() && !p.Addr().IsLoopback() {
			physical = p.Addr().String()
			break
		}
	}
	if physical == "" {
		t.Fatal("no physical test interface")
	}
	direct, e := net.Listen("tcp4", net.JoinHostPort(physical, "0"))
	if e != nil {
		t.Fatal(e)
	}
	defer direct.Close()
	go func() {
		c, e := direct.Accept()
		if e == nil {
			defer c.Close()
			b := make([]byte, 4)
			io.ReadFull(c, b)
			c.Write([]byte("real"))
		}
	}()
	c2, e := peer.DialTCP(ctx, netip.MustParseAddrPort(direct.Addr().String()))
	if e != nil {
		t.Fatal(e)
	}
	defer c2.Close()
	c2.SetDeadline(time.Now().Add(4 * time.Second))
	c2.Write([]byte("ping"))
	b = make([]byte, 4)
	if _, e = io.ReadFull(c2, b); e != nil || string(b) != "real" {
		t.Fatal("direct traffic entered WG", e)
	}
	if handler.count.Load() != 1 {
		t.Fatal("nonlisted traffic crossed WG backend")
	}
}
