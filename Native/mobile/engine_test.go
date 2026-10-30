// SPDX-License-Identifier: GPL-3.0-only
package mobile

import (
	"encoding/binary"
	"encoding/json"
	"strings"
	"sync"
	"testing"
)

const testProfile = `{"address":"203.0.113.10","port":443,"uuid":"00000000-0000-4000-8000-000000000001","network":"tcp","security":"tls","serverName":"example.org"}`

type fakeSink struct {
	mu      sync.Mutex
	packets [][]byte
}

func (s *fakeSink) WritePacket(b []byte) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.packets = append(s.packets, append([]byte(nil), b...))
	return true
}

type noNetwork struct{ t *testing.T }

func (p noNetwork) Protect(int64) bool {
	p.t.Error("unexpected external socket; tests are offline")
	return false
}
func TestConfigIsClosed(t *testing.T) {
	raw, err := buildConfig(testProfile)
	if err != nil {
		t.Fatal(err)
	}
	var c map[string]any
	if err = json.Unmarshal(raw, &c); err != nil {
		t.Fatal(err)
	}
	if len(c["inbounds"].([]any)) != 0 || len(c["outbounds"].([]any)) != 1 {
		t.Fatal("unexpected listeners or fallback")
	}
	for _, input := range []string{
		strings.Replace(testProfile, `"tcp"`, `"ws"`, 1),
		strings.Replace(testProfile, `"203.0.113.10"`, `"example.org"`, 1),
		strings.Replace(testProfile, `"port":443`, `"port":0`, 1),
		strings.Replace(testProfile, `"security":"tls"`, `"security":"other"`, 1),
		strings.Replace(testProfile, `"address"`, `"inbounds"`, 1),
		testProfile + `{}`,
	} {
		if _, err = buildConfig(input); err == nil {
			t.Fatalf("accepted invalid profile: %s", input)
		}
	}
}
func TestXHTTPConfig(t *testing.T) {
	input := strings.Replace(testProfile, `"tcp"`, `"xhttp"`, 1)
	raw, err := buildConfig(input)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(raw), `"xhttpSettings"`) {
		t.Fatal("missing XHTTP")
	}
	// Construction only: no outbound dial and no proxy server.
	sink := &fakeSink{}
	engine, err := Start(input, sink, noNetwork{t})
	if err != nil {
		t.Fatal(err)
	}
	engine.Stop()
}
func TestPacketFlowRoundTripAndStop(t *testing.T) {
	sink := &fakeSink{}
	e, err := Start(testProfile, sink, noNetwork{t})
	if err != nil {
		t.Fatal(err)
	}
	defer e.Stop()
	if _, err := Start(testProfile, sink, noNetwork{t}); err == nil {
		t.Fatal("second runtime accepted")
	}
	if err := e.Input([]byte{0}); err == nil {
		t.Fatal("short packet accepted")
	}
	packet := make([]byte, 28)
	packet[0] = 0x45
	binary.BigEndian.PutUint16(packet[2:4], 28)
	packet[8] = 64
	packet[9] = 1
	copy(packet[12:16], []byte{10, 77, 0, 2})
	copy(packet[16:20], []byte{1, 1, 1, 1})
	packet[20] = 8
	binary.BigEndian.PutUint16(packet[24:26], 7)
	checksum := func(b []byte) uint16 {
		var s uint32
		for i := 0; i+1 < len(b); i += 2 {
			s += uint32(binary.BigEndian.Uint16(b[i:]))
		}
		for s>>16 != 0 {
			s = (s & 65535) + (s >> 16)
		}
		return ^uint16(s)
	}
	binary.BigEndian.PutUint16(packet[10:12], checksum(packet[:20]))
	binary.BigEndian.PutUint16(packet[22:24], checksum(packet[20:]))
	if err := e.Input(packet); err != nil {
		t.Fatal(err)
	}
	sink.mu.Lock()
	n := len(sink.packets)
	if n == 1 && sink.packets[0][20] != 0 {
		t.Error("not ICMP echo reply")
	}
	sink.mu.Unlock()
	if n != 1 {
		t.Fatalf("want callback packet, got %d", n)
	}
	e.Stop()
	e.Stop()
	if err := e.Input(packet); err == nil {
		t.Fatal("stopped engine accepted packet")
	}
	next, err := Start(testProfile, sink, noNetwork{t})
	if err != nil {
		t.Fatal(err)
	}
	next.Stop()
}
func TestPacketAdapterCopiesAndCloses(t *testing.T) {
	s := &fakeSink{}
	p := &packetAdapter{sink: s}
	h := []byte{1}
	if err := p.WritePacket(h, []byte{2}); err != nil {
		t.Fatal(err)
	}
	h[0] = 9
	if s.packets[0][0] != 1 {
		t.Fatal("retained caller buffer")
	}
	_ = p.Close()
	if err := p.WritePacket(h, nil); err == nil {
		t.Fatal("write after close")
	}
}
