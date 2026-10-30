// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"net"
	"strconv"

	"github.com/pion/transport/v4"
)

// relayOnlyNet forbids Pion from opening sockets or performing OS DNS/interface
// discovery. TURN uses only the protected connection supplied by createSession.
// Explicit failures also prevent a future upstream change silently bypassing
// socket protection. Only numeric UDP address parsing is needed by this mode.
type relayOnlyNet struct{}

var _ transport.Net = relayOnlyNet{}

func (relayOnlyNet) ListenPacket(string, string) (net.PacketConn, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) ListenUDP(string, *net.UDPAddr) (transport.UDPConn, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) ListenTCP(string, *net.TCPAddr) (transport.TCPListener, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) Dial(string, string) (net.Conn, error) { return nil, transport.ErrNotSupported }
func (relayOnlyNet) DialUDP(string, *net.UDPAddr, *net.UDPAddr) (transport.UDPConn, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) DialTCP(string, *net.TCPAddr, *net.TCPAddr) (transport.TCPConn, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) ResolveIPAddr(string, string) (*net.IPAddr, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) ResolveTCPAddr(string, string) (*net.TCPAddr, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) ResolveUDPAddr(network, address string) (*net.UDPAddr, error) {
	if network != "udp" && network != "udp4" && network != "udp6" {
		return nil, transport.ErrNotSupported
	}
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return nil, transport.ErrNotSupported
	}
	ip := net.ParseIP(host)
	p, err := strconv.Atoi(port)
	if ip == nil || err != nil || p < 1 || p > 65535 {
		return nil, transport.ErrNotSupported
	}
	return &net.UDPAddr{IP: ip, Port: p}, nil
}
func (relayOnlyNet) Interfaces() ([]*transport.Interface, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) InterfaceByIndex(int) (*transport.Interface, error) {
	return nil, transport.ErrNotSupported
}
func (relayOnlyNet) InterfaceByName(string) (*transport.Interface, error) {
	return nil, transport.ErrNotSupported
}
func (n relayOnlyNet) CreateDialer(*net.Dialer) transport.Dialer { return n }
func (relayOnlyNet) CreateListenConfig(*net.ListenConfig) transport.ListenConfig {
	return deniedListenConfig{}
}

type deniedListenConfig struct{}

func (deniedListenConfig) Listen(context.Context, string, string) (net.Listener, error) {
	return nil, transport.ErrNotSupported
}
func (deniedListenConfig) ListenPacket(context.Context, string, string) (net.PacketConn, error) {
	return nil, transport.ErrNotSupported
}
