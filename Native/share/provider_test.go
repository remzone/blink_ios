// SPDX-License-Identifier: GPL-3.0-only
package share

import (
	"encoding/json"
	"github.com/xtls/xray-core/infra/conf"
	"testing"
)

func TestProviderLabelsPreserveConnectionAndExplicitMux(t *testing.T) {
	base := "vless://00000000-0000-4000-8000-000000000001@example.org:443?security=tls&sni=example.org&type=ws&path=%2Fvpn"
	for _, suffix := range []string{
		"&x-durev-block=regular&x-durev-prio=2&x-durev-sni-change=true",
		"&mux=true&muxConcurrency=8&x-durev-block=warp",
		"&mux=false&concurrency=4",
	} {
		out, err := ParseSingle(base + suffix)
		if err != nil {
			t.Fatal(err)
		}
		if out.StreamSetting.TLSSettings.ServerName != "example.org" || out.StreamSetting.WSSettings.Path != "/vpn" {
			t.Fatal("connection settings changed")
		}
		if suffix == "&mux=true&muxConcurrency=8&x-durev-block=warp" && (out.MuxSettings == nil || !out.MuxSettings.Enabled || out.MuxSettings.Concurrency != 8) {
			t.Fatal("explicit mux lost")
		}
		raw, err := MarshalOutbound(out)
		if err != nil {
			t.Fatal(err)
		}
		var restored conf.OutboundDetourConfig
		if err = json.Unmarshal(raw, &restored); err != nil {
			t.Fatal(err)
		}
		if _, err = restored.Build(); err != nil {
			t.Fatal("serialized outbound does not build")
		}
	}
	xhttp, err := ParseSingle("vless://00000000-0000-4000-8000-000000000001@example.org:443?type=xhttp&security=tls&sni=example.org&mode=auto&path=%2Fvpn&concurrency=4&x-durev-prio=3")
	if err != nil {
		t.Fatal(err)
	}
	if xhttp.MuxSettings != nil {
		t.Fatal("advisory concurrency enabled mux")
	}
	for _, suffix := range []string{"&unknown=1", "&x-durev-unknown=1", "&x-durev-prio=1&x-durev-prio=2", "&mux=maybe", "&muxConcurrency=8", "&concurrency=4", "&muxConcurrency=0", "&concurrency=129", "&mux=true&concurrency=4&muxConcurrency=8", "&allowInsecure=1"} {
		if _, err := ParseSingle(base + suffix); err == nil {
			t.Fatal("invalid option accepted")
		}
	}
}
