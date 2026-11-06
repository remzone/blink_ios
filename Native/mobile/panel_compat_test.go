// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/base64"
	"encoding/json"
	"github.com/remzone/blink_ios/native/share"
	"net/url"
	"os"
	"strings"
	"testing"
)

func TestPanelWireGuardLinkAndAmneziaParameters(t *testing.T) {
	key := "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
	pub := "AgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgI="
	link := "wireguard://" + url.QueryEscape(key) + "@127.0.0.1:51820?publickey=" + url.QueryEscape(pub) + "&address=10.77.0.2%2F32&dns=1.1.1.1&mtu=1280&keepalive=25#DE%20Berlin"
	raw, e := ImportProfile(link)
	if e != nil {
		t.Fatal(e)
	}
	var p ImportedProfile
	json.Unmarshal([]byte(raw), &p)
	if p.Kind != "wireguard" || p.Name != "DE Berlin" {
		t.Fatal("WireGuard metadata lost")
	}
	source, _, e := unwrapWG(p.Source)
	if e != nil {
		t.Fatal(e)
	}
	c, e := parseWG(source)
	if e != nil {
		t.Fatal(e)
	}
	u, e := c.uapi()
	if e != nil || !strings.Contains(u, "persistent_keepalive_interval=25") {
		t.Fatal("WireGuard URI UAPI failed")
	}
	conf := strings.Replace(fixtureWG, "[Peer]", "HeaderProtectionKey = "+strings.Repeat("ab", 32)+"\nRandomTrailers = on\nDisableCookies = off\n[Peer]", 1)
	conf = strings.Replace(conf, "10.77.0.1/32\nEndpoint", "0.0.0.0/0, ::/0\nEndpoint", 1)
	conf = strings.Replace(conf, "PersistentKeepalive = 25", "PersistentKeepalive = 15-25", 1)
	raw, e = ImportProfile("vpn://" + base64.RawURLEncoding.EncodeToString([]byte(conf)))
	if e != nil {
		t.Fatal(e)
	}
	json.Unmarshal([]byte(raw), &p)
	source, _, _ = unwrapWG(p.Source)
	c, e = parseWG(source)
	if e != nil {
		t.Fatal(e)
	}
	if p.Kind != "amneziawg" || len(c.Routes) != 1 || c.Amnezia["random_trailers"] != "true" || c.Peers[0].Keepalive != "15-25" {
		t.Fatal("AWG panel fields lost")
	}
}
func TestPanelExtendedXrayFields(t *testing.T) {
	prefix := "vless://00000000-0000-4000-8000-000000000001@example.org:443?"
	out, e := share.ParseSingle(prefix + "type=xhttp&security=tls&sni=example.org&extra=" + url.QueryEscape(`{"mode":"packet-up","xPaddingBytes":"100-200","xmux":{"maxConcurrency":"4-8"}}`))
	if e != nil {
		t.Fatal(e)
	}
	if out.StreamSetting.XHTTPSettings == nil || len(out.StreamSetting.XHTTPSettings.Extra) == 0 {
		t.Fatal("XHTTP extra lost")
	}
	out, e = share.ParseSingle(strings.Replace(prefix, "example.org", "127.0.0.1", 1) + "type=kcp&seed=fixture&headerType=srtp&mtu=1280&tti=20")
	if e != nil {
		t.Fatal(e)
	}
	if out.StreamSetting.FinalMask == nil || len(out.StreamSetting.FinalMask.Udp) != 2 {
		t.Fatal("KCP seed/header not translated")
	}
}
func TestPanelJSONSubscriptionPreservesSettings(t *testing.T) {
	source := `{"remarks":"DE Berlin","inbounds":[{"protocol":"socks","tag":"mixed","port":10808,"sniffing":{"enabled":true,"destOverride":["tls","http","quic"],"routeOnly":true}}],"outbounds":[{"tag":"proxy","protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"},"streamSettings":{"network":"tcp"},"mux":{"enabled":true,"concurrency":8}},{"tag":"direct","protocol":"freedom"}],"routing":{"rules":[{"type":"field","domain":["domain:example.org"],"outboundTag":"direct"}]},"dns":{"servers":["1.1.1.1"]}}`
	raw, opt, e := prepareXrayJSON(source)
	if e != nil {
		t.Fatal(e)
	}
	if !opt.Sniffing.Enabled || !opt.Sniffing.RouteOnly || opt.Tag != "mixed" || !opt.PreserveDNS {
		t.Fatal("sniffing metadata lost")
	}
	var c map[string]json.RawMessage
	json.Unmarshal(raw, &c)
	if string(c["inbounds"]) != "[]" || !strings.Contains(string(c["routing"]), "example.org") || !strings.Contains(string(c["outbounds"]), `"concurrency":8`) {
		t.Fatal("JSON routing/mux lost or listeners retained")
	}
	list, e := ImportProfiles("[" + source + "," + strings.ReplaceAll(source, "DE Berlin", "NL Amsterdam") + "]")
	if e != nil {
		t.Fatal(e)
	}
	var result struct{ Profiles []ImportedProfile }
	json.Unmarshal([]byte(list), &result)
	if len(result.Profiles) != 2 || result.Profiles[1].Name != "NL Amsterdam" {
		t.Fatal("country profiles collapsed")
	}
	for _, bad := range []string{strings.Replace(source, `"remarks":"DE Berlin"`, `"remarks":"DE","remarks":"NL"`, 1), strings.Replace(source, `"dns":{"servers":["1.1.1.1"]}`, `"api":{"tag":"admin"}`, 1)} {
		if _, _, e = prepareXrayJSON(bad); e == nil {
			t.Fatal("unsafe config accepted")
		}
	}
}
func TestTUICAndHysteria1Imports(t *testing.T) {
	for _, s := range []string{"tuic://00000000-0000-4000-8000-000000000001:password@example.org:443?congestion_control=bbr&udp_relay_mode=quic&alpn=h3&sni=example.org&allow_insecure=0#FR", "hysteria://password@example.org:443?upmbps=10&downmbps=50&peer=example.org#UK"} {
		if _, e := ImportProfile(s); e != nil {
			t.Fatal(e)
		}
	}
}

