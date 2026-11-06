// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/json"
	"errors"
	"net"
	"strings"
)

// Resolve remote dial endpoints before installing TUN; keep original TLS names.
func prepareJSONEndpoints(raw []byte) ([]byte, error) {
	var c map[string]any
	if json.Unmarshal(raw, &c) != nil {
		return nil, errors.New("invalid JSON")
	}
	outs, _ := c["outbounds"].([]any)
	for _, entry := range outs {
		o, _ := entry.(map[string]any)
		s, _ := o["settings"].(map[string]any)
		stream, _ := o["streamSettings"].(map[string]any)
		var endpoints []map[string]any
		if s != nil {
			if _, ok := s["address"].(string); ok {
				endpoints = append(endpoints, s)
			}
			for _, k := range []string{"servers", "vnext"} {
				if a, ok := s[k].([]any); ok {
					for _, v := range a {
						if m, ok := v.(map[string]any); ok {
							endpoints = append(endpoints, m)
						}
					}
				}
			}
		}
		for _, server := range endpoints {
			host, _ := server["address"].(string)
			if host == "" || net.ParseIP(host) != nil {
				continue
			}
			ip, e := resolveEndpoint(host)
			if e != nil {
				return nil, e
			}
			if stream != nil {
				tlsSettings, _ := stream["tlsSettings"].(map[string]any)
				if tlsSettings == nil && stream["security"] == "tls" {
					tlsSettings = map[string]any{}
					stream["tlsSettings"] = tlsSettings
				}
				if tlsSettings != nil {
					if name, _ := tlsSettings["serverName"].(string); name == "" {
						tlsSettings["serverName"] = host
					}
				}
			}
			server["address"] = ip
		}
		// Xray's WireGuard peer bind uses internet.DialSystem (the registered protector).
		if s != nil {
			if peers, ok := s["peers"].([]any); ok {
				for _, v := range peers {
					peer, _ := v.(map[string]any)
					ep, _ := peer["endpoint"].(string)
					if ep != "" {
						host, port, e := net.SplitHostPort(ep)
						if e != nil {
							return nil, errors.New("invalid peer endpoint")
						}
						ip, e := resolveEndpoint(strings.Trim(host, "[]"))
						if e != nil {
							return nil, e
						}
						peer["endpoint"] = net.JoinHostPort(ip, port)
					}
				}
			}
		}
	}
	return json.Marshal(c)
}
