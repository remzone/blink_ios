// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
)

func TestStandardProfileImports(t *testing.T) {
	links := []string{
		"vless://00000000-0000-4000-8000-000000000001@example.org:443?type=ws&security=tls&sni=example.org&path=%2Fvpn#WS",
		"trojan://secret@example.org:443?security=tls&sni=example.org",
		"ss://" + base64.RawStdEncoding.EncodeToString([]byte("aes-128-gcm:password")) + "@example.org:8388",
		"socks://user:pass@example.org:1080",
		"vmess://" + base64.StdEncoding.EncodeToString([]byte(`{"v":"2","ps":"VMess","add":"example.org","port":"443","id":"00000000-0000-4000-8000-000000000001","aid":"0","net":"ws","tls":"tls","host":"example.org","path":"/vpn"}`)),
		"hy2://secret@example.org:443?sni=example.org",
	}
	for _, link := range links {
		p, e := ImportProfile(link)
		if e != nil {
			t.Fatalf("scheme %s: %v", strings.Split(link, ":")[0], e)
		}
		var v ImportedProfile
		if json.Unmarshal([]byte(p), &v) != nil || v.Kind != "xray" {
			t.Fatal("bad profile envelope")
		}
	}
	doc, e := ImportProfiles(base64.StdEncoding.EncodeToString([]byte(strings.Join(append(links, "openvpn://unsupported"), "\n"))))
	if e != nil {
		t.Fatal(e)
	}
	var list struct {
		Profiles []ImportedProfile
		Rejected []any
	}
	json.Unmarshal([]byte(doc), &list)
	if len(list.Profiles) != len(links) || len(list.Rejected) != 1 {
		t.Fatal("subscription dropped a node without a result")
	}
}
func TestRejectProxyOptionsAndRedactErrors(t *testing.T) {
	for _, s := range []string{"trojan://SECRET@example.org:443?allowInsecure=1", "vless://SECRET@example.org:443?type=ws&type=tcp", "ss://SECRET@example.org:80000", "vless://SECRET@example.org:443?plugin=ignored", "openvpn://SECRET@example.org:443", "vless://SECRET@example.org:443?security=none&sni=ignored.example", "trojan://SECRET@example.org:443?security=tls&flow=ignored", "vless://SECRET@example.org:443?type=tcp&mode=ignored"} {
		if _, e := ImportProfile(s); e == nil {
			t.Fatal("invalid profile accepted")
		} else if strings.Contains(e.Error(), "SECRET") {
			t.Fatal("credential in error")
		}
	}
}

const fixtureWG = `[Interface]
PrivateKey = AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE=
Address = 10.77.0.2/32
DNS = 10.77.0.1
[Peer]
PublicKey = AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI=
AllowedIPs = 10.77.0.1/32
Endpoint = 127.0.0.1:51820
PersistentKeepalive = 25
`

func TestWireGuardAndAmneziaConf(t *testing.T) {
	for _, extra := range []string{"", "Jc = 4\nJmin = 40\nJmax = 80\nS1 = 15\nS2 = 25\nH1 = 100\nH2 = 200\nH3 = 300\nH4 = 400\n"} {
		source := strings.Replace(fixtureWG, "[Peer]", extra+"[Peer]", 1)
		c, e := parseWG(source)
		if e != nil {
			t.Fatal(e)
		}
		if len(c.Peers) != 1 || c.MTU != 1280 {
			t.Fatal("invalid WG parse")
		}
		raw, e := ImportProfile(source)
		if e != nil {
			t.Fatal(e)
		}
		if strings.Contains(raw, "amneziawg") != (extra != "") {
			t.Fatal("wrong kind")
		}
	}
	for _, bad := range []string{strings.Replace(fixtureWG, "[Peer]", "PostUp = run-script\n[Peer]", 1), strings.Replace(fixtureWG, "Address = 10.77.0.2/32", "Address = invalid", 1), strings.Replace(fixtureWG, "PersistentKeepalive = 25", "PublicKey = duplicate", 1)} {
		if _, e := parseWG(bad); e == nil {
			t.Fatal("invalid WG config accepted")
		}
	}
}

// A subscription is a collection of independently selectable endpoints, even
// when several countries use the same protocol and the same credentials.
func TestMultiCountrySubscriptionPreservesEndpoints(t *testing.T) {
	links := []string{
		"vless://00000000-0000-4000-8000-000000000001@de.example.org:443?security=tls&type=ws&path=%2Fvpn#DE%20Berlin",
		"vless://00000000-0000-4000-8000-000000000001@nl.example.org:443?security=tls&type=tcp#NL%20Amsterdam",
		"trojan://fixture@us.example.org:443?security=tls#US%20New%20York",
		"hy2://fixture@jp.example.org:443#JP%20Tokyo",
	}
	plain := strings.Join(links, "\r\n")
	sources := []string{plain}
	for _, enc := range []*base64.Encoding{base64.StdEncoding, base64.RawStdEncoding, base64.URLEncoding, base64.RawURLEncoding} {
		sources = append(sources, enc.EncodeToString([]byte(plain)))
	}
	names := []string{"DE Berlin", "NL Amsterdam", "US New York", "JP Tokyo"}
	for i, source := range sources {
		raw, err := ImportProfiles(source)
		if err != nil {
			t.Fatalf("encoding %d: %v", i, err)
		}
		var result struct {
			Profiles []ImportedProfile
			Rejected []json.RawMessage
		}
		if err := json.Unmarshal([]byte(raw), &result); err != nil {
			t.Fatal(err)
		}
		if len(result.Profiles) != len(links) || len(result.Rejected) != 0 {
			t.Fatalf("encoding %d: imported %d, rejected %d", i, len(result.Profiles), len(result.Rejected))
		}
		for j, profile := range result.Profiles {
			if profile.Name != names[j] || profile.Source != links[j] {
				t.Fatalf("encoding %d: endpoint %d lost its name or connection settings", i, j)
			}
		}
	}
}
