// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"github.com/remzone/blink_ios/native/share"
	_ "github.com/xtls/xray-core/app/dns"
	_ "github.com/xtls/xray-core/app/observatory"
	_ "github.com/xtls/xray-core/app/observatory/burst"
	_ "github.com/xtls/xray-core/app/stats"
	_ "github.com/xtls/xray-core/proxy/blackhole"
	_ "github.com/xtls/xray-core/proxy/freedom"
	_ "github.com/xtls/xray-core/proxy/http"
	_ "github.com/xtls/xray-core/proxy/hysteria"
	_ "github.com/xtls/xray-core/proxy/loopback"
	_ "github.com/xtls/xray-core/proxy/masque"
	_ "github.com/xtls/xray-core/proxy/shadowsocks"
	_ "github.com/xtls/xray-core/proxy/shadowsocks_2022"
	_ "github.com/xtls/xray-core/proxy/socks"
	_ "github.com/xtls/xray-core/proxy/trojan"
	_ "github.com/xtls/xray-core/proxy/vmess/outbound"
	_ "github.com/xtls/xray-core/proxy/wireguard"
	_ "github.com/xtls/xray-core/transport/internet/grpc"
	_ "github.com/xtls/xray-core/transport/internet/httpupgrade"
	_ "github.com/xtls/xray-core/transport/internet/hysteria"
	_ "github.com/xtls/xray-core/transport/internet/kcp"
	_ "github.com/xtls/xray-core/transport/internet/masque"
	_ "github.com/xtls/xray-core/transport/internet/websocket"
	_ "github.com/xtls/xray-core/transport/internet/xdrive"
	"net"
	"net/url"
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
	original := source
	normalized, label, err := unwrapWG(source)
	if err != nil {
		return ImportedProfile{}, err
	}
	source = normalized
	p := ImportedProfile{Schema: "blink.profile.v1", Source: original, Addresses: []string{"10.77.0.2/32"}, DNS: []string{"1.1.1.1"}, Routes: []string{"0.0.0.0/0"}, MTU: 1280}
	if len(source) == 0 || len(source) > 1048576 {
		return p, errors.New("profile exceeds size limit")
	}
	if strings.HasPrefix(source, "tuic://") || strings.HasPrefix(source, "hysteria://") {
		if _, e := parseQUIC(source); e != nil {
			return p, e
		}
		p.Kind = "tuic"
		if strings.HasPrefix(source, "hysteria://") {
			p.Kind = "hysteria1"
		}
		p.Name = share.DisplayName(source, p.Kind)
		return p, nil
	}
	if strings.HasPrefix(source, "{") {
		if _, _, e := prepareXrayJSON(source); e != nil {
			return p, e
		}
		p.Kind = "xray-json"
		p.Name = safeProfileName(jsonLabel(source), "Xray JSON")
		return p, nil
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
		if label != "" {
			p.Name = share.DisplayName("wg://profile#"+url.PathEscape(label), p.Kind)
		} else {
			for _, line := range strings.Split(source, "\n") {
				if strings.HasPrefix(strings.TrimSpace(line), "# ") {
					p.Name = safeProfileName(strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), "# ")), p.Kind)
					break
				}
			}
		}
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
	if len(source) > 1048576 {
		return "", errors.New("subscription exceeds size limit")
	}
	source = strings.TrimSpace(source)
	clash := strings.HasPrefix(source, "proxies:") || strings.Contains(source, "\nproxies:")
	if !clash && !strings.Contains(source, "://") && !strings.Contains(source, "[Interface]") && !strings.HasPrefix(source, "{") && !strings.HasPrefix(source, "[") {
		var b []byte
		var e error
		for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
			b, e = enc.DecodeString(strings.Join(strings.Fields(source), ""))
			if e == nil {
				break
			}
		}
		if e != nil || len(b) > 1048576 {
			return "", errors.New("invalid subscription encoding")
		}
		source = string(b)
		clash = strings.HasPrefix(source, "proxies:") || strings.Contains(source, "\nproxies:")
	}
	lines := strings.Split(source, "\n")
	if clash {
		var e error
		lines, e = importClash(source)
		if e != nil {
			return "", e
		}
	}
	if strings.HasPrefix(source, "[") && !strings.HasPrefix(source, "[Interface]") {
		var entries []json.RawMessage
		if !uniqueProfileJSON([]byte(source)) || json.Unmarshal([]byte(source), &entries) != nil {
			return "", errors.New("invalid JSON subscription")
		}
		lines = nil
		for _, entry := range entries {
			lines = append(lines, string(entry))
		}
	}
	if strings.HasPrefix(source, "{") {
		lines = []string{source}
	}
	if strings.Contains(source, "[Interface]") {
		lines = []string{source}
	}
	if len(lines) > 1024 {
		return "", errors.New("too many subscription nodes")
	}
	providerHints := false
	profiles := []ImportedProfile{}
	rejected := []map[string]any{}
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		p, e := importProfile(line)
		if e != nil {
			rejected = append(rejected, map[string]any{"index": i + 1, "reason": e.Error()})
		} else {
			if u, err := url.Parse(line); err == nil {
				q := u.Query()
				providerHints = providerHints || q.Has("x-durev-block") || q.Has("x-durev-prio") || q.Has("x-durev-sni-change") || (q.Has("concurrency") && !q.Has("mux"))
			}
			profiles = append(profiles, p)
		}
	}
	if len(profiles) == 0 {
		return "", errors.New("no supported profiles; check protocol and parameters")
	}
	b, e := json.Marshal(map[string]any{"profiles": profiles, "rejected": rejected, "notice": func() string {
		if clash {
			return "Импортированы узлы Clash. Группы, правила и DNS документа не применяются; для сохранения маршрутизации используйте Xray JSON."
		}
		if providerHints {
			return "Импортированы параметры подключения. Метки группировки провайдера, автоматическая замена SNI и concurrency без явного mux не применяются."
		}
		return ""
	}()})
	return string(b), e
}
func decodeImported(raw string) (ImportedProfile, error) {
	var p ImportedProfile
	if len(raw) > 1500000 || json.Unmarshal([]byte(raw), &p) != nil || p.Schema != "blink.profile.v1" {
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
	if p.Kind == "tuic" || p.Kind == "hysteria1" {
		return startQUIC(p, sink, protector)
	}
	if p.Kind == "xray-json" {
		raw, opt, e := prepareXrayJSON(p.Source)
		if e != nil {
			return nil, e
		}
		raw, e = prepareJSONEndpoints(raw)
		if e != nil {
			return nil, e
		}
		return startConfigOptions(raw, sink, protector, opt)
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
	outbound, e := share.MarshalOutbound(o)
	if e != nil {
		return nil, errors.New("invalid proxy configuration")
	}
	cfg, e := json.Marshal(map[string]any{"log": map[string]any{"loglevel": "none"}, "inbounds": []any{}, "outbounds": []json.RawMessage{outbound}})
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

func safeProfileName(name, fallback string) string {
	u := url.URL{Scheme: "profile", Host: "name", Fragment: name}
	return share.DisplayName(u.String(), fallback)
}
