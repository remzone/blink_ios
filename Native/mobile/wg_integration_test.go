// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"fmt"
	awg "github.com/amnezia-vpn/amneziawg-go/v3/device"
	"golang.org/x/crypto/curve25519"
	wc "golang.zx2c4.com/wireguard/conn"
	wd "golang.zx2c4.com/wireguard/device"
	wt "golang.zx2c4.com/wireguard/tun"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

type allowWG struct{ count atomic.Int32 }

func (a *allowWG) Protect(int64) bool { a.count.Add(1); return true }

type echoWGWriter struct{ packets *wgPacketDevice }

func (e *echoWGWriter) WritePacket(p []byte) bool {
	if len(p) != 24 || string(p[20:]) != "ping" {
		return false
	}
	b := append([]byte(nil), p...)
	copy(b[12:16], p[16:20])
	copy(b[16:20], p[12:16])
	copy(b[20:], "pong")
	b[10] = 0
	b[11] = 0
	binary.BigEndian.PutUint16(b[10:12], checksumIP(b[:20]))
	e.packets.Input(b)
	return true
}
func checksumIP(b []byte) uint16 {
	var n uint32
	for i := 0; i+1 < len(b); i += 2 {
		n += uint32(binary.BigEndian.Uint16(b[i:]))
	}
	for n>>16 != 0 {
		n = n&65535 + n>>16
	}
	return ^uint16(n)
}

type standardWGTUN struct {
	*wgPacketDevice
	events chan wt.Event
	once   sync.Once
}

func (s *standardWGTUN) Events() <-chan wt.Event { return s.events }
func (s *standardWGTUN) Close() error {
	s.once.Do(func() { close(s.events) })
	return s.wgPacketDevice.Close()
}
func TestWireGuardAndAmneziaPacketRoundTrip(t *testing.T) {
	for _, kind := range []string{"wireguard", "amneziawg"} {
		t.Run(kind, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
			defer cancel()
			clientPrivate := make([]byte, 32)
			serverPrivate := make([]byte, 32)
			rand.Read(clientPrivate)
			rand.Read(serverPrivate)
			clientPublic, _ := curve25519.X25519(clientPrivate, curve25519.Basepoint)
			serverPublic, _ := curve25519.X25519(serverPrivate, curve25519.Basepoint)
			socket, e := net.ListenPacket("udp4", "127.0.0.1:0")
			if e != nil {
				t.Fatal(e)
			}
			port := socket.LocalAddr().(*net.UDPAddr).Port
			socket.Close()
			echo := &echoWGWriter{}
			packets := newWGPacketDevice(&packetAdapter{sink: echo}, 1280)
			echo.packets = packets
			serverConf := fmt.Sprintf("private_key=%s\nlisten_port=%d\n", hex.EncodeToString(serverPrivate), port)
			extra := ""
			if kind == "amneziawg" {
				extra = "jc=2\njmin=30\njmax=50\ns1=15\ns2=25\nh1=100\nh2=200\nh3=300\nh4=400\n"
			}
			serverConf += extra + "public_key=" + hex.EncodeToString(clientPublic) + "\nallowed_ip=10.77.0.2/32\n"
			if kind == "wireguard" {
				dev := wd.NewDevice(&standardWGTUN{wgPacketDevice: packets, events: make(chan wt.Event)}, wc.NewDefaultBind(), &wd.Logger{Verbosef: func(string, ...any) {}, Errorf: func(string, ...any) {}})
				defer dev.Close()
				if e = dev.IpcSet(serverConf); e != nil {
					t.Fatal(e)
				}
				if e = dev.Up(); e != nil {
					t.Fatal(e)
				}
			} else {
				dev := awg.NewDevice(packets, &protectedWGBind{protector: &allowWG{}}, &awg.Logger{Verbosef: func(string, ...any) {}, Errorf: func(string, ...any) {}})
				defer dev.Close()
				if e = dev.IpcSet(serverConf); e != nil {
					t.Fatal(e)
				}
				if e = dev.Up(); e != nil {
					t.Fatal(e)
				}
			}
			conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.77.0.2/32\nDNS = 10.77.0.1\n", base64.StdEncoding.EncodeToString(clientPrivate))
			conf += strings.ReplaceAll(strings.ReplaceAll(extra, "=", " = "), "\n", "\n")
			conf += fmt.Sprintf("[Peer]\nPublicKey = %s\nEndpoint = 127.0.0.1:%d\nAllowedIPs = 10.77.0.1/32\nPersistentKeepalive = 1\n", base64.StdEncoding.EncodeToString(serverPublic), port)
			raw, e := ImportProfile(conf)
			if e != nil {
				t.Fatal(e)
			}
			sink := &channelWriter{ctx: ctx, packets: make(chan []byte, 8)}
			protected := &allowWG{}
			engine, e := StartProfile(raw, sink, protected)
			if e != nil {
				t.Fatal(e)
			}
			defer engine.Stop()
			p := make([]byte, 24)
			p[0] = 0x45
			p[3] = 24
			p[8] = 64
			p[9] = 253
			copy(p[12:16], []byte{10, 77, 0, 2})
			copy(p[16:20], []byte{10, 77, 0, 1})
			copy(p[20:], "ping")
			binary.BigEndian.PutUint16(p[10:12], checksumIP(p[:20]))
			if e = engine.Input(p); e != nil {
				t.Fatal(e)
			}
			select {
			case response := <-sink.packets:
				if string(response[20:]) != "pong" {
					t.Fatal("wrong encrypted round-trip payload")
				}
			case <-ctx.Done():
				t.Fatal("no encrypted WireGuard packet round trip")
			}
			if protected.count.Load() == 0 {
				t.Fatal("no socket protection")
			}
			engine.Stop()
			engine.Stop()
		})
	}
}
