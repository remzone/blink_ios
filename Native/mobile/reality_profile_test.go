package mobile

import (
	"crypto/ecdh"
	"crypto/rand"
	"encoding/base64"
	"github.com/remzone/blink_ios/native/share"
	"testing"
)

// Import success must also mean the generated REALITY config can start.
func TestREALITYImportedProfileStartsWithoutServerOnlyFields(t *testing.T) {
	key, err := ecdh.X25519().GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	uri := "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:443?type=tcp&security=reality&fp=firefox&pbk=" + base64.RawURLEncoding.EncodeToString(key.PublicKey().Bytes()) + "&sid=6510a1be30f108&sni=+web.example.org&spx=%2Ffixture&support-x25519mlkem768=true"
	outbound, err := share.ParseSingle(uri)
	if err != nil {
		t.Fatal(err)
	}
	reality := outbound.StreamSetting.REALITYSettings
	if reality == nil || reality.ServerName != "web.example.org" || reality.ShortId != "6510a1be30f108" || reality.SpiderX != "/fixture" {
		t.Fatal("SNI normalization or REALITY options lost")
	}
	profile, err := ImportProfile(uri)
	if err != nil {
		t.Fatal(err)
	}
	engine, err := StartProfile(profile, &fakeSink{}, noNetwork{t})
	if err != nil {
		t.Fatal(err)
	}
	engine.Stop()
}