func TestClashCountryNodesAndExplicitBoundary(t *testing.T) {
	source := `proxies:
  - name: DE Berlin
    type: vless
    server: example.org
    port: 443
    uuid: 00000000-0000-4000-8000-000000000001
    tls: true
    network: ws
    ws-opts:
      path: /vpn
      headers:
        Host: example.org
  - name: NL Amsterdam
    type: tuic
    server: example.org
    port: 443
    uuid: 00000000-0000-4000-8000-000000000001
    password: fixture
    congestion-controller: bbr
    udp-relay-mode: native
  - name: unsupported
    type: openvpn
    server: example.org
    port: 443
rules:
  - MATCH,DIRECT
`
	raw, e := ImportProfiles(source)
	if e != nil {
		t.Fatal(e)
	}
	var doc struct {
		Profiles []ImportedProfile
		Rejected []any
		Notice   string
	}
	json.Unmarshal([]byte(raw), &doc)
	if len(doc.Profiles) != 2 || len(doc.Rejected) != 1 || doc.Notice == "" || doc.Profiles[0].Name != "DE Berlin" {
		t.Fatal("Clash nodes or boundary notice lost")
	}
	if _, e := importClash("proxies: &nodes [*nodes]"); e == nil {
		t.Fatal("recursive YAML alias accepted")
	}
	if _, e := importClash("proxies: []\nproxies: []\n"); e == nil {
		t.Fatal("duplicate YAML key accepted")
	}
}

func TestActualPanelExports(t *testing.T) {
	raw, e := os.ReadFile("testdata/panel-exports.json")
	if e != nil {
		t.Fatal(e)
	}
	var cases []struct{ Name, Source, Kind string }
	if e = json.Unmarshal(raw, &cases); e != nil {
		t.Fatal(e)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			parsed, e := ImportProfile(c.Source)
			if e != nil {
				t.Fatal(e)
			}
			var p ImportedProfile
			json.Unmarshal([]byte(parsed), &p)
			if p.Kind == "amneziawg" {
				source, _, e := unwrapWG(p.Source)
				if e != nil {
					t.Fatal(e)
				}
				wg, e := parseWG(source)
				if e != nil {
					t.Fatal(e)
				}
				if len(wg.Amnezia["header_protection_key"]) != 64 {
					t.Fatal("AWG base64 header key was not converted to UAPI hex")
				}
			}
			if p.Kind != c.Kind {
				t.Fatalf("kind %s, want %s", p.Kind, c.Kind)
			}
		})
	}
}
