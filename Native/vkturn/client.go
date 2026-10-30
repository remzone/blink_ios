// SPDX-License-Identifier: GPL-3.0-only
// Mobile lifecycle adapter for the pinned vk-turn-proxy VLESS wire protocol.
package vkturn

import (
	"context"
	"errors"
	"io"
	"net"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/xtaci/smux"
)

var ErrCaptchaRequired = errors.New("captcha_required")

// Config contains no server administration credentials. Streams is 1..16.
// VKCallURL is the VK call join link from an authenticated subscription.
type Config struct {
	// DNSServer is an explicitly selected physical-network bootstrap DNS IP.
	// It is not a tunnel DNS server; all queries are socket-protected.
	DNSServer string
	PeerHost  string
	PeerPort  int
	VKCallURL string
	Streams   int
}

type sessionFactory func(context.Context, *net.UDPAddr) (*smux.Session, func(), error)

// Client owns every listener, connection, credential cache and goroutine it starts.
// External sockets require a non-nil fail-closed protector. The callback must
// return promptly and must not retain fd: it is valid only during the callback.
type Client struct {
	ctx                             context.Context
	cancel                          context.CancelFunc
	networkCtx                      context.Context
	networkCancel                   context.CancelFunc
	listener                        net.Listener
	dialer                          *net.Dialer
	resolver                        *net.Resolver
	config                          Config
	link                            string
	done                            chan struct{}
	events                          chan string
	mu                              sync.Mutex
	state                           string
	sessions                        []*smux.Session
	counter                         atomic.Uint64
	paused                          atomic.Bool
	wg                              sync.WaitGroup
	factory                         sessionFactory
	authGate                        chan struct{}
	username, password, turnAddress string
	credsUntil, nextAuth            time.Time
}

// Start validates before touching the network and returns a loopback TCP endpoint
// immediately. Status is connecting until a full TURN/DTLS/KCP/smux path exists.
// It deliberately does not wait for VK or attempt CAPTCHA automation.
func Start(ctx context.Context, cfg Config, protect func(uintptr) bool) (*Client, error) {
	return start(ctx, cfg, protect, nil)
}
func start(ctx context.Context, cfg Config, protect func(uintptr) bool, factory sessionFactory) (*Client, error) {
	if ctx == nil || protect == nil {
		return nil, errors.New("context and socket protector are required")
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	u, err := url.Parse(cfg.VKCallURL)
	if err != nil || u.Scheme != "https" || (u.Host != "vk.com" && u.Host != "www.vk.com") || u.User != nil || u.RawQuery != "" || u.Fragment != "" || !regexp.MustCompile(`^/call/join/[A-Za-z0-9_=-]+$`).MatchString(u.Path) || u.RawPath != "" {
		return nil, errors.New("invalid VK call URL")
	}
	if net.ParseIP(cfg.DNSServer) == nil || cfg.Streams < 1 || cfg.Streams > 16 || cfg.PeerPort < 1 || cfg.PeerPort > 65535 || !validHost(cfg.PeerHost) {
		return nil, errors.New("invalid transport configuration")
	}
	ctx, cancel := context.WithCancel(ctx)
	nctx, ncancel := context.WithCancel(ctx)
	c := &Client{ctx: ctx, cancel: cancel, networkCtx: nctx, networkCancel: ncancel, config: cfg, link: strings.TrimPrefix(u.Path, "/call/join/"), done: make(chan struct{}), events: make(chan string, 1), authGate: make(chan struct{}, 1), state: "connecting"}
	c.authGate <- struct{}{}
	control := func(_, _ string, raw syscall.RawConn) error {
		allowed := false
		if err := raw.Control(func(fd uintptr) { allowed = protect(fd) }); err != nil {
			return errors.New("socket protection failed")
		}
		if !allowed {
			return errors.New("socket protection rejected")
		}
		return nil
	}
	// Use explicit bootstrap DNS, never iOS /etc/resolv.conf discovery or a
	// hidden public resolver fallback. Protect both UDP and TCP DNS sockets.
	dnsDialer := &net.Dialer{Timeout: 10 * time.Second, Control: control}
	c.resolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
		return dnsDialer.DialContext(ctx, network, net.JoinHostPort(cfg.DNSServer, "53"))
	}}
	c.dialer = &net.Dialer{Timeout: 15 * time.Second, KeepAlive: 30 * time.Second, Control: control, Resolver: c.resolver}
	c.listener, err = net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		cancel()
		ncancel()
		return nil, errors.New("local listener unavailable")
	}
	c.factory = factory
	if c.factory == nil {
		c.factory = c.createSession
	}
	c.events <- "connecting"
	go c.run()
	return c, nil
}
func validHost(host string) bool {
	if net.ParseIP(host) != nil {
		return true
	}
	if len(host) == 0 || len(host) > 253 {
		return false
	}
	for _, label := range strings.Split(host, ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, ch := range label {
			if !(ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z' || ch >= '0' && ch <= '9' || ch == '-') {
				return false
			}
		}
	}
	return true
}
func (c *Client) Addr() string   { return c.listener.Addr().String() }
func (c *Client) Status() string { c.mu.Lock(); defer c.mu.Unlock(); return c.state }

