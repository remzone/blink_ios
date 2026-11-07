package mobile

import (
	"encoding/json"
	"runtime/debug"
	"testing"
)

func TestRuntimeDiagnosticsAndValidatedMemoryTarget(t *testing.T) {
	previousLimit := debug.SetMemoryLimit(-1)
	previousGC := debug.SetGCPercent(100)
	defer debug.SetMemoryLimit(previousLimit)
	defer debug.SetGCPercent(previousGC)
	if ConfigureRuntime(1, 75) || ConfigureRuntime(32*1024*1024, 0) {
		t.Fatal("unsafe runtime setting accepted")
	}
	if !ConfigureRuntime(64*1024*1024, 75) || debug.SetMemoryLimit(-1) != 64*1024*1024 {
		t.Fatal("memory target not applied")
	}
	var stats map[string]int64
	if e := json.Unmarshal([]byte(RuntimeStatsJSON()), &stats); e != nil {
		t.Fatal(e)
	}
	for _, key := range []string{"heapBytes", "goBytes", "heapObjects", "gcCycles", "goroutines"} {
		v, ok := stats[key]
		if !ok || v < 0 {
			t.Fatalf("missing/non-numeric runtime metric %s", key)
		}
	}
}
