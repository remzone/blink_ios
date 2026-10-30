package vkturn

import (
	"context"
	"io"
	"net"
	"testing"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"github.com/remzone/blink_ios/native/vkturn/tcputil"
	"github.com/xtaci/smux"
)

// fixtureNet permits only a loopback UDP relay for the in-process test server.
// Production relayOnlyNet continues to forbid all additional OS sockets.
type fixtureNet struct{ relayOnlyNet }

func (fixtureNet) ListenPacket(network, address string) (net.PacketConn, error) {
	host, _, e := net.SplitHostPort(address)
	if e != nil || host != "127.0.0.1" {
		return nil, net.InvalidAddrError("loopback fixture only")
	}
	return net.ListenPacket(network, address)
}

// Real framing layers, fake local TURN credentials, in-process echo VPS. No VK,
// external network destinations, OS tunnel interface or routing changes involved.
func TestLoopbackTURNDTLSKCPWire(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cert, e := selfsign.GenerateSelfSigned()
	if e != nil {
		t.Fatal(e)
	}
	log := logging.NewDefaultLoggerFactory()
	log.DefaultLogLevel = logging.LogLevelDisabled
	dtlsListener, e := dtls.ListenWithOptions("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)}, dtls.WithCertificates(cert), dtls.WithExtendedMasterSecret(dtls.RequireExtendedMasterSecret), dtls.WithCipherSuites(dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256), dtls.WithConnectionIDGenerator(dtls.RandomCIDGenerator(8)), dtls.WithLoggerFactory(log))
	if e != nil {
		t.Fatal(e)
	}
	defer dtlsListener.Close()
	stopListener := context.AfterFunc(ctx, func() { dtlsListener.Close() })
	defer stopListener()
	serverDone := make(chan error, 1)
	go func() {
		conn, e := dtlsListener.Accept()
		if e != nil {
			serverDone <- e
			return
		}
		defer conn.Close()
		stop := context.AfterFunc(ctx, func() { conn.Close() })
		defer stop()
		if e = conn.(*dtls.Conn).HandshakeContext(ctx); e != nil {
			serverDone <- e
			return
		}
		k, e := tcputil.NewKCPOverDTLS(conn, true)
		if e != nil {
			serverDone <- e
			return
		}
		defer k.Close()
		session, e := smux.Server(k, tcputil.DefaultSmuxConfig())
		if e != nil {
			serverDone <- e
			return
		}
		defer session.Close()
		stream, e := session.AcceptStream()
		if e != nil {
			serverDone <- e
			return
		}
		defer stream.Close()
		_, e = io.Copy(stream, stream)
		serverDone <- e
	}()
	turnListener, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer turnListener.Close()
	turnServer, e := turn.NewServer(turn.ServerConfig{
		Realm: "local-test", LoggerFactory: log,
		AuthHandler: func(*turn.RequestAttributes) (string, []byte, bool) {
			return "mock", turn.GenerateAuthKey("mock", "local-test", "mock"), true
		},
		ListenerConfigs: []turn.ListenerConfig{{Listener: turnListener, RelayAddressGenerator: &turn.RelayAddressGeneratorStatic{RelayAddress: net.IPv4(127, 0, 0, 1), Address: "127.0.0.1", Net: fixtureNet{}}}},
	})
	if e != nil {
		t.Fatal(e)
	}
	defer turnServer.Close()
	assigned := make(chan struct{})
	var c *Client
	cfg := testConfig()
	cfg.PeerPort = dtlsListener.Addr().(*net.UDPAddr).Port
	factory := func(ctx context.Context, peer *net.UDPAddr) (*smux.Session, func(), error) {
		select {
		case <-ctx.Done():
			return nil, nil, ctx.Err()
		case <-assigned:
		}
		return c.createSession(ctx, peer)
	}
	c, e = start(ctx, cfg, allow, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.username, c.password, c.turnAddress = "mock", "mock", turnListener.Addr().String()
	c.credsUntil = time.Now().Add(time.Hour)
	close(assigned)
	waitStatus(t, c, "ready")
	conn, e := net.DialTimeout("tcp", c.Addr(), time.Second)
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(3 * time.Second))
	payload := []byte("VLESS framing fixture: TURN TCP / DTLS / KCP / smux")
	if _, e = conn.Write(payload); e != nil {
		t.Fatal(e)
	}
	out := make([]byte, len(payload))
	if _, e = io.ReadFull(conn, out); e != nil {
		t.Fatal(e)
	}
	if string(out) != string(payload) {
		t.Fatal("wire payload mismatch")
	}
	conn.Close()
	c.Close()
	cancel()
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatal("server fixture did not stop")
	}
}
