// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/remzone/blink_ios/native/share"
	_ "github.com/xtls/xray-core/proxy/hysteria"
	_ "github.com/xtls/xray-core/proxy/shadowsocks"
	_ "github.com/xtls/xray-core/proxy/shadowsocks_2022"
	_ "github.com/xtls/xray-core/proxy/socks"
	_ "github.com/xtls/xray-core/proxy/trojan"
	_ "github.com/xtls/xray-core/proxy/vmess/outbound"
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	_ "github.com/xtls/xray-core/transport/internet/httpupgrade"
	_ "github.com/xtls/xray-core/transport/internet/hysteria"
	_ "github.com/xtls/xray-core/transport/internet/kcp"
	_ "github.com/xtls/xray-core/transport/internet/websocket"
	"net"
	"strings"
	"time"
)

// ImportedProfile contains secrets. Only store it in platform encrypted storage.
type ImportedProfile struct {
	Schema    string   `json:"schema"`
	Kind      string   `json:"kind"`
	Name      string   `json:"name"`
	Source    string   `json:"source"`
	Addresses []string `json:"addresses"`
	DNS       []string `json:"dns"`
	Routes    []string `json:"routes"`
	MTU       int      `json:"mtu"`
}

func importProfile(source string) (ImportedProfile, error) {
	source = strings.TrimSpace(strings.TrimPrefix(source, "\ufeff"))
	p := ImportedProfile{Schema: "blink.profile.v1", Source: source, Addresses: []string{"10.77.0.2/32"}, DNS: []string{"1.1.1.1"}, Routes: []string{"0.0.0.0/0"}, MTU: 1280}
	if len(source) == 0 || len(source) > 65536 {
		return p, errors.New("profile exceeds size limit")
	}
	if strings.Contains(source, "[Interface]") {
		w, e := parseWG(source)
		if e != nil {
			return p, e
		}
		p.Kind = "wireguard"
		if len(w.Amnezia) > 0 {
			p.Kind = "amneziawg"
		}
		p.Name = p.Kind
		p.Addresses = w.Addresses
		p.DNS = w.DNS
		p.Routes = w.Routes
		p.MTU = w.MTU
		return p, nil
	}
	o, e := share.ParseSingle(source)
	if e != nil {
		return p, e
	}
	p.Kind = "xray"
	p.Name = share.DisplayName(source, strings.ToUpper(o.Protocol))
	return p, nil
}

// ImportProfile validates one URI or WireGuard/AmneziaWG .conf without connecting.
func ImportProfile(source string) (string, error) {
	p, e := importProfile(source)
	if e != nil {
		return "", e
	}
	b, e := json.Marshal(p)
	return string(b), e
}

// ImportProfiles accepts a bounded plain/base64 URI subscription or one .conf.
// Every rejected node has a credential-free reason rather than disappearing.
func ImportProfiles(source string) (string, error) {
	if len(source) > 131072 {
		return "", errors.New("subscription exceeds size limit")
	}
	source = strings.TrimSpace(source)
	if !strings.Contains(source, "://") && !strings.Contains(source, "[Interface]") {
		var b []byte
		var e error
		for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
			b, e = enc.DecodeString(strings.Join(strings.Fields(source), ""))
			if e == nil {
				break
			}
		}
		if e != nil || len(b) > 131072 {
			return "", errors.New("invalid subscription encoding")
		}
		source = string(b)
	}
	lines := strings.Split(source, "\n")
	if strings.Contains(source, "[Interface]") {
		lines = []string{source}
	}
	if len(lines) > 256 {
		return "", errors.New("too many subscription nodes")
	}
	profiles := []ImportedProfile{}
	rejected := []map[string]any{}
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p, e := importProfile(line)
		if e != nil {
			rejected = append(rejected, map[string]any{"index": i + 1, "reason": "Unsupported or invalid protocol/settings"})
		} else {
			profiles = append(profiles, p)
		}
	}
	if len(profiles) == 0 {
		return "", errors.New("no supported profiles; check protocol and parameters")
	}
	b, e := json.Marshal(map[string]any{"profiles": profiles, "rejected": rejected})
	return string(b), e
}
func decodeImported(raw string) (ImportedProfile, error) {
	var p ImportedProfile
	if len(raw) > 100000 || json.Unmarshal([]byte(raw), &p) != nil || p.Schema != "blink.profile.v1" {
		return p, errors.New("invalid saved profile")
	}
	return importProfile(p.Source)
}

// StartProfile connects directly, without VK/TURN credentials or CAPTCHA.
func StartProfile(raw string, sink PacketWriter, protector Protector) (*Engine, error) {
	p, e := decodeImported(raw)
	if e != nil {
		return nil, e
	}
	if p.Kind != "xray" {
		return startWireGuard(p, sink, protector)
	}
	o, e := share.ParseSingle(p.Source)
	if e != nil {
		return nil, e
	}
	var settings map[string]any
	if o.Settings == nil || json.Unmarshal(*o.Settings, &settings) != nil {
		return nil, errors.New("invalid proxy settings")
	}
	host, _ := settings["address"].(string)
	if host == "" {
		return nil, errors.New("missing proxy endpoint")
	}
	ip, e := resolveEndpoint(host)
	if e != nil {
		return nil, e
	}
	settings["address"] = ip
	encoded, _ := json.Marshal(settings)
	msg := json.RawMessage(encoded)
	o.Settings = &msg
	o.Tag = "proxy"
	cfg, e := json.Marshal(map[string]any{"log": map[string]any{"loglevel": "none"}, "inbounds": []any{}, "outbounds": []any{o}})
	if e != nil {
		return nil, errors.New("invalid proxy configuration")
	}
	return startConfig(cfg, sink, protector)
}
func resolveEndpoint(host string) (string, error) {
	if net.ParseIP(host) != nil {
		return host, nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	ips, e := net.DefaultResolver.LookupIPAddr(ctx, host)
	if e != nil || len(ips) == 0 {
		return "", errors.New("endpoint DNS resolution failed")
	}
	for _, a := range ips {
		if a.IP.To4() != nil {
			return a.IP.String(), nil
		}
	}
	return ips[0].IP.String(), nil
}
