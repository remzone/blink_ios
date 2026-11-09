// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"errors"
	"net"
	"strconv"
	"strings"
)

// The endpoint is always TURN's private packet bridge. A supplied endpoint
// is parsed for syntax, then replaced before any resolution or dial.
func vkWireGuardConfig(source, endpoint string) (ImportedProfile, error) {
	if len(source) > 16384 {
		return ImportedProfile{}, errors.New("VK WireGuard config too large")
	}
	c, e := parseWG(source)
	if e != nil || len(c.Peers) != 1 || len(c.Amnezia) != 0 || c.MTU > 1280 {
		return ImportedProfile{}, errors.New("VK WireGuard requires one standard WG peer and MTU at most 1280")
	}
	host, port, e := net.SplitHostPort(endpoint)
	if e != nil || net.ParseIP(host) == nil || !net.ParseIP(host).IsLoopback() {
		return ImportedProfile{}, errors.New("invalid VK packet endpoint")
	}
	if n, e := strconv.Atoi(port); e != nil || n < 1 {
		return ImportedProfile{}, errors.New("invalid VK packet port")
	}
	lines := strings.Split(source, "\n")
	for i, line := range lines {
		parts := strings.SplitN(line, "=", 2)
		if len(parts) == 2 && strings.EqualFold(strings.TrimSpace(parts[0]), "Endpoint") {
			lines[i] = "Endpoint = " + endpoint
		}
	}
	return ImportedProfile{Source: strings.Join(lines, "\n")}, nil
}
