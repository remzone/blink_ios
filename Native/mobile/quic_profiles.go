// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"

	hy "github.com/sagernet/sing-quic/hysteria"
	"github.com/sagernet/sing-quic/tuic"
	"github.com/sagernet/sing/common/logger"
	M "github.com/sagernet/sing/common/metadata"
	aTLS "github.com/sagernet/sing/common/tls"
	xnet "github.com/xtls/xray-core/common/net"
	"github.com/xtls/xray-core/proxy/tun"
)

type quicProfile struct {
	Host, Port, Password, SNI, CC, Relay string
	UUID                                 [16]byte
	ALPN                                 []string
	Up, Down                             uint64
	Ports                                []string
	Obfs                                 string
}

func parseQUIC(source string) (quicProfile, error) {
	p := quicProfile{}
	u, e := url.Parse(source)
	if e != nil || u.User == nil || u.Hostname() == "" || u.Path != "" && u.Path != "/" {
		return p, errors.New("invalid QUIC URI")
	}
	if u.Scheme != "tuic" && u.Scheme != "hysteria" {
		return p, errors.New("unsupported QUIC protocol")
	}
	p.Host = u.Hostname()
	p.Port = u.Port()
	if p.Port == "" {
		p.Port = "443"
	}
	n, e := strconv.Atoi(p.Port)
	if e != nil || n < 1 || n > 65535 {
		return p, errors.New("invalid QUIC port")
	}
	q, e := url.ParseQuery(u.RawQuery)
	if e != nil {
		return p, errors.New("invalid QUIC options")
	}
	allowed := map[string]bool{}
	keys := "sni peer alpn allow_insecure insecure security"
	if u.Scheme == "tuic" {
		keys += " congestion_control udp_relay_mode"
	} else {
		keys += " auth auth_str upmbps downmbps up down obfs obfsParam mport hop_interval"
	}
	for _, k := range strings.Fields(keys) {
		allowed[k] = true
	}
	if q.Get("sni") != "" && q.Get("peer") != "" && q.Get("sni") != q.Get("peer") {
		return p, errors.New("conflicting TLS names")
	}

	for k, v := range q {
		if !allowed[k] || len(v) != 1 {
			return p, errors.New("unsupported QUIC option")
		}
	}
	for _, k := range []string{"allow_insecure", "insecure"} {
		if v := q.Get(k); v != "" && v != "0" && v != "false" {
			return p, errors.New("TLS verification required")
		}
	}
	if q.Get("security") != "" && q.Get("security") != "tls" {
		return p, errors.New("QUIC requires TLS")
	}
	p.SNI = q.Get("sni")
	if p.SNI == "" {
		p.SNI = q.Get("peer")
	}
	if p.SNI == "" {
		p.SNI = p.Host
	}
	if s := q.Get("alpn"); s != "" {
		p.ALPN = strings.Split(s, ",")
	}
	if u.Scheme == "tuic" {
		b, e := hex.DecodeString(strings.ReplaceAll(u.User.Username(), "-", ""))
		if e != nil || len(b) != 16 {
			return p, errors.New("invalid TUIC UUID")
		}
		copy(p.UUID[:], b)
		p.Password, _ = u.User.Password()
		if p.Password == "" {
			return p, errors.New("TUIC password required")
		}
		p.CC = q.Get("congestion_control")
		if p.CC == "" {
			p.CC = "bbr"
		}
		if p.CC != "bbr" && p.CC != "cubic" && p.CC != "new_reno" {
			return p, errors.New("unknown congestion control")
		}
		p.Relay = q.Get("udp_relay_mode")
		if p.Relay != "" && p.Relay != "native" && p.Relay != "quic" {
			return p, errors.New("unknown UDP relay mode")
		}
		if len(p.ALPN) == 0 {
			p.ALPN = []string{"h3"}
		}
	} else {
		p.Password = u.User.Username()
		if v := q.Get("auth"); v != "" {
			p.Password = v
		}
		if v := q.Get("auth_str"); v != "" {
			p.Password = v
		}
		p.Up = 10 * 125000
		p.Down = 50 * 125000
		for _, pair := range [][2]string{{"upmbps", "up"}, {"downmbps", "down"}} {
			v := q.Get(pair[0])
			if v == "" {
				v = q.Get(pair[1])
			}
			if v != "" {
				n, e := strconv.ParseUint(v, 10, 32)
				if e != nil || n < 1 || n > 10000 {
					return p, errors.New("invalid Hysteria bandwidth")
				}
				if pair[1] == "up" {
					p.Up = n * 125000
				} else {
					p.Down = n * 125000
				}
			}
		}
		if v := q.Get("mport"); v != "" {
			p.Ports = strings.Split(strings.ReplaceAll(v, "-", ":"), ",")
		}
		p.Obfs = q.Get("obfsParam")
		if q.Get("obfs") != "" && q.Get("obfs") != "xplus" {
			return p, errors.New("Hysteria v1 obfs must be xplus")
		}
		if q.Has("hop_interval") {
			return p, errors.New("custom Hysteria hop interval not supported")
		}
	}
	return p, nil
}

