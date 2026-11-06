// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
	"errors"
	"fmt"
	"gopkg.in/yaml.v3"
	"net/url"
	"strconv"
	"strings"
)

// Clash documents import named nodes. Rule/provider execution is intentionally
// not emulated; the caller receives an explicit notice instead of silent loss.
func importClash(source string) ([]string, error) {
	var node yaml.Node
	if yaml.Unmarshal([]byte(source), &node) != nil {
		return nil, errors.New("invalid YAML")
	}
	count := 0
	var bounded func(*yaml.Node, int) bool
	bounded = func(n *yaml.Node, d int) bool {
		count++
		if count > 100000 || d > 32 || n.Kind == yaml.AliasNode {
			return false
		}
		for _, child := range n.Content {
			if !bounded(child, d+1) {
				return false
			}
		}
		return true
	}
	if !bounded(&node, 0) {
		return nil, errors.New("YAML aliases or depth unsupported")
	}
	var doc struct {
		Proxies []map[string]any `yaml:"proxies"`
	}
	if node.Decode(&doc) != nil || len(doc.Proxies) == 0 || len(doc.Proxies) > 1024 {
		return nil, errors.New("Clash proxies required")
	}
	out := make([]string, 0, len(doc.Proxies))
	for _, proxy := range doc.Proxies {
		s, e := clashNode(proxy)
		if e != nil {
			out = append(out, "unsupported-clash://node")
		} else {
			out = append(out, s)
		}
	}
	return out, nil
}
func clashString(m map[string]any, k string) string {
	v := m[k]
	if v == nil {
		return ""
	}
	return fmt.Sprint(v)
}
func clashList(v any) []string {
	switch x := v.(type) {
	case string:
		return strings.Split(x, ",")
	case []any:
		r := []string{}
		for _, v := range x {
			r = append(r, fmt.Sprint(v))
		}
		return r
	default:
		return nil
	}
}
func clashNode(p map[string]any) (string, error) {
	allowed := map[string]bool{}
	for _, k := range strings.Fields("name type server port uuid password cipher security alterId flow encryption network tls servername sni alpn client-fingerprint skip-cert-verify reality-opts ws-opts grpc-opts http-opts h2-opts http-upgrade-opts xhttp-opts udp packet-encoding ip ipv6 private-key public-key pre-shared-key allowed-ips reserved dns mtu persistent-keepalive amnezia-wg-option token congestion-controller udp-relay-mode reduce-rtt disable-sni obfs obfs-password ports hop-interval up down auth auth-str protocol auth_str fast-open username") {
		allowed[k] = true
	}
	for k := range p {
		if !allowed[k] {
			return "", errors.New("unsupported Clash node field")
		}
	}
	kind := clashString(p, "type")
	host := clashString(p, "server")
	port, e := strconv.Atoi(clashString(p, "port"))
	if e != nil || port < 1 || port > 65535 || host == "" {
		return "", errors.New("invalid Clash endpoint")
	}
	if p["skip-cert-verify"] == true || p["disable-sni"] == true || p["reduce-rtt"] == true || p["fast-open"] == true || p["udp"] == false {
		return "", errors.New("unsupported TLS bypass or early data")
	}
	for _, k := range []string{"packet-encoding", "token"} {
		if clashString(p, k) != "" {
			return "", errors.New("unsupported Clash extension")
		}
	}
	for key, allowed := range map[string]string{"ws-opts": "path headers", "grpc-opts": "grpc-service-name", "reality-opts": "public-key short-id"} {
		if value, ok := p[key].(map[string]any); ok {
			for k := range value {
				if !strings.Contains(" "+allowed+" ", " "+k+" ") {
					return "", errors.New("unsupported nested Clash option")
				}
			}
		}
	}
	if kind != "vless" && clashString(p, "flow") != "" {
		return "", errors.New("flow requires VLESS")
	}
	if protocol := clashString(p, "protocol"); protocol != "" && protocol != "udp" {
		return "", errors.New("only UDP Hysteria transport supported")
	}
	name := clashString(p, "name")
	sni := clashString(p, "servername")
	if sni == "" {
		sni = clashString(p, "sni")
	}
	if sni == "" {
		sni = host
	}
	if kind == "wireguard" {
		address := []string{}
		for _, k := range []string{"ip", "ipv6"} {
			v := clashString(p, k)
			if v != "" {
				if !strings.Contains(v, "/") {
					if k == "ipv6" {
						v += "/128"
					} else {
						v += "/32"
					}
				}
				address = append(address, v)
			}
		}
		routes := clashList(p["allowed-ips"])
		if len(routes) == 0 {
			routes = []string{"0.0.0.0/0"}
			if p["ipv6"] != nil {
				routes = append(routes, "::/0")
			}
		}
		conf := "[Interface]\nPrivateKey = " + clashString(p, "private-key") + "\nAddress = " + strings.Join(address, ", ") + "\n"
		for _, pair := range [][2]string{{"dns", "DNS"}, {"mtu", "MTU"}} {
			v := clashString(p, pair[0])
			if pair[0] == "dns" {
				v = strings.Join(clashList(p["dns"]), ", ")
			}
			if v != "" {
				conf += pair[1] + " = " + v + "\n"
			}
		}
		if awg, ok := p["amnezia-wg-option"].(map[string]any); ok {
			for k, v := range awg {
				conf += k + " = " + fmt.Sprint(v) + "\n"
			}
		}
		conf += "# " + strings.ReplaceAll(name, "\n", " ") + "\n[Peer]\nPublicKey = " + clashString(p, "public-key") + "\nEndpoint = " + fmt.Sprintf("%s:%d", bracketHost(host), port) + "\nAllowedIPs = " + strings.Join(routes, ", ") + "\n"
		for _, pair := range [][2]string{{"pre-shared-key", "PresharedKey"}, {"persistent-keepalive", "PersistentKeepalive"}} {
			if v := clashString(p, pair[0]); v != "" {
				conf += pair[1] + " = " + v + "\n"
			}
		}
		if p["reserved"] != nil && fmt.Sprint(p["reserved"]) != "[0 0 0]" {
			return "", errors.New("reserved bytes unsupported")
		}
		return conf, nil
	}
	if kind == "tuic" || kind == "hysteria" {
		u := url.URL{Scheme: kind, Host: fmt.Sprintf("%s:%d", bracketHost(host), port), Fragment: name}
		if kind == "tuic" {
			u.User = url.UserPassword(clashString(p, "uuid"), clashString(p, "password"))
		} else {
			auth := clashString(p, "auth-str")
			if auth == "" {
				auth = clashString(p, "auth_str")
			}
			if auth == "" {
				auth = clashString(p, "auth")
			}
			u.User = url.User(auth)
		}
		q := url.Values{"sni": []string{sni}}
		if kind == "hysteria" {
			if obfs := clashString(p, "obfs"); obfs != "" {
				q.Set("obfs", "xplus")
				q.Set("obfsParam", obfs)
			}
		}
		if alpn := clashList(p["alpn"]); len(alpn) > 0 {
			q.Set("alpn", strings.Join(alpn, ","))
		}
		for _, pair := range [][2]string{{"congestion-controller", "congestion_control"}, {"udp-relay-mode", "udp_relay_mode"}, {"up", "upmbps"}, {"down", "downmbps"}} {
			if v := clashString(p, pair[0]); v != "" {
				q.Set(pair[1], v)
			}
		}
		u.RawQuery = q.Encode()
		return u.String(), nil
	}
	settings := map[string]any{"address": host, "port": port}
	protocol := kind
	switch kind {
	case "vless":
		settings["id"] = clashString(p, "uuid")
		settings["encryption"] = "none"
		if v := clashString(p, "encryption"); v != "" {
			settings["encryption"] = v
		}
		if v := clashString(p, "flow"); v != "" {
			settings["flow"] = v
		}
	case "vmess":
		if a := clashString(p, "alterId"); a != "" && a != "0" {
			return "", errors.New("legacy alterId unsupported")
		}
		settings["id"] = clashString(p, "uuid")
		cipher := clashString(p, "cipher")
		if cipher == "" {
			cipher = clashString(p, "security")
		}
		if cipher == "" {
			cipher = "auto"
		}
		settings["security"] = cipher
	case "trojan":
		settings["password"] = clashString(p, "password")
	case "ss":
		protocol = "shadowsocks"
		settings["method"] = clashString(p, "cipher")
		settings["password"] = clashString(p, "password")
	case "socks5":
		protocol = "socks"
		settings["user"] = clashString(p, "username")
		settings["pass"] = clashString(p, "password")
	case "http":
		settings["user"] = clashString(p, "username")
		settings["pass"] = clashString(p, "password")
	case "hysteria2":
		protocol = "hysteria"
		settings["version"] = 2
	default:
		return "", errors.New("unsupported Clash protocol")
	}
	stream := map[string]any{}
	network := clashString(p, "network")
	if network == "" {
		network = "tcp"
	}
	stream["network"] = network
	tlsOn := p["tls"] == true || kind == "trojan" || kind == "hysteria2"
	if tlsOn {
		stream["security"] = "tls"
		tls := map[string]any{"serverName": sni}
		if a := clashList(p["alpn"]); len(a) > 0 {
			tls["alpn"] = a
		}
		if fp := clashString(p, "client-fingerprint"); fp != "" {
			tls["fingerprint"] = fp
		}
		stream["tlsSettings"] = tls
	}
	if reality, ok := p["reality-opts"].(map[string]any); ok {
		stream["security"] = "reality"
		delete(stream, "tlsSettings")
		stream["realitySettings"] = map[string]any{"serverName": sni, "fingerprint": clashString(p, "client-fingerprint"), "publicKey": clashString(reality, "public-key"), "shortId": clashString(reality, "short-id")}
	}
	switch network {
	case "tcp":
		if p["http-opts"] != nil {
			return "", errors.New("Clash HTTP header options require JSON")
		}
	case "ws":
		o, _ := p["ws-opts"].(map[string]any)
		ws := map[string]any{"path": clashString(o, "path")}
		if h, ok := o["headers"].(map[string]any); ok {
			ws["headers"] = h
			ws["host"] = clashString(h, "Host")
		}
		stream["wsSettings"] = ws
	case "grpc":
		o, _ := p["grpc-opts"].(map[string]any)
		stream["grpcSettings"] = map[string]any{"serviceName": clashString(o, "grpc-service-name")}
	case "httpupgrade":
		o, _ := p["http-upgrade-opts"].(map[string]any)
		stream["httpupgradeSettings"] = o
	case "xhttp":
		o, _ := p["xhttp-opts"].(map[string]any)
		stream["xhttpSettings"] = o
	default:
		return "", errors.New("unsupported Clash network")
	}

	if kind == "hysteria2" {
		stream["network"] = "hysteria"
		stream["hysteriaSettings"] = map[string]any{"version": 2, "auth": clashString(p, "password")}
		if p["up"] != nil || p["down"] != nil {
			if p["up"] == nil || p["down"] == nil {
				return "", errors.New("both Hysteria bandwidth values required")
			}
			stream["quicParams"] = map[string]any{"congestion": "brutal", "brutalUp": clashString(p, "up") + " Mbps", "brutalDown": clashString(p, "down") + " Mbps"}
		}
		if obfs := clashString(p, "obfs"); obfs != "" {
			if obfs != "salamander" {
				return "", errors.New("unsupported obfuscation")
			}
			stream["finalmask"] = map[string]any{"udp": []any{map[string]any{"type": "salamander", "settings": map[string]any{"password": clashString(p, "obfs-password")}}}}
		}
		if p["ports"] != nil || p["hop-interval"] != nil {
			return "", errors.New("Hysteria port hopping requires native URI/JSON")
		}
	}

	out := map[string]any{"protocol": protocol, "tag": "proxy", "settings": settings, "streamSettings": stream}
	c := map[string]any{"remarks": name, "inbounds": []any{}, "outbounds": []any{out}}
	b, e := json.Marshal(c)
	return string(b), e
}
func bracketHost(host string) string {
	if strings.Contains(host, ":") {
		return "[" + strings.Trim(host, "[]") + "]"
	}
	return host
}
