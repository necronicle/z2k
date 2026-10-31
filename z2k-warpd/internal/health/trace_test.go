package health

import "testing"

// Ответ /cdn-cgi/trace — строки key=value. Поле warp у Cloudflare: off — мимо
// WARP, on — бесплатный WARP, plus — WARP+ (account_type limited/unlimited).
// Полевой случай 31.10.2026: аккаунт unlimited, рукопожатие и ответ через
// туннель есть, а проба требовала ровно warp=on и объявляла туннель мёртвым —
// WARP+ не поднимался никогда.
func TestTraceViaWarp(t *testing.T) {
	cases := []struct {
		name string
		body string
		want bool
	}{
		{"free", "fl=1\nh=1.1.1.1\nip=104.28.1.1\nwarp=on\ngateway=off\n", true},
		{"plus", "fl=1\nh=1.1.1.1\nip=104.28.1.1\nwarp=plus\ngateway=off\n", true},
		{"off", "fl=1\nh=1.1.1.1\nip=95.24.1.1\nwarp=off\ngateway=off\n", false},
		{"no field", "fl=1\nh=1.1.1.1\n", false},
		{"crlf", "warp=plus\r\ngateway=off\r\n", true},
		{"not a key", "x=warp=on\n", false},
	}
	for _, c := range cases {
		if got := traceViaWarp([]byte(c.body)); got != c.want {
			t.Errorf("%s: traceViaWarp=%v, want %v", c.name, got, c.want)
		}
	}
}
