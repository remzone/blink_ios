// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptrace"
	"strings"
	"syscall"
	"time"
)

// ProbeInternet is user-triggered. Direct mode requires physical socket protection;
// tunnel mode deliberately has no bypass or fallback. Platform must verify VPN state.
func ProbeInternet(kind string, direct bool, protector Protector) (string, error) {
	targets := map[string]string{"ip": "https://www.cloudflare.com/cdn-cgi/trace", "google": "https://www.google.com/generate_204", "youtube": "https://www.youtube.com/generate_204"}
	endpoint, ok := targets[kind]
	if !ok {
		return "", errors.New("unknown diagnostic")
	}
	if direct && protector == nil {
		return "", errors.New("physical protector required")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	started := time.Now()
	var dns, tcp, tlsStart, response time.Time
	result := map[string]any{"kind": kind, "direct": direct}
	control := func(network, address string, c syscall.RawConn) error {
		var ok bool
		if e := c.Control(func(fd uintptr) { ok = protector.Protect(int64(fd)) }); e != nil {
			return e
		}
		if !ok {
			return errors.New("diagnostic protection failed")
		}
		return nil
	}
	dial := net.Dialer{Timeout: 8 * time.Second}
	if direct {
		dial.Control = control
		dnsDial := net.Dialer{Control: control, Timeout: 5 * time.Second}
		dial.Resolver = &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, network, address string) (net.Conn, error) {
			return dnsDial.DialContext(ctx, network, address)
		}}
	}
	tr := &http.Transport{Proxy: nil, DialContext: func(ctx context.Context, network, address string) (net.Conn, error) {
		return dial.DialContext(ctx, "tcp4", address)
	}, TLSHandshakeTimeout: 8 * time.Second, DisableKeepAlives: true, DisableCompression: true}
	defer tr.CloseIdleConnections()
	client := &http.Client{Transport: tr, CheckRedirect: func(*http.Request, []*http.Request) error { return errors.New("diagnostic redirect refused") }}
	trace := &httptrace.ClientTrace{DNSStart: func(httptrace.DNSStartInfo) { dns = time.Now() }, DNSDone: func(httptrace.DNSDoneInfo) { result["dnsMs"] = time.Since(dns).Milliseconds() }, ConnectStart: func(string, string) { tcp = time.Now() }, ConnectDone: func(string, string, error) { result["tcpMs"] = time.Since(tcp).Milliseconds() }, TLSHandshakeStart: func() { tlsStart = time.Now() }, TLSHandshakeDone: func(tls.ConnectionState, error) { result["tlsMs"] = time.Since(tlsStart).Milliseconds() }, WroteRequest: func(httptrace.WroteRequestInfo) { response = time.Now() }, GotFirstResponseByte: func() { result["responseMs"] = time.Since(response).Milliseconds() }}
	req, _ := http.NewRequestWithContext(httptrace.WithClientTrace(ctx, trace), http.MethodGet, endpoint, nil)
	res, e := client.Do(req)
	if e != nil {
		return "", errors.New("HTTPS diagnostic failed; check selected network")
	}
	defer res.Body.Close()
	if res.StatusCode != 200 && res.StatusCode != 204 {
		return "", errors.New("diagnostic HTTP status rejected")
	}
	body, e := io.ReadAll(io.LimitReader(res.Body, 8193))
	if e != nil || len(body) > 8192 {
		return "", errors.New("invalid diagnostic response")
	}
	if kind == "ip" {
		for _, line := range strings.Split(string(body), "\n") {
			if strings.HasPrefix(line, "ip=") {
				ip := strings.TrimSpace(strings.TrimPrefix(line, "ip="))
				if net.ParseIP(ip) != nil {
					result["ip"] = ip
				}
			}
		}
		if result["ip"] == nil {
			return "", errors.New("invalid diagnostic IP")
		}
	}
	result["totalMs"] = time.Since(started).Milliseconds()
	result["checkedAt"] = time.Now().Unix()
	b, _ := json.Marshal(result)
	return string(b), nil
}
