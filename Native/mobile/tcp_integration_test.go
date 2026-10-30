// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/xtls/xray-core/proxy/tun"
)

type channelWriter struct {
	ctx     context.Context
	packets chan []byte
}

func (w *channelWriter) WritePacket(p []byte) bool {
	select {
	case w.packets <- append([]byte(nil), p...):
		return true
	case <-w.ctx.Done():
		return false
	}
}

// A loopback mock speaks only the minimal VLESS response and echoes bytes. This
// tests packetFlow->TCP stack->Xray VLESS->mock->packetFlow without a VPN/server.
func TestTCPVLESSLoopbackMock(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan error, 1)
	go func() {
		c, err := listener.Accept()
		if err != nil {
			done <- err
			return
		}
		defer c.Close()
		_ = c.SetDeadline(time.Now().Add(5 * time.Second))
		fixed := make([]byte, 18)
		if _, err = io.ReadFull(c, fixed); err != nil {
			done <- err
			return
		}
		if fixed[0] != 0 {
			done <- fmt.Errorf("not VLESS")
			return
		}
		if _, err = io.CopyN(io.Discard, c, int64(fixed[17])); err != nil {
			done <- err
			return
		}
		addr := make([]byte, 4)
		if _, err = io.ReadFull(c, addr); err != nil {
			done <- err
			return
		}
		if addr[0] != 1 || binary.BigEndian.Uint16(addr[1:3]) != 80 || addr[3] != 1 {
			done <- fmt.Errorf("unexpected VLESS target header %v", addr)
			return
		}
		target := make([]byte, 4)
		if _, err = io.ReadFull(c, target); err != nil {
			done <- err
			return
		}
		if string(target) != string([]byte{198, 51, 100, 1}) {
			done <- fmt.Errorf("wrong virtual destination")
			return
		}
		if _, err = c.Write([]byte{0, 0}); err != nil {
			done <- err
			return
		}
		input := make([]byte, 4)
		if _, err = io.ReadFull(c, input); err != nil {
			done <- err
			return
		}
		if string(input) != "ping" {
			done <- fmt.Errorf("wrong payload")
			return
		}
		_, err = c.Write([]byte("pong"))
		done <- err
	}()
	_, port, _ := net.SplitHostPort(listener.Addr().String())
	profile := strings.Replace(testProfile, `"address":"203.0.113.10","port":443`, `"address":"127.0.0.1","port":`+port, 1)
	profile = strings.Replace(profile, `"security":"tls"`, `"security":"none"`, 1)
	toPeer := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	e, err := Start(profile, toPeer, noNetwork{t})
	if err != nil {
		t.Fatal(err)
	}
	defer e.Stop()
	toEngine := &channelWriter{ctx: ctx, packets: make(chan []byte, 128)}
	peerAdapter := &packetAdapter{sink: toEngine}
	peer, err := tun.NewStack(ctx, tun.StackOptions{Tun: peerAdapter, MTU: 1280, Addresses: []netip.Addr{netip.MustParseAddr("10.77.0.2")}}, nil)
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
	c, err := peer.DialTCP(ctx, netip.MustParseAddrPort("198.51.100.1:80"))
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err = c.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	response := make([]byte, 4)
	if _, err = io.ReadFull(c, response); err != nil {
		t.Fatal(err)
	}
	if string(response) != "pong" {
		t.Fatalf("reply %q", response)
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
}
