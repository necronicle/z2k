package main

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestMetrics_TextFormat(t *testing.T) {
	ms := newMetricSet()
	ms.inc("relay_session_close_total", `reason="peer_close"`)
	ms.inc("relay_session_close_total", `reason="peer_close"`)
	ms.add("relay_dial_total", `result="ok"`, 5)
	ms.observe("relay_dial_latency_seconds", 42*time.Millisecond)
	ms.gauge("relay_sessions", func() int64 { return 7 })
	var buf bytes.Buffer
	ms.write(&buf)
	out := buf.String()
	for _, want := range []string{
		"# TYPE relay_session_close_total counter\n",
		`relay_session_close_total{reason="peer_close"} 2` + "\n",
		`relay_dial_total{result="ok"} 5` + "\n",
		"# TYPE relay_dial_latency_seconds histogram\n",
		`relay_dial_latency_seconds_bucket{le="0.05"} 1` + "\n",
		`relay_dial_latency_seconds_bucket{le="+Inf"} 1` + "\n",
		"relay_dial_latency_seconds_count 1\n",
		"relay_sessions 7\n",
	} {
		if !strings.Contains(out, want) {
			t.Fatalf("нет строки %q в выводе:\n%s", want, out)
		}
	}
	if strings.Contains(out, `le="0.025"} 1`) {
		t.Fatalf("42 мс попали в бакет 0.025:\n%s", out)
	}
}

func TestAdminMux_ServesMetricsAndPprof(t *testing.T) {
	srv := httptest.NewServer(newAdminMux())
	defer srv.Close()
	for _, path := range []string{"/metrics", "/debug/pprof/"} {
		resp, err := http.Get(srv.URL + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != 200 {
			t.Fatalf("%s: статус %d", path, resp.StatusCode)
		}
	}
}
