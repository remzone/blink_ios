// SPDX-License-Identifier: GPL-3.0-only
package share

import (
	"testing"
)

func TestKCPSeedAndHeaderBuild(t *testing.T) {
	out, e := parseOutboundShareLink("vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?type=kcp&seed=fixture&headerType=srtp&mtu=1280&tti=20")
	if e != nil {
		t.Fatal(e)
	}
	if _, e = out.Build(); e != nil {
		t.Fatal(e)
	}
}
