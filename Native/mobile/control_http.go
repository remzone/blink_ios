package mobile

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"syscall"
	"time"
)

var panelControlPath = regexp.MustCompile(`(?:^|/)api/vokop/v1/(?:status|subscriptions/[A-Za-z0-9_-]{32,128}(?:/(?:account|routing))?)$`)

// FetchPanelControl never follows the VPN's default route. Status and subscription
// updates remain available during an outage; HTTPS verification remains enabled.
func FetchPanelControl(raw string, protector Protector) (string, error) {
	u, e := url.Parse(raw)
	if e != nil || len(raw) > 4096 || u.Scheme != "https" || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" || !panelControlPath.MatchString(strings.TrimPrefix(u.Path, "/")) || protector == nil {
		return "", errors.New("invalid panel control URL")
	}
	control := func(_, _ string, c syscall.RawConn) error {
		var ok bool
		if e := c.Control(func(fd uintptr) { ok = protector.Protect(int64(fd)) }); e != nil || !ok {
			return errors.New("physical network unavailable")
		}
		return nil
	}
	dnsDial := &net.Dialer{Timeout: 3 * time.Second, Control: control}
	resolver := &net.Resolver{PreferGo: true, Dial: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return dnsDial.DialContext(ctx, "tcp4", "1.1.1.1:53")
	}}
	dial := &net.Dialer{Timeout: 5 * time.Second, Control: control, Resolver: resolver}
	transport := &http.Transport{DialContext: dial.DialContext, TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12}, TLSHandshakeTimeout: 5 * time.Second, DisableKeepAlives: true, Proxy: nil}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 10 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, _ := http.NewRequest("GET", u.String(), nil)
	request.Header.Set("Accept", "application/json")
	request.Header.Set("Cache-Control", "no-store")
	request.Header.Set("User-Agent", "Blink-routing/1.0")
	response, e := client.Do(request)
	if e != nil {
		return "", errors.New("panel control connection failed")
	}
	defer response.Body.Close()
	if response.StatusCode != 200 {
		return "", errors.New("panel control endpoint unavailable")
	}
	body, e := io.ReadAll(io.LimitReader(response.Body, 1048577))
	if e != nil || len(body) > 1048576 || !json.Valid(body) {
		return "", errors.New("invalid panel control response")
	}
	return string(body), nil
}
