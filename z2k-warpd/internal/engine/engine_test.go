package engine

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/status"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

// fakeTransport — Open удаётся по таблице; Health управляется тестом.
type fakeTransport struct {
	step   account.Step
	openOK bool
	mu     sync.Mutex
	h      transport.Health
	closed bool
}

func (f *fakeTransport) Open(context.Context) error {
	if !f.openOK {
		return transport.ErrNoHandshake
	}
	f.mu.Lock()
	f.h = transport.Health{Connected: true, LastHandshake: time.Unix(1, 0)}
	f.mu.Unlock()
	return nil
}
func (f *fakeTransport) Health() transport.Health { f.mu.Lock(); defer f.mu.Unlock(); return f.h }
func (f *fakeTransport) Close() error             { f.mu.Lock(); f.closed = true; f.mu.Unlock(); return nil }
func (f *fakeTransport) Endpoint() string         { return "1.2.3.4:1" }
func (f *fakeTransport) die() {
	f.mu.Lock()
	f.h = transport.Health{Err: errors.New("boom")}
	f.mu.Unlock()
}

type harness struct {
	t        *testing.T
	dir      string
	dev      string
	stat     string
	now      time.Time
	sleeps   []time.Duration
	cmds     []string
	made     []*fakeTransport
	openOK   map[string]bool
	switched []string
	rules    map[string]bool
	mu       sync.Mutex
}

func newHarness(t *testing.T, d *account.Device, openOK map[string]bool) *harness {
	dir := t.TempDir()
	h := &harness{t: t, dir: dir, dev: filepath.Join(dir, "device.json"), stat: filepath.Join(dir, "status.json"),
		now: time.Unix(10000, 0), openOK: openOK, rules: map[string]bool{}}
	if err := d.Save(h.dev); err != nil {
		t.Fatal(err)
	}
	return h
}

func (h *harness) config() Config {
	return Config{
		DevicePath: h.dev, StatusPath: h.stat,
		Now: func() time.Time { h.mu.Lock(); defer h.mu.Unlock(); return h.now },
		Sleep: func(ctx context.Context, d time.Duration) error {
			h.mu.Lock()
			h.sleeps = append(h.sleeps, d)
			h.now = h.now.Add(d)
			h.mu.Unlock()
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-time.After(time.Millisecond):
				return nil
			}
		},
		NewTransport: func(step account.Step, _ tun.Device, _ *account.Device) (transport.Transport, error) {
			f := &fakeTransport{step: step, openOK: h.openOK[step.Transport+":"+itoa(step.Port)]}
			if step.Transport == "wg" && step.Host == "" {
				panic("wg step without host")
			}
			h.mu.Lock()
			h.made = append(h.made, f)
			h.mu.Unlock()
			return f, nil
		},
		CreateTUN: func(name string, mtu int) (tun.Device, error) { return newNullTun(mtu), nil },
		Run: func(name string, args ...string) (string, error) {
			h.mu.Lock()
			defer h.mu.Unlock()
			h.cmds = append(h.cmds, name+" "+strings.Join(args, " "))
			if name == "iptables" && len(args) > 4 {
				key := strings.Join(args[4:], " ")
				switch args[3] {
				case "-C":
					if h.rules[key] {
						return "", nil
					}
					return "", errors.New("no rule")
				case "-A":
					h.rules[key] = true
				case "-D":
					delete(h.rules, key)
				}
			}
			return "", nil
		},
		Probe: func(context.Context, string) error { return nil },
		SwitchTunnel: func(_ context.Context, d *account.Device, tunnel string) error {
			h.mu.Lock()
			h.switched = append(h.switched, tunnel)
			h.mu.Unlock()
			d.Tunnel = tunnel
			if tunnel == account.TunnelMasque && d.H2 == nil {
				d.H2 = &account.H2Key{PrivateKey: "k"}
			}
			return nil
		},
		Tick: time.Second,
	}
}

func itoa(i int) string {
	b := []byte{}
	if i == 0 {
		return "0"
	}
	for i > 0 {
		b = append([]byte{byte('0' + i%10)}, b...)
		i /= 10
	}
	return string(b)
}

func baseDevice() *account.Device {
	return &account.Device{PrivateKey: "p", ID: "id", Token: "t", ClientID: "Mv0s", AddrV4: "172.16.0.2",
		PeerKey: "peer", Tunnel: account.TunnelWG, Endpoint: account.Endpoint{V4: "8.6.112.0", Ports: []int{854}}}
}

