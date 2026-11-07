// SPDX-License-Identifier: GPL-3.0-only
package vkturn

import (
	"context"
	"net"
	"testing"

	"github.com/xtaci/smux"
)

func TestCallAliasesUseSameAuthorizationID(t *testing.T) {
	for _, host := range []string{"vk.com", "vk.ru", "www.vk.com", "www.vk.ru"} {
		t.Run(host, func(t *testing.T) {
			cfg := testConfig()
			cfg.VKCallURL = "https://" + host + "/call/join/Same_ID-42="
			// An injected session factory prevents calls to VK or CAPTCHA requests.
			factory := func(ctx context.Context, _ *net.UDPAddr) (*smux.Session, func(), error) {
				<-ctx.Done()
				return nil, nil, ctx.Err()
			}
			client, err := start(context.Background(), cfg, allow, factory)
			if err != nil {
				t.Fatal(err)
			}
			defer client.Close()
			if client.link != "Same_ID-42=" || client.config.VKCallURL != cfg.VKCallURL {
				t.Fatal("call identity changed or original URL was lost")
			}
		})
	}
}
