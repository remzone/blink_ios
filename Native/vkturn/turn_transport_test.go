// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"github.com/remzone/blink_ios/native/vkturn/tcputil"
	"github.com/xtaci/smux"
	"io"
	"net"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestTURNTransportsProtectedDTLSSmux(t *testing.T) {
	for _, network := range []string{"tcp", "udp"} {
		t.Run(network, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			logger := &logging.DefaultLoggerFactory{Writer: io.Discard, DefaultLogLevel: logging.LogLevelDisabled}
			cfg := turn.ServerConfig{Realm: "fixture", AuthHandler: func(ra *turn.RequestAttributes) (string, []byte, bool) {
				return ra.Username, turn.GenerateAuthKey("fixture", ra.Realm, "fixture-password"), ra.Username == "fixture"
			}, LoggerFactory: logger}
			generator := &turn.RelayAddressGeneratorStatic{RelayAddress: net.IPv4(127, 0, 0, 1), Address: "127.0.0.1"}
			var addr string
			if network == "udp" {
				socket, e := net.ListenPacket("udp4", "127.0.0.1:0")
				if e != nil {
					t.Fatal(e)
				}
				defer socket.Close()
				addr = socket.LocalAddr().String()
				cfg.PacketConnConfigs = []turn.PacketConnConfig{{PacketConn: socket, RelayAddressGenerator: generator}}
			} else {
				listener, e := net.Listen("tcp4", "127.0.0.1:0")
				if e != nil {
					t.Fatal(e)
				}
				defer listener.Close()
				addr = listener.Addr().String()
				cfg.ListenerConfigs = []turn.ListenerConfig{{Listener: listener, RelayAddressGenerator: generator}}
			}
			server, e := turn.NewServer(cfg)
			if e != nil {
				t.Fatal(e)
			}
			defer server.Close()
			cert, e := selfsign.GenerateSelfSigned()
			if e != nil {
				t.Fatal(e)
			}
			peer, e := dtls.ListenWithOptions("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)}, dtls.WithCertificates(cert), dtls.WithExtendedMasterSecret(dtls.RequireExtendedMasterSecret), dtls.WithCipherSuites(dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256))
			if e != nil {
				t.Fatal(e)
			}
			defer peer.Close()
			stop := context.AfterFunc(ctx, func() { peer.Close() })
			defer stop()
			done := make(chan error, 1)
			go func() {
				conn, e := peer.Accept()
				if e != nil {
					done <- e
					return
				}
				defer conn.Close()
				stop := context.AfterFunc(ctx, func() { conn.Close() })
				defer stop()
				if e = conn.(*dtls.Conn).HandshakeContext(ctx); e != nil {
					done <- e
					return
				}
				k, e := tcputil.NewKCPOverDTLS(conn, true)
				if e != nil {
					done <- e
					return
				}
				defer k.Close()
				mux, e := smux.Server(k, tcputil.DefaultSmuxConfig())
				if e != nil {
					done <- e
					return
				}
				defer mux.Close()
				stream, e := mux.AcceptStream()
				if e != nil {
					done <- e
					return
				}
				defer stream.Close()
				b := make([]byte, 5)
				if _, e = io.ReadFull(stream, b); e == nil {
					_, e = stream.Write(b)
				}
				done <- e
			}()
			var protected atomic.Int32
			c := &Client{config: Config{TURNTransport: network}, resolver: net.DefaultResolver, dialer: &net.Dialer{Timeout: time.Second, Control: func(_, _ string, raw syscall.RawConn) error { return raw.Control(func(uintptr) { protected.Add(1) }) }}}
			mux, cleanup, e := c.createSessionWithCredentials(ctx, peer.Addr().(*net.UDPAddr), "fixture", "fixture-password", addr)
			if e != nil {
				t.Fatal(e)
			}
			defer cleanup()
			stream, e := mux.OpenStream()
			if e != nil {
				t.Fatal(e)
			}
			defer stream.Close()
			stream.SetDeadline(time.Now().Add(2 * time.Second))
			if _, e = stream.Write([]byte("hello")); e != nil {
				t.Fatal(e)
			}
			b := make([]byte, 5)
			if _, e = io.ReadFull(stream, b); e != nil {
				t.Fatal(e)
			}
			if string(b) != "hello" {
				t.Fatal("invalid relay payload")
			}
			if e = <-done; e != nil {
				t.Fatal(e)
			}
			if protected.Load() == 0 {
				t.Fatal("TURN socket not protected")
			}
		})
	}
}
func TestRejectsUnknownTURNTransport(t *testing.T) {
	cfg := testConfig()
	cfg.TURNTransport = "automatic"
	if c, e := Start(context.Background(), cfg, allow); e == nil {
		c.Close()
		t.Fatal("invalid transport accepted")
	}
}
