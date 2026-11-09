// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"errors"
	"github.com/pion/dtls/v3"
	"github.com/remzone/blink_ios/native/vkturn/tcputil"
	"github.com/xtaci/smux"
	"net"
	"time"
)

// Explicit diagnostic mode. It never runs as an automatic fallback for VK mode.
func (c *Client) createDirectSession(ctx context.Context, peer *net.UDPAddr) (*smux.Session, func(), error) {
	conn, err := c.dialer.DialContext(ctx, "udp", peer.String())
	if err != nil {
		return nil, nil, errors.New("UDP connection failed")
	}
	cancelSocket := context.AfterFunc(ctx, func() { _ = conn.Close() })
	cleanupSocket := func() { cancelSocket(); _ = conn.Close() }
	dc, err := dtls.ClientWithOptions(&connectedPacketConn{Conn: conn, peer: peer}, peer,
		dtls.WithInsecureSkipVerify(true),
		dtls.WithExtendedMasterSecret(dtls.RequireExtendedMasterSecret),
		dtls.WithCipherSuites(dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256),
		dtls.WithConnectionIDGenerator(dtls.OnlySendCIDGenerator()))
	if err != nil {
		cleanupSocket()
		return nil, nil, errors.New("DTLS initialization failed")
	}
	handshake, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	if err = dc.HandshakeContext(handshake); err != nil {
		_ = dc.Close()
		cleanupSocket()
		return nil, nil, errors.New("DTLS handshake failed")
	}
	kcp, err := tcputil.NewKCPOverDTLS(dc, false)
	if err != nil {
		_ = dc.Close()
		cleanupSocket()
		return nil, nil, errors.New("KCP initialization failed")
	}
	session, err := smux.Client(kcp, tcputil.DefaultSmuxConfig())
	if err != nil {
		_ = kcp.Close()
		_ = dc.Close()
		cleanupSocket()
		return nil, nil, errors.New("multiplexer initialization failed")
	}
	stopMetrics := startTransportMetrics(ctx, kcp, 3)
	return session, func() { stopMetrics(); _ = session.Close(); _ = kcp.Close(); _ = dc.Close(); cleanupSocket() }, nil
}

type connectedPacketConn struct {
	net.Conn
	peer net.Addr
}

func (c *connectedPacketConn) ReadFrom(b []byte) (int, net.Addr, error) {
	n, e := c.Read(b)
	return n, c.peer, e
}
func (c *connectedPacketConn) WriteTo(b []byte, _ net.Addr) (int, error) { return c.Write(b) }
