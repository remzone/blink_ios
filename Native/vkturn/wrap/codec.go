// SPDX-License-Identifier: GPL-3.0-only
package wrap

import "net"

// PacketConn applies the upstream rtpopus codec to every DTLS datagram.
func PacketConn(pc net.PacketConn, key []byte, server bool) (net.PacketConn, error) {
	c, e := newWrapConn(key, server)
	if e != nil {
		return nil, e
	}
	return &packetConn{PacketConn: pc, codec: c}, nil
}

type packetConn struct {
	net.PacketConn
	codec   *wrapConn
	readBuf [2048]byte
}

func (c *packetConn) WriteTo(b []byte, a net.Addr) (int, error) {
	p := make([]byte, len(b)+wrapOverhead)
	n, e := c.codec.wrapInto(p, b)
	if e != nil {
		return 0, e
	}
	_, e = c.PacketConn.WriteTo(p[:n], a)
	if e != nil {
		return 0, e
	}
	return len(b), nil
}
func (c *packetConn) ReadFrom(b []byte) (int, net.Addr, error) {
	p := c.readBuf[:]
	for {
		n, a, e := c.PacketConn.ReadFrom(p)
		if e != nil {
			return 0, a, e
		}
		n, e = c.codec.unwrapPacket(p[:n], b)
		if e == nil {
			return n, a, nil
		}
	}
}
