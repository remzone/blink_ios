// SPDX-FileCopyrightText: 2023 The Pion community <https://pion.ly>
// SPDX-License-Identifier: MIT
// Adapted from cacggghp/vk-turn-proxy e8a96967dc66f3dbd631596ea6a8b9fe03f9be69.
// Repository distribution includes GPL-3.0; see LICENSE and UPSTREAM.md.
package vkturn

import (
	"context"
	"encoding/hex"
	"errors"
	"github.com/remzone/blink_ios/native/vkturn/srtpwrap"
	"github.com/remzone/blink_ios/native/vkturn/wrap"
	"io"
	"net"
	"sync"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"github.com/remzone/blink_ios/native/vkturn/tcputil"
	"github.com/xtaci/smux"
)

// createSession preserves upstream default VLESS wire framing:
// TURN over the explicitly selected TCP or UDP socket, then unchanged DTLS/KCP/smux.
// DTLS deliberately has upstream's unauthenticated peer certificate mode. This
// is NOT authenticated TLS to the VPS; don't advertise certificate verification.
func (c *Client) createSession(ctx context.Context, peer *net.UDPAddr) (*smux.Session, func(), error) {
	user, pass, raw, err := c.credentials(ctx)
	if err != nil {
		return nil, nil, err
	}
	return c.createSessionWithCredentials(ctx, peer, user, pass, raw)
}

// Isolated from VK authentication so both TURN transports can be wire-tested locally.
func (c *Client) createSessionWithCredentials(ctx context.Context, peer *net.UDPAddr, user, pass, raw string) (*smux.Session, func(), error) {
	if c.config.TURNTransport == "auto" || c.config.TURNTransport == "" {
		started := time.Now()
		session, cleanup, network, err := raceTURNTransport(ctx, func(child context.Context, network string) (*smux.Session, func(), error) {
			return c.createTURNTransportSession(child, peer, user, pass, raw, network)
		})
		if err == nil {
			mode := int64(1)
			if network == "tcp" {
				mode = 2
			}
			RecordDiagnostic("native.vk.smux_ready", map[string]int64{"stage": 6, "mode": mode, "elapsedMs": time.Since(started).Milliseconds()})
		}
		return session, cleanup, err
	}
	return c.createTURNTransportSession(ctx, peer, user, pass, raw, c.config.TURNTransport)
}

func (c *Client) createTURNTransportSession(ctx context.Context, peer *net.UDPAddr, user, pass, raw, network string) (*smux.Session, func(), error) {

	media, release, err := c.createTURNPacketSession(ctx, peer, user, pass, raw, network)
	if err != nil {
		return nil, nil, err
	}
	closers := []func(){release}
	var once sync.Once
	cleanup := func() {
		once.Do(func() {
			for i := len(closers) - 1; i >= 0; i-- {
				closers[i]()
			}
		})
	}
	success := false
	defer func() {
		if !success {
			cleanup()
		}
	}()
	kcp, err := tcputil.NewKCPOverDTLS(media, false)
	if err != nil {
		return nil, nil, errors.New("KCP creation failed")
	}
	closers = append(closers, func() { _ = kcp.Close() })
	c.config.Tuning.apply(kcp)
	session, err := smux.Client(kcp, tcputil.DefaultSmuxConfig())
	if err != nil {
		return nil, nil, errors.New("smux creation failed")
	}
	closers = append(closers, func() { _ = session.Close() })
	mode := int64(1)
	if network == "tcp" {
		mode = 2
	}
	closers = append(closers, startTransportMetrics(ctx, kcp, mode))
	diagnosticStage("native.vk.smux_ready", 6)
	success = true
	return session, cleanup, nil
}