type physicalDialer struct{ protector Protector }

func (d physicalDialer) control(network, address string, c syscall.RawConn) error {
	var ok bool
	if e := c.Control(func(fd uintptr) { ok = d.protector.Protect(int64(fd)) }); e != nil {
		return e
	}
	if !ok {
		return errors.New("unprotected QUIC socket")
	}
	return nil
}
func (d physicalDialer) DialContext(ctx context.Context, network string, dest M.Socksaddr) (net.Conn, error) {
	dial := net.Dialer{Control: d.control, Timeout: 10 * time.Second}
	return dial.DialContext(ctx, network, dest.String())
}
func (d physicalDialer) ListenPacket(ctx context.Context, dest M.Socksaddr) (net.PacketConn, error) {
	lc := net.ListenConfig{Control: d.control}
	network := "udp4"
	address := "0.0.0.0:0"
	if dest.IsIPv6() {
		network = "udp6"
		address = "[::]:0"
	}
	return lc.ListenPacket(ctx, network, address)
}

type standardTLS struct {
	config  *tls.Config
	timeout time.Duration
}

func (s *standardTLS) ServerName() string                   { return s.config.ServerName }
func (s *standardTLS) SetServerName(v string)               { s.config.ServerName = v }
func (s *standardTLS) NextProtos() []string                 { return s.config.NextProtos }
func (s *standardTLS) SetNextProtos(v []string)             { s.config.NextProtos = v }
func (s *standardTLS) HandshakeTimeout() time.Duration      { return s.timeout }
func (s *standardTLS) SetHandshakeTimeout(v time.Duration)  { s.timeout = v }
func (s *standardTLS) STDConfig() (*tls.Config, error)      { return s.config, nil }
func (s *standardTLS) Client(c net.Conn) (aTLS.Conn, error) { return tls.Client(c, s.config), nil }
func (s *standardTLS) Clone() aTLS.Config                   { return &standardTLS{s.config.Clone(), s.timeout} }

type quicClient interface {
	DialConn(context.Context, M.Socksaddr) (net.Conn, error)
	CloseWithError(error) error
}
type quicPackets interface {
	ListenPacket(context.Context) (net.PacketConn, error)
}
type hyPackets interface {
	ListenPacket(context.Context, M.Socksaddr) (net.PacketConn, error)
}
type quicHandler struct {
	ctx    context.Context
	client quicClient
}

