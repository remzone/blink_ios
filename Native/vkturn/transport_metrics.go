package vkturn

import (
	"context"
	"github.com/xtaci/kcp-go/v5"
	"time"
)

// RTT and RTO come from KCP acknowledgements, not from an HTTPS/IP probe.
// count is the process-wide retransmitted segment counter, never packet content.
func startTransportMetrics(ctx context.Context, session *kcp.UDPSession, mode int64) func() {
	child, cancel := context.WithCancel(ctx)
	done := make(chan struct{})
	go func() {
		defer close(done)
		timer := time.NewTicker(time.Second)
		defer timer.Stop()
		ticks := 0
		for {
			select {
			case <-child.Done():
				return
			case <-timer.C:
				ticks++
				if ticks <= 20 || ticks%5 == 0 {
					RecordDiagnostic("native.vk.transport", map[string]int64{
						"mode": mode, "rttMs": int64(session.GetSRTT()), "rtoMs": int64(session.GetRTO()),
						"count": int64(kcp.DefaultSnmp.Copy().RetransSegs),
					})
				}
			}
		}
	}()
	return func() { cancel(); <-done }
}
