// SPDX-FileCopyrightText: 2023 The Pion community <https://pion.ly>
// SPDX-License-Identifier: MIT
// Adapted from cacggghp/vk-turn-proxy e8a96967dc66f3dbd631596ea6a8b9fe03f9be69.
// Repository distribution includes GPL-3.0; see LICENSE and UPSTREAM.md.
package vkturn

import (
	"context"
	"errors"
	"io"
	"net"
	"time"

	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/pion/logging"
	"github.com/pion/turn/v5"
	"github.com/remzone/blink_ios/native/vkturn/tcputil"
	"github.com/xtaci/smux"
)

// createSession preserves upstream default VLESS wire framing:
// TURN over TCP, DTLS datagrams, KCP, then smux multiplexed TCP streams.
// DTLS deliberately has upstream's unauthenticated peer certificate mode. This
// is NOT authenticated TLS to the VPS; don't advertise certificate verification.
func (c *Client) createSession(ctx context.Context, peer *net.UDPAddr) (*smux.Session, func(), error) {
	user, pass, raw, err := c.credentials(ctx)
	if err != nil {
		return nil, nil, err
	}
	address, err := c.resolveTURN(ctx, raw)
	if err != nil {
		return nil, nil, err
	}
	dialCtx, dialCancel := context.WithTimeout(ctx, 5*time.Second)
	defer dialCancel()
	conn, err := c.dialer.DialContext(dialCtx, "tcp", address)
	if err != nil {
		return nil, nil, errors.New("TURN connection failed")
	}
	// Allocate has no context parameter. Closing its underlying TCP connection
	// interrupts pending transactions and all DTLS reads on cancellation.
	stopClose := context.AfterFunc(ctx, func() { _ = conn.Close() })
	closers := []func(){func() { stopClose(); _ = conn.Close() }}
	cleanup := func() {
		for i := len(closers) - 1; i >= 0; i-- {
			closers[i]()
		}
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
	client, err := turn.NewClient(&turn.ClientConfig{
		STUNServerAddr: address, TURNServerAddr: address, Conn: turn.NewSTUNConn(conn),
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
	closers = append(closers, func() { _ = relay.Close() })
	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		return nil, nil, errors.New("DTLS certificate generation failed")
	}
	dtlsConn, err := dtls.ClientWithOptions(&relayPacketConn{relay: relay, peer: peer}, peer,
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
	handshakeCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	if err = dtlsConn.HandshakeContext(handshakeCtx); err != nil {
		return nil, nil, errors.New("DTLS handshake failed")
	}
	kcp, err := tcputil.NewKCPOverDTLS(dtlsConn, false)
	if err != nil {
		return nil, nil, errors.New("KCP creation failed")
	}
	closers = append(closers, func() { _ = kcp.Close() })
	session, err := smux.Client(kcp, tcputil.DefaultSmuxConfig())
	if err != nil {
		return nil, nil, errors.New("smux creation failed")
	}
	closers = append(closers, func() { _ = session.Close() })
	success = true
	return session, cleanup, nil
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
