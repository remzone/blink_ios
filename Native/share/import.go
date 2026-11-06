// SPDX-License-Identifier: GPL-3.0-only
package share

import (
	"encoding/json"
	"errors"
	"github.com/xtls/xray-core/infra/conf"
	"net/url"
	"strconv"
	"strings"
	"unicode"
)

// ParseSingle has no network or runtime side effects. Errors never contain the link.
func ParseSingle(source string) (out *conf.OutboundDetourConfig, err error) {
	defer func() {
		if recover() != nil {
			out = nil
			err = errors.New("invalid proxy link")
		}
		if err != nil {
			err = errors.New("unsupported or invalid proxy settings")
		}
	}()
	if len(source) > 16384 || strings.ContainsAny(source, "\r\n") {
		return nil, errors.New("invalid link")
	}
	if strings.HasPrefix(source, "vmess://") && !strings.Contains(strings.TrimPrefix(source, "vmess://"), "@") {
		source, err = vmessJSON(source)
		if err != nil {
			return nil, err
		}
	}
	if strings.HasPrefix(source, "ss://") && !strings.Contains(source, "@") {
		raw := strings.TrimPrefix(source, "ss://")
		encoded, fragment, _ := strings.Cut(raw, "#")
		decoded, e := decodeBase64Text(encoded)
		if e != nil {
			return nil, e
		}
		auth, host, ok := strings.Cut(decoded, "@")
		if !ok {
			return nil, errors.New("invalid ss")
		}
		method, password, ok := strings.Cut(auth, ":")
		if !ok {
			return nil, errors.New("invalid ss")
		}
		source = "ss://" + url.UserPassword(method, password).String() + "@" + host
		if fragment != "" {
			source += "#" + fragment
		}
	}
	var u *url.URL
	if strings.HasPrefix(source, "hy2://") || strings.HasPrefix(source, "hysteria2://") {
		u, _, err = hysteria2URL(source)
	} else {
		u, err = url.Parse(source)
	}
	if err != nil || u == nil || u.Hostname() == "" || len(u.Hostname()) > 253 || u.User == nil && u.Scheme != "socks" {
		return nil, errors.New("endpoint required")
	}
	port, e := strconv.Atoi(u.Port())
	if e != nil || port < 1 || port > 65535 {
		return nil, errors.New("invalid port")
	}
	if u.Path != "" && u.Path != "/" {
		return nil, errors.New("path must be a query parameter")
	}
	allowed := map[string]bool{}
	for _, k := range strings.Fields("type security encryption sni fp pbk sid pqv spx ech pcs vcn alpn flow host path mode headerType mtu tti authority serviceName obfs obfs-password mport ports hop-interval up down insecure allowInsecure") {
		allowed[k] = true
	}
	q, e := url.ParseQuery(u.RawQuery)
	if e != nil {
		return nil, e
	}
	for k, v := range q {
		if !allowed[k] || len(v) != 1 {
			return nil, errors.New("unknown or duplicate option")
		}
	}
	if u.Scheme != "hy2" && u.Scheme != "hysteria2" && (q.Has("insecure") || q.Has("allowInsecure")) {
		return nil, errors.New("insecure TLS unsupported")
	}
	if q.Has("extra") || q.Has("fm") {
		return nil, errors.New("extended settings unsupported")
	}
	network := q.Get("type")
	if network != "" && !contains([]string{"tcp", "raw", "ws", "websocket", "grpc", "gun", "httpupgrade", "xhttp", "splithttp", "kcp", "mkcp"}, network) {
		return nil, errors.New("transport unsupported")
	}
	security := q.Get("security")
	implicitTLS := (u.Scheme == "trojan" || u.Scheme == "hy2" || u.Scheme == "hysteria2") && security == ""
	if security != "tls" && security != "reality" && !implicitTLS {
		for _, k := range []string{"sni", "fp", "alpn", "ech", "pcs", "vcn"} {
			if q.Has(k) {
				return nil, errors.New("TLS option without TLS")
			}
		}
	}
	for _, k := range []string{"pbk", "sid", "pqv", "spx"} {
		if q.Has(k) && security != "reality" {
			return nil, errors.New("REALITY option without REALITY")
		}
	}
	if q.Has("encryption") && u.Scheme != "vless" && u.Scheme != "vmess" {
		return nil, errors.New("irrelevant encryption")
	}
	if q.Has("flow") && u.Scheme != "vless" {
		return nil, errors.New("irrelevant flow")
	}
	hy2 := u.Scheme == "hy2" || u.Scheme == "hysteria2"
	for _, k := range []string{"obfs", "obfs-password", "mport", "ports", "hop-interval", "up", "down"} {
		if q.Has(k) && !hy2 {
			return nil, errors.New("irrelevant QUIC option")
		}
	}
	effective := network
	if effective == "" {
		effective = "tcp"
	}
	if q.Has("mode") && !contains([]string{"grpc", "gun", "xhttp", "splithttp"}, effective) {
		return nil, errors.New("irrelevant mode")
	}
	for _, k := range []string{"serviceName", "authority"} {
		if q.Has(k) && effective != "grpc" && effective != "gun" {
			return nil, errors.New("irrelevant gRPC option")
		}
	}
	for _, k := range []string{"mtu", "tti"} {
		if q.Has(k) && effective != "kcp" && effective != "mkcp" {
			return nil, errors.New("irrelevant KCP option")
		}
	}
	if h := q.Get("headerType"); h != "" && h != "none" && (effective != "tcp" && effective != "raw" || h != "http") {
		return nil, errors.New("unsupported transport header")
	}
	for _, k := range []string{"path", "host"} {
		if q.Has(k) && !contains([]string{"ws", "websocket", "httpupgrade", "xhttp", "splithttp"}, effective) && !((effective == "tcp" || effective == "raw") && q.Get("headerType") == "http") {
			return nil, errors.New("irrelevant HTTP option")
		}
	}
	out, err = parseOutboundShareLink(source)
	if err != nil {
		return nil, err
	}
	if out.StreamSetting == nil && u.Scheme == "trojan" {
		out.StreamSetting = &conf.StreamConfig{Security: "tls", TLSSettings: &conf.TLSConfig{ServerName: u.Hostname()}}
	}
	if out.StreamSetting != nil {
		if t := out.StreamSetting.TLSSettings; t != nil {
			if t.AllowInsecure {
				return nil, errors.New("TLS verification required")
			}
			if t.ServerName == "" {
				t.ServerName = u.Hostname()
			}
		}
		if out.StreamSetting.Security != "" && !contains([]string{"none", "tls", "reality"}, out.StreamSetting.Security) {
			return nil, errors.New("security unsupported")
		}
	}
	if _, err = out.Build(); err != nil {
		return nil, err
	}
	return out, nil
}
func contains(values []string, s string) bool {
	for _, v := range values {
		if v == s {
			return true
		}
	}
	return false
}
func DisplayName(source, fallback string) string {
	u, e := url.Parse(source)
	if e != nil || u.Fragment == "" {
		return fallback
	}
	r := []rune(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) {
			return -1
		}
		return r
	}, u.Fragment))
	if len(r) > 100 {
		r = r[:100]
	}
	return string(r)
}
func vmessJSON(source string) (string, error) {
	text, e := decodeBase64Text(strings.TrimPrefix(source, "vmess://"))
	if e != nil {
		return "", e
	}
	var m map[string]json.RawMessage
	if !uniqueJSON([]byte(text)) || json.Unmarshal([]byte(text), &m) != nil {
		return "", errors.New("invalid vmess JSON")
	}
	allowed := map[string]bool{}
	for _, k := range strings.Fields("v ps add port id aid scy net type host path tls sni alpn fp") {
		allowed[k] = true
	}
	for k := range m {
		if !allowed[k] {
			return "", errors.New("unsupported vmess field")
		}
	}
	get := func(k string) string {
		var s string
		if json.Unmarshal(m[k], &s) == nil {
			return s
		}
		return string(m[k])
	}
	if a := get("aid"); a != "" && a != "0" {
		return "", errors.New("legacy VMess alterId unsupported")
	}
	host := get("add")
	if strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	u := &url.URL{Scheme: "vmess", Host: host + ":" + get("port"), User: url.User(get("id")), Fragment: get("ps")}
	q := url.Values{}
	for _, pair := range [][2]string{{"net", "type"}, {"scy", "encryption"}, {"host", "host"}, {"path", "path"}, {"sni", "sni"}, {"alpn", "alpn"}, {"fp", "fp"}} {
		if v := get(pair[0]); v != "" {
			key := pair[1]
			if get("net") == "grpc" || get("net") == "gun" {
				if key == "path" {
					key = "serviceName"
				}
				if key == "host" {
					key = "authority"
				}
			}
			q.Set(key, v)
		}
	}
	if v := get("type"); v != "" && v != "none" {
		q.Set("headerType", v)
	}
	if v := get("tls"); v != "" && v != "none" {
		q.Set("security", v)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}
