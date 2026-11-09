package mobile

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	_ "github.com/xtls/xray-core/app/dns/fakedns"
	"github.com/xtls/xray-core/common/session"
	"net"
	"strconv"
)

func decodeRouting(raw string) (*RoutingPolicy, error) {
	if raw == "" || raw == "null" {
		return nil, nil
	}
	var p RoutingPolicy
	if len(raw) > 1048576 || json.Unmarshal([]byte(raw), &p) != nil || p.Validate() != nil {
		return nil, errors.New("invalid routing policy")
	}
	if p.Mode == "all" {
		return nil, nil
	}
	return &p, nil
}

// DNS delivers FakeIP mappings, so arbitrary TCP/UDP and ECH flows retain the
// queried hostname. Unknown IP traffic defaults to protected device networking.
func splitConfig(raw []byte, p *RoutingPolicy) ([]byte, packetOptions, error) {
	opt := packetOptions{PreserveDNS: true, Sniffing: session.SniffingRequest{Enabled: true, OverrideDestinationForProtocol: []string{"fakedns", "http", "tls", "quic"}}}
	var c map[string]any
	if json.Unmarshal(raw, &c) != nil {
		return nil, opt, errors.New("invalid split configuration")
	}
	out, ok := c["outbounds"].([]any)
	if !ok || len(out) != 1 {
		return nil, opt, errors.New("selective routing requires a single VPN outbound")
	}
	proxy, ok := out[0].(map[string]any)
	if !ok || proxy["tag"] != "proxy" {
		return nil, opt, errors.New("missing VPN outbound")
	}
	c["outbounds"] = []any{map[string]any{"tag": "blink-direct", "protocol": "freedom", "settings": map[string]any{"domainStrategy": "UseIPv4"}}, proxy, map[string]any{"tag": "blink-dns", "protocol": "dns", "settings": map[string]any{"rules": []any{map[string]any{"qType": "28", "action": "return"}, map[string]any{"action": "hijack"}}}}}
	c["fakedns"] = []any{map[string]any{"ipPool": "198.18.0.0/15", "poolSize": 8192}}
	c["dns"] = map[string]any{"servers": []any{"fakedns", "tcp://1.1.1.1"}, "queryStrategy": "UseIPv4", "tag": "blink-real-dns"}
	rules := []any{map[string]any{"type": "field", "inboundTag": []string{"blink-real-dns"}, "outboundTag": "blink-direct"}, map[string]any{"type": "field", "port": "53", "network": "tcp,udp", "outboundTag": "blink-dns"}}
	add := func(values []string, field, tag string) {
		if len(values) == 0 {
			return
		}
		rules = append(rules, map[string]any{"type": "field", field: values, "outboundTag": tag})
	}
	domains := func(items []string) []string {
		v := make([]string, len(items))
		for i, s := range items {
			v[i] = "domain:" + s
		}
		return v
	}
	add(domains(p.ExcludeDomains), "domain", "blink-direct")
	add(p.ExcludeIPs, "ip", "blink-direct")
	add(domains(p.Domains), "domain", "proxy")
	add(p.IPs, "ip", "proxy")
	// A stale/unknown fake address must never escape to an Internet socket.
	c["outbounds"] = append(c["outbounds"].([]any), map[string]any{"tag": "blink-unmapped", "protocol": "blackhole"})
	add([]string{"198.18.0.0/15"}, "ip", "blink-unmapped")
	c["routing"] = map[string]any{"domainStrategy": "IPIfNonMatch", "domainMatcher": "hybrid", "rules": rules}
	b, e := json.Marshal(c)
	return b, opt, e
}
func startRoutedConfig(raw []byte, p *RoutingPolicy, sink PacketWriter, protector Protector) (*Engine, error) {
	if p == nil {
		return startConfig(raw, sink, protector)
	}
	cfg, opt, e := splitConfig(raw, p)
	if e != nil {
		return nil, e
	}
	return startConfigOptions(cfg, sink, protector, opt)
}
func routedWireGuard(p ImportedProfile, policy *RoutingPolicy, sink PacketWriter, protector Protector) (*Engine, error) {
	source, _, e := unwrapWG(p.Source)
	if e != nil {
		return nil, e
	}
	c, e := parseWG(source)
	if e != nil {
		return nil, e
	}
	if len(c.Amnezia) > 0 {
		return nil, errors.New("selective routing does not support AmneziaWG extensions; use full VPN")
	}
	key := func(s string) string { b, _ := hex.DecodeString(s); return base64.StdEncoding.EncodeToString(b) }
	peers := []any{}
	for _, peer := range c.Peers {
		host, port, e := net.SplitHostPort(peer.Endpoint)
		if e != nil {
			return nil, e
		}
		ip, e := resolveEndpoint(host)
		if e != nil {
			return nil, e
		}
		keepalive, _ := strconv.Atoi(peer.Keepalive)
		peers = append(peers, map[string]any{"publicKey": key(peer.Key), "preSharedKey": key(peer.PSK), "endpoint": net.JoinHostPort(ip, port), "allowedIPs": peer.Allowed, "keepAlive": keepalive})
	}
	cfg, _ := json.Marshal(map[string]any{"log": map[string]any{"loglevel": "none"}, "inbounds": []any{}, "outbounds": []any{map[string]any{"tag": "proxy", "protocol": "wireguard", "settings": map[string]any{"secretKey": key(c.Private), "address": c.Addresses, "peers": peers, "mtu": c.MTU, "noKernelTun": true, "remoteDNS": []string{"1.1.1.1"}}}}})
	return startRoutedConfig(cfg, policy, sink, protector)
}
