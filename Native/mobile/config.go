// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"strings"
	"time"
)

// Connection is deliberately narrower than arbitrary Xray JSON: no inbound
// listener, freedom fallback, API server, filesystem paths or log destinations.
type Connection struct {
	Address     string `json:"address"`
	Port        int    `json:"port"`
	UUID        string `json:"uuid"`
	Network     string `json:"network"`
	Security    string `json:"security"`
	ServerName  string `json:"serverName"`
	Fingerprint string `json:"fingerprint"`
	PublicKey   string `json:"publicKey"`
	ShortID     string `json:"shortId"`
	Flow        string `json:"flow"`
	Host        string `json:"host"`
	Path        string `json:"path"`
	Mode        string `json:"mode"`
}

func buildConfig(input string) ([]byte, error) {
	if len(input) > 16384 {
		return nil, errors.New("profile too large")
	}
	var c Connection
	d := json.NewDecoder(strings.NewReader(input))
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return nil, errors.New("invalid profile")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return nil, errors.New("trailing profile data")
	}
	// Resolve the endpoint before NE tunnel routes are installed. Avoid recursive
	// system DNS lookups inside the tunnel for the transport's own destination.
	if net.ParseIP(c.Address) == nil || c.Port < 1 || c.Port > 65535 || !validUUID(c.UUID) {
		return nil, errors.New("invalid endpoint")
	}
	if c.Network != "tcp" && c.Network != "xhttp" {
		return nil, errors.New("unsupported transport")
	}
	if c.Security != "tls" && c.Security != "reality" && c.Security != "none" {
		return nil, errors.New("unsupported security")
	}
	if c.Flow != "" && c.Flow != "xtls-rprx-vision" {
		return nil, errors.New("unsupported flow")
	}
	if c.Network == "xhttp" && c.Flow != "" {
		return nil, errors.New("XHTTP does not use Vision flow")
	}
	if c.Security != "none" && (c.ServerName == "" || len(c.ServerName) > 253) {
		return nil, errors.New("server name required")
	}
	stream := map[string]any{"network": c.Network, "security": c.Security}
	if c.Security == "tls" {
		stream["tlsSettings"] = map[string]any{"serverName": c.ServerName, "fingerprint": c.Fingerprint, "allowInsecure": false}
	}
	if c.Security == "reality" {
		if c.PublicKey == "" || c.Fingerprint == "" {
			return nil, errors.New("REALITY key and fingerprint required")
		}
		stream["realitySettings"] = map[string]any{"serverName": c.ServerName, "fingerprint": c.Fingerprint, "publicKey": c.PublicKey, "shortId": c.ShortID}
	}
	if c.Network == "xhttp" {
		if c.Mode == "" {
			c.Mode = "auto"
		}
		if c.Mode != "auto" && c.Mode != "packet-up" && c.Mode != "stream-up" && c.Mode != "stream-one" {
			return nil, errors.New("unsupported XHTTP mode")
		}
		if c.Path == "" {
			c.Path = "/"
		}
		if len(c.Path) > 4096 || !strings.HasPrefix(c.Path, "/") || len(c.Host) > 253 {
			return nil, errors.New("invalid XHTTP endpoint")
		}
		stream["xhttpSettings"] = map[string]any{"host": c.Host, "path": c.Path, "mode": c.Mode}
	}
	cfg := map[string]any{
		"log":       map[string]any{"loglevel": "none"},
		"inbounds":  []any{},
		"outbounds": []any{map[string]any{"tag": "proxy", "protocol": "vless", "settings": map[string]any{"vnext": []any{map[string]any{"address": c.Address, "port": c.Port, "users": []any{map[string]any{"id": c.UUID, "encryption": "none", "flow": c.Flow}}}}}, "streamSettings": stream}},
	}
	return json.Marshal(cfg)
}
func validUUID(s string) bool {
	if len(s) != 36 {
		return false
	}
	for i, c := range []byte(s) {
		if i == 8 || i == 13 || i == 18 || i == 23 {
			if c != '-' {
				return false
			}
		} else if !bytes.ContainsRune([]byte("0123456789abcdefABCDEF"), rune(c)) {
			return false
		}
	}
	return true
}

// PrepareProfile resolves only the proxy endpoint before iOS installs VPN routes.
// It does not connect to the proxy or validate its availability.
func PrepareProfile(input string) (string, error) {
	if len(input) > 16384 {
		return "", errors.New("profile too large")
	}
	var c Connection
	d := json.NewDecoder(strings.NewReader(input))
	d.DisallowUnknownFields()
	if err := d.Decode(&c); err != nil {
		return "", errors.New("invalid profile")
	}
	if err := d.Decode(new(any)); err != io.EOF {
		return "", errors.New("trailing profile data")
	}
	if c.Address == "" || len(c.Address) > 253 {
		return "", errors.New("invalid endpoint")
	}
	if net.ParseIP(c.Address) == nil {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		addresses, err := net.DefaultResolver.LookupIPAddr(ctx, c.Address)
		if err != nil || len(addresses) == 0 {
			return "", errors.New("endpoint DNS resolution failed")
		}
		c.Address = addresses[0].IP.String()
	}
	raw, err := json.Marshal(c)
	if err != nil {
		return "", errors.New("invalid profile")
	}
	if _, err = buildConfig(string(raw)); err != nil {
		return "", err
	}
	return string(raw), nil
}