func (h *quicHandler) HandleConnection(local net.Conn, dest xnet.Destination) {
	defer local.Close()
	target := M.ParseSocksaddrHostPort(dest.Address.String(), uint16(dest.Port))
	ctx, cancel := context.WithCancel(h.ctx)
	defer cancel()
	if dest.Network == xnet.Network_TCP {
		remote, e := h.client.DialConn(ctx, target)
		if e != nil {
			return
		}
		defer remote.Close()
		stop := context.AfterFunc(ctx, func() { local.Close(); remote.Close() })
		defer stop()
		done := make(chan struct{})
		go func() { io.Copy(remote, local); remote.Close(); close(done) }()
		io.Copy(local, remote)
		local.Close()
		remote.Close()
		<-done
		return
	}
	var remote net.PacketConn
	var e error
	if c, ok := h.client.(quicPackets); ok {
		remote, e = c.ListenPacket(ctx)
	} else {
		remote, e = h.client.(hyPackets).ListenPacket(ctx, target)
	}
	if e != nil {
		return
	}
	defer remote.Close()
	stop := context.AfterFunc(ctx, func() { local.Close(); remote.Close() })
	defer stop()
	done := make(chan struct{})
	go func() {
		defer close(done)
		buf := make([]byte, 65535)
		for {
			local.SetReadDeadline(time.Now().Add(90 * time.Second))
			n, e := local.Read(buf)
			if e != nil {
				remote.Close()
				return
			}
			remote.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if _, e = remote.WriteTo(buf[:n], target); e != nil {
				local.Close()
				return
			}
		}
	}()
	buf := make([]byte, 65535)
	for {
		remote.SetReadDeadline(time.Now().Add(90 * time.Second))
		n, _, e := remote.ReadFrom(buf)
		if e != nil {
			break
		}
		if _, e = local.Write(buf[:n]); e != nil {
			break
		}
	}
	local.Close()
	remote.Close()
	<-done
}

type quicBackend struct {
	stack  tun.Stack
	client quicClient
	cancel context.CancelFunc
}

func (b *quicBackend) Input(p []byte) { b.stack.Input(p) }
func (b *quicBackend) Close() error {
	b.cancel()
	b.client.CloseWithError(io.EOF)
	return b.stack.Close()
}
func startQUIC(p ImportedProfile, sink PacketWriter, protector Protector) (*Engine, error) {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if active != nil || sink == nil || protector == nil {
		return nil, errors.New("invalid or active engine")
	}
	q, e := parseQUIC(p.Source)
	if e != nil {
		return nil, e
	}
	ip, e := resolveEndpoint(q.Host)
	if e != nil {
		return nil, e
	}
	ctx, cancel := context.WithCancel(context.Background())
	cfg := &standardTLS{&tls.Config{ServerName: q.SNI, NextProtos: q.ALPN, MinVersion: tls.VersionTLS13}, 10 * time.Second}
	dial := physicalDialer{protector}
	address := M.ParseSocksaddr(net.JoinHostPort(ip, q.Port))
	var client quicClient
	if p.Kind == "tuic" {
		client, e = tuic.NewClient(tuic.ClientOptions{Context: ctx, Dialer: dial, ServerAddress: address, TLSConfig: cfg, UUID: q.UUID, Password: q.Password, CongestionControl: q.CC, UDPStream: q.Relay == "quic"})
	} else {
		client, e = hy.NewClient(hy.ClientOptions{Context: ctx, Dialer: dial, Logger: logger.NOP(), ServerAddress: address, ServerPorts: q.Ports, SendBPS: q.Up, ReceiveBPS: q.Down, Password: q.Password, XPlusPassword: q.Obfs, TLSConfig: cfg})
	}
	if e != nil {
		cancel()
		return nil, errors.New("QUIC settings rejected")
	}
	adapter := &packetAdapter{sink: sink}
	stack, e := tun.NewStack(ctx, tun.StackOptions{Tun: adapter, MTU: 1280}, &quicHandler{ctx, client})
	if e != nil {
		client.CloseWithError(e)
		cancel()
		return nil, errors.New("QUIC packet stack failed")
	}
	engine := &Engine{stack: &quicBackend{stack, client, cancel}, adapter: adapter, cancel: cancel}
	active = engine
	return engine, nil
}
