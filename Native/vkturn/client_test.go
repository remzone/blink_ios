package vkturn

import (
	"context"
	"errors"
	"github.com/xtaci/smux"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func testConfig() Config {
	return Config{DNSServer: "127.0.0.1", PeerHost: "127.0.0.1", PeerPort: 56000, VKCallURL: "https://vk.com/call/join/example", Streams: 1}
}
func allow(uintptr) bool { return true }
func waitStatus(t *testing.T, c *Client, want string) {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		if c.Status() == want {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("status %q, want %q", c.Status(), want)
		case <-c.Events():
		}
	}
}
func TestValidationBeforeNetwork(t *testing.T) {
	for _, mut := range []func(*Config){func(c *Config) { c.DNSServer = "" }, func(c *Config) { c.DNSServer = "dns.example" }, func(c *Config) { c.DNSServer = "127.0.0.1:53" }, func(c *Config) { c.Streams = 0 }, func(c *Config) { c.Streams = 17 }, func(c *Config) { c.PeerPort = 0 }, func(c *Config) { c.PeerHost = "host:80" }, func(c *Config) { c.VKCallURL = "http://vk.com/call/join/a" }, func(c *Config) { c.VKCallURL = "https://vk.com.evil/call/join/a" }, func(c *Config) { c.VKCallURL = "https://vk.com/call/join/a?secret=1" }, func(c *Config) { c.VKCallURL = "https://vk.com/call/join/a%2Fb" }} {
		cfg := testConfig()
		mut(&cfg)
		if _, e := Start(context.Background(), cfg, allow); e == nil {
			t.Fatal("accepted invalid config")
		}
	}
	if _, e := Start(context.Background(), testConfig(), nil); e == nil {
		t.Fatal("missing protector accepted")
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if _, e := Start(ctx, testConfig(), allow); !errors.Is(e, context.Canceled) {
		t.Fatal(e)
	}
}
func TestCancellationWaitsForWorkersAndCloseIsConcurrentSafe(t *testing.T) {
	entered := make(chan struct{})
	var exited atomic.Bool
	factory := func(ctx context.Context, _ *net.UDPAddr) (*smux.Session, func(), error) {
		close(entered)
		<-ctx.Done()
		exited.Store(true)
		return nil, nil, ctx.Err()
	}
	c, e := start(context.Background(), testConfig(), allow, factory)
	if e != nil {
		t.Fatal(e)
	}
	<-entered
	var wg sync.WaitGroup
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); _ = c.Close() }()
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("Close did not cancel workers")
	}
	if !exited.Load() || c.Status() != "stopped" {
		t.Fatal("not stopped")
	}
	if conn, e := net.DialTimeout("tcp", c.Addr(), time.Second); e == nil {
		conn.Close()
		t.Fatal("listener still open")
	}
}
func TestCaptchaPausesWithoutRetry(t *testing.T) {
	var calls atomic.Int32
	factory := func(context.Context, *net.UDPAddr) (*smux.Session, func(), error) {
		calls.Add(1)
		return nil, nil, ErrCaptchaRequired
	}
	cfg := testConfig()
	cfg.Streams = 3
	c, e := start(context.Background(), cfg, allow, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	waitStatus(t, c, "captcha_required")
	time.Sleep(400 * time.Millisecond)
	if calls.Load() != 1 {
		t.Fatalf("captcha retried %d", calls.Load())
	}
	if c.Status() != "captcha_required" {
		t.Fatal(c.Status())
	}
}
func TestLoopbackTCPThroughSmuxAndShutdown(t *testing.T) {
	var serverDone chan struct{}
	factory := func(ctx context.Context, _ *net.UDPAddr) (*smux.Session, func(), error) {
		a, b := net.Pipe()
		client, e := smux.Client(a, nil)
		if e != nil {
			return nil, nil, e
		}
		server, e := smux.Server(b, nil)
		if e != nil {
			return nil, nil, e
		}
		serverDone = make(chan struct{})
		go func() {
			defer close(serverDone)
			stream, e := server.AcceptStream()
			if e != nil {
				return
			}
			defer stream.Close()
			_, _ = io.Copy(stream, stream)
		}()
		return client, func() { client.Close(); server.Close(); a.Close(); b.Close(); <-serverDone }, nil
	}
	c, e := start(context.Background(), testConfig(), allow, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	waitStatus(t, c, "ready")
	conn, e := net.Dial("tcp", c.Addr())
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(2 * time.Second))
	payload := "vless fixture bytes"
	if _, e = io.WriteString(conn, payload); e != nil {
		t.Fatal(e)
	}
	got := make([]byte, len(payload))
	if _, e = io.ReadFull(conn, got); e != nil {
		t.Fatal(e)
	}
	if string(got) != payload {
		t.Fatal(string(got))
	}
	if e = c.Close(); e != nil {
		t.Fatal(e)
	}
}
func TestProtectedDialFailsClosed(t *testing.T) {
	factory := func(ctx context.Context, _ *net.UDPAddr) (*smux.Session, func(), error) {
		<-ctx.Done()
		return nil, nil, ctx.Err()
	}
	var calls atomic.Int32
	c, e := start(context.Background(), testConfig(), func(uintptr) bool { calls.Add(1); return false }, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	// Loopback destination, but protection rejection must happen before connect.
	conn, e := c.dialer.DialContext(context.Background(), "tcp", c.Addr())
	if e == nil {
		conn.Close()
		t.Fatal("rejected protector bypassed")
	}
	if calls.Load() == 0 {
		t.Fatal("protector not called")
	}
}
func TestProtectedDNSDialFailsClosed(t *testing.T) {
	factory := func(ctx context.Context, _ *net.UDPAddr) (*smux.Session, func(), error) {
		<-ctx.Done()
		return nil, nil, ctx.Err()
	}
	var calls atomic.Int32
	c, e := start(context.Background(), testConfig(), func(uintptr) bool { calls.Add(1); return false }, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	_, e = c.resolver.Dial(context.Background(), "udp", "127.0.0.1:53")
	if e == nil {
		t.Fatal("resolver bypassed protector")
	}
	if calls.Load() == 0 {
		t.Fatal("DNS protector not called")
	}
}
func TestBoundedResponse(t *testing.T) {
	if _, e := readBounded(strings.NewReader(strings.Repeat("x", 1024*1024+1))); e == nil {
		t.Fatal("oversize accepted")
	}
}

func TestTokenChainFixture(t *testing.T) {
	ctx := context.Background()
	step := 0
	do := func(data, endpoint string) (map[string]interface{}, error) {
		step++
		switch step {
		case 1:
			if !strings.Contains(endpoint, "login.vk.ru") {
				t.Fatal(endpoint)
			}
			return map[string]interface{}{"data": map[string]interface{}{"access_token": "anon&secret"}}, nil
		case 2:
			if !strings.Contains(data, "access_token=anon%26secret") {
				t.Fatal("token not escaped")
			}
			return map[string]interface{}{}, nil
		case 3:
			return map[string]interface{}{"response": map[string]interface{}{"token": "joined&token"}}, nil
		case 4:
			return map[string]interface{}{"session_key": "session&key"}, nil
		case 5:
			if !strings.Contains(data, "anonymToken=joined%26token") || !strings.Contains(data, "session_key=session%26key") {
				t.Fatal("token injection")
			}
			return map[string]interface{}{"turn_server": map[string]interface{}{"username": "user", "credential": "pass", "urls": []interface{}{"turn:127.0.0.1:3478?transport=tcp"}}}, nil
		default:
			t.Fatal("unexpected request")
			return nil, nil
		}
	}
	u, p, a, e := tokenChainRequests(ctx, "example", VKCredentials{"public-app", "public-key"}, do)
	if e != nil || u != "user" || p != "pass" || a != "127.0.0.1:3478" || step != 5 {
		t.Fatalf("fixture sequence failed: %v", e)
	}
}
func TestCaptchaParsingDoesNotExposeChallenge(t *testing.T) {
	for _, body := range []string{`{"error":{"error_code":14,"captcha_sid":"secret-challenge"}}`, `{"error":{"captcha_sid":"secret-challenge"}}`} {
		_, e := parseVKResponse([]byte(body))
		if !errors.Is(e, ErrCaptchaRequired) || e.Error() != "captcha_required" {
			t.Fatal(e)
		}
	}
	_, e := parseVKResponse([]byte(`{"access_token":"sensitive" broken`))
	if e == nil || strings.Contains(e.Error(), "sensitive") {
		t.Fatal("response content leaked")
	}
}
func TestTokenChainCancellationDuringDelay(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	calls := 0
	_, _, _, e := tokenChainRequests(ctx, "example", VKCredentials{}, func(string, string) (map[string]interface{}, error) {
		calls++
		cancel()
		return map[string]interface{}{"data": map[string]interface{}{"access_token": "x"}}, nil
	})
	if !errors.Is(e, context.Canceled) || calls != 1 {
		t.Fatal("did not cancel credential chain")
	}
}

// A silent TURN server exercises cancellation inside Pion Allocate's transaction
// wait, not merely the service's injected factory cancellation path.
func TestCancelDuringTURNAllocation(t *testing.T) {
	server, e := net.Listen("tcp4", "127.0.0.1:0")
	if e != nil {
		t.Fatal(e)
	}
	defer server.Close()
	request := make(chan struct{})
	serverDone := make(chan struct{})
	go func() {
		defer close(serverDone)
		conn, e := server.Accept()
		if e != nil {
			return
		}
		defer conn.Close()
		buf := make([]byte, 2048)
		if _, e = conn.Read(buf); e == nil {
			close(request)
		}
		_, _ = io.Copy(io.Discard, conn)
	}()
	assigned := make(chan struct{})
	var c *Client
	factory := func(ctx context.Context, peer *net.UDPAddr) (*smux.Session, func(), error) {
		select {
		case <-ctx.Done():
			return nil, nil, ctx.Err()
		case <-assigned:
		}
		session, cleanup, err := c.createSession(ctx, peer)
		if err != nil {
			t.Logf("mock session setup: %v", err)
		}
		return session, cleanup, err
	}
	c, e = start(context.Background(), testConfig(), allow, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	c.username = "mock"
	c.password = "mock"
	c.turnAddress = server.Addr().String()
	c.credsUntil = time.Now().Add(time.Hour)
	close(assigned)
	select {
	case <-request:
	case <-time.After(2 * time.Second):
		t.Fatal("mock allocation request not sent")
	}
	closed := make(chan struct{})
	go func() { c.Close(); close(closed) }()
	select {
	case <-closed:
	case <-time.After(2 * time.Second):
		t.Fatal("TURN transaction did not cancel")
	}
	select {
	case <-serverDone:
	case <-time.After(2 * time.Second):
		t.Fatal("TURN socket leaked")
	}
}

func TestBootstrapDNSIgnoresPlatformResolver(t *testing.T) {
	factory := func(ctx context.Context, _ *net.UDPAddr) (*smux.Session, func(), error) {
		<-ctx.Done()
		return nil, nil, ctx.Err()
	}
	c, e := start(context.Background(), testConfig(), allow, factory)
	if e != nil {
		t.Fatal(e)
	}
	defer c.Close()
	// Connected UDP setup sends no query. The unroutable fixture address must
	// be replaced by the explicitly configured loopback bootstrap DNS endpoint.
	conn, e := c.resolver.Dial(context.Background(), "udp", "192.0.2.99:1234")
	if e != nil {
		t.Fatal(e)
	}
	defer conn.Close()
	if conn.RemoteAddr().String() != "127.0.0.1:53" {
		t.Fatalf("unexpected DNS destination %s", conn.RemoteAddr())
	}
}
