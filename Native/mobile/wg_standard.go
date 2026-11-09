// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	ac "github.com/amnezia-vpn/amneziawg-go/v3/conn"
	wc "golang.zx2c4.com/wireguard/conn"
	wd "golang.zx2c4.com/wireguard/device"
	wt "golang.zx2c4.com/wireguard/tun"
	"sync"
)

// Ordinary WG uses the official WireGuard implementation. The Amnezia fork is
// reserved for configurations that actually use its extensions.
type wgDevice interface {
	IpcSet(string) error
	Up() error
	Close()
}
type wgStandardPacketDevice struct {
	*wgPacketDevice
	standardEvents chan wt.Event
	closeOnce      sync.Once
}

func (d *wgStandardPacketDevice) Events() <-chan wt.Event { return d.standardEvents }
func (d *wgStandardPacketDevice) Close() error {
	d.closeOnce.Do(func() { close(d.standardEvents) })
	return d.wgPacketDevice.Close()
}
func newStandardWGDevice(p *wgPacketDevice, protector Protector) *wd.Device {
	events := make(chan wt.Event, 1)
	events <- wt.EventUp
	return wd.NewDevice(&wgStandardPacketDevice{wgPacketDevice: p, standardEvents: events}, &protectedStandardBind{base: &protectedWGBind{protector: protector}}, &wd.Logger{Verbosef: func(string, ...any) {}, Errorf: func(string, ...any) { recordWGDiagnosticError() }})
}

type protectedStandardBind struct{ base *protectedWGBind }

func (b *protectedStandardBind) BatchSize() int         { return b.base.BatchSize() }
func (b *protectedStandardBind) Close() error           { return b.base.Close() }
func (b *protectedStandardBind) SetMark(n uint32) error { return b.base.SetMark(n) }
func (b *protectedStandardBind) ParseEndpoint(s string) (wc.Endpoint, error) {
	return b.base.ParseEndpoint(s)
}
func (b *protectedStandardBind) Send(bufs [][]byte, ep wc.Endpoint) error {
	return b.base.Send(bufs, ep)
}
func (b *protectedStandardBind) Open(port uint16) ([]wc.ReceiveFunc, uint16, error) {
	functions, actual, e := b.base.Open(port)
	if e != nil {
		return nil, 0, e
	}
	result := make([]wc.ReceiveFunc, len(functions))
	for i, receive := range functions {
		result[i] = func(bufs [][]byte, sizes []int, endpoints []wc.Endpoint) (int, error) {
			eps := make([]ac.Endpoint, len(endpoints))
			n, e := receive(bufs, sizes, eps)
			for j := 0; j < n; j++ {
				endpoints[j] = eps[j]
			}
			return n, e
		}
	}
	return result, actual, nil
}
