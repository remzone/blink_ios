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
	DNSServer string `json:"dnsServer"`
	UUID      string `json:"uuid"`
	PeerHost  string `json:"peerHost"`
	PeerPort  int    `json:"peerPort"`
	VKCallURL string `json:"vkCallURL"`
	Streams   int    `json:"streams"`
	ExpiresAt int64  `json:"expiresAt"`
}

// StartVK uses the same KCP/smux/TURN wire protocol as the pinned server.
// Engine start is not evidence of transport readiness; inspect Status.
func StartVK(profileJSON string, sink PacketWriter, protector Protector) (*Engine, error) {
	if len(profileJSON) > 16384 || sink == nil || protector == nil {
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
	now := time.Now().Unix()
	if !validUUID(p.UUID) || p.ExpiresAt <= now || p.ExpiresAt > now+2678400 {
		return nil, errors.New("invalid or expired subscription")
	}
	transport, err := vkturn.Start(context.Background(), vkturn.Config{PeerHost: p.PeerHost, PeerPort: p.PeerPort, VKCallURL: p.VKCallURL, Streams: p.Streams, DNSServer: p.DNSServer}, func(fd uintptr) bool { return protector.Protect(int64(fd)) })
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
	e, err := Start(string(raw), sink, protector)
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
