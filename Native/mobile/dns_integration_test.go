// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"encoding/binary"
	"fmt"
	"github.com/xtls/xray-core/infra/conf/serial"
	"github.com/xtls/xray-core/proxy/tun"
	"golang.org/x/net/dns/dnsmessage"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"
)

// Real IP UDP query -> TUN/Xray -> TCP VLESS -> DNS TCP frame -> UDP answer.
func TestDNSUsesProxyTCPAndSuppressesAAAA(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	listener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		c, e := listener.Accept()
		if e != nil {
			done <- e
			return
		}
		defer c.Close()
		c.SetDeadline(time.Now().Add(5 * time.Second))
		header := make([]byte, 18)
		if _, e = io.ReadFull(c, header); e != nil {
			done <- e
			return
		}
		io.CopyN(io.Discard, c, int64(header[17]))
		target := make([]byte, 8)
		if _, e = io.ReadFull(c, target); e != nil {
			done <- e
			return
		}
		if target[0] != 1 || binary.BigEndian.Uint16(target[1:3]) != 53 || target[3] != 1 || string(target[4:]) != string([]byte{198, 51, 100, 53}) {
			done <- fmt.Errorf("DNS escaped TCP VLESS target")
			return
		}
		c.Write([]byte{0, 0})
		size := make([]byte, 2)
		if _, e = io.ReadFull(c, size); e != nil {
			done <- e
			return
		}
		q := make([]byte, int(binary.BigEndian.Uint16(size)))
		if _, e = io.ReadFull(c, q); e != nil {
			done <- e
			return
		}
		var query dnsmessage.Message
		if query.Unpack(q) != nil || len(query.Questions) != 1 || query.Questions[0].Type != dnsmessage.TypeA {
			done <- fmt.Errorf("wrong DNS query")
			return
		}
		query.Header.Response = true
		query.Header.RecursionAvailable = true
		query.Answers = []dnsmessage.Resource{{Header: dnsmessage.ResourceHeader{Name: query.Questions[0].Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60}, Body: &dnsmessage.AResource{A: [4]byte{203, 0, 113, 1}}}}
		answer, _ := query.Pack()
		binary.BigEndian.PutUint16(size, uint16(len(answer)))
		_, e = c.Write(append(size, answer...))
		done <- e
	}()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	profile := strings.Replace(testProfile, `"address":"203.0.113.10","port":443`, `"address":"127.0.0.1","port":`+port, 1)
	profile = strings.Replace(profile, `"security":"tls"`, `"security":"none"`, 1)
	toPeer := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	rawConfig, _ := buildConfig(profile)
	rawConfig, _ = withProxyDNS(rawConfig)
	if _, parseErr := serial.LoadJSONConfig(strings.NewReader(string(rawConfig))); parseErr != nil {
		t.Fatal(parseErr)
	}
	engine, e := Start(profile, toPeer, noNetwork{t})
	if e != nil {
		t.Fatal(e)
	}
	defer engine.Stop()
	toEngine := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	peer, e := tun.NewStack(ctx, tun.StackOptions{Tun: &packetAdapter{sink: toEngine}, MTU: 1280, Addresses: []netip.Addr{netip.MustParseAddr("10.77.0.2")}}, nil)
	if e != nil {
		t.Fatal(e)
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
				engine.Input(p)
			case <-ctx.Done():
				return
			}
		}
	}()
	socket, e := peer.DialUDP()
	if e != nil {
		t.Fatal(e)
	}
	defer socket.Close()
	socket.SetDeadline(time.Now().Add(4 * time.Second))
	name, _ := dnsmessage.NewName("fixture.example.org.")
	for _, kind := range []dnsmessage.Type{dnsmessage.TypeAAAA, dnsmessage.TypeA} {
		q := dnsmessage.Message{Header: dnsmessage.Header{ID: uint16(kind), RecursionDesired: true}, Questions: []dnsmessage.Question{{Name: name, Type: kind, Class: dnsmessage.ClassINET}}}
		raw, _ := q.Pack()
		if _, e = socket.WriteTo(raw, &net.UDPAddr{IP: net.IPv4(198, 51, 100, 53), Port: 53}); e != nil {
			t.Fatal(e)
		}
		buf := make([]byte, 2048)
		n, _, e := socket.ReadFrom(buf)
		if e != nil {
			t.Fatal(e)
		}
		var answer dnsmessage.Message
		if answer.Unpack(buf[:n]) != nil || !answer.Response || answer.ID != uint16(kind) {
			t.Fatal("bad DNS response")
		}
		if kind == dnsmessage.TypeAAAA && len(answer.Answers) != 0 {
			t.Fatal("IPv6 advertised without a usable path")
		}
		if kind == dnsmessage.TypeA && len(answer.Answers) != 1 {
			t.Fatal("DNS did not return proxy answer")
		}
	}
	if e = <-done; e != nil {
		t.Fatal(e)
	}
}
