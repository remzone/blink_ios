// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"bytes"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/xtls/xray-core/app/proxyman"
	"github.com/xtls/xray-core/common/session"
	"github.com/xtls/xray-core/infra/conf"
	"github.com/xtls/xray-core/infra/conf/serial"
)

type packetOptions struct {
	Tag         string
	Idle        time.Duration
	Level       uint32
	Sniffing    session.SniffingRequest
	PreserveDNS bool
}

// Imports panel JSON without opening its desktop listeners. Packet sniffing is
// transferred explicitly into the public TUN handler context, not discarded.
func prepareXrayJSON(source string) ([]byte, packetOptions, error) {
	opt := packetOptions{Tag: "mixed", PreserveDNS: true}
	if !uniqueProfileJSON([]byte(source)) {
		return nil, opt, errors.New("invalid or duplicate JSON fields")
	}
	var c map[string]json.RawMessage
	if json.Unmarshal([]byte(source), &c) != nil || c["outbounds"] == nil {
		return nil, opt, errors.New("Xray outbounds required")
	}
	allowed := map[string]bool{}
	for _, k := range strings.Fields("remarks remark name inbounds outbounds routing dns policy stats log observatory burstObservatory fakeDns geodata") {
		allowed[k] = true
	}
	for k := range c {
		if !allowed[k] {
			return nil, opt, errors.New("unsupported Xray top-level feature")
		}
	}
	var inbound []conf.InboundDetourConfig
	if raw := c["inbounds"]; raw != nil {
		if json.Unmarshal(raw, &inbound) != nil {
			return nil, opt, errors.New("invalid inbound metadata")
		}
	}
	if len(inbound) > 16 {
		return nil, opt, errors.New("too many desktop listeners")
	}
	selected := false
	for _, ib := range inbound {
		if ib.Protocol != "socks" && ib.Protocol != "http" && ib.Protocol != "mixed" && ib.Protocol != "tun" {
			return nil, opt, errors.New("not a client JSON config")
		}
		if selected {
			continue
		}
		selected = true
		opt.Tag = ib.Tag
		if ib.Settings != nil {
			var settings struct {
				UserLevel uint32 `json:"userLevel"`
			}
			if json.Unmarshal(*ib.Settings, &settings) != nil {
				return nil, opt, errors.New("invalid inbound policy")
			}
			opt.Level = settings.UserLevel
		}
		if ib.SniffingConfig != nil {
			s, e := ib.SniffingConfig.Build()
			if e != nil {
				return nil, opt, errors.New("invalid sniffing")
			}
			opt.Sniffing, e = proxyman.BuildSniffingRequest(s)
			if e != nil {
				return nil, opt, errors.New("invalid sniffing matchers")
			}
		}
	}
	if policy := c["policy"]; policy != nil {
		var p struct {
			Levels map[string]struct {
				ConnIdle *int `json:"connIdle"`
			} `json:"levels"`
		}
		if json.Unmarshal(policy, &p) != nil {
			return nil, opt, errors.New("invalid policy")
		}
		if level, ok := p.Levels[strconv.FormatUint(uint64(opt.Level), 10)]; ok && level.ConnIdle != nil {
			if *level.ConnIdle < 0 {
				return nil, opt, errors.New("invalid idle timeout")
			}
			opt.Idle = time.Duration(*level.ConnIdle) * time.Second
		}
	}

	var outs []map[string]json.RawMessage
	if json.Unmarshal(c["outbounds"], &outs) != nil || len(outs) == 0 || len(outs) > 64 {
		return nil, opt, errors.New("invalid outbounds")
	}
	supported := map[string]bool{}
	for _, k := range strings.Fields("vless vmess trojan shadowsocks socks http hysteria masque wireguard freedom blackhole dns loopback") {
		supported[k] = true
	}
	proxy := false
	for _, out := range outs {
		var protocol string
		json.Unmarshal(out["protocol"], &protocol)
		if !supported[protocol] {
			return nil, opt, errors.New("unsupported JSON outbound protocol")
		}
		if protocol != "freedom" && protocol != "blackhole" && protocol != "dns" && protocol != "loopback" {
			proxy = true
		}
	}
	if !proxy {
		return nil, opt, errors.New("a remote proxy is required")
	}
	// Local file references, interfaces and platform socket overrides are not portable.
	var value any
	json.Unmarshal([]byte(source), &value)
	if unsafeProfileField(value) {
		return nil, opt, errors.New("external files or platform socket overrides unsupported")
	}
	c["inbounds"] = json.RawMessage("[]")
	c["log"] = json.RawMessage(`{"loglevel":"none"}`)
	for _, k := range []string{"remarks", "remark", "name"} {
		delete(c, k)
	}
	raw, e := json.Marshal(c)
	if e != nil {
		return nil, opt, e
	}
	if _, e = serial.LoadJSONConfig(bytes.NewReader(raw)); e != nil {
		return nil, opt, errors.New("Xray JSON settings rejected")
	}
	return raw, opt, nil
}
func unsafeProfileField(v any) bool {
	switch x := v.(type) {
	case map[string]any:
		for k, v := range x {
			switch k {
			case "certificateFile", "keyFile", "interface", "mark", "tcpCongestion", "tcpFastOpen", "sockopt":
				return true
			}
			if unsafeProfileField(v) {
				return true
			}
		}
	case []any:
		for _, v := range x {
			if unsafeProfileField(v) {
				return true
			}
		}
	}
	return false
}
func uniqueProfileJSON(raw []byte) bool {
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	var walk func(int) bool
	walk = func(depth int) bool {
		if depth > 48 {
			return false
		}
		t, e := d.Token()
		if e != nil {
			return false
		}
		q, ok := t.(json.Delim)
		if !ok {
			return true
		}
		seen := map[string]bool{}
		for d.More() {
			if q == '{' {
				t, e = d.Token()
				if e != nil {
					return false
				}
				k, ok := t.(string)
				if !ok || seen[k] {
					return false
				}
				seen[k] = true
			}
			if !walk(depth + 1) {
				return false
			}
		}
		_, e = d.Token()
		return e == nil
	}
	if !walk(0) {
		return false
	}
	_, e := d.Token()
	return e != nil && e.Error() == "EOF"
}
func jsonLabel(source string) string {
	var c map[string]json.RawMessage
	json.Unmarshal([]byte(source), &c)
	for _, key := range []string{"remarks", "remark", "name"} {
		var s string
		if json.Unmarshal(c[key], &s) == nil && s != "" {
			return s
		}
	}
	return "Xray JSON"
}
