package wg

import (
	"testing"
	"time"
)

func TestParseHealth(t *testing.T) {
	now := time.Unix(1787470700, 0)
	h := parseHealth("private_key=ab\npublic_key=cd\nlast_handshake_time_sec=1787470690\nlast_handshake_time_nsec=0\nrx_bytes=584\ntx_bytes=3784\n", now)
	if !h.Connected || h.Rx != 584 || h.Tx != 3784 || now.Sub(h.LastHandshake) != 10*time.Second {
		t.Fatalf("%+v", h)
	}
}

func TestParseHealthNoHandshake(t *testing.T) {
	now := time.Unix(1787470700, 0)
	h := parseHealth("rx_bytes=0\ntx_bytes=148\nlast_handshake_time_sec=0\n", now)
	if h.Connected || !h.LastHandshake.IsZero() {
		t.Fatalf("no handshake must not be connected: %+v", h)
	}
}

func TestParseHealthStaleHandshake(t *testing.T) {
	now := time.Unix(1787470700, 0)
	h := parseHealth("last_handshake_time_sec=1787470000\nrx_bytes=1\n", now) // 700 с назад
	if h.Connected {
		t.Fatalf("stale handshake must not be connected: %+v", h)
	}
}

func TestIpcConfig(t *testing.T) {
	cfg, err := ipcConfig("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=", "bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=", "8.6.112.0", 2408)
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{
		"private_key=0000000000000000000000000000000000000000000000000000000000000000\n",
		"replace_peers=true\n",
		"public_key=6e65ce0be17517110c17d77288ad87e7fd5252dcc7d09b95a39d61db03df832a\n",
		"endpoint=8.6.112.0:2408\n",
		"allowed_ip=0.0.0.0/0\n",
		"persistent_keepalive_interval=25\n",
	} {
		if !contains(cfg, want) {
			t.Fatalf("missing %q in\n%s", want, cfg)
		}
	}
}

func contains(s, sub string) bool { return len(s) >= len(sub) && (s == sub || indexOf(s, sub) >= 0) }
func indexOf(s, sub string) int {
	for i := 0; i+len(sub) <= len(s); i++ {
		if s[i:i+len(sub)] == sub {
			return i
		}
	}
	return -1
}
