// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"errors"
	"net"
	"sync"
	"time"

	kcp "github.com/xtaci/kcp-go/v5"
)

// Tuning only changes local scheduling/windows, never DTLS/KCP/smux framing.
// Empty values retain the pinned server's original client behavior.
type Tuning struct {
	Preset     string `json:"preset"`
	MTU        int    `json:"mtu"`
	Window     int    `json:"window"`
	IntervalMS int    `json:"intervalMs"`
	Congestion bool   `json:"congestion"`
	PaceKiB    int    `json:"paceKiB"`
}

func (t Tuning) validate() error {
	if t.Preset != "" && t.Preset != "compatibility" && t.Preset != "balanced" && t.Preset != "conservative" && t.Preset != "custom" {
		return errors.New("invalid transport preset")
	}
	if t.MTU != 0 && (t.MTU < 576 || t.MTU > 1200) {
		return errors.New("invalid KCP MTU")
	}
	if t.PaceKiB != 0 && (t.PaceKiB < 16 || t.PaceKiB > 4096) {
		return errors.New("invalid uplink pace")
	}
	if t.Preset == "custom" {
		if t.Window < 16 || t.Window > 256 || t.IntervalMS < 10 || t.IntervalMS > 100 {
			return errors.New("invalid custom KCP settings")
		}
	} else if t.Window != 0 || t.IntervalMS != 0 || t.Congestion {
		return errors.New("custom settings require custom preset")
	}
	return nil
}
func (t Tuning) parameters() (nodelay, interval, window, nc int) {
	switch t.Preset {
	case "balanced":
		return 1, 20, 64, 0
	case "conservative":
		return 0, 40, 32, 0
	case "custom":
		nc = 1
		if t.Congestion {
			nc = 0
		}
		return 1, t.IntervalMS, t.Window, nc
	default:
		return 1, 20, 256, 1
	}
}
func (t Tuning) apply(session *kcp.UDPSession) {
	nodelay, interval, window, nc := t.parameters()
	session.SetNoDelay(nodelay, interval, 2, nc)
	session.SetWindowSize(window, window)
	mtu := t.MTU
	if mtu == 0 {
		mtu = 1200
	}
	session.SetMtu(mtu)
}

// Pace whole DTLS application datagrams before encryption, preserving boundaries.
// At most one datagram bursts per allocation; cancellation/Close wake a waiting write.
func (t Tuning) paced(ctx context.Context, conn net.Conn) net.Conn {
	if t.PaceKiB == 0 {
		return conn
	}
	return &pacedConn{Conn: conn, ctx: ctx, closed: make(chan struct{}), rate: int64(t.PaceKiB) * 1024}
}

type pacedConn struct {
	net.Conn
	ctx    context.Context
	closed chan struct{}
	once   sync.Once
	mu     sync.Mutex
	next   time.Time
	rate   int64
}

func (p *pacedConn) Write(b []byte) (int, error) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if delay := time.Until(p.next); delay > 0 {
		timer := time.NewTimer(delay)
		defer timer.Stop()
		select {
		case <-timer.C:
		case <-p.ctx.Done():
			return 0, p.ctx.Err()
		case <-p.closed:
			return 0, net.ErrClosed
		}
	}
	select {
	case <-p.ctx.Done():
		return 0, p.ctx.Err()
	case <-p.closed:
		return 0, net.ErrClosed
	default:
	}
	n, err := p.Conn.Write(b)
	p.next = time.Now().Add(time.Duration((int64(n)*int64(time.Second) + p.rate - 1) / p.rate))
	return n, err
}
func (p *pacedConn) Close() error { p.once.Do(func() { close(p.closed) }); return p.Conn.Close() }
