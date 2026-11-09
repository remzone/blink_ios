package mobile

import (
	"encoding/json"
	"errors"
	"net/netip"
	"regexp"
	"sort"
	"strings"
)

// RoutingPolicy is data, never an executable Xray configuration.
type RoutingPolicy struct {
	Schema         string   `json:"schema"`
	Mode           string   `json:"mode"`
	Revision       int64    `json:"revision"`
	UpdatedAt      int64    `json:"updated_at"`
	Domains        []string `json:"domains"`
	IPs            []string `json:"ips"`
	ExcludeDomains []string `json:"exclude_domains,omitempty"`
	ExcludeIPs     []string `json:"exclude_ips,omitempty"`
	Sources        []string `json:"sources,omitempty"`
	SourceRevision string   `json:"source_revision,omitempty"`
}

var routeDomainLabel = regexp.MustCompile(`^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$`)

func NormalizeRoutingEntries(entries []string) ([]string, []string, error) {
	if len(entries) > 20000 {
		return nil, nil, errors.New("too many routing entries")
	}
	domains := map[string]bool{}
	ips := map[string]bool{}
	count := 0
	for _, entry := range entries {
		for _, line := range strings.Split(entry, "\n") {
			if i := strings.Index(line, "#"); i >= 0 {
				line = line[:i]
			}
			for _, v := range strings.FieldsFunc(line, func(r rune) bool { return r == ',' || r == ';' || r == ' ' || r == '\t' || r == '\r' }) {
				count++
				if count > 20000 {
					return nil, nil, errors.New("too many routing entries")
				}
				v = strings.ToLower(strings.TrimSpace(v))
				if len(v) > 253 {
					return nil, nil, errors.New("routing entry too long")
				}
				if ip, e := netip.ParseAddr(v); e == nil {
					ips[netip.PrefixFrom(ip, ip.BitLen()).String()] = true
					continue
				}
				if ip, e := netip.ParsePrefix(v); e == nil {
					if ip.Bits() == 0 {
						return nil, nil, errors.New("use all mode instead of a default route")
					}
					ips[ip.Masked().String()] = true
					continue
				}
				v = strings.TrimPrefix(strings.TrimPrefix(v, "*."), ".")
				v = strings.TrimSuffix(v, ".")
				if v == "" || v == "localhost" {
					return nil, nil, errors.New("invalid routing domain")
				}
				for _, label := range strings.Split(v, ".") {
					if !routeDomainLabel.MatchString(label) {
						return nil, nil, errors.New("enter domains or IP prefixes, without URLs or regex")
					}
				}
				domains[v] = true
			}
		}
	}
	d := make([]string, 0, len(domains))
	i := make([]string, 0, len(ips))
	for v := range domains {
		d = append(d, v)
	}
	for v := range ips {
		i = append(i, v)
	}
	sort.Strings(d)
	sort.Strings(i)
	return d, i, nil
}
func (p RoutingPolicy) Validate() error {
	if p.Schema != "blink.routing.v1" || (p.Mode != "all" && p.Mode != "selected") || p.Revision < 1 || p.Revision > 9007199254740991 || p.UpdatedAt < 0 {
		return errors.New("invalid routing policy")
	}
	if len(p.Domains)+len(p.IPs)+len(p.ExcludeDomains)+len(p.ExcludeIPs) > 20000 {
		return errors.New("too many routing rules")
	}
	for _, pair := range [][2][]string{{p.Domains, p.IPs}, {p.ExcludeDomains, p.ExcludeIPs}} {
		d, i, e := NormalizeRoutingEntries(append(append([]string{}, pair[0]...), pair[1]...))
		if e != nil {
			return e
		}
		if len(d) != len(pair[0]) || len(i) != len(pair[1]) {
			return errors.New("noncanonical or duplicate routing rules")
		}
		expected := map[string]bool{}
		for _, v := range pair[0] {
			expected[v] = true
		}
		for _, v := range d {
			if !expected[v] {
				return errors.New("noncanonical domain")
			}
		}
		expected = map[string]bool{}
		for _, v := range pair[1] {
			expected[v] = true
		}
		for _, v := range i {
			if !expected[v] {
				return errors.New("noncanonical prefix")
			}
		}
	}
	if p.Mode == "selected" && len(p.Domains)+len(p.IPs) == 0 {
		return errors.New("selected mode requires VPN destinations")
	}
	return nil
}

// Local exclusions always win over server and local inclusions.
func MergeRoutingPolicy(serverJSON, overrideJSON string) (string, error) {
	p := RoutingPolicy{Schema: "blink.routing.v1", Mode: "all", Revision: 1}
	if serverJSON != "" && serverJSON != "null" {
		if len(serverJSON) > 1048576 || json.Unmarshal([]byte(serverJSON), &p) != nil || p.Validate() != nil {
			return "", errors.New("invalid server routing policy")
		}
	}
	var local struct {
		Mode    string `json:"mode"`
		Include string `json:"include"`
		Exclude string `json:"exclude"`
	}
	if len(overrideJSON) > 131072 {
		return "", errors.New("local routing rules too large")
	}
	if overrideJSON != "" {
		if json.Unmarshal([]byte(overrideJSON), &local) != nil {
			return "", errors.New("invalid local routing settings")
		}
	}
	if local.Mode != "" && local.Mode != "inherit" {
		if local.Mode != "all" && local.Mode != "selected" {
			return "", errors.New("invalid local routing mode")
		}
		p.Mode = local.Mode
	}
	d, i, e := NormalizeRoutingEntries([]string{local.Include})
	if e != nil {
		return "", e
	}
	p.Domains = append(p.Domains, d...)
	p.IPs = append(p.IPs, i...)
	d, i, e = NormalizeRoutingEntries([]string{local.Exclude})
	if e != nil {
		return "", e
	}
	p.ExcludeDomains = append(p.ExcludeDomains, d...)
	p.ExcludeIPs = append(p.ExcludeIPs, i...)
	p.Domains, p.IPs, e = NormalizeRoutingEntries(append(p.Domains, p.IPs...))
	if e != nil {
		return "", e
	}
	p.ExcludeDomains, p.ExcludeIPs, e = NormalizeRoutingEntries(append(p.ExcludeDomains, p.ExcludeIPs...))
	if e != nil {
		return "", e
	}
	if e = p.Validate(); e != nil {
		return "", e
	}
	raw, e := json.Marshal(p)
	return string(raw), e
}
