// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"time"

	"github.com/remzone/blink_ios/native/vkturn"
)

type VKProfile struct {
	Routing       *RoutingPolicy `json:"routing,omitempty"`
	Backend       string         `json:"backend"`
	Protocol      string         `json:"protocol"`
	WrapKey       string         `json:"wrapKey"`
	WireGuard     string         `json:"wireguard"`
	TURNServer    string         `json:"turnServer"`
	Tuning        vkturn.Tuning  `json:"tuning"`
	Bootstrap     string         `json:"bootstrap,omitempty"`
	TURNTransport string         `json:"turnTransport"`
	DNSServer     string         `json:"dnsServer"`
	ManualCaptcha bool           `json:"manualCaptcha"`
	Mode          string         `json:"mode"`
	UUID          string         `json:"uuid"`
	PeerHost      string         `json:"peerHost"`
	PeerPort      int            `json:"peerPort"`
	VKCallURL     string         `json:"vkCallURL"`
	Streams       int            `json:"streams"`
	ExpiresAt     int64          `json:"expiresAt"`
}

// StartVK uses the same KCP/smux/TURN wire protocol as the pinned server.
// Engine start is not evidence of transport readiness; inspect Status.
func StartVK(profileJSON string, sink PacketWriter, protector Protector) (*Engine, error) {
	if len(profileJSON) > 1572864 || sink == nil || protector == nil {
		return nil, errors.New("invalid VK profile")
	}
	var p VKProfile
	d := json.NewDecoder(strings.NewReader(profileJSON))
	d.DisallowUnknownFields()
	if err := d.Decode(&p); err != nil {
		return nil, errors.New("invalid VK profile")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, errors.New("trailing VK profile data")
	}
	if p.Mode != "" && p.Mode != "vk" && p.Mode != "direct" {
		return nil, errors.New("invalid tunnel mode")
	}
	if p.Routing != nil {
		if e := p.Routing.Validate(); e != nil {
			return nil, e
		}
		if p.Routing.Mode == "all" {
			p.Routing = nil
		}
	}
	now := time.Now().Unix()
	if !validUUID(p.UUID) || p.ExpiresAt <= now || p.ExpiresAt > 253402300799 {
		return nil, errors.New("invalid or expired subscription")
	}
	if p.Backend == "" {
		p.Backend = "vless"
	}
	if p.Protocol == "" {
		p.Protocol = "kcp"
	}
	if p.Backend == "vless" {
		if p.Protocol != "kcp" || p.WireGuard != "" {
			return nil, errors.New("VLESS requires KCP/smux")
		}
	} else if p.Backend == "wireguard" {
		if p.Protocol != "dtls" && p.Protocol != "srtp" && p.Protocol != "wrap" {
			return nil, errors.New("unsupported WireGuard transport")
		}
		if _, err := vkWireGuardConfig(p.WireGuard, "127.0.0.1:1"); err != nil {
			return nil, err
		}
	} else {
		return nil, errors.New("unsupported VK payload backend")
	}
	transport, err := vkturn.Start(context.Background(), vkturn.Config{Protocol: p.Protocol, WrapKey: p.WrapKey, TURNServer: p.TURNServer, Tuning: p.Tuning, Bootstrap: p.Bootstrap, PeerHost: p.PeerHost, PeerPort: p.PeerPort, VKCallURL: p.VKCallURL, Streams: p.Streams, DNSServer: p.DNSServer, Direct: p.Mode == "direct", ManualCaptcha: p.ManualCaptcha, TURNTransport: p.TURNTransport}, func(fd uintptr) bool { return protector.Protect(int64(fd)) })
	if err != nil {
		return nil, errors.New("VK transport initialization failed")
	}
	host, portString, err := net.SplitHostPort(transport.Addr())
	if err != nil {
		_ = transport.Close()
		return nil, errors.New("invalid local transport address")
	}
	port, err := strconv.Atoi(portString)
	if err != nil {
		_ = transport.Close()
		return nil, errors.New("invalid local transport port")
	}
	raw, _ := json.Marshal(Connection{Address: host, Port: port, UUID: p.UUID, Network: "tcp", Security: "none"})
	var e *Engine
	if p.Backend == "wireguard" {
		profile, parseErr := vkWireGuardConfig(p.WireGuard, transport.Addr())
		if parseErr != nil {
			_ = transport.Close()
			return nil, parseErr
		}
		if p.Routing != nil {
			e, err = routedWireGuard(profile, p.Routing, sink, protector)
		} else {
			e, err = startWireGuard(profile, sink, protector)
		}
	} else {
		cfg, buildErr := buildConfig(string(raw))
		if buildErr != nil {
			_ = transport.Close()
			return nil, buildErr
		}
		e, err = startRoutedConfig(cfg, p.Routing, sink, protector)
	}
	if err != nil {
		_ = transport.Close()
		return nil, err
	}
	e.mu.Lock()
	e.vkTransport = transport
	e.expiry = time.AfterFunc(time.Until(time.Unix(p.ExpiresAt, 0)), func() { e.Stop() })
	e.mu.Unlock()
	return e, nil
}

func (e *Engine) Status() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stack == nil {
		return "stopped"
	}
	if e.vkTransport != nil {
		return e.vkTransport.Status()
	}
	return "running"
}

// CaptchaJSON is a private UI API; do not expose it to launcher providers or logs.
func (e *Engine) CaptchaJSON() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.vkTransport == nil {
		return "{}"
	}
	return e.vkTransport.CaptchaJSON()
}
func (e *Engine) SubmitCaptcha(id, kind, value string) bool {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.vkTransport == nil {
		return false
	}
	return e.vkTransport.SubmitCaptcha(id, kind, value)
}

// ExportVKBootstrap is secret, memory-only data for an iOS app->extension handoff.
// It expires within 90 seconds and must only enter shared Keychain, never logs.
func (e *Engine) ExportVKBootstrap() string {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.vkTransport == nil {
		return ""
	}
	return e.vkTransport.ExportBootstrap()
}
