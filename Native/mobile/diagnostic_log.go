// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"crypto/x509"
	"errors"
	"github.com/remzone/blink_ios/native/vkturn"
	corelog "github.com/xtls/xray-core/common/log"
	"io"
	"net"
	"sync"
	"syscall"
	"time"
)

// Never format Message/Content: access logs, endpoint names and authentication
// data remain in the core. Only classify the underlying Go error by its type.
type diagnosticCoreLog struct {
	mu     sync.Mutex
	last   map[int]time.Time
	counts map[int]int64
}

func newDiagnosticCoreLog() *diagnosticCoreLog {
	return &diagnosticCoreLog{last: map[int]time.Time{}, counts: map[int]int64{}}
}
func (*diagnosticCoreLog) Severity() corelog.Severity { return corelog.Severity_Info }
func (l *diagnosticCoreLog) Handle(message corelog.Message) {
	general, ok := message.(*corelog.GeneralMessage)
	if !ok || general.Severity > corelog.Severity_Info {
		return
	}
	// DNS/transport errors are sometimes reported at Info with a typed cause.
	// Ignore ordinary Info messages and preformatted strings; never format them.
	if general.Severity == corelog.Severity_Info {
		err, ok := general.Content.(error)
		if !ok || errors.Unwrap(err) == nil {
			return
		}
	}
	stage := int64(0)
	if err, ok := general.Content.(error); ok {
		var dns *net.DNSError
		var timeout net.Error
		var certificate x509.UnknownAuthorityError
		switch {
		case errors.As(err, &dns):
			stage = 1
		case errors.As(err, &timeout) && timeout.Timeout():
			stage = 2
		case errors.As(err, &certificate):
			stage = 3
		case errors.Is(err, syscall.ECONNREFUSED):
			stage = 4
		case errors.Is(err, syscall.ECONNRESET):
			stage = 5
		case errors.Is(err, io.EOF), errors.Is(err, net.ErrClosed):
			stage = 6
		}
	}
	key := int(stage)*10 + int(general.Severity)
	l.mu.Lock()
	l.counts[key]++
	count := l.counts[key]
	emit := time.Since(l.last[key]) >= time.Second
	if emit {
		l.last[key] = time.Now()
	}
	l.mu.Unlock()
	if emit {
		vkturn.RecordDiagnostic("native.xray.error", map[string]int64{"stage": stage, "errorCode": int64(general.Severity), "count": count})
	}
}

var wgDiagnosticCounter struct {
	sync.Mutex
	count int64
	last  time.Time
}

func recordWGDiagnosticError() {
	wgDiagnosticCounter.Lock()
	wgDiagnosticCounter.count++
	count := wgDiagnosticCounter.count
	emit := time.Since(wgDiagnosticCounter.last) >= time.Second
	if emit {
		wgDiagnosticCounter.last = time.Now()
	}
	wgDiagnosticCounter.Unlock()
	if emit {
		vkturn.RecordDiagnostic("native.wireguard.error", map[string]int64{"count": count})
	}
}
