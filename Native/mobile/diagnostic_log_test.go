package mobile

import (
	"encoding/json"
	"fmt"
	"github.com/remzone/blink_ios/native/vkturn"
	corelog "github.com/xtls/xray-core/common/log"
	"net"
	"testing"
)

type unformattableDiagnosticError struct{}

func (unformattableDiagnosticError) Error() string {
	panic("diagnostic logger must never format raw core errors")
}
func TestDiagnosticCoreLogClassifiesWithoutFormattingSecrets(t *testing.T) {
	vkturn.DrainDiagnosticsJSON()
	logger := newDiagnosticCoreLog()
	logger.Handle(&corelog.GeneralMessage{Severity: corelog.Severity_Warning, Content: unformattableDiagnosticError{}})
	logger.Handle(&corelog.GeneralMessage{Severity: corelog.Severity_Error, Content: &net.DNSError{Err: "private-token", Name: "private.example", IsTimeout: true}})
	var rows []vkturn.DiagnosticEvent
	if err := json.Unmarshal([]byte(vkturn.DrainDiagnosticsJSON()), &rows); err != nil || len(rows) != 2 {
		t.Fatalf("diagnostic classification: %d %v", len(rows), err)
	}
	if rows[1].Fields["stage"] != 1 {
		t.Fatal("DNS category missing")
	}
	logger.Handle(&corelog.GeneralMessage{Severity: corelog.Severity_Info, Content: fmt.Errorf("private endpoint: %w", &net.DNSError{Err: "private-token", Name: "private.example"})})
	var infoRows []vkturn.DiagnosticEvent
	if json.Unmarshal([]byte(vkturn.DrainDiagnosticsJSON()), &infoRows) != nil || len(infoRows) != 1 || infoRows[0].Fields["stage"] != 1 {
		t.Fatal("typed DNS failure at Info was lost")
	}
	logger.Handle(&corelog.GeneralMessage{Severity: corelog.Severity_Info, Content: unformattableDiagnosticError{}})
	logger.Handle(&corelog.GeneralMessage{Severity: corelog.Severity_Debug, Content: unformattableDiagnosticError{}})
	if vkturn.DrainDiagnosticsJSON() != "[]" {
		t.Fatal("verbose debug logging enabled")
	}
}
