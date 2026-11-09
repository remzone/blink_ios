package mobile

import (
	"context"
	"encoding/json"
	"fmt"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/features/routing"
	routing_session "github.com/xtls/xray-core/features/routing/session"
	"github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/net/dns/dnsmessage"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

func TestRoutingMergePrecedenceAndValidation(t *testing.T) {
	p := RoutingPolicy{Schema: "blink.routing.v1", Mode: "selected", Revision: 4, Domains: []string{"example.org"}, IPs: []string{"1.1.1.0/24"}}
	b, _ := json.Marshal(p)
	raw, e := MergeRoutingPolicy(string(b), `{"mode":"inherit","include":"*.Other.org, 1.1.1.3","exclude":"example.org"}`)
	if e != nil {
		t.Fatal(e)
	}
	var merged RoutingPolicy
	json.Unmarshal([]byte(raw), &merged)
	if len(merged.Domains) != 2 || len(merged.IPs) != 2 || len(merged.ExcludeDomains) != 1 || merged.Mode != "selected" {
		t.Fatal("local rules replaced server data")
	}
	for _, s := range []string{`{"include":"https://example.org"}`, `{"exclude":"regexp:.*"}`, `{"mode":"bad"}`, `{"include":"0.0.0.0/0"}`} {
		if _, e = MergeRoutingPolicy(string(b), s); e == nil {
			t.Fatal("unsafe rule accepted")
		}
	}
}
func routingPeer(t *testing.T, ctx context.Context, engine *Engine, toPeer *channelWriter) tun.Stack {
	t.Helper()
	out := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	peer, e := tun.NewStack(ctx, tun.StackOptions{Tun: &packetAdapter{sink: out}, MTU: 1280, Addresses: []netip.Addr{netip.MustParseAddr("10.77.0.2")}}, nil)
	if e != nil {
		t.Fatal(e)
	}
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
			case p := <-out.packets:
				_ = engine.Input(p)
			case <-ctx.Done():
				return
			}
		}
	}()
	return peer
}
func TestSelectiveRoutingFakeDNSAndProtectedDirect(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
	defer cancel()
	listener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	mock := make(chan error, 1)
	go func() {
		c, e := listener.Accept()
		if e != nil {
			mock <- e
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(8 * time.Second))
		fixed := make([]byte, 18)
		if _, e = io.ReadFull(c, fixed); e != nil {
			mock <- e
			return
		}
		io.CopyN(io.Discard, c, int64(fixed[17]))
		target := make([]byte, 4)
		io.ReadFull(c, target)
		if target[3] != 2 {
			mock <- fmt.Errorf("domain lost in fake DNS route")
			return
		}
		size := []byte{0}
		io.ReadFull(c, size)
		domain := make([]byte, int(size[0]))
		io.ReadFull(c, domain)
		if string(domain) != "media.vpn.example" {
			mock <- fmt.Errorf("wrong VPN domain")
			return
		}
		c.Write([]byte{0, 0})
		data := make([]byte, 4)
		_, e = io.ReadFull(c, data)
		if e == nil {
			_, e = c.Write([]byte("pong"))
		}
		mock <- e
	}()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	raw, _ := buildConfig(strings.Replace(strings.Replace(testProfile, `"address":"203.0.113.10","port":443`, `"address":"127.0.0.1","port":`+port, 1), `"security":"tls"`, `"security":"none"`, 1))
	policy := &RoutingPolicy{Schema: "blink.routing.v1", Mode: "selected", Revision: 1, Domains: []string{"vpn.example"}}
	writer := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	protect := &allowWG{}
	engine, e := startRoutedConfig(raw, policy, writer, protect)
	if e != nil {
		t.Fatal(e)
	}
	defer engine.Stop()
	peer := routingPeer(t, ctx, engine, writer)
	defer peer.Close()
	dns, e := peer.DialUDP()
	if e != nil {
		t.Fatal(e)
	}
	defer dns.Close()
	dns.SetDeadline(time.Now().Add(5 * time.Second))
	name, _ := dnsmessage.NewName("media.vpn.example.")
	q := dnsmessage.Message{Header: dnsmessage.Header{ID: 17, RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET}}}
	query, _ := q.Pack()
	dns.WriteTo(query, &net.UDPAddr{IP: net.IPv4(1, 1, 1, 1), Port: 53})
	buffer := make([]byte, 2048)
	n, _, e := dns.ReadFrom(buffer)
	if e != nil {
		t.Fatal("FakeDNS", e)
	}
	var answer dnsmessage.Message
	if answer.Unpack(buffer[:n]) != nil || len(answer.Answers) != 1 {
		t.Fatal("missing fake answer")
	}
	a, ok := answer.Answers[0].Body.(*dnsmessage.AResource)
	if !ok {
		t.Fatal("not A")
	}
	fake := netip.AddrFrom4(a.A)
	if !netip.MustParsePrefix("198.18.0.0/15").Contains(fake) {
		t.Fatal("real DNS used instead of fake mapping")
	}
	c, e := peer.DialTCP(ctx, netip.AddrPortFrom(fake, 80))
	if e != nil {
		t.Fatal(e)
	}
	c.SetDeadline(time.Now().Add(5 * time.Second))
	c.Write([]byte("ping"))
	response := make([]byte, 4)
	_, e = io.ReadFull(c, response)
	c.Close()
	if e != nil || string(response) != "pong" {
		t.Fatal("VPN domain routing failed", e)
	}
	if e = <-mock; e != nil {
		t.Fatal(e)
	}
	// A separate real socket proves unknown traffic bypasses the VPN outbound.
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
			c.Write([]byte("safe"))
		}
	}()
	address := netip.MustParseAddrPort(direct.Addr().String())
	c, e = peer.DialTCP(ctx, address)
	if e != nil {
		t.Fatal(e)
	}
	c.SetDeadline(time.Now().Add(4 * time.Second))
	c.Write([]byte("ping"))
	_, e = io.ReadFull(c, response)
	c.Close()
	if e != nil || string(response) != "safe" {
		t.Fatal("default route did not go directly", e)
	}
	if protect.count.Load() == 0 {
		t.Fatal("direct socket bypassed platform protection")
	}
	udpServer, e := net.ListenPacket("udp4", net.JoinHostPort(physical, "0"))
	if e != nil {
		t.Fatal(e)
	}
	defer udpServer.Close()
	go func() {
		b := make([]byte, 16)
		n, a, e := udpServer.ReadFrom(b)
		if e == nil {
			udpServer.WriteTo(b[:n], a)
		}
	}()
	udp, e := peer.DialUDP()
	if e != nil {
		t.Fatal(e)
	}
	defer udp.Close()
	udp.SetDeadline(time.Now().Add(4 * time.Second))
	udp.WriteTo([]byte("direct-udp"), udpServer.LocalAddr())
	b := make([]byte, 32)
	n, _, e = udp.ReadFrom(b)
	if e != nil || string(b[:n]) != "direct-udp" {
		t.Fatal("UDP default did not go directly", e)
	}
}

