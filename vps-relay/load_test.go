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

// Controlled local TCP load: two sessions, 4096 streams each. No public DC traffic.
func TestLoad_AssignedCapacity(t *testing.T) {
	withInts(t, maxStreamsTotal, 8192, maxStreamsPerSess, 4096)
	startFakeDC(t, func(c net.Conn) {
		defer c.Close()
		buf := make([]byte, 1024)
		for {
			n, err := c.Read(buf)
			if n > 0 {
				if _, e := c.Write(buf[:n]); e != nil {
					return
				}
			}
			if err != nil {
				return
			}
		}
	})
	url := startRelay(t)
	id, key := testInstall(t)
	runtime.GC()
	var before, after runtime.MemStats
	runtime.ReadMemStats(&before)
	a, _ := dialV2(t, url, id, key, "capacity")
	b, _ := dialV2(t, url, id, key, "capacity")
	for _, ws := range []*websocket.Conn{a, b} {
		for sid := uint16(1); sid <= 4096; sid++ {
			sendFrame(t, ws, sid, muxCONNECT, connectPayload(tgTarget, 443))
			expectFrame(t, ws, sid, muxCONNECT_OK, 5*time.Second)
		}
	}
	if n := liveStreams.Load(); n != 8192 {
		t.Fatalf("streams=%d", n)
	}
	runtime.GC()
	runtime.ReadMemStats(&after)
	t.Logf("8192 streams established; additional heap including local TCP peers: %.1f MiB", float64(after.HeapInuse-before.HeapInuse)/(1024*1024))
	c, _ := dialV2(t, url, id, key, "capacity")
	sendFrame(t, c, 1, muxCONNECT, connectPayload(tgTarget, 443))
	expectFrame(t, c, 1, muxCONNECT_FAIL, time.Second)
	var lat []time.Duration
	for _, ws := range []*websocket.Conn{a, b} {
		for sid := uint16(1); sid <= 100; sid++ {
			start := time.Now()
			sendFrame(t, ws, sid, muxDATA, []byte("capacity echo"))
			if p := expectFrame(t, ws, sid, muxDATA, time.Second); string(p) != "capacity echo" {
				t.Fatal("echo mismatch")
			}
			lat = append(lat, time.Since(start))
		}
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	t.Logf("echo p95=%s", lat[len(lat)*95/100])
	a.Close()
	b.Close()
	c.Close()
	until := time.Now().Add(10 * time.Second)
	for liveStreams.Load() != 0 && time.Now().Before(until) {
		time.Sleep(10 * time.Millisecond)
	}
	if n := liveStreams.Load(); n != 0 {
		t.Fatalf("leaked streams=%d", n)
	}
}
