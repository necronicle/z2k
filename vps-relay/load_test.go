//go:build load

package main

import (
	"net"
	"runtime"
	"sort"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Нагрузочный прогон (спека §8), не входит в обычный сьют:
//
//	ulimit -n 20000; go test -tags load -run TestLoad_3000Sessions -count=1 -v .
//
// Требования: heap на сессию ≤ 120 КБ, p95 кадра ≤ 5 мс.
func TestLoad_3000Sessions(t *testing.T) {
	// Поддельный DC с маленьким буфером: 9000 соединений с 64 КБ каждое —
	// это память стенда, а не релея.
	startFakeDC(t, func(c net.Conn) {
		defer c.Close()
		buf := make([]byte, 4096)
		for {
			n, err := c.Read(buf)
			if n > 0 {
				if _, werr := c.Write(buf[:n]); werr != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	})
	url := startRelay(t)
	id, priv := testInstall(t)
	prev := *perInstallMaxSessions
	*perInstallMaxSessions = 0
	t.Cleanup(func() { *perInstallMaxSessions = prev })

	runtime.GC()
	var before runtime.MemStats
	runtime.ReadMemStats(&before)

	const N = 3000
	conns := make([]*websocket.Conn, 0, N)
	for i := 0; i < N; i++ {
		ws, _ := dialV2(t, url, id, priv, "load")
		for sid := uint16(1); sid <= 3; sid++ {
			sendFrame(t, ws, sid, muxCONNECT, connectPayload(tgTarget, 443))
			expectFrame(t, ws, sid, muxCONNECT_OK, 5*time.Second)
		}
		conns = append(conns, ws)
	}
	runtime.GC()
	var after runtime.MemStats
	runtime.ReadMemStats(&after)
	perSession := (after.HeapInuse - before.HeapInuse) / N
	t.Logf("сессий %d, стримов %d, heap на сессию: %d КБ (в т.ч. поддельный клиент в том же процессе)", N, liveStreams.Load(), perSession/1024)
	if perSession > 120*1024 {
		t.Fatalf("heap на сессию %d КБ > 120 КБ", perSession/1024)
	}

	var lat []time.Duration
	for _, ws := range conns[:200] {
		t0 := time.Now()
		sendFrame(t, ws, 1, muxDATA, []byte("p"))
		expectFrame(t, ws, 1, muxDATA, 5*time.Second)
		lat = append(lat, time.Since(t0))
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	p95 := lat[len(lat)*95/100]
	t.Logf("p95 кадра: %s, медиана %s", p95, lat[len(lat)/2])
	if p95 > 5*time.Millisecond {
		t.Fatalf("p95 кадра %s > 5 мс", p95)
	}
}