// Events is a coalescing status callback channel, containing only fixed public
// state names. Consumers must also query Status; they need not drain this channel.
// No unbounded callback goroutine can prevent Close. Closed after all workers exit.
func (c *Client) Events() <-chan string { return c.events }
func (c *Client) Close() error          { c.cancel(); <-c.done; return nil }
func (c *Client) setState(s string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.state == s || (c.paused.Load() && s != "captcha_required" && s != "stopped") {
		return
	}
	c.state = s
	select {
	case <-c.events:
	default:
	}
	select {
	case c.events <- s:
	default:
	}
}
func (c *Client) resolvePeer(ctx context.Context) (*net.UDPAddr, error) {
	ips, err := c.resolver.LookupIPAddr(ctx, c.config.PeerHost)
	if err != nil || len(ips) == 0 {
		return nil, errors.New("peer resolution failed")
	}
	return &net.UDPAddr{IP: ips[0].IP, Zone: ips[0].Zone, Port: c.config.PeerPort}, nil
}
func (c *Client) run() {
	defer close(c.done)
	stop := context.AfterFunc(c.ctx, func() { _ = c.listener.Close() })
	defer stop()
	for i := 0; i < c.config.Streams; i++ {
		c.wg.Add(1)
		go func(id int) { defer c.wg.Done(); c.maintain(id) }(i)
	}
	slots := make(chan struct{}, 128)
	for {
		conn, err := c.listener.Accept()
		if err != nil {
			c.cancel()
			break
		}
		select {
		case slots <- struct{}{}:
		default:
			_ = conn.Close()
			continue
		}
		c.mu.Lock()
		var sess *smux.Session
		if len(c.sessions) > 0 && !c.paused.Load() {
			sess = c.sessions[c.counter.Add(1)%uint64(len(c.sessions))]
		}
		c.mu.Unlock()
		if sess == nil || sess.IsClosed() {
			_ = conn.Close()
			<-slots
			continue
		}
		c.wg.Add(1)
		go func() {
			defer c.wg.Done()
			defer func() { <-slots }()
			defer conn.Close()
			stream, err := sess.OpenStream()
			if err != nil {
				return
			}
			defer stream.Close()
			pipe(c.ctx, conn, stream)
		}()
	}
	c.networkCancel()
	c.wg.Wait()
	// Clear cached secrets once workers can no longer access them.
	c.username, c.password, c.turnAddress = "", "", ""
	c.setState("stopped")
	close(c.events)
}
func (c *Client) maintain(id int) {
	if pause(c.networkCtx, time.Duration(id)*300*time.Millisecond) != nil {
		return
	}
	for c.networkCtx.Err() == nil {
		peer, err := c.resolvePeer(c.networkCtx)
		var session *smux.Session
		var cleanup func()
		if err == nil {
			session, cleanup, err = c.factory(c.networkCtx, peer)
		}
		if err != nil {
			if errors.Is(err, ErrCaptchaRequired) {
				c.paused.Store(true)
				c.setState("captcha_required")
				c.networkCancel()
				return
			}
			c.updateState()
			if pause(c.networkCtx, 3*time.Second) != nil {
				return
			}
			continue
		}
		c.mu.Lock()
		c.sessions = append(c.sessions, session)
		c.mu.Unlock()
		c.updateState()
		select {
		case <-c.networkCtx.Done():
		case <-session.CloseChan():
		}
		c.mu.Lock()
		for i, s := range c.sessions {
			if s == session {
				c.sessions = append(c.sessions[:i], c.sessions[i+1:]...)
				break
			}
		}
		c.mu.Unlock()
		cleanup()
		c.updateState()
		if pause(c.networkCtx, 2*time.Second) != nil {
			return
		}
	}
}
func (c *Client) updateState() {
	if c.paused.Load() {
		return
	}
	c.mu.Lock()
	n := len(c.sessions)
	c.mu.Unlock()
	if c.paused.Load() {
		return
	}
	if n > 0 {
		c.setState("ready")
	} else {
		c.setState("connecting")
	}
}
func pause(ctx context.Context, d time.Duration) error {
	if d <= 0 {
		return ctx.Err()
	}
	t := time.NewTimer(d)
	defer t.Stop()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-t.C:
		return nil
	}
}
func pipe(ctx context.Context, a, b net.Conn) {
	stop := context.AfterFunc(ctx, func() { _ = a.Close(); _ = b.Close() })
	defer stop()
	done := make(chan struct{})
	go func() { _, _ = io.Copy(a, b); _ = a.Close(); _ = b.Close(); close(done) }()
	_, _ = io.Copy(b, a)
	_ = a.Close()
	_ = b.Close()
	<-done
}
func (c *Client) resolveTURN(ctx context.Context, address string) (string, error) {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return "", errors.New("invalid TURN address")
	}
	p, e := strconv.Atoi(port)
	if e != nil || p < 1 || p > 65535 {
		return "", errors.New("invalid TURN port")
	}
	ips, err := c.resolver.LookupIPAddr(ctx, host)
	if err != nil || len(ips) == 0 {
		return "", errors.New("TURN resolution failed")
	}
	return net.JoinHostPort(ips[0].IP.String(), port), nil
}
