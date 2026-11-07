package vkturn

import (
	"encoding/json"
	"errors"
	"strings"
	"sync"
	"testing"
)

func TestDiagnosticRingIsBoundedAndConcurrent(t *testing.T) {
	DrainDiagnosticsJSON()
	var wg sync.WaitGroup
	for i := 0; i < 4; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				RecordDiagnostic("native.vk.retry", map[string]int64{"stage": 5})
			}
		}()
	}
	wg.Wait()
	var events []DiagnosticEvent
	if e := json.Unmarshal([]byte(DrainDiagnosticsJSON()), &events); e != nil || len(events) != 128 {
		t.Fatalf("ring size: %d %v", len(events), e)
	}
	if DrainDiagnosticsJSON() != "[]" {
		t.Fatal("drain replays events")
	}
}
func TestDiagnosticFailureNeverExportsErrorText(t *testing.T) {
	if diagnosticFailureStage(errors.New("DTLS handshake failed")) != 5 {
		t.Fatal("handshake stage missing")
	}
	raw := "https://panel.example/sub/private-secret"
	stage := diagnosticFailureStage(errors.New(raw))
	if stage != 0 {
		t.Fatal("unknown error classified as known failure")
	}
	RecordDiagnostic("native.vk.retry", map[string]int64{"stage": stage})
	if strings.Contains(DrainDiagnosticsJSON(), "private-secret") {
		t.Fatal("secret leaked")
	}
}