// Test the real engine router: a direct IP exception wins even when the same
// hostname is explicitly included in the VPN domain list. Static DNS avoids
// external lookups and ensures the router does not classify a FakeDNS answer.
func TestSelectiveRoutingDirectIPOverridesDomain(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	raw, err := buildConfig(testProfile)
	if err != nil {
		t.Fatal(err)
	}
	p := &RoutingPolicy{Schema: "blink.routing.v1", Mode: "selected", Revision: 1, Domains: []string{"vpn.example"}, ExcludeIPs: []string{"203.0.113.0/24"}}
	cfg, opt, err := splitConfig(raw, p)
	if err != nil {
		t.Fatal(err)
	}
	var doc map[string]any
	json.Unmarshal(cfg, &doc)
	doc["dns"].(map[string]any)["hosts"] = map[string]any{"media.vpn.example": "203.0.113.7"}
	cfg, _ = json.Marshal(doc)
	engine, err := startConfigOptions(cfg, &channelWriter{ctx: ctx, packets: make(chan []byte, 32)}, &allowWG{}, opt)
	if err != nil {
		t.Fatal(err)
	}
	defer engine.Stop()
	router := engine.instance.GetFeature(routing.RouterType()).(routing.Router)
	request := session.ContextWithOutbounds(ctx, []*session.Outbound{{Target: xnet.TCPDestination(xnet.DomainAddress("media.vpn.example"), 443)}})
	result, err := router.PickRoute(routing_session.AsRoutingContext(request))
	if err != nil {
		t.Fatal(err)
	}
	if result.GetOutboundTag() != "blink-direct" {
		t.Fatal("IP exclusion lost to included domain", result.GetOutboundTag())
	}
}
