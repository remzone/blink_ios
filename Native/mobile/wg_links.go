// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/base64"
	"errors"
	"fmt"
	"net/url"
	"strings"
)

// Panel vpn:// wraps plain INI in raw base64url (not a compressed Amnezia backup).
func unwrapWG(source string) (string, string, error) {
	if strings.HasPrefix(source, "vpn://") {
		text := strings.TrimPrefix(source, "vpn://")
		if len(text) > 90000 {
			return "", "", errors.New("oversized vpn link")
		}
		var raw []byte
		var err error
		for _, enc := range []*base64.Encoding{base64.RawURLEncoding, base64.URLEncoding, base64.RawStdEncoding, base64.StdEncoding} {
			raw, err = enc.DecodeString(text)
			if err == nil {
				break
			}
		}
		if err != nil || !strings.Contains(string(raw), "[Interface]") {
			return "", "", errors.New("vpn link must contain a plain WireGuard conf")
		}
		return string(raw), "", nil
	}
	if !strings.HasPrefix(source, "wireguard://") && !strings.HasPrefix(source, "wg://") {
		return source, "", nil
	}
	u, e := url.Parse(source)
	if e != nil || u.User == nil || u.Hostname() == "" || u.Port() == "" || u.Path != "" {
		return "", "", errors.New("invalid WireGuard URI")
	}
	q, e := url.ParseQuery(u.RawQuery)
	if e != nil {
		return "", "", errors.New("invalid WireGuard query")
	}
	allowed := map[string]bool{}
	for _, k := range strings.Fields("publickey address mtu dns presharedkey keepalive reserved allowedips") {
		allowed[k] = true
	}
	for k, v := range q {
		if !allowed[k] || len(v) != 1 {
			return "", "", errors.New("unsupported WireGuard option")
		}
	}
	if q.Get("reserved") != "" && q.Get("reserved") != "0,0,0" {
		return "", "", errors.New("nonzero reserved bytes unsupported")
	}
	addresses := q.Get("address")
	routes := q.Get("allowedips")
	if routes == "" {
		routes = "0.0.0.0/0"
		if strings.Contains(addresses, ":") {
			routes += ", ::/0"
		}
	}
	conf := fmt.Sprintf("[Interface]\nPrivateKey = %s\nAddress = %s\n", u.User.Username(), addresses)
	for _, pair := range [][2]string{{"dns", "DNS"}, {"mtu", "MTU"}} {
		if v := q.Get(pair[0]); v != "" {
			conf += pair[1] + " = " + v + "\n"
		}
	}
	conf += fmt.Sprintf("[Peer]\nPublicKey = %s\nEndpoint = %s\nAllowedIPs = %s\n", q.Get("publickey"), u.Host, routes)
	for _, pair := range [][2]string{{"presharedkey", "PresharedKey"}, {"keepalive", "PersistentKeepalive"}} {
		if v := q.Get(pair[0]); v != "" {
			conf += pair[1] + " = " + v + "\n"
		}
	}
	// Values are single INI fields; reject injection even after URL percent decoding.
	for _, v := range append([]string{u.User.Username()}, queryValues(q)...) {
		if strings.ContainsAny(v, "\r\n\x00") {
			return "", "", errors.New("invalid WireGuard field")
		}
	}
	return conf, u.Fragment, nil
}
func queryValues(q url.Values) []string {
	r := []string{}
	for _, v := range q {
		r = append(r, v...)
	}
	return r
}