// waitFor ждёт условие до deadline, а не фиксированные 200 итераций по 5 мс.
//
// Прежний бюджет — ровно одна секунда — измерял не поведение движка, а скорость
// машины. Под -race детектор гонок замедляет всё в разы, и на общем раннере
// GitHub этой секунды не хватало: TestAllFailSetsNoEndpointAndCoolsDown падал
// «timeout waiting for no_endpoint status» на коммите, который движка вообще не
// касался, и краснил релиз. Локально тот же тест проходил всегда.
//
// Таймаут здесь — страховка от зависания, а не утверждение о скорости, поэтому
// бюджет щедрый: зелёный прогон всё равно возвращается за миллисекунды, а
// красный означает настоящее зависание, а не занятый раннер.
func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for {
		if cond() {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timeout waiting for %s", what)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func readStatus(h *harness) *status.Status {
	s, err := status.Read(h.stat)
	if err != nil {
		return nil
	}
	return s
}

func TestFirstFailsSecondWorksAndRemembersLastGood(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:854": true})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, h.config()); close(done) }()
	waitFor(t, "ready", func() bool { s := readStatus(h); return s != nil && s.Ready && s.Transport == "wg" })
	d, _ := account.Load(h.dev)
	if d.LastGood == nil || d.LastGood.Port != 854 {
		t.Fatalf("last_good %+v", d.LastGood)
	}
	if d.Iface != "z2ktun0" {
		t.Fatalf("iface %q", d.Iface)
	}
	cancel()
	<-done
	if _, err := os.Stat(h.stat); !os.IsNotExist(err) {
		t.Fatal("status.json must be removed on exit")
	}
	joined := strings.Join(h.cmds, "\n")
	for _, want := range []string{"ip addr add 172.16.0.2/32 dev z2ktun0", "-A FORWARD -o z2ktun0 -j ACCEPT", "-A POSTROUTING -o z2ktun0 -j MASQUERADE", "-D POSTROUTING -o z2ktun0 -j MASQUERADE", "-D FORWARD -o z2ktun0 -j ACCEPT", "ip link set dev z2ktun0 down"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing %q in\n%s", want, joined)
		}
	}
}

func TestAllFailSetsNoEndpointAndCoolsDown(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, h.config()); close(done) }()
	waitFor(t, "cooldown sleep", func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		for _, s := range h.sleeps {
			if s >= 4*time.Minute {
				return true
			}
		}
		return false
	})
	waitFor(t, "no_endpoint status", func() bool { s := readStatus(h); return s != nil && !s.Ready && s.LastError == status.ErrNoEndpoint })
	h.mu.Lock()
	sw := strings.Join(h.switched, ",")
	h.mu.Unlock()
	if !strings.Contains(sw, "masque") {
		t.Fatalf("h2 step must switch key to masque: %q", sw)
	}
	cancel()
	<-done
}

func TestDeadTransportIsClosedAndLadderMoves(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true, "wg:854": true})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, h.config()); close(done) }()
	waitFor(t, "ready on 2408", func() bool { s := readStatus(h); return s != nil && s.Ready })
	h.mu.Lock()
	first := h.made[0]
	h.mu.Unlock()
	first.die()
	waitFor(t, "second transport", func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return len(h.made) >= 2 && h.made[1].step.Port == 854
	})
	first.mu.Lock()
	closed := first.closed
	first.mu.Unlock()
	if !closed {
		t.Fatal("dead transport not closed")
	}
	cancel()
	<-done
}

func TestSecondInstanceRefusesAndKeepsTheFirstOnesStatus(t *testing.T) {
	// Поле r-79.4: второй экземпляр падал на TUN («device or resource busy»),
	// но по дороге сносил status.json живого первого, а init записывал в
	// pidfile его мёртвый pid — selfheal перезапускал вечно.
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, h.config()); close(done) }()
	waitFor(t, "первый готов", func() bool { s := readStatus(h); return s != nil && s.Ready })

	cfg2 := h.config()
	if err := Run(context.Background(), cfg2); err != ErrAlreadyRunning {
		t.Fatalf("второй экземпляр обязан отказаться: %v", err)
	}
	if s := readStatus(h); s == nil || !s.Ready {
		t.Fatal("второй экземпляр снёс status.json первого")
	}
	cancel()
	<-done
}

func TestStatusExistsWhileTheLadderIsStillWalking(t *testing.T) {
	// Пока лестница ищет транспорт (десятки секунд), status.json обязан
	// существовать со «не готов»: иначе панель и диагностика говорят
	// «движок не запущен», а selfheal снимает маршрут.
	h := newHarness(t, baseDevice(), map[string]bool{}) // ни один транспорт не поднимется
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, h.config()); close(done) }()
	waitFor(t, "статус во время обхода", func() bool { s := readStatus(h); return s != nil && !s.Ready && s.Iface == "z2ktun0" })
	cancel()
	<-done
}

func TestMissingDeviceJSON(t *testing.T) {
	dir := t.TempDir()
	cfg := Config{DevicePath: filepath.Join(dir, "none.json"), StatusPath: filepath.Join(dir, "status.json")}
	if err := Run(context.Background(), cfg); err == nil {
		t.Fatal("want error")
	}
}

func TestForceStepUsesOnlyThatStep(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	cfg := h.config()
	cfg.ForceStep = &account.Step{Transport: "wg", Port: 854} // не работает по таблице
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, cfg); close(done) }()
	waitFor(t, "two attempts", func() bool { h.mu.Lock(); defer h.mu.Unlock(); return len(h.made) >= 2 })
	h.mu.Lock()
	for _, m := range h.made {
		if m.step.Port != 854 {
			t.Fatalf("forced step violated: %+v", m.step)
		}
	}
	h.mu.Unlock()
	cancel()
	<-done
}

func TestForcedStepDoesNotWriteLastGood(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:854": true})
	cfg := h.config()
	cfg.ForceStep = &account.Step{Transport: "wg", Port: 854}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, cfg); close(done) }()
	waitFor(t, "ready", func() bool { s := readStatus(h); return s != nil && s.Ready })
	cancel()
	<-done
	d, _ := account.Load(h.dev)
	if d.LastGood != nil {
		t.Fatalf("forced run wrote last_good %+v", d.LastGood)
	}
}
