// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
	"github.com/remzone/blink_ios/native/vkturn"
	"runtime"
	"runtime/debug"
	"runtime/metrics"
)

// ConfigureRuntime sets a per-process soft Go memory target, not an iOS memory guarantee.
// Call before preparing assets/starting a core. It never forces a GC in the packet loop.
func ConfigureRuntime(memoryLimitBytes int64, gcPercent int) bool {
	if memoryLimitBytes < 16*1024*1024 || memoryLimitBytes > 256*1024*1024 || gcPercent < 50 || gcPercent > 200 {
		return false
	}
	debug.SetMemoryLimit(memoryLimitBytes)
	debug.SetGCPercent(gcPercent)
	return true
}
func RuntimeStatsJSON() string {
	samples := []metrics.Sample{{Name: "/memory/classes/heap/objects:bytes"}, {Name: "/memory/classes/total:bytes"}, {Name: "/memory/classes/heap/released:bytes"}, {Name: "/gc/cycles/total:gc-cycles"}, {Name: "/gc/heap/objects:objects"}}
	metrics.Read(samples)
	result := map[string]int64{"heapBytes": int64(samples[0].Value.Uint64()), "goBytes": int64(samples[1].Value.Uint64() - samples[2].Value.Uint64()), "gcCycles": int64(samples[3].Value.Uint64()), "heapObjects": int64(samples[4].Value.Uint64()), "goroutines": int64(runtime.NumGoroutine())}
	b, _ := json.Marshal(result)
	return string(b)
}
func DrainDiagnosticEventsJSON() string { return vkturn.DrainDiagnosticsJSON() }

func SetDiagnosticSession(id string) bool { return vkturn.SetDiagnosticSession(id) }
