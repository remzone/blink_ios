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
	if err != nil || u == nil || u.Hostname() == "" || len(u.Hostname()) > 253 || u.User == nil && u.Scheme != "socks" && u.Scheme != "http" && u.Scheme != "https" {
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
	for _, k := range strings.Fields("type security encryption sni fp pbk sid pqv spx ech pcs vcn alpn flow host path mode headerType mtu tti authority serviceName obfs obfs-password mport ports hop-interval up down insecure allowInsecure extra fm cs support-x25519mlkem768 seed plugin x_padding_bytes") {
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
	for _, key := range []string{"extra", "fm"} {
		if q.Has(key) && !uniqueJSON([]byte(q.Get(key))) {
			return nil, errors.New("invalid extended JSON")
		}
	}
	if q.Has("extra") && networkForQuery(q) != "xhttp" && networkForQuery(q) != "splithttp" {
		return nil, errors.New("XHTTP extra without XHTTP")
	}
	if q.Has("plugin") {
		return nil, errors.New("external plugin unsupported")
	}
	network := q.Get("type")
	if network != "" && !contains([]string{"tcp", "raw", "ws", "websocket", "grpc", "gun", "httpupgrade", "xhttp", "splithttp", "kcp", "mkcp"}, network) {
		return nil, errors.New("transport unsupported")
	}
	security := q.Get("security")
	implicitTLS := (u.Scheme == "trojan" || u.Scheme == "hy2" || u.Scheme == "hysteria2") && security == ""
	if security != "tls" && security != "reality" && !implicitTLS {
		for _, k := range []string{"sni", "fp", "alpn", "ech", "pcs", "vcn", "cs"} {
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
	for _, k := range []string{"mtu", "tti", "seed"} {
		if q.Has(k) && effective != "kcp" && effective != "mkcp" {
			return nil, errors.New("irrelevant KCP option")
		}
	}
	if h := q.Get("headerType"); h != "" && h != "none" {
		if effective == "kcp" || effective == "mkcp" {
			if !contains([]string{"dns", "srtp", "utp", "wechat-video", "dtls", "wireguard"}, h) {
				return nil, errors.New("unknown KCP header")
			}
		} else if (effective != "tcp" && effective != "raw") || h != "http" {
			return nil, errors.New("irrelevant transport header")
		}
	}

	for _, k := range []string{"path", "host"} {
		if q.Has(k) && !contains([]string{"ws", "websocket", "httpupgrade", "xhttp", "splithttp"}, effective) && !((effective == "tcp" || effective == "raw") && q.Get("headerType") == "http") {
			return nil, errors.New("irrelevant HTTP option")
		}
	}
	if padding := q.Get("x_padding_bytes"); padding != "" {
		if effective != "xhttp" && effective != "splithttp" {
			return nil, errors.New("XHTTP padding without XHTTP")
		}
		extra := map[string]json.RawMessage{}
		if v := q.Get("extra"); v != "" {
			if json.Unmarshal([]byte(v), &extra) != nil {
				return nil, errors.New("invalid XHTTP extra")
			}
		}
		if value := extra["xPaddingBytes"]; value != nil {
			var existing string
			if json.Unmarshal(value, &existing) != nil || existing != padding {
				return nil, errors.New("conflicting XHTTP padding")
			}
		} else {
			value, _ := json.Marshal(padding)
			extra["xPaddingBytes"] = value
		}
		value, _ := json.Marshal(extra)
		q.Set("extra", string(value))
		q.Del("x_padding_bytes")
		u.RawQuery = q.Encode()
		source = u.String()
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
	for _, k := range strings.Fields("v ps add port id aid scy net type host path tls sni alpn fp mtu tti authority mode ech pcs vcn cs fm x_padding_bytes xPaddingBytes xPaddingObfsMode xPaddingKey xPaddingHeader xPaddingPlacement xPaddingMethod uplinkHTTPMethod sessionIDPlacement sessionIDKey sessionIDTable sessionIDLength sessionPlacement sessionKey seqPlacement seqKey uplinkDataPlacement uplinkDataKey scMaxEachPostBytes scMinPostsIntervalMs uplinkChunkSize noGRPCHeader xmux downloadSettings headers") {
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
	for _, pair := range [][2]string{{"net", "type"}, {"scy", "encryption"}, {"host", "host"}, {"path", "path"}, {"sni", "sni"}, {"alpn", "alpn"}, {"fp", "fp"}, {"ech", "ech"}, {"pcs", "pcs"}, {"vcn", "vcn"}, {"cs", "cs"}, {"authority", "authority"}, {"mode", "mode"}, {"mtu", "mtu"}, {"tti", "tti"}} {
		if v := get(pair[0]); v != "" {
			key := pair[1]
			if key == "path" && (get("net") == "kcp" || get("net") == "mkcp") {
				key = "seed"
			}
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
		if get("net") == "grpc" || get("net") == "gun" {
			q.Set("mode", v)
		} else {
			q.Set("headerType", v)
		}
	}
	if value := m["fm"]; len(value) > 0 {
		q.Set("fm", string(value))
	}
	if get("net") == "xhttp" {
		extra := map[string]json.RawMessage{}
		for k, v := range m {
			switch k {
			case "v", "ps", "add", "port", "id", "aid", "scy", "net", "type", "host", "path", "tls", "sni", "alpn", "fp", "authority", "mode", "ech", "pcs", "vcn", "cs", "fm":
			default:
				if k == "x_padding_bytes" {
					k = "xPaddingBytes"
				}
				extra[k] = v
			}
		}
		if len(extra) > 0 {
			b, _ := json.Marshal(extra)
			q.Set("extra", string(b))
		}
	}
	if v := get("tls"); v != "" && v != "none" {
		q.Set("security", v)
	}
	u.RawQuery = q.Encode()
	return u.String(), nil
}

func networkForQuery(q url.Values) string { return q.Get("type") }
