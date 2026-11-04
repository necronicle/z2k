package main

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"
)

func TestRedirectorExactAllowlist(t *testing.T) {
	for host, want := range map[string]bool{"redirector.googlevideo.com": true, "REDIRECTOR.GOOGLEVIDEO.COM.": true, "x.redirector.googlevideo.com": false, "r1.googlevideo.com": false, "redirector.googlevideo.com.evil.test": false} {
		if got := isInstaHost(host); got != want {
			t.Errorf("%s allowed=%v want=%v", host, got, want)
		}
	}
}

func TestRedirectorCollectsAllResolvers(t *testing.T) {
	var calls atomic.Int32
	lookup := func(_ context.Context, _ string, resolver string) ([]string, error) {
		n := calls.Add(1)
		out := []string{"::1", "142.251.13.100"}
		for i := 0; i < 10; i++ {
			out = append(out, fmt.Sprintf("142.251.%d.%d", n, i+1))
		}
		return out, nil
	}
	got := collectResolveV4(context.Background(), "redirector.googlevideo.com", lookup)
	if calls.Load() != 4 || len(got) != 32 {
		t.Fatalf("calls=%d addresses=%d", calls.Load(), len(got))
	}
	calls.Store(0)
	got = collectResolveV4(context.Background(), "instagram.com", lookup)
	if len(got) != 8 {
		t.Fatalf("Meta cap changed: %d", len(got))
	}
}

func TestRedirectorSlowResolverDoesNotStarveOthers(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	got := collectResolveV4(ctx, "redirector.googlevideo.com", func(ctx context.Context, host, addr string) ([]string, error) {
		if addr == "" {
			<-ctx.Done()
			return nil, ctx.Err()
		}
		return []string{"142.251.13.100"}, nil
	})
	if len(got) != 1 || got[0] != "142.251.13.100" {
		t.Fatalf("fast answers lost: %v", got)
	}
}
