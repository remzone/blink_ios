package vkturn

import (
	"context"
	"github.com/xtaci/kcp-go/v5"
	"time"
)

// RTT and RTO come from KCP acknowledgements, not from an HTTPS/IP probe.
// SNMP counters are process-wide; compare deltas between samples, never packet content.
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
					snapshot := kcp.DefaultSnmp.Copy()
					RecordDiagnostic("native.vk.transport", map[string]int64{
						"mode": mode, "rttMs": int64(session.GetSRTT()), "rtoMs": int64(session.GetRTO()),
						"count":        int64(snapshot.RetransSegs),
						"inputPackets": int64(snapshot.InPkts), "outputPackets": int64(snapshot.OutPkts),
						"rxBytes": int64(snapshot.InBytes), "txBytes": int64(snapshot.OutBytes),
						"inputErrors": int64(snapshot.InErrs + snapshot.InCsumErrors + snapshot.KCPInErrors),
					})
				}
			}
		}
	}()
	return func() { cancel(); <-done }
}
