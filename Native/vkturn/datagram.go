// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

func validWrapKey(s string) bool { b, e := hex.DecodeString(s); return e == nil && len(b) == 32 }

// WireGuard is a packet protocol. It never passes through KCP/smux and never
// inherits VLESS credentials. One shared bounded queue distributes WG records.
func (c *Client) runPackets() {
	defer close(c.done)
	stop := context.AfterFunc(c.ctx, func() { _ = c.packets.Close(); c.networkCancel() })
	defer stop()
	for i := 0; i < c.config.Streams; i++ {
		c.wg.Add(1)
		go func(id int) { defer c.wg.Done(); c.maintainPackets(id) }(i)
	}
	buf := make([]byte, 2048)
	for {
		n, addr, e := c.packets.ReadFromUDP(buf)
		if e != nil {
			break
		}
		if n > 1600 || !addr.IP.IsLoopback() {
			continue
		}
		c.mu.Lock()
		c.packetAddress = addr
		c.mu.Unlock()
		select {
		case c.packetOut <- append([]byte(nil), buf[:n]...):
		default:
		}
	}
	c.networkCancel()
	c.wg.Wait()
	<-c.authGate
	c.username, c.password, c.turnAddress = "", "", ""
	c.authGate <- struct{}{}
	c.setState("stopped")
	close(c.events)
}
func (c *Client) maintainPackets(id int) {
	if pause(c.networkCtx, time.Duration(id)*300*time.Millisecond) != nil {
		return
	}
	attempt := 0
	for c.networkCtx.Err() == nil {
		ctx := c.networkCtx
		peer, e := c.resolvePeer(ctx)
		leg := int64(1)
		var media net.Conn
		var release func()
		if e == nil {
			var user, pass, raw string
			user, pass, raw, e = c.credentials(ctx)
			if e == nil {
				network := c.config.TURNTransport
				// A failed or stale session switches the physical relay leg. Wire protocol
				// and authenticated payload never change during automatic selection.
				if network == "" || network == "auto" {
					network = "tcp"
					if attempt%2 == 1 {
						network = "udp"
					}
				}
				if network == "tcp" {
					leg = 2
				}
				media, release, e = c.createTURNPacketSession(ctx, peer, user, pass, raw, network)
			}
		}
		attempt++
		if e != nil {
			RecordDiagnostic("native.vk.retry", map[string]int64{"stream": int64(id), "stage": diagnosticFailureStage(e)})
			if errors.Is(e, ErrCaptchaRequired) {
				c.paused.Store(true)
				c.setState("captcha_required")
				c.networkCancel()
				return
			}
			if pause(ctx, 2*time.Second) != nil {
				return
			}
			continue
		}
		var replacement [20]byte
		copy(replacement[:4], []byte{0xff, 'R', 'E', 'P'})
		binary.BigEndian.PutUint16(replacement[4:6], uint16(id))
		binary.BigEndian.PutUint64(replacement[6:14], uint64(attempt))
		probe := func() error {
			_ = media.SetWriteDeadline(time.Now().Add(5 * time.Second))
			for _, b := range [][]byte{c.group[:], replacement[:]} {
				if _, e := media.Write(b); e != nil {
					return e
				}
			}
			ping := make([]byte, 12)
			copy(ping[:4], []byte{0xff, 'P', 'N', 'G'})
			binary.BigEndian.PutUint64(ping[4:], uint64(time.Now().UnixNano()))
			_, e := media.Write(ping)
			return e
		}
		// A completed DTLS handshake alone is not a ready data path. Require
		// the pinned server's authenticated transport echo before installing VPN.
		e = probe()
		var initial [2048]byte
		if e == nil {
			_ = media.SetReadDeadline(time.Now().Add(5 * time.Second))
			var n int
			n, e = media.Read(initial[:])
			if e == nil && !packetProbe(initial[:n]) {
				e = errors.New("missing server probe echo")
			}
		}
		if e != nil {
			RecordDiagnostic("native.vk.retry", map[string]int64{"stream": int64(id), "stage": 7})
			release()
			if pause(ctx, time.Second) != nil {
				return
			}
			continue
		}
		var rtt atomic.Int64
		rtt.Store(probeRTT(initial[:12]))
		mode := int64(3)
		if c.config.Protocol == "srtp" {
			mode = 4
		} else if c.config.Protocol == "wrap" {
			mode = 5
		}
		var tx, rx, out, in atomic.Int64
		c.mu.Lock()
		c.packetReady++
		c.mu.Unlock()
		c.packetState()
		child, cancel := context.WithCancel(ctx)
		stop := context.AfterFunc(child, release)
		var pair sync.WaitGroup
		pair.Add(2)
		go func() {
			defer pair.Done()
			defer cancel()
			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-child.Done():
					return
				case <-ticker.C:
					if probe() != nil {
						return
					}
				case b := <-c.packetOut:
					_ = media.SetWriteDeadline(time.Now().Add(5 * time.Second))
					tx.Add(int64(len(b)))
					out.Add(1)
					if _, e := media.Write(b); e != nil {
						return
					}
				}
			}
		}()
		go func() {
			defer pair.Done()
			defer cancel()
			buf := make([]byte, 2048)
			for {
				_ = media.SetReadDeadline(time.Now().Add(15 * time.Second))
				n, e := media.Read(buf)
				if e != nil {
					return
				}
				if packetProbe(buf[:n]) {
					rtt.Store(probeRTT(buf[:n]))
					continue
				}
				if n > 0 && buf[0] == 0xff {
					continue
				}
				rx.Add(int64(n))
				in.Add(1)
				if n > 1600 {
					continue
				}
				c.mu.Lock()
				addr := c.packetAddress
				c.mu.Unlock()
				if addr != nil {
					_, _ = c.packets.WriteToUDP(buf[:n], addr)
				}
			}
		}()
		metricsDone := make(chan struct{})
		go func() {
			defer close(metricsDone)
			ticker := time.NewTicker(5 * time.Second)
			defer ticker.Stop()
			for {
				select {
				case <-child.Done():
					return
				case <-ticker.C:
					RecordDiagnostic("native.vk.transport", map[string]int64{"mode": mode, "stage": leg, "rttMs": rtt.Load(), "stream": int64(id), "txBytes": tx.Load(), "rxBytes": rx.Load(), "inputPackets": in.Load(), "outputPackets": out.Load()})
				}
			}
		}()
		pair.Wait()
		<-metricsDone
		stop()
		release()
		cancel()
		c.mu.Lock()
		c.packetReady--
		c.mu.Unlock()
		c.packetState()
		if pause(ctx, time.Second) != nil {
			return
		}
	}
}
func (c *Client) packetState() {
	c.mu.Lock()
	n := c.packetReady
	c.mu.Unlock()
	if n > 0 {
		c.setState("ready")
	} else {
		c.setState("connecting")
	}
}

func packetProbe(b []byte) bool {
	return len(b) == 12 && bytes.Equal(b[:4], []byte{0xff, 'P', 'N', 'G'})
}
func probeRTT(b []byte) int64 {
	n := time.Now().UnixNano() - int64(binary.BigEndian.Uint64(b[4:12]))
	if n < 0 || n > int64(15*time.Second) {
		return 0
	}
	return n / int64(time.Millisecond)
}
