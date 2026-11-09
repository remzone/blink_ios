// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"golang.org/x/crypto/curve25519"
	wc "golang.zx2c4.com/wireguard/conn"
	wd "golang.zx2c4.com/wireguard/device"
	wt "golang.zx2c4.com/wireguard/tun"
)

// This test deliberately uses the independently built, pinned upstream server,
// a real authenticated TURN relay and a standard WireGuard server. No VK token
// or public network is involved. Run with BLINK_TURN_SERVER=/path/to/server.
func TestVKWireGuardUpstreamRoundTrip(t *testing.T) {
	binaryPath := os.Getenv("BLINK_TURN_SERVER")
	if binaryPath == "" {
		t.Skip("set BLINK_TURN_SERVER to the pinned anton48 server binary")
	}
	for _, protocol := range []string{"dtls", "srtp", "wrap"} {
		for _, network := range []string{"tcp", "udp", "auto"} {
			t.Run(protocol+"-"+network, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
				defer cancel()
				privateClient, privateServer := make([]byte, 32), make([]byte, 32)
				_, _ = rand.Read(privateClient)
				_, _ = rand.Read(privateServer)
				publicClient, _ := curve25519.X25519(privateClient, curve25519.Basepoint)
				publicServer, _ := curve25519.X25519(privateServer, curve25519.Basepoint)
				port := freeVKPort(t)
				echo := &echoWGWriter{}
				packets := newWGPacketDevice(&packetAdapter{sink: echo}, 1280)
				echo.packets = packets
				device := wd.NewDevice(&standardWGTUN{wgPacketDevice: packets, events: make(chan wt.Event)}, wc.NewDefaultBind(), &wd.Logger{Verbosef: func(string, ...any) {}, Errorf: func(string, ...any) {}})
				defer device.Close()
				if e := device.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.77.0.2/32\n", hex.EncodeToString(privateServer), port, hex.EncodeToString(publicClient))); e != nil {
					t.Fatal(e)
				}
				if e := device.Up(); e != nil {
					t.Fatal(e)
				}
				peerPort := freeVKPort(t)
				peerAddr := fmt.Sprintf("127.0.0.1:%d", peerPort)
				args := []string{"-listen", peerAddr, "-connect", fmt.Sprintf("127.0.0.1:%d", port), "-downlink-pace", "0"}
				key := ""
				switch protocol {
				case "srtp":
					args = append(args, "-srtp")
				case "wrap":
					key = strings.Repeat("12", 32)
					args = append(args, "-wrap-srtp", "-wrap-key", key)
				}
				process := exec.CommandContext(ctx, binaryPath, args...)
				process.Stdout = io.Discard
				process.Stderr = io.Discard
				if e := process.Start(); e != nil {
					t.Fatal(e)
				}
				defer func() { _ = process.Process.Kill(); _ = process.Wait() }()
				logger := &logging.DefaultLoggerFactory{Writer: io.Discard, DefaultLogLevel: logging.LogLevelDisabled}
				relayConfig := turn.ServerConfig{Realm: "fixture", LoggerFactory: logger, AuthHandler: func(a *turn.RequestAttributes) (string, []byte, bool) {
					return a.Username, turn.GenerateAuthKey("fixture", a.Realm, "password"), a.Username == "fixture"
				}}
				generator := &turn.RelayAddressGeneratorStatic{RelayAddress: net.IPv4(127, 0, 0, 1), Address: "127.0.0.1"}
				var address string
				if network == "tcp" {
					listener, e := net.Listen("tcp4", "127.0.0.1:0")
					if e != nil {
						t.Fatal(e)
					}
					defer listener.Close()
					address = listener.Addr().String()
					relayConfig.ListenerConfigs = []turn.ListenerConfig{{Listener: listener, RelayAddressGenerator: generator}}
				} else {
					socket, e := net.ListenPacket("udp4", "127.0.0.1:0")
					if e != nil {
						t.Fatal(e)
					}
					defer socket.Close()
					address = socket.LocalAddr().String()
					relayConfig.PacketConnConfigs = []turn.PacketConnConfig{{PacketConn: socket, RelayAddressGenerator: generator}}
				}
				relay, e := turn.NewServer(relayConfig)
				if e != nil {
					t.Fatal(e)
				}
				defer relay.Close()
				call := "https://vk.ru/call/join/FIXTURE"
				bootstrap, _ := json.Marshal(map[string]any{"username": "fixture", "password": "password", "address": address, "peerHost": "127.0.0.1", "peerPort": peerPort, "callURL": call, "expiresAt": time.Now().Add(80 * time.Second).Unix()})
				// The unreachable supplied endpoint proves the engine rewrites WG endpoints
				// to TURN and cannot succeed by accidentally connecting directly to WG.
				source := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = 10.77.0.2/32\nDNS = 10.77.0.1\nMTU = 1280\n[Peer]\nPublicKey = %s\nEndpoint = 192.0.2.1:9\nAllowedIPs = 10.77.0.1/32\nPersistentKeepalive = 1\n", base64.StdEncoding.EncodeToString(privateClient), base64.StdEncoding.EncodeToString(publicServer))
				profile := VKProfile{Backend: "wireguard", Protocol: protocol, WrapKey: key, WireGuard: source, UUID: "11111111-1111-4111-8111-111111111111", PeerHost: "127.0.0.1", PeerPort: peerPort, VKCallURL: call, Streams: 2, ExpiresAt: time.Now().Add(time.Hour).Unix(), DNSServer: "1.1.1.1", TURNTransport: network, Bootstrap: string(bootstrap)}
				raw, _ := json.Marshal(profile)
				sink := &channelWriter{ctx: ctx, packets: make(chan []byte, 8)}
				protected := &allowWG{}
				engine, e := StartVK(string(raw), sink, protected)
				if e != nil {
					t.Fatal(e)
				}
				defer engine.Stop()
				for engine.Status() != "ready" {
					select {
					case <-ctx.Done():
						t.Fatal("TURN not ready")
					case <-time.After(20 * time.Millisecond):
					}
				}
				packet := make([]byte, 24)
				packet[0] = 0x45
				packet[3] = 24
				packet[8] = 64
				packet[9] = 253
				copy(packet[12:16], []byte{10, 77, 0, 2})
				copy(packet[16:20], []byte{10, 77, 0, 1})
				copy(packet[20:], "ping")
				binary.BigEndian.PutUint16(packet[10:12], checksumIP(packet[:20]))
				for round := 0; round < 8; round++ {
					if e = engine.Input(packet); e != nil {
						t.Fatal(e)
					}
					select {
					case response := <-sink.packets:
						if string(response[20:]) != "pong" {
							t.Fatal("bad encrypted round trip")
						}
					case <-ctx.Done():
						t.Fatal("no WG packet via TURN", round)
					}
					if round < 7 {
						time.Sleep(time.Second)
					}
				}
				if protected.count.Load() == 0 {
					t.Fatal("no socket protection")
				}
				done := make(chan struct{})
				go func() { engine.Stop(); close(done) }()
				select {
				case <-done:
				case <-time.After(2 * time.Second):
					t.Fatal("shutdown leaked or blocked")
				}
			})
		}
	}
}
func freeVKPort(t *testing.T) int {
	t.Helper()
	s, e := net.ListenPacket("udp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	p := s.LocalAddr().(*net.UDPAddr).Port
	_ = s.Close()
	return p
}
