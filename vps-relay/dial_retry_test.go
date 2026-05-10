package main

import (
	"context"
	"errors"
	"fmt"
	"net"
	"sync/atomic"
	"testing"
	"time"
)

type fakeNetErr struct{ timeout bool }

func (e *fakeNetErr) Error() string   { return "fake" }
func (e *fakeNetErr) Timeout() bool   { return e.timeout }
func (e *fakeNetErr) Temporary() bool { return false }

func TestIsTimeoutErr(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want bool
	}{
		{"nil", nil, false},
		{"plain", errors.New("boom"), false},
		{"context.DeadlineExceeded", context.DeadlineExceeded, true},
		{"net.Error timeout", &fakeNetErr{timeout: true}, true},
		{"net.Error not timeout", &fakeNetErr{timeout: false}, false},
		{"wrapped DeadlineExceeded", fmt.Errorf("wrap: %w", context.DeadlineExceeded), true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := isTimeoutErr(tc.err); got != tc.want {
				t.Errorf("isTimeoutErr(%v) = %v, want %v", tc.err, got, tc.want)
			}
		})
	}
}

func TestDialWithRetry_FirstAttemptSucceeds(t *testing.T) {
	var calls int32
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		atomic.AddInt32(&calls, 1)
		return &net.TCPConn{}, nil
	}
	conn, attempt, err := dialWithRetry(context.Background(), dial, "1.2.3.4:443", time.Second, 3, 10*time.Millisecond)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if conn == nil {
		t.Fatal("expected conn")
	}
	if attempt != 0 {
		t.Errorf("attempt=%d, want 0", attempt)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Errorf("calls=%d, want 1", got)
	}
}

func TestDialWithRetry_TimeoutThenSuccess(t *testing.T) {
	var calls int32
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		n := atomic.AddInt32(&calls, 1)
		if n == 1 {
			return nil, &fakeNetErr{timeout: true}
		}
		return &net.TCPConn{}, nil
	}
	conn, attempt, err := dialWithRetry(context.Background(), dial, "x", time.Second, 2, 1*time.Millisecond)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if conn == nil {
		t.Fatal("expected conn")
	}
	if attempt != 1 {
		t.Errorf("attempt=%d, want 1", attempt)
	}
	if got := atomic.LoadInt32(&calls); got != 2 {
		t.Errorf("calls=%d, want 2", got)
	}
}

func TestDialWithRetry_AllAttemptsTimeout(t *testing.T) {
	var calls int32
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		atomic.AddInt32(&calls, 1)
		return nil, &fakeNetErr{timeout: true}
	}
	conn, attempt, err := dialWithRetry(context.Background(), dial, "x", time.Second, 3, 1*time.Millisecond)
	if err == nil {
		t.Fatal("expected error")
	}
	if conn != nil {
		t.Fatal("expected nil conn")
	}
	if attempt != 2 {
		t.Errorf("attempt=%d, want 2 (last index)", attempt)
	}
	if got := atomic.LoadInt32(&calls); got != 3 {
		t.Errorf("calls=%d, want 3", got)
	}
}

func TestDialWithRetry_NonTimeoutErrorNoRetry(t *testing.T) {
	var calls int32
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		atomic.AddInt32(&calls, 1)
		return nil, errors.New("connection refused")
	}
	_, attempt, err := dialWithRetry(context.Background(), dial, "x", time.Second, 5, 1*time.Millisecond)
	if err == nil {
		t.Fatal("expected error")
	}
	if attempt != 0 {
		t.Errorf("attempt=%d, want 0", attempt)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Errorf("calls=%d, want 1 (no retry on non-timeout)", got)
	}
}

func TestDialWithRetry_ContextCanceledMidLoop(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	var calls int32
	dial := func(c context.Context, network, addr string) (net.Conn, error) {
		atomic.AddInt32(&calls, 1)
		if atomic.LoadInt32(&calls) == 1 {
			cancel() // trip outer ctx after first failure, before backoff finishes
			return nil, &fakeNetErr{timeout: true}
		}
		return &net.TCPConn{}, nil
	}
	_, _, err := dialWithRetry(ctx, dial, "x", time.Second, 3, 50*time.Millisecond)
	if !errors.Is(err, context.Canceled) {
		t.Errorf("err=%v, want context.Canceled", err)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Errorf("calls=%d, want 1 (canceled during backoff)", got)
	}
}

func TestDialWithRetry_ZeroAttemptsDefaults(t *testing.T) {
	var calls int32
	dial := func(ctx context.Context, network, addr string) (net.Conn, error) {
		atomic.AddInt32(&calls, 1)
		return &net.TCPConn{}, nil
	}
	_, _, err := dialWithRetry(context.Background(), dial, "x", time.Second, 0, time.Millisecond)
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if got := atomic.LoadInt32(&calls); got != 1 {
		t.Errorf("calls=%d, want 1 (zero attempts treated as 1)", got)
	}
}
