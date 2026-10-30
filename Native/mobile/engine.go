// SPDX-License-Identifier: GPL-3.0-only
// Package mobile binds one Go runtime for Xray and packet-oriented iOS I/O.
// It does not access utun file descriptors or any private Apple API.
package mobile

import (
	"context"
	"errors"
	"github.com/remzone/blink_ios/native/vkturn"
	"io"
	"net"
	"strings"
	"sync"
	"syscall"
	"time"

	_ "github.com/xtls/xray-core/app/dispatcher"
	_ "github.com/xtls/xray-core/app/log"
	_ "github.com/xtls/xray-core/app/policy"
	_ "github.com/xtls/xray-core/app/proxyman/inbound"
	_ "github.com/xtls/xray-core/app/proxyman/outbound"
	"github.com/xtls/xray-core/core"
	"github.com/xtls/xray-core/infra/conf/serial"
	"github.com/xtls/xray-core/proxy/tun"
	_ "github.com/xtls/xray-core/proxy/vless/outbound"
	"github.com/xtls/xray-core/transport/internet"
	_ "github.com/xtls/xray-core/transport/internet/reality"
	_ "github.com/xtls/xray-core/transport/internet/splithttp"
	_ "github.com/xtls/xray-core/transport/internet/tcp"
	_ "github.com/xtls/xray-core/transport/internet/tls"
)

type PacketWriter interface{ WritePacket(packet []byte) bool }
type Protector interface{ Protect(fd int64) bool }

var lifecycle sync.Mutex
var active *Engine
var controllerOnce sync.Once
var controllerError error
var protection struct {
	sync.RWMutex
	protector Protector
}

// Engine must live only in the dedicated BlinkXrayTunnel extension, never the
// legacy WireGuardKit+Mobile process. Its input must be fed in packet order.
type Engine struct {
	vkTransport *vkturn.Client
	expiry      *time.Timer
	mu          sync.Mutex
	stack       tun.Stack
	adapter     *packetAdapter
	instance    *core.Instance
	cancel      context.CancelFunc
}

type packetAdapter struct {
	mu     sync.RWMutex
	sink   PacketWriter
	closed bool
}

func (p *packetAdapter) Start() error          { return nil }
func (p *packetAdapter) Name() (string, error) { return "packetFlow", nil }
func (p *packetAdapter) Index() (int, error) {
	return 0, errors.New("packetFlow has no public interface index")
}
func (p *packetAdapter) ReadPacket([]byte) ([]byte, error) { return nil, io.EOF }
func (p *packetAdapter) Close() error {
	p.mu.Lock()
	p.closed = true
	p.sink = nil
	p.mu.Unlock()
	return nil
}
func (p *packetAdapter) WritePacket(header, payload []byte) error {
	p.mu.RLock()
	defer p.mu.RUnlock()
	if p.closed {
		return io.ErrClosedPipe
	}
	packet := make([]byte, 0, len(header)+len(payload))
	packet = append(packet, header...)
	packet = append(packet, payload...)
	if p.sink == nil || !p.sink.WritePacket(packet) {
		return io.ErrClosedPipe
	}
	return nil
}

func registerController() error {
	controllerOnce.Do(func() {
		controllerError = internet.RegisterDialerController(func(network, address string, c syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return errors.New("invalid dial destination")
			}
			if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
				return nil
			}
			protection.RLock()
			p := protection.protector
			protection.RUnlock()
			if p == nil {
				return errors.New("socket protector unavailable")
			}
			var ok bool
			if err := c.Control(func(fd uintptr) { ok = p.Protect(int64(fd)) }); err != nil {
				return err
			}
			if !ok {
				return errors.New("socket protection failed")
			}
			return nil
		})
	})
	return controllerError
}

func Start(profileJSON string, sink PacketWriter, protector Protector) (*Engine, error) {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	if active != nil {
		return nil, errors.New("engine already running")
	}
	if sink == nil || protector == nil {
		return nil, errors.New("packet writer and protector required")
	}
	raw, err := buildConfig(profileJSON)
	if err != nil {
		return nil, err
	}
	config, err := serial.LoadJSONConfig(strings.NewReader(string(raw)))
	if err != nil {
		return nil, errors.New("Xray profile rejected")
	}
	if err := registerController(); err != nil {
		return nil, errors.New("socket protection registration failed")
	}
	protection.Lock()
	protection.protector = protector
	protection.Unlock()
	success := false
	defer func() {
		if !success {
			protection.Lock()
			protection.protector = nil
			protection.Unlock()
		}
	}()
	ctx, cancel := context.WithCancel(context.Background())
	instance, err := core.NewWithContext(ctx, config)
	if err != nil {
		cancel()
		return nil, errors.New("Xray initialization failed")
	}
	fail := func() { cancel(); _ = instance.Close() }
	// Construct the supported registered handler without calling Handler.Start,
	// which would create an OS TUN. We own the public packet-oriented stack.
	handler, err := core.CreateObject(instance, &tun.Config{MTU: 1280})
	if err != nil {
		fail()
		return nil, errors.New("packet handler initialization failed")
	}
	connectionHandler, ok := handler.(tun.ConnectionHandler)
	if !ok {
		fail()
		return nil, errors.New("unsupported Xray handler API")
	}
	adapter := &packetAdapter{sink: sink}
	stack, err := tun.NewStack(ctx, tun.StackOptions{Tun: adapter, MTU: 1280}, connectionHandler)
	if err != nil {
		fail()
		return nil, errors.New("packet stack initialization failed")
	}
	if err = instance.Start(); err != nil {
		_ = stack.Close()
		_ = adapter.Close()
		fail()
		return nil, errors.New("Xray start failed")
	}
	// Do not call stack.Start(): Input receives public NEPacketTunnelFlow packets.
	e := &Engine{stack: stack, adapter: adapter, instance: instance, cancel: cancel}
	active = e
	success = true
	return e, nil
}

func (e *Engine) Input(packet []byte) error {
	if len(packet) < 20 || len(packet) > 65535 {
		return errors.New("invalid packet size")
	}
	version := packet[0] >> 4
	if version != 4 && version != 6 || version == 6 && len(packet) < 40 {
		return errors.New("invalid IP packet")
	}
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stack == nil {
		return io.ErrClosedPipe
	}
	// Stack.Input may modify bytes; gomobile caller memory must not be retained.
	e.stack.Input(append([]byte(nil), packet...))
	return nil
}
func (e *Engine) Stop() {
	lifecycle.Lock()
	defer lifecycle.Unlock()
	e.mu.Lock()
	stack := e.stack
	e.stack = nil
	transport := e.vkTransport
	e.vkTransport = nil
	if e.expiry != nil {
		e.expiry.Stop()
		e.expiry = nil
	}
	e.mu.Unlock()
	if stack == nil {
		return
	}
	e.cancel()
	_ = stack.Close()
	_ = e.adapter.Close()
	_ = e.instance.Close()
	if transport != nil {
		_ = transport.Close()
	}
	if active == e {
		active = nil
		protection.Lock()
		protection.protector = nil
		protection.Unlock()
	}
}
