package vkturn

import (
	"context"
	"errors"
	"github.com/xtaci/smux"
	"io"
	"net"
	"testing"
	"time"
)

func TestAutoTURNFallsBackWithoutWaitingForStalledUDP(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	udpClosed := make(chan struct{})
	started := time.Now()
	session, cleanup, network, err := raceTURNTransport(ctx, func(child context.Context, network string) (*smux.Session, func(), error) {
		if network == "udp" {
			<-child.Done()
			close(udpClosed)
			return nil, nil, child.Err()
		}
		a, b := net.Pipe()
		client, e := smux.Client(a, nil)
		if e != nil {
			return nil, nil, e
		}
		server, e := smux.Server(b, nil)
		if e != nil {
			client.Close()
			return nil, nil, e
		}
		go func() {
			stream, e := server.AcceptStream()
			if e == nil {
				defer stream.Close()
				io.Copy(stream, stream)
			}
		}()
		return client, func() { client.Close(); server.Close() }, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer cleanup()
	if network != "tcp" || time.Since(started) > 2*time.Second {
		t.Fatal("Auto waited for blocked UDP instead of starting TCP")
	}
	select {
	case <-udpClosed:
	case <-ctx.Done():
		t.Fatal("Unused UDP attempt was not cancelled")
	}
	stream, err := session.OpenStream()
	if err != nil {
		t.Fatal(err)
	}
	defer stream.Close()
	stream.SetDeadline(time.Now().Add(time.Second))
	if _, err = stream.Write([]byte("ping")); err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 4)
	if _, err = io.ReadFull(stream, data); err != nil || string(data) != "ping" {
		t.Fatal("Selected session is unusable")
	}
}
func TestAutoTURNStopsWhenBothNetworksFailOrCallerCancels(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if _, _, _, err := raceTURNTransport(ctx, func(context.Context, string) (*smux.Session, func(), error) { return nil, nil, errors.New("offline") }); err == nil {
		t.Fatal("Offline transports reported ready")
	}
	cancelled, stop := context.WithCancel(context.Background())
	stop()
	if _, _, _, err := raceTURNTransport(cancelled, func(ctx context.Context, _ string) (*smux.Session, func(), error) {
		<-ctx.Done()
		return nil, nil, ctx.Err()
	}); err == nil {
		t.Fatal("Cancelled startup reported ready")
	}
}
