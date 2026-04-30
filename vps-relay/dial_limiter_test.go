package main

import (
	"context"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestDialLimiter_AcquireReleaseBasic(t *testing.T) {
	l := newDialLimiter(2, 100*time.Millisecond)
	defer l.close()
	ctx := context.Background()

	rel1, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatalf("acquire 1: %v", err)
	}
	rel2, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatalf("acquire 2: %v", err)
	}

	if _, err := l.acquire(ctx, "1.1.1.1"); !errors.Is(err, errDialThrottle) {
		t.Errorf("expected errDialThrottle on full bucket, got %v", err)
	}

	rel1()
	rel3, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatalf("acquire 3 after release: %v", err)
	}
	rel2()
	rel3()
}

func TestDialLimiter_MultipleTargetsIndependent(t *testing.T) {
	l := newDialLimiter(1, 50*time.Millisecond)
	defer l.close()
	ctx := context.Background()

	rel1, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	defer rel1()

	rel2, err := l.acquire(ctx, "2.2.2.2")
	if err != nil {
		t.Fatalf("different target should not block: %v", err)
	}
	defer rel2()
}

func TestDialLimiter_ContextCancel(t *testing.T) {
	l := newDialLimiter(1, time.Hour)
	defer l.close()

	rel1, err := l.acquire(context.Background(), "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	defer rel1()

	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() {
		_, err := l.acquire(ctx, "1.1.1.1")
		done <- err
	}()

	time.Sleep(20 * time.Millisecond)
	cancel()

	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Errorf("expected context.Canceled, got %v", err)
		}
	case <-time.After(100 * time.Millisecond):
		t.Fatal("acquire did not unblock on ctx cancel")
	}
}

func TestDialLimiter_ReleaseIdempotent(t *testing.T) {
	l := newDialLimiter(1, 50*time.Millisecond)
	defer l.close()
	ctx := context.Background()

	rel, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	rel()
	rel() // must be no-op, must not panic, must not over-release

	rel2, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatalf("acquire after double-release: %v", err)
	}
	rel2()
}

func TestDialLimiter_GCRemovesIdleBuckets(t *testing.T) {
	l := newDialLimiter(1, 50*time.Millisecond)
	defer l.close()
	ctx := context.Background()

	rel, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	rel()

	l.mu.Lock()
	if _, ok := l.buckets["1.1.1.1"]; !ok {
		l.mu.Unlock()
		t.Fatal("bucket missing after acquire")
	}
	l.mu.Unlock()

	l.gcOnce(time.Now().Add(10*time.Minute), 5*time.Minute)

	l.mu.Lock()
	_, exists := l.buckets["1.1.1.1"]
	l.mu.Unlock()
	if exists {
		t.Error("idle bucket not GC'd")
	}
}

func TestDialLimiter_GCKeepsActiveBuckets(t *testing.T) {
	l := newDialLimiter(1, 50*time.Millisecond)
	defer l.close()
	ctx := context.Background()

	rel, err := l.acquire(ctx, "1.1.1.1")
	if err != nil {
		t.Fatal(err)
	}
	defer rel()

	// Even far in the future, an in-use bucket must not be removed.
	l.gcOnce(time.Now().Add(time.Hour), 5*time.Minute)

	l.mu.Lock()
	_, exists := l.buckets["1.1.1.1"]
	l.mu.Unlock()
	if !exists {
		t.Error("active bucket was GC'd")
	}
}

func TestDialLimiter_ConcurrentAcquireRelease(t *testing.T) {
	l := newDialLimiter(4, 200*time.Millisecond)
	defer l.close()
	ctx := context.Background()

	var inFlight atomic.Int32
	var maxSeen atomic.Int32
	var wg sync.WaitGroup

	for i := 0; i < 50; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			rel, err := l.acquire(ctx, "1.1.1.1")
			if err != nil {
				return
			}
			cur := inFlight.Add(1)
			for {
				prev := maxSeen.Load()
				if cur <= prev || maxSeen.CompareAndSwap(prev, cur) {
					break
				}
			}
			time.Sleep(10 * time.Millisecond)
			inFlight.Add(-1)
			rel()
		}()
	}
	wg.Wait()

	if got := maxSeen.Load(); got > 4 {
		t.Errorf("max in-flight = %d, want <= 4", got)
	}
}
