// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
	"errors"
	_ "github.com/xtls/xray-core/app/router"
	_ "github.com/xtls/xray-core/proxy/dns"
)

// DNS wire messages stay inside the chosen proxy, using TCP to avoid UDP retries.
// Xray/VK advertise IPv4 only; AAAA gets an empty response, not a stalled route.
func withProxyDNS(raw []byte) ([]byte, error) {
	var c map[string]any
	if json.Unmarshal(raw, &c) != nil {
		return nil, errors.New("invalid engine configuration")
	}
	out, ok := c["outbounds"].([]any)
	if !ok || len(out) != 1 {
		return nil, errors.New("one proxy outbound required")
	}
	p, ok := out[0].(map[string]any)
	if !ok || p["tag"] != "proxy" {
		return nil, errors.New("proxy tag required")
	}
	c["outbounds"] = append(out, map[string]any{"tag": "dns-tcp", "protocol": "dns", "settings": map[string]any{"network": "tcp", "rules": []any{map[string]any{"qType": "28", "action": "return"}, map[string]any{"action": "direct"}}}, "streamSettings": map[string]any{"sockopt": map[string]any{"dialerProxy": "proxy"}}})
	c["routing"] = map[string]any{"domainStrategy": "AsIs", "rules": []any{map[string]any{"type": "field", "network": "tcp,udp", "port": "53", "outboundTag": "dns-tcp"}}}
	return json.Marshal(c)
}
