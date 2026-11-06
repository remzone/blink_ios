// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"errors"
	"github.com/amnezia-vpn/amneziawg-go/v3/conn"
	"github.com/amnezia-vpn/amneziawg-go/v3/device"
	"github.com/amnezia-vpn/amneziawg-go/v3/tun"
	"io"
	"net"
	"net/netip"
	"os"
	"strconv"
	"sync"
	"syscall"
)

type wgPacketDevice struct {
	queue  chan []byte
	done   chan struct{}
	events chan tun.Event
	once   sync.Once
	sink   *packetAdapter
	mtu    int
}

func newWGPacketDevice(sink *packetAdapter, mtu int) *wgPacketDevice {
	p := &wgPacketDevice{queue: make(chan []byte, 256), done: make(chan struct{}), events: make(chan tun.Event, 1), sink: sink, mtu: mtu}
	p.events <- tun.EventUp
	return p
}
func (p *wgPacketDevice) File() *os.File           { return nil }
func (p *wgPacketDevice) Name() (string, error)    { return "Blink packet flow", nil }
func (p *wgPacketDevice) MTU() (int, error)        { return p.mtu, nil }
func (p *wgPacketDevice) BatchSize() int           { return 1 }
func (p *wgPacketDevice) Events() <-chan tun.Event { return p.events }
func (p *wgPacketDevice) Close() error {
	p.once.Do(func() { close(p.done); close(p.events) })
	return nil
}
func (p *wgPacketDevice) Read(bufs [][]byte, sizes []int, offset int) (int, error) {
	select {
	case <-p.done:
		return 0, os.ErrClosed
	case b := <-p.queue:
		if len(bufs) == 0 || len(sizes) == 0 || len(bufs[0])-offset < len(b) {
			return 0, io.ErrShortBuffer
		}
		sizes[0] = copy(bufs[0][offset:], b)
		return 1, nil
	}
}
func (p *wgPacketDevice) Write(bufs [][]byte, offset int) (int, error) {
	for i, b := range bufs {
		if offset < 0 || len(b) < offset {
			return i, io.ErrShortBuffer
		}
		if e := p.sink.WritePacket(nil, b[offset:]); e != nil {
			return i, e
		}
	}
	return len(bufs), nil
}
func (p *wgPacketDevice) Input(b []byte) {
	select {
	case <-p.done:
		return
	default:
	}
	packet := append([]byte(nil), b...)
	select {
	case p.queue <- packet:
	case <-p.done:
	default: /* bounded queue; packet protocols retransmit */
	}
}

type wgBackend struct {
	packets *wgPacketDevice
	device  *device.Device
}

func (w *wgBackend) Input(p []byte) { w.packets.Input(p) }
func (w *wgBackend) Close() error   { w.device.Close(); return nil }
func startWireGuard(p ImportedProfile, sink PacketWriter, protector Protector) (*Engine, error) {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if active != nil || sink == nil || protector == nil {
		return nil, errors.New("invalid or active VPN engine")
	}
	source, _, e := unwrapWG(p.Source)
	if e != nil {
		return nil, e
	}
	c, e := parseWG(source)
	if e != nil {
		return nil, e
	}
	uapi, e := c.uapi()
	if e != nil {
		return nil, e
	}
	adapter := &packetAdapter{sink: sink}
	packets := newWGPacketDevice(adapter, c.MTU)
	logger := &device.Logger{Verbosef: func(string, ...any) {}, Errorf: func(string, ...any) {}}
	d := device.NewDevice(packets, &protectedWGBind{protector: protector}, logger)
	if e = d.IpcSet(uapi); e != nil {
		d.Close()
		adapter.Close()
		return nil, errors.New("WireGuard/AmneziaWG settings rejected")
	}
	if e = d.Up(); e != nil {
		d.Close()
		adapter.Close()
		return nil, errors.New("protected WireGuard socket setup failed")
	}
	_, cancel := context.WithCancel(context.Background())
	engine := &Engine{stack: &wgBackend{packets: packets, device: d}, adapter: adapter, cancel: cancel}
	active = engine
	return engine, nil
}

