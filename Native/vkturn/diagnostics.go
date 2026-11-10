// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"encoding/json"
	"github.com/google/uuid"
	"sync"
	"time"
)

// Fixed event identifiers and numbers only. No error strings, URLs, tokens or traffic.
type DiagnosticEvent struct {
	SessionID  string           `json:"sessionId,omitempty"`
	OccurredAt int64            `json:"occurredAt"`
	Event      string           `json:"event"`
	Fields     map[string]int64 `json:"fields"`
}

var diagnosticRing struct {
	sync.Mutex
	events    []DiagnosticEvent
	sessionID string
	disabled  bool
}

func RecordDiagnostic(event string, fields map[string]int64) {
	diagnosticRing.Lock()
	defer diagnosticRing.Unlock()
	if diagnosticRing.disabled {
		return
	}
	if len(diagnosticRing.events) >= 128 {
		copy(diagnosticRing.events, diagnosticRing.events[1:])
		diagnosticRing.events = diagnosticRing.events[:127]
	}
	diagnosticRing.events = append(diagnosticRing.events, DiagnosticEvent{SessionID: diagnosticRing.sessionID, OccurredAt: time.Now().UnixMilli(), Event: event, Fields: fields})
}
func DrainDiagnosticsJSON() string {
	diagnosticRing.Lock()
	defer diagnosticRing.Unlock()
	if len(diagnosticRing.events) == 0 {
		return "[]"
	}
	raw, _ := json.Marshal(diagnosticRing.events)
	diagnosticRing.events = nil
	return string(raw)
}
func diagnosticStage(event string, stage int) {
	RecordDiagnostic(event, map[string]int64{"stage": int64(stage)})
}

func diagnosticFailureStage(err error) int64 {
	if err == nil {
		return 0
	}
	switch err.Error() {
	case "TURN connection failed":
		return 1
	case "TURN client creation failed", "TURN listener failed":
		return 2
	case "TURN allocation failed":
		return 3
	case "DTLS certificate generation failed", "DTLS client creation failed":
		return 4
	case "DTLS handshake failed":
		return 5
	case "KCP creation failed":
		return 6
	case "smux creation failed":
		return 7
	case "peer resolution failed", "TURN resolution failed":
		return 8
	default:
		return 0
	}
}

func SetDiagnosticSession(id string) bool {
	if _, err := uuid.Parse(id); err != nil || len(id) != 36 {
		return false
	}
	diagnosticRing.Lock()
	defer diagnosticRing.Unlock()
	diagnosticRing.sessionID = id
	return true
}

// SetDiagnosticCollection stops allocation and discards queued native events.
func SetDiagnosticCollection(enabled bool) {
	diagnosticRing.Lock()
	defer diagnosticRing.Unlock()
	diagnosticRing.disabled = !enabled
	if !enabled {
		diagnosticRing.events = nil
	}
}
