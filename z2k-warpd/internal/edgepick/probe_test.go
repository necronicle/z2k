package edgepick

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestLookupDoHWithClientUsesOnlyARecords(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/dns-query" || r.URL.Query().Get("name") != metaHost || r.URL.Query().Get("type") != "A" || r.Header.Get("Accept") != "application/dns-json" {
			t.Errorf("unexpected DoH request: %s", r.URL.String())
		}
		_, _ = w.Write([]byte(`{"Status":0,"Answer":[{"type":28,"data":"2606:4700::1"},{"type":1,"data":"162.159.140.220"}]}`))
	}))
	defer srv.Close()
	got, err := lookupDoHWithClient(context.Background(), srv.Client(), srv.URL+"/dns-query?name=speed.cloudflare.com&type=A")
	if err != nil || got != "162.159.140.220:443" {
		t.Fatalf("target=%q err=%v", got, err)
	}
}

func TestLookupDoHWithClientRejectsBadAnswers(t *testing.T) {
	for _, body := range []string{`{"Status":2}`, `{"Status":0,"Answer":[{"type":1,"data":"127.0.0.1"}]}`, `{"Status":0,"Answer":[{"type":1,"data":"nonsense"}]}`, `bad-json`} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		_, err := lookupDoHWithClient(context.Background(), srv.Client(), srv.URL)
		srv.Close()
		if err == nil {
			t.Fatalf("accepted DoH response %q", body)
		}
	}
}

func TestParseMetaUsesEdgeCountryNotExitCountry(t *testing.T) {
	meta, err := parseMeta([]byte(`{"country":"RU","colo":{"iata":"FRA","cca2":"DE"}}`))
	if err != nil || meta.Colo != "FRA" || meta.Country != "DE" {
		t.Fatalf("meta=%+v err=%v", meta, err)
	}
	if _, err := parseMeta([]byte(`{"country":"RU","colo":{"iata":"DME"}}`)); err == nil {
		t.Fatal("missing edge country was accepted")
	}
}

func TestProbeWithClientSendsRefererAndCountsLoss(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.Header.Get("Referer") != "https://speed.cloudflare.com" {
			t.Errorf("Referer=%q", r.Header.Get("Referer"))
		}
		if calls == 1 {
			http.Error(w, "try again", http.StatusServiceUnavailable)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"country":"RU","colo":{"iata":"HEL","cca2":"FI"}}`))
	}))
	defer srv.Close()
	meta, rtt, loss, err := probeWithClient(context.Background(), srv.Client(), srv.URL)
	if err != nil || meta.Country != "FI" || meta.Colo != "HEL" || loss != 33 || rtt <= 0 || calls != 3 {
		t.Fatalf("meta=%+v rtt=%s loss=%d calls=%d err=%v", meta, rtt, loss, calls, err)
	}
}

func TestProbeWithClientRejectsOversizedAndInvalidResponses(t *testing.T) {
	for _, body := range []string{strings.Repeat("x", 5000), `{"colo":{"iata":"FRA"}}`, `bad-json`} {
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = w.Write([]byte(body))
		}))
		_, _, _, err := probeWithClient(context.Background(), srv.Client(), srv.URL)
		srv.Close()
		if err == nil {
			t.Fatalf("accepted response %q", body[:min(len(body), 20)])
		}
	}
}

func TestProbeWithClientStopsAfterCancellation(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-r.Context().Done()
	}))
	defer srv.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	defer cancel()
	start := time.Now()
	_, _, _, err := probeWithClient(ctx, srv.Client(), srv.URL)
	if err == nil || time.Since(start) > time.Second {
		t.Fatalf("probe did not stop promptly: err=%v elapsed=%s", err, time.Since(start))
	}
}