type wgEndpoint struct{ address netip.AddrPort }

func (e *wgEndpoint) ClearSrc()           {}
func (e *wgEndpoint) SrcToString() string { return "" }
func (e *wgEndpoint) DstToString() string { return e.address.String() }
func (e *wgEndpoint) DstIP() netip.Addr   { return e.address.Addr() }
func (e *wgEndpoint) SrcIP() netip.Addr   { return netip.Addr{} }
func (e *wgEndpoint) DstToBytes() []byte  { b, _ := e.address.MarshalBinary(); return b }

type protectedWGBind struct {
	mu        sync.Mutex
	sockets   map[bool]*net.UDPConn
	protector Protector
}

var errWGProtection = errors.New("socket protection rejected")

func (b *protectedWGBind) BatchSize() int { return 1 }
func (b *protectedWGBind) SetMark(mark uint32) error {
	if mark != 0 {
		return errors.New("socket marks unsupported")
	}
	return nil
}
func (b *protectedWGBind) ParseEndpoint(s string) (conn.Endpoint, error) {
	a, e := netip.ParseAddrPort(s)
	if e != nil {
		return nil, e
	}
	return &wgEndpoint{address: a}, nil
}
func (b *protectedWGBind) Open(port uint16) ([]conn.ReceiveFunc, uint16, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.sockets) > 0 {
		return nil, 0, conn.ErrBindAlreadyOpen
	}
	b.sockets = map[bool]*net.UDPConn{}
	closeAll := func() {
		for _, c := range b.sockets {
			c.Close()
		}
		b.sockets = nil
	}
	var fns []conn.ReceiveFunc
	for _, v4 := range []bool{true, false} {
		network, host := "udp6", "::"
		if v4 {
			network, host = "udp4", "0.0.0.0"
		}
		lc := net.ListenConfig{Control: func(_, _ string, raw syscall.RawConn) error {
			ok := false
			if e := raw.Control(func(fd uintptr) { ok = b.protector.Protect(int64(fd)) }); e != nil {
				return e
			}
			if !ok {
				return errWGProtection
			}
			return nil
		}}
		pc, e := lc.ListenPacket(context.Background(), network, net.JoinHostPort(host, strconv.Itoa(int(port))))
		if e != nil {
			if errors.Is(e, errWGProtection) {
				closeAll()
				return nil, 0, e
			}
			continue
		}
		c := pc.(*net.UDPConn)
		if port == 0 {
			port = uint16(c.LocalAddr().(*net.UDPAddr).Port)
		}
		b.sockets[v4] = c
		fns = append(fns, func(bufs [][]byte, sizes []int, eps []conn.Endpoint) (int, error) {
			if len(bufs) == 0 || len(sizes) == 0 || len(eps) == 0 {
				return 0, io.ErrShortBuffer
			}
			n, a, e := c.ReadFromUDPAddrPort(bufs[0])
			if e != nil {
				return 0, e
			}
			sizes[0] = n
			eps[0] = &wgEndpoint{address: a}
			return 1, nil
		})
	}
	if len(fns) == 0 {
		closeAll()
		return nil, 0, errors.New("no protected UDP socket")
	}
	return fns, port, nil
}
func (b *protectedWGBind) Close() error {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, c := range b.sockets {
		c.Close()
	}
	b.sockets = nil
	return nil
}
func (b *protectedWGBind) Send(bufs [][]byte, ep conn.Endpoint) error {
	a, ok := ep.(*wgEndpoint)
	if !ok {
		return conn.ErrWrongEndpointType
	}
	b.mu.Lock()
	c := b.sockets[a.address.Addr().Is4()]
	b.mu.Unlock()
	if c == nil {
		return net.ErrClosed
	}
	for _, p := range bufs {
		if _, e := c.WriteToUDPAddrPort(p, a.address); e != nil {
			return e
		}
	}
	return nil
}
