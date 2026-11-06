// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
)

type wgPeer struct {
	Key, PSK, Endpoint string
	Allowed            []string
	Keepalive          string
}
type wgConfig struct {
	Private                string
	Addresses, DNS, Routes []string
	Peers                  []wgPeer
	Amnezia                map[string]string
	MTU                    int
}

func wgKey(value string) (string, error) {
	b, e := base64.StdEncoding.DecodeString(value)
	if e != nil || len(b) != 32 {
		return "", errors.New("WireGuard key must be 32-byte base64")
	}
	return hex.EncodeToString(b), nil
}
func parseWG(source string) (wgConfig, error) {
	c := wgConfig{MTU: 1280, Amnezia: map[string]string{}}
	section := ""
	seen := map[string]bool{}
	scanner := bufio.NewScanner(strings.NewReader(source))
	scanner.Buffer(make([]byte, 4096), 65536)
	awg := map[string]bool{}
	for _, k := range strings.Fields("jc jmin jmax s1 s2 s3 s4 h1 h2 h3 h4 i1 i2 i3 i4 i5 header_protection_key content_padding_addition rekey_after_time rekey_timeout reject_after_time keepalive_timeout max_handshake_attempts random_trailers disable_cookies") {
		awg[k] = true
	}
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			if line != "[Interface]" && line != "[Peer]" {
				return c, errors.New("unsupported conf section")
			}
			if line == "[Interface]" && section != "" {
				return c, errors.New("duplicate Interface")
			}
			section = line
			seen = map[string]bool{}
			if section == "[Peer]" {
				c.Peers = append(c.Peers, wgPeer{})
				if len(c.Peers) > 16 {
					return c, errors.New("too many peers")
				}
			}
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		key = strings.ToLower(strings.TrimSpace(key))
		aliases := map[string]string{"headerprotectionkey": "header_protection_key", "contentpaddingaddition": "content_padding_addition", "rekeyaftertime": "rekey_after_time", "rekeytimeout": "rekey_timeout", "rejectaftertime": "reject_after_time", "keepalivetimeout": "keepalive_timeout", "maxhandshakeattempts": "max_handshake_attempts", "randomtrailers": "random_trailers", "disablecookies": "disable_cookies"}
		if canonical, ok := aliases[key]; ok {
			key = canonical
		}
		value = strings.TrimSpace(value)
		if !ok || section == "" || seen[key] || len(value) > 4096 {
			return c, errors.New("invalid or duplicate conf key")
		}
		seen[key] = true
		if section == "[Interface]" {
			switch key {
			case "privatekey":
				var e error
				c.Private, e = wgKey(value)
				if e != nil {
					return c, e
				}
			case "address":
				for _, s := range strings.Split(value, ",") {
					p, e := netip.ParsePrefix(strings.TrimSpace(s))
					if e != nil {
						return c, errors.New("invalid interface address")
					}
					c.Addresses = append(c.Addresses, p.String())
				}
			case "dns":
				for _, s := range strings.Split(value, ",") {
					a, e := netip.ParseAddr(strings.TrimSpace(s))
					if e != nil {
						return c, errors.New("DNS must be an IP address")
					}
					c.DNS = append(c.DNS, a.String())
				}
			case "mtu":
				n, e := strconv.Atoi(value)
				if e != nil || n < 1280 || n > 9000 {
					return c, errors.New("invalid MTU")
				}
				c.MTU = n
			default:
				if !awg[key] {
					return c, errors.New("unsupported conf option; scripts are not executed")
				}
				if strings.ContainsAny(value, "\r\n\x00") {
					return c, errors.New("invalid Amnezia parameter")
				}
				if key == "random_trailers" || key == "disable_cookies" {
					switch strings.ToLower(value) {
					case "on":
						value = "true"
					case "off":
						value = "false"
					}
					if _, err := strconv.ParseBool(value); err != nil {
						return c, errors.New("invalid AWG boolean")
					}
				}
				if key == "header_protection_key" {
					if raw, e := hex.DecodeString(value); e == nil && len(raw) == 32 {
						value = hex.EncodeToString(raw)
					} else {
						var e error
						value, e = wgKey(value)
						if e != nil {
							return c, errors.New("invalid AWG header protection key")
						}
					}
				}
				c.Amnezia[key] = value
			}
		} else {
			p := &c.Peers[len(c.Peers)-1]
			switch key {
			case "publickey":
				var e error
				p.Key, e = wgKey(value)
				if e != nil {
					return c, e
				}
			case "presharedkey":
				var e error
				p.PSK, e = wgKey(value)
				if e != nil {
					return c, e
				}
			case "endpoint":
				host, port, e := net.SplitHostPort(value)
				n, _ := strconv.Atoi(port)
				if e != nil || host == "" || n < 1 || n > 65535 {
					return c, errors.New("invalid WireGuard endpoint")
				}
				p.Endpoint = value
			case "allowedips":
				for _, s := range strings.Split(value, ",") {
					a, e := netip.ParsePrefix(strings.TrimSpace(s))
					if e != nil {
						return c, errors.New("invalid AllowedIPs")
					}
					p.Allowed = append(p.Allowed, a.Masked().String())
					c.Routes = append(c.Routes, a.Masked().String())
				}
			case "persistentkeepalive":
				parts := strings.Split(value, "-")
				if len(parts) > 2 {
					return c, errors.New("invalid keepalive")
				}
				previous := -1
				for _, part := range parts {
					n, e := strconv.Atoi(part)
					if e != nil || n < 0 || n > 65535 || n < previous {
						return c, errors.New("invalid keepalive")
					}
					previous = n
				}
				p.Keepalive = value
			default:
				return c, errors.New("unsupported peer option")
			}
		}
	}
	if scanner.Err() != nil || c.Private == "" || len(c.Addresses) == 0 || len(c.Peers) == 0 {
		return c, errors.New("incomplete WireGuard profile")
	}
	for _, p := range c.Peers {
		if p.Key == "" || p.Endpoint == "" || len(p.Allowed) == 0 {
			return c, errors.New("incomplete WireGuard peer")
		}
	}
	family := map[bool]bool{}
	for _, value := range c.Addresses {
		p, _ := netip.ParsePrefix(value)
		family[p.Addr().Is6()] = true
	}
	prefixes := []netip.Prefix{}
	for _, value := range c.Routes {
		p, _ := netip.ParsePrefix(value)
		if !family[p.Addr().Is6()] {
			continue
		}
		prefixes = append(prefixes, p)
	}
	c.Routes = nil
	for _, p := range prefixes {
		c.Routes = append(c.Routes, p.String())
	}
	if len(c.Routes) == 0 {
		return c, errors.New("no routes for configured interface family")
	}
	if len(c.DNS) == 0 {
		c.DNS = []string{"1.1.1.1"}
	}
	for _, value := range c.DNS {
		a, _ := netip.ParseAddr(value)
		covered := false
		for _, p := range prefixes {
			if p.Contains(a) {
				covered = true
				break
			}
		}
		if !covered || !family[a.Is6()] {
			return c, errors.New("DNS must be covered by AllowedIPs and an interface family")
		}
	}
	for k, v := range c.Amnezia {
		limit := uint64(0)
		if k == "jc" {
			limit = 128
		}
		if k == "jmin" || k == "jmax" || k == "s1" || k == "s2" || k == "s3" || k == "s4" {
			limit = 1280
		}
		if limit > 0 {
			n, e := strconv.ParseUint(v, 10, 32)
			if e != nil || n > limit {
				return c, errors.New("Amnezia padding/count exceeds mobile limit")
			}
		}
	}
	if c.Amnezia["jmin"] != "" && c.Amnezia["jmax"] != "" {
		a, _ := strconv.Atoi(c.Amnezia["jmin"])
		b, _ := strconv.Atoi(c.Amnezia["jmax"])
		if a > b {
			return c, errors.New("invalid Amnezia junk size range")
		}
	}

	return c, nil
}
func (c wgConfig) uapi() (string, error) {
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\nreplace_peers=true\n", c.Private)
	for k, v := range c.Amnezia {
		fmt.Fprintf(&b, "%s=%s\n", k, v)
	}
	for _, p := range c.Peers {
		host, port, _ := net.SplitHostPort(p.Endpoint)
		ip, e := resolveEndpoint(host)
		if e != nil {
			return "", e
		}
		fmt.Fprintf(&b, "public_key=%s\nendpoint=%s\nreplace_allowed_ips=true\npersistent_keepalive_interval=%s\n", p.Key, net.JoinHostPort(ip, port), keepalive(p.Keepalive))
		if p.PSK != "" {
			fmt.Fprintf(&b, "preshared_key=%s\n", p.PSK)
		}
		for _, a := range p.Allowed {
			fmt.Fprintf(&b, "allowed_ip=%s\n", a)
		}
	}
	return b.String(), nil
}

func keepalive(s string) string {
	if s == "" {
		return "0"
	}
	return s
}
