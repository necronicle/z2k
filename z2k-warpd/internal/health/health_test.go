package health

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

func mon(probeErr error, calls *int) *Monitor {
	return &Monitor{
		Probe: func(context.Context, string) error { *calls++; return probeErr },
		Doubt: 30 * time.Second,
		Fails: 2,
	}
}

func conn(rx, tx uint64) transport.Health {
	return transport.Health{Connected: true, LastHandshake: time.Unix(1, 0), Rx: rx, Tx: tx}
}

func TestRxGrowingIsAliveWithoutProbe(t *testing.T) {
	var calls int
	m := mon(nil, &calls)
	t0 := time.Unix(1000, 0)
	if v := m.Assess(context.Background(), conn(100, 100), t0, "172.16.0.2"); v != Alive {
		t.Fatal(v)
	}
	if v := m.Assess(context.Background(), conn(200, 300), t0.Add(time.Second), "172.16.0.2"); v != Alive {
		t.Fatal(v)
	}
	if calls != 0 {
		t.Fatalf("probe called %d times", calls)
	}
}

func TestIdleIsAlive(t *testing.T) {
	var calls int
	m := mon(nil, &calls)
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	// ни tx, ни rx не растут 5 минут — никто не пользуется, это не смерть
	if v := m.Assess(context.Background(), conn(100, 100), t0.Add(5*time.Minute), ""); v != Alive {
		t.Fatal(v)
	}
	if calls != 0 {
		t.Fatal("probe on idle")
	}
}

func TestTxWithoutRxTriggersProbeThenAlive(t *testing.T) {
	var calls int
	m := mon(nil, &calls)
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	if v := m.Assess(context.Background(), conn(100, 500), t0.Add(10*time.Second), ""); v != Alive || calls != 0 {
		t.Fatalf("too early: %v calls=%d", v, calls)
	}
	if v := m.Assess(context.Background(), conn(100, 900), t0.Add(31*time.Second), ""); v != Alive || calls != 1 {
		t.Fatalf("probe must run once and pass: %v calls=%d", v, calls)
	}
}

func TestTwoProbeFailuresAreDead(t *testing.T) {
	var calls int
	m := mon(errors.New("timeout"), &calls)
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	if v := m.Assess(context.Background(), conn(100, 500), t0.Add(31*time.Second), ""); v != Doubtful || calls != 1 {
		t.Fatalf("first fail: %v calls=%d", v, calls)
	}
	if v := m.Assess(context.Background(), conn(100, 900), t0.Add(62*time.Second), ""); v != Dead || calls != 2 {
		t.Fatalf("second fail: %v calls=%d", v, calls)
	}
}

func TestProbeRateLimited(t *testing.T) {
	var calls int
	m := mon(errors.New("x"), &calls)
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	m.Assess(context.Background(), conn(100, 500), t0.Add(31*time.Second), "")
	m.Assess(context.Background(), conn(100, 600), t0.Add(32*time.Second), "") // сразу за первой — не пробовать
	if calls != 1 {
		t.Fatalf("probe hammered: %d", calls)
	}
}

func TestDisconnectedIsDoubtfulImmediately(t *testing.T) {
	var calls int
	m := mon(errors.New("x"), &calls)
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	h := transport.Health{Connected: false}
	if v := m.Assess(context.Background(), h, t0.Add(time.Second), ""); v != Doubtful {
		t.Fatal(v)
	}
	if v := m.Assess(context.Background(), h, t0.Add(40*time.Second), ""); v != Dead {
		t.Fatal(v)
	}
}

func TestTransportErrorIsDead(t *testing.T) {
	m := mon(nil, new(int))
	h := transport.Health{Connected: false, Err: errors.New("closed")}
	if v := m.Assess(context.Background(), h, time.Unix(1, 0), ""); v != Dead {
		t.Fatal(v)
	}
}

func TestResetAfterReopen(t *testing.T) {
	var calls int
	m := mon(errors.New("x"), &calls)
	t0 := time.Unix(1000, 0)
	m.Assess(context.Background(), conn(100, 100), t0, "")
	m.Assess(context.Background(), conn(100, 500), t0.Add(31*time.Second), "")
	m.Reset()
	if v := m.Assess(context.Background(), conn(0, 0), t0.Add(32*time.Second), ""); v != Alive {
		t.Fatal(v)
	}
}
