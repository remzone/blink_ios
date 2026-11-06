// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"github.com/pion/dtls/v3"
	"github.com/pion/dtls/v3/pkg/crypto/selfsign"
	"github.com/remzone/blink_ios/native/vkturn/tcputil"
	"github.com/xtaci/smux"
	"io"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

func TestExplicitDirectDTLSAndProtectedSocket(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	cert, err := selfsign.GenerateSelfSigned()
	if err != nil {
		t.Fatal(err)
	}
	listener, err := dtls.ListenWithOptions("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)}, dtls.WithCertificates(cert), dtls.WithExtendedMasterSecret(dtls.RequireExtendedMasterSecret), dtls.WithCipherSuites(dtls.TLS_ECDHE_ECDSA_WITH_AES_128_GCM_SHA256))
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	stop := context.AfterFunc(ctx, func() { listener.Close() })
	defer stop()
	done := make(chan error, 1)
	go func() {
		conn, e := listener.Accept()
		if e != nil {
			done <- e
			return
		}
		defer conn.Close()
		interrupt := context.AfterFunc(ctx, func() { conn.Close() })
		defer interrupt()
		if e = conn.(*dtls.Conn).HandshakeContext(ctx); e != nil {
			done <- e
			return
		}
		k, e := tcputil.NewKCPOverDTLS(conn, true)
		if e != nil {
			done <- e
			return
		}
		defer k.Close()
		s, e := smux.Server(k, tcputil.DefaultSmuxConfig())
		if e != nil {
			done <- e
			return
		}
		defer s.Close()
		stream, e := s.AcceptStream()
		if e != nil {
			done <- e
			return
		}
		defer stream.Close()
		payload := make([]byte, 5)
		if _, e = io.ReadFull(stream, payload); e == nil {
			_, e = stream.Write(payload)
		}
		done <- e
	}()
	var protected atomic.Int32
	client, err := Start(ctx, Config{DNSServer: "1.1.1.1", Direct: true, PeerHost: "127.0.0.1", PeerPort: listener.Addr().(*net.UDPAddr).Port, VKCallURL: "https://vk.ru/call/join/test", Streams: 1}, func(uintptr) bool { protected.Add(1); return true })
	if err != nil {
		t.Fatal(err)
	}
	defer client.Close()
	for client.Status() != "ready" && ctx.Err() == nil {
		time.Sleep(10 * time.Millisecond)
	}
	if client.Status() != "ready" {
		t.Fatal("direct transport not ready")
	}
	conn, err := net.Dial("tcp", client.Addr())
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(time.Second))
	if _, err = conn.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	payload := make([]byte, 5)
	if _, err = io.ReadFull(conn, payload); err != nil {
		t.Fatal(err)
	}
	if string(payload) != "hello" {
		t.Fatal("invalid echo")
	}
	if err = <-done; err != nil {
		t.Fatal(err)
	}
	if protected.Load() < 1 {
		t.Fatal("UDP socket was not protected")
	}
}
