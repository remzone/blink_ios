package vkturn

import (
	"context"
	"errors"
	"github.com/xtaci/smux"
	"time"
)

type turnAttempt func(context.Context, string) (*smux.Session, func(), error)

// Race full TURN/DTLS/smux readiness, with a small head start for datagram UDP.
// Each loser owns its cleanup until the result is accepted by the caller.
func raceTURNTransport(ctx context.Context, attempt turnAttempt) (*smux.Session, func(), string, error) {
	type result struct {
		session *smux.Session
		cleanup func()
		network string
		err     error
	}
	results := make(chan result)
	udp, stopUDP := context.WithCancel(ctx)
	tcp, stopTCP := context.WithCancel(ctx)
	launch := func(network string, child context.Context, delay time.Duration) {
		go func() {
			if pause(child, delay) != nil {
				return
			}
			session, cleanup, err := attempt(child, network)
			r := result{session, cleanup, network, err}
			select {
			case results <- r:
			case <-child.Done():
				if cleanup != nil {
					cleanup()
				}
			}
		}()
	}
	launch("udp", udp, 0)
	launch("tcp", tcp, 250*time.Millisecond)
	for failures := 0; failures < 2; failures++ {
		select {
		case r := <-results:
			if r.err == nil && r.session != nil && r.cleanup != nil {
				var stopWinner context.CancelFunc
				if r.network == "udp" {
					stopTCP()
					stopWinner = stopUDP
				} else {
					stopUDP()
					stopWinner = stopTCP
				}
				return r.session, func() { stopWinner(); r.cleanup() }, r.network, nil
			}
			if r.cleanup != nil {
				r.cleanup()
			}
		case <-ctx.Done():
			stopUDP()
			stopTCP()
			return nil, nil, "", ctx.Err()
		}
	}
	stopUDP()
	stopTCP()
	return nil, nil, "", errors.New("UDP and TCP TURN transports failed")
}
