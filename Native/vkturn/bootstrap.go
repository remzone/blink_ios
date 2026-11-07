// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"encoding/json"
	"errors"
	"net"
	"strings"
	"time"
)

// Private app->extension handoff. Never expose this through launcher/status APIs.
type turnBootstrap struct {
	Username  string `json:"username"`
	Password  string `json:"password"`
	Address   string `json:"address"`
	PeerHost  string `json:"peerHost"`
	PeerPort  int    `json:"peerPort"`
	CallURL   string `json:"callURL"`
	ExpiresAt int64  `json:"expiresAt"`
}

func validateBootstrap(raw string, cfg Config) (turnBootstrap, error) {
	var b turnBootstrap
	if len(raw) > 32768 || json.Unmarshal([]byte(raw), &b) != nil {
		return b, errors.New("invalid TURN handoff")
	}
	host, port, e := net.SplitHostPort(b.Address)
	now := time.Now().Unix()
	if e != nil || host == "" || port == "" || b.Username == "" || b.Password == "" || len(b.Username) > 4096 || len(b.Password) > 4096 || strings.ContainsAny(b.Username+b.Password, "\r\n\x00") || b.PeerHost != cfg.PeerHost || b.PeerPort != cfg.PeerPort || !sameVKCall(b.CallURL, cfg.VKCallURL) || b.ExpiresAt <= now || b.ExpiresAt > now+90 {
		return b, errors.New("expired or mismatched TURN handoff")
	}
	return b, nil
}
func (c *Client) ExportBootstrap() string {
	if c.Status() != "ready" {
		return ""
	}
	select {
	case <-c.ctx.Done():
		return ""
	case <-c.authGate:
	}
	defer func() { c.authGate <- struct{}{} }()
	if c.ctx.Err() != nil || time.Now().After(c.credsUntil) || c.username == "" {
		return ""
	}
	until := time.Now().Add(90 * time.Second)
	if c.credsUntil.Before(until) {
		until = c.credsUntil
	}
	b, _ := json.Marshal(turnBootstrap{Username: c.username, Password: c.password, Address: c.turnAddress, PeerHost: c.config.PeerHost, PeerPort: c.config.PeerPort, CallURL: c.config.VKCallURL, ExpiresAt: until.Unix()})
	return string(b)
}