func (c *Client) createTURNPacketSession(ctx context.Context, peer *net.UDPAddr, user, pass, raw, network string) (net.Conn, func(), error) {
	diagnosticStage("native.vk.turn_resolve", 1)
	address, err := c.resolveTURN(ctx, raw)
	if err != nil {
		return nil, nil, err
	}
	dialCtx, dialCancel := context.WithTimeout(ctx, 5*time.Second)
	defer dialCancel()
	conn, err := c.dialer.DialContext(dialCtx, network, address)
	if err != nil {
		return nil, nil, errors.New("TURN connection failed")
	}
	diagnosticStage("native.vk.turn_connected", 2)
	// Allocate has no context parameter. Closing its underlying TCP connection
	// interrupts pending transactions and all DTLS reads on cancellation.
	stopClose := context.AfterFunc(ctx, func() { _ = conn.Close() })
	closers := []func(){func() { stopClose(); _ = conn.Close() }}
	var cleanOnce sync.Once
	cleanup := func() {
		cleanOnce.Do(func() {
			_ = conn.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
			for i := len(closers) - 1; i >= 0; i-- {
				closers[i]()
			}
		})
	}
	success := false
	defer func() {
		if !success {
			cleanup()
		}
	}()
	family := turn.RequestedAddressFamilyIPv6
	if peer.IP.To4() != nil {
		family = turn.RequestedAddressFamilyIPv4
	}
	logger := &logging.DefaultLoggerFactory{Writer: io.Discard, DefaultLogLevel: logging.LogLevelDisabled, ScopeLevels: map[string]logging.LogLevel{}}
	var controlConn net.PacketConn
	if network == "udp" {
		controlConn = &connectedPacketConn{Conn: conn, peer: conn.RemoteAddr()}
	} else {
		controlConn = turn.NewSTUNConn(conn)
	}
	client, err := turn.NewClient(&turn.ClientConfig{
		STUNServerAddr: address, TURNServerAddr: address, Conn: controlConn,
		Net: relayOnlyNet{}, Username: user, Password: pass, RequestedAddressFamily: family, LoggerFactory: logger,
	})
	if err != nil {
		return nil, nil, errors.New("TURN client creation failed")
	}
	// Closing only the TCP reader does not wake Pion's transaction waiter.
	// Explicitly cancel its transaction map as well, before waiting for setup.
	stopTURN := context.AfterFunc(ctx, client.Close)
	closers = append(closers, func() { stopTURN(); client.Close() })
	if err = client.Listen(); err != nil {
		return nil, nil, errors.New("TURN listener failed")
	}
	relay, err := client.Allocate()
	if err != nil {
		return nil, nil, errors.New("TURN allocation failed")
	}
	diagnosticStage("native.vk.turn_allocated", 3)
	closers = append(closers, func() { _ = relay.Close() })
	if c.config.Protocol == "srtp" {
		hs, cancel := context.WithTimeout(ctx, 8*time.Second)
		defer cancel()
		media, e := srtpwrap.Client(hs, &relayPacketConn{relay: relay, peer: peer}, peer, nil)
		if e != nil {
			return nil, nil, errors.New("SRTP handshake failed")
		}
		closers = append(closers, func() { _ = media.Close() })
		success = true
		return c.config.Tuning.paced(ctx, &boundedMediaConn{Conn: media, physical: conn}), cleanup, nil
	}
	var packets net.PacketConn = &relayPacketConn{relay: relay, peer: peer}
	if c.config.Protocol == "wrap" {
		key, _ := hex.DecodeString(c.config.WrapKey)
		packets, err = wrap.PacketConn(packets, key, false)
		if err != nil {
			return nil, nil, errors.New("invalid wrap key")
		}
	}
	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		return nil, nil, errors.New("DTLS certificate generation failed")
	}
	dtlsConn, err := dtls.ClientWithOptions(packets, peer,
		dtls.WithCertificates(cert), dtls.WithInsecureSkipVerify(true),
		dtls.WithExtendedMasterSecret(dtls.RequireExtendedMasterSecret),
		dtls.WithCipherSuites(dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256),
		dtls.WithConnectionIDGenerator(dtls.OnlySendCIDGenerator()),
		dtls.WithLoggerFactory(logger),
	)
	if err != nil {
		return nil, nil, errors.New("DTLS client creation failed")
	}
	closers = append(closers, func() { _ = dtlsConn.Close() })
	timeout := 30 * time.Second
	if c.config.TURNTransport == "auto" || c.config.TURNTransport == "" {
		timeout = 8 * time.Second
	}
	handshakeCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	diagnosticStage("native.vk.dtls_begin", 4)
	if err = dtlsConn.HandshakeContext(handshakeCtx); err != nil {
		if ctx.Err() == nil {
			diagnosticStage("native.vk.dtls_failed", 4)
		}
		return nil, nil, errors.New("DTLS handshake failed")
	}
	diagnosticStage("native.vk.dtls_ready", 5)

	success = true
	return c.config.Tuning.paced(ctx, &boundedMediaConn{Conn: dtlsConn, physical: conn}), cleanup, nil

}

type relayPacketConn struct {
	relay net.PacketConn
	peer  net.Addr
}

func (r *relayPacketConn) ReadFrom(b []byte) (int, net.Addr, error) { return r.relay.ReadFrom(b) }
func (r *relayPacketConn) WriteTo(b []byte, _ net.Addr) (int, error) {
	return r.relay.WriteTo(b, r.peer)
}
func (r *relayPacketConn) Close() error                       { return r.relay.Close() }
func (r *relayPacketConn) LocalAddr() net.Addr                { return r.relay.LocalAddr() }
func (r *relayPacketConn) SetDeadline(t time.Time) error      { return r.relay.SetDeadline(t) }
func (r *relayPacketConn) SetReadDeadline(t time.Time) error  { return r.relay.SetReadDeadline(t) }
func (r *relayPacketConn) SetWriteDeadline(t time.Time) error { return r.relay.SetWriteDeadline(t) }

type boundedMediaConn struct {
	net.Conn
	physical net.Conn
}

func (c *boundedMediaConn) Close() error {
	_ = c.physical.SetWriteDeadline(time.Now().Add(500 * time.Millisecond))
	return c.Conn.Close()
}
