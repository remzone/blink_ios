// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"bytes"
	"context"
	"io"
	"net"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

// Independent process built from cacggghp's pinned source + the server tuning
// patch. Exercises original KCP/smux framing over authenticated TURN for >5s.
func TestVLESSServerTuningInterop(t *testing.T) {
	path := os.Getenv("BLINK_VLESS_SERVER")
	if path == "" {
		t.Skip("set BLINK_VLESS_SERVER to the patched pinned VLESS server")
	}
	for _, network := range []string{"tcp", "udp"} {
		t.Run(network, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
			defer cancel()
			echo, e := net.Listen("tcp4", "127.0.0.1:0")
			if e != nil {
				t.Fatal(e)
			}
			defer echo.Close()
			go func() {
				for {
					c, e := echo.Accept()
					if e != nil {
						return
					}
					go func() { defer c.Close(); _, _ = io.Copy(c, c) }()
				}
			}()
			port, e := net.ListenPacket("udp4", "127.0.0.1:0")
			if e != nil {
				t.Fatal(e)
			}
			peer := port.LocalAddr().(*net.UDPAddr)
			port.Close()
			process := exec.CommandContext(ctx, path, "-listen", peer.String(), "-connect", echo.Addr().String(), "-vless", "-kcp-preset", "custom", "-kcp-window", "32", "-kcp-interval", "30", "-kcp-congestion=true", "-kcp-mtu", "1008", "-downlink-pace", "128")
			process.Stdout = io.Discard
			process.Stderr = io.Discard
			if e = process.Start(); e != nil {
				t.Fatal(e)
			}
			defer func() { _ = process.Process.Kill(); _ = process.Wait() }()
			logger := &logging.DefaultLoggerFactory{Writer: io.Discard, DefaultLogLevel: logging.LogLevelDisabled}
			cfg := turn.ServerConfig{Realm: "fixture", LoggerFactory: logger, AuthHandler: func(a *turn.RequestAttributes) (string, []byte, bool) {
				return a.Username, turn.GenerateAuthKey("fixture", a.Realm, "password"), a.Username == "fixture"
			}}
			generator := &turn.RelayAddressGeneratorStatic{RelayAddress: net.IPv4(127, 0, 0, 1), Address: "127.0.0.1"}
			var address string
			if network == "tcp" {
				l, e := net.Listen("tcp4", "127.0.0.1:0")
				if e != nil {
					t.Fatal(e)
				}
				defer l.Close()
				address = l.Addr().String()
				cfg.ListenerConfigs = []turn.ListenerConfig{{Listener: l, RelayAddressGenerator: generator}}
			} else {
				p, e := net.ListenPacket("udp4", "127.0.0.1:0")
				if e != nil {
					t.Fatal(e)
				}
				defer p.Close()
				address = p.LocalAddr().String()
				cfg.PacketConnConfigs = []turn.PacketConnConfig{{PacketConn: p, RelayAddressGenerator: generator}}
			}
			relay, e := turn.NewServer(cfg)
			if e != nil {
				t.Fatal(e)
			}
			defer relay.Close()
			client := &Client{config: Config{TURNTransport: network, Tuning: Tuning{Preset: "balanced", MTU: 1008, PaceKiB: 128}}, resolver: net.DefaultResolver, dialer: &net.Dialer{Timeout: time.Second}}
			mux, release, e := client.createSessionWithCredentials(ctx, peer, "fixture", "password", address)
			if e != nil {
				t.Fatal(e)
			}
			defer release()
			stream, e := mux.OpenStream()
			if e != nil {
				t.Fatal(e)
			}
			defer stream.Close()
			for i := 0; i < 8; i++ {
				_ = stream.SetDeadline(time.Now().Add(4 * time.Second))
				sent := bytes.Repeat([]byte{byte(i + 1)}, 8192)
				if _, e = stream.Write(sent); e != nil {
					t.Fatal(e)
				}
				received := make([]byte, len(sent))
				if _, e = io.ReadFull(stream, received); e != nil || !bytes.Equal(sent, received) {
					t.Fatal("KCP/smux stream lost payload", e)
				}
				if i < 7 {
					time.Sleep(time.Second)
				}
			}
			if strings.Contains(mux.RemoteAddr().String(), "unreachable") {
				t.Fatal("bad address")
			}
		})
	}
}
