// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"errors"
	"net/url"
	"regexp"
	"strings"
)

var callPathPattern = regexp.MustCompile(`^/call/join/[A-Za-z0-9_=-]+$`)

// The official vk.com/vk.ru (and www) links identify the same call by its
// case-sensitive join ID. Validate both URLs before comparing that identity;
// an arbitrary host with a matching path must never reuse TURN authorization.
func vkCallID(raw string) (string, error) {
	u, err := url.Parse(raw)
	if err != nil || len(raw) > 2048 || u.Scheme != "https" ||
		(u.Host != "vk.com" && u.Host != "www.vk.com" && u.Host != "vk.ru" && u.Host != "www.vk.ru") ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" || u.RawPath != "" || !callPathPattern.MatchString(u.Path) {
		return "", errors.New("invalid VK call URL")
	}
	return strings.TrimPrefix(u.Path, "/call/join/"), nil
}

func sameVKCall(left, right string) bool {
	a, err := vkCallID(left)
	if err != nil {
		return false
	}
	b, err := vkCallID(right)
	return err == nil && a == b
}
