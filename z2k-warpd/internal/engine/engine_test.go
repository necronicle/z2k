package engine

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/edgepick"
	"github.com/necronicle/z2k/z2k-warpd/internal/status"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
)

func TestForeignEdgeSelectedBeforeFasterDomestic(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	ru := account.Step{Transport: "wg", Host: "8.6.112.1", Port: 2408}
	fi := account.Step{Transport: "wg", Host: "188.114.96.23", Port: 2408}
	cfg := h.config()
	cfg.EdgeCandidates = []account.Step{ru, fi}
	cfg.EdgeCachePath = filepath.Join(h.dir, "edge-cache.json")
	cfg.EdgeWAN = func(string) (string, error) { return "usb0|192.0.2.2", nil }
	cfg.GeoProbe = func(context.Context, string) (edgepick.Meta, time.Duration, int, error) {
		h.mu.Lock()
		host := h.made[len(h.made)-1].step.Host
		h.mu.Unlock()
		if host == fi.Host {
			return edgepick.Meta{Colo: "HEL", Country: "FI"}, 40 * time.Millisecond, 0, nil
		}
		return edgepick.Meta{Colo: "DME", Country: "RU"}, 5 * time.Millisecond, 0, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = Run(ctx, cfg); close(done) }()
	waitFor(t, "foreign edge ready", func() bool {
		s := readStatus(h)
		if s == nil || !s.Ready {
			return false
		}
		h.mu.Lock()
		defer h.mu.Unlock()
		return len(h.made) >= 3 && h.made[len(h.made)-1].step.Host == fi.Host
	})
	if s := readStatus(h); s.EdgeColo != "HEL" || s.EdgeCountry != "FI" || s.EdgeRTTMs != 40 || s.EdgeSelection != "foreign" {
		t.Fatalf("selected edge status: %+v", s)
	}
	h.mu.Lock()
	now := h.now
	h.mu.Unlock()
	if got := edgepick.LoadCache(cfg.EdgeCachePath, "usb0|192.0.2.2", now); len(got) != 2 || got[0].Country != "RU" || got[1].Country != "FI" {
		t.Fatalf("verified cache: %+v", got)
	}
	cancel()
	<-done
}

func TestForeignScanCancellationLeavesNoCacheOrReadyRoute(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	cfg := h.config()
	cfg.EdgeCandidates = []account.Step{{Transport: "wg", Host: "8.6.112.1", Port: 2408}}
	cfg.EdgeCachePath = filepath.Join(h.dir, "edge-cache.json")
	cfg.EdgeWAN = func(string) (string, error) { return "usb0|192.0.2.2", nil }
	started := make(chan struct{})
	cfg.GeoProbe = func(ctx context.Context, _ string) (edgepick.Meta, time.Duration, int, error) {
		close(started)
		<-ctx.Done()
		return edgepick.Meta{}, 0, 100, ctx.Err()
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = Run(ctx, cfg); close(done) }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("scan did not start")
	}
	if s := readStatus(h); s == nil || s.Ready {
		t.Fatalf("scan marked ready: %+v", s)
	}
	cancel()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("cancelled scan did not stop")
	}
	if _, err := os.Stat(cfg.EdgeCachePath); !os.IsNotExist(err) {
		t.Fatalf("partial cache left after cancel: %v", err)
	}
}

func TestForeignEdgeFailureFallsThroughToDomestic(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	fi := account.Step{Transport: "wg", Host: "188.114.96.23", Port: 2408}
	ru := account.Step{Transport: "wg", Host: "8.6.112.1", Port: 2408}
	cfg := h.config()
	cfg.EdgeCandidates = []account.Step{fi, ru}
	cfg.EdgeCachePath = filepath.Join(h.dir, "edge-cache.json")
	cfg.EdgeWAN = func(string) (string, error) { return "usb0|192.0.2.2", nil }
	cfg.GeoProbe = func(context.Context, string) (edgepick.Meta, time.Duration, int, error) {
		h.mu.Lock()
		host := h.made[len(h.made)-1].step.Host
		h.mu.Unlock()
		if host == fi.Host {
			return edgepick.Meta{Colo: "HEL", Country: "FI"}, 30 * time.Millisecond, 0, nil
		}
		return edgepick.Meta{Colo: "DME", Country: "RU"}, 10 * time.Millisecond, 0, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = Run(ctx, cfg); close(done) }()
	waitFor(t, "foreign ready", func() bool { s := readStatus(h); return s != nil && s.Ready && s.EdgeSelection == "foreign" })
	h.mu.Lock()
	foreignTransport := h.made[len(h.made)-1]
	h.mu.Unlock()
	foreignTransport.die()
	waitFor(t, "domestic fallback ready", func() bool { s := readStatus(h); return s != nil && s.Ready && s.EdgeSelection == "domestic" })
	cancel()
	<-done
}

func TestUnlocatedEdgeIsNotPreferredOverLocatedDomestic(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	unknown := account.Step{Transport: "wg", Host: "8.6.112.1", Port: 2408}
	ru := account.Step{Transport: "wg", Host: "188.114.96.23", Port: 2408}
	cfg := h.config()
	cfg.EdgeCandidates = []account.Step{unknown, ru}
	cfg.EdgeCachePath = filepath.Join(h.dir, "edge-cache.json")
	cfg.EdgeWAN = func(string) (string, error) { return "usb0|192.0.2.2", nil }
	cfg.GeoProbe = func(context.Context, string) (edgepick.Meta, time.Duration, int, error) {
		h.mu.Lock()
		host := h.made[len(h.made)-1].step.Host
		h.mu.Unlock()
		if host == unknown.Host {
			return edgepick.Meta{}, 0, 100, errors.New("meta HTTPS timeout")
		}
		return edgepick.Meta{Colo: "DME", Country: "RU"}, 20 * time.Millisecond, 0, nil
	}
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = Run(ctx, cfg); close(done) }()
	waitFor(t, "located domestic ready", func() bool {
		s := readStatus(h)
		return s != nil && s.Ready && s.EdgeSelection == "domestic"
	})
	h.mu.Lock()
	selected := h.made[len(h.made)-1].step.Host
	h.mu.Unlock()
	if selected != ru.Host {
		t.Fatalf("selected unlocated endpoint %s", selected)
	}
	h.mu.Lock()
	now := h.now
	h.mu.Unlock()
	if got := edgepick.LoadCache(cfg.EdgeCachePath, "usb0|192.0.2.2", now); len(got) != 1 || got[0].Step != ru {
		t.Fatalf("unlocated endpoint entered preferred cache: %+v", got)
	}
	cancel()
	<-done
}

func TestCachedForeignEdgeRecheckedOnlyOnMatchingWAN(t *testing.T) {
	for _, tc := range []struct{ name, wan, firstHost string }{
		{"same WAN", "usb0|192.0.2.2", "188.114.96.23"},
		{"changed WAN", "wifi0|198.51.100.3", "8.6.112.1"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
			fi := account.Step{Transport: "wg", Host: "188.114.96.23", Port: 2408}
			ru := account.Step{Transport: "wg", Host: "8.6.112.1", Port: 2408}
			cfg := h.config()
			cfg.EdgeCandidates = []account.Step{ru, fi}
			cfg.EdgeCachePath = filepath.Join(h.dir, "edge-cache.json")
			if err := edgepick.SaveCache(context.Background(), cfg.EdgeCachePath, "usb0|192.0.2.2", []edgepick.Result{{Step: fi, Country: "FI", Colo: "HEL", CheckedAt: h.now}}); err != nil {
				t.Fatal(err)
			}
			cfg.EdgeWAN = func(string) (string, error) { return tc.wan, nil }
			cfg.GeoProbe = func(context.Context, string) (edgepick.Meta, time.Duration, int, error) {
				return edgepick.Meta{Colo: "HEL", Country: "FI"}, 30 * time.Millisecond, 0, nil
			}
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() { _ = Run(ctx, cfg); close(done) }()
			waitFor(t, "ready after cache decision", func() bool { s := readStatus(h); return s != nil && s.Ready })
			h.mu.Lock()
			first := h.made[0].step.Host
			h.mu.Unlock()
			if first != tc.firstHost {
				t.Fatalf("first scanned host %s, want %s", first, tc.firstHost)
			}
			cancel()
			<-done
		})
	}
}

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
				if args[3] == "-I" && len(args) > 5 && args[5] == "1" {
					key = args[4] + " " + strings.Join(args[6:], " ")
				}
				switch args[3] {
				case "-C":
					if h.rules[key] {
						return "", nil
					}
					return "", errors.New("no rule")
				case "-A", "-I":
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

// fmtSprintf — форматирование логов теста; отдельной функцией, чтобы
// "fmt" не тянулся в каждый вызов.
func fmtSprintf(f string, a ...any) string { return fmt.Sprintf(f, a...) }

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
	for _, want := range []string{"ip addr add 172.16.0.2/32 dev z2ktun0", "-I FORWARD 1 -o z2ktun0 -m mark --mark 0x989/0x989 -j ACCEPT", "-I FORWARD 1 -i z2ktun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", "-A POSTROUTING -o z2ktun0 -j MASQUERADE", "-D POSTROUTING -o z2ktun0 -j MASQUERADE", "-D FORWARD -o z2ktun0 -m mark --mark 0x989/0x989 -j ACCEPT", "-D FORWARD -i z2ktun0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT", "ip link set dev z2ktun0 down"} {
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

// РЕГРЕСС ИЗ ПОЛЯ: транспорт встал — трафик не идёт — готовность объявлена.
//
// Диагностика 2026-08-24 15:44 с роутера пользователя:
//
//	"ready":true,"transport":"h2","rx":248,"tx":314319
//
// Триста килобайт отправлено, двести сорок восемь байт получено. Маршруты
// подняты, весь завёрнутый в WARP трафик — в никуда, и так пять минут, пока
// не пришёл EOF. Проба не спасала, потому что rx ПОДТЕКАЛ: любой его рост
// сбрасывает счётчик сомнения, тридцатисекундное окно не истекает никогда.
//
// Чинить это выбором транспортов в коде нельзя — на одной линии мёртв один,
// на другой другой, и правка начинает ходить по кругу. Готовность обязана
// быть ДОКАЗАННОЙ: пока сквозная проба не прошла, ready не даём, и тогда
// shell не поднимает маршрут, а трафик идёт напрямую (fail-open).
func TestBlackHoleNeverBecomesReady(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true})
	cfg := h.config()
	cfg.Probe = func(context.Context, string) error { return errors.New("чёрная дыра") }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { _ = Run(ctx, cfg); close(done) }()

	// Транспорт открылся — это видно по появлению status.json с ним.
	waitFor(t, "транспорт открыт", func() bool {
		s := readStatus(h)
		return s != nil && s.Transport != ""
	})
	// И сколько бы он ни держался, готовым не становится ни разу.
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if s := readStatus(h); s != nil && s.Ready {
			t.Fatal("непроверенный туннель объявлен готовым — маршруты уйдут в чёрную дыру")
		}
		time.Sleep(10 * time.Millisecond)
	}
	cancel()
	<-done
}

// Шаг, который ВСТАЁТ, но не возит, не должен ни попадать в last_good, ни
// сбрасывать счёт прохода лестницы.
//
// Поле 2026-08-27: wg:188.114.97.1:4500 — «handshake ok», через 15 с «dead».
// Роутер записывал его как рабочий по факту рукопожатия и каждый следующий
// старт начинал ровно с него; остальные ступени не пробовались ни разу, а
// кулдаун не наступал никогда, потому что тот же вызов сбрасывал счёт прохода.
func TestOpenedButUnprovenIsNotRememberedAndCoolsDown(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true, "wg:854": true, "h2:443": true})
	cfg := h.config()
	var logMu sync.Mutex
	var logged strings.Builder
	cfg.Logf = func(f string, a ...any) {
		logMu.Lock()
		defer logMu.Unlock()
		logged.WriteString(fmtSprintf(f, a...) + "\n")
	}
	cfg.Probe = func(context.Context, string) error { return errors.New("probe: warp=off") }
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, cfg); close(done) }()

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
	waitFor(t, "no_transit status", func() bool {
		s := readStatus(h)
		return s != nil && !s.Ready && s.LastError == status.ErrNoTransit
	})
	d, _ := account.Load(h.dev)
	if d.LastGood != nil {
		t.Fatalf("шаг без доказанной живости попал в last_good: %+v", d.LastGood)
	}
	logMu.Lock()
	out := logged.String()
	logMu.Unlock()
	if !strings.Contains(out, "dead (probe: warp=off)") {
		t.Fatalf("причина смерти не из пробы:\n%s", out)
	}
	if strings.Contains(out, "dead (<nil>)") {
		t.Fatalf("пустая причина смерти в логе:\n%s", out)
	}
	cancel()
	<-done
}

// Режим «только MASQUE»: WG не открывается ни лестницей, ни пробой возврата,
// и h2 не записывается в память — иначе автомат потом стартовал бы с него.
func TestModeH2NeverTouchesWGAndDoesNotPinLastGood(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"wg:2408": true, "wg:854": true, "h2:443": true})
	cfg := h.config()
	cfg.Mode = "h2"
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, cfg); close(done) }()
	waitFor(t, "ready on h2", func() bool { s := readStatus(h); return s != nil && s.Ready && s.Transport == "h2" })
	start := h.config().Now()
	waitFor(t, "11 минут на h2", func() bool { return h.config().Now().Sub(start) > 11*time.Minute })
	cancel()
	<-done
	h.mu.Lock()
	for _, m := range h.made {
		if m.step.Transport != "h2" {
			h.mu.Unlock()
			t.Fatalf("в режиме MASQUE открыт %+v", m.step)
		}
	}
	h.mu.Unlock()
	d, _ := account.Load(h.dev)
	if d.LastGood != nil {
		t.Fatalf("режим MASQUE записал last_good %+v", d.LastGood)
	}
}

// Контраст к тесту выше: в автомате та же картина через десять минут на h2
// уходит обратно на WireGuard. Без него тест режима проходил бы и тогда, когда
// проба возврата сломана целиком.
func TestAutoOnH2ProbesBackToWG(t *testing.T) {
	d := baseDevice()
	d.LastGood = &account.Step{Transport: "h2", Port: 443}
	h := newHarness(t, d, map[string]bool{"wg:2408": true, "h2:443": true})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, h.config()); close(done) }()
	// Статус наружу пишется не чаще раза в секунду, а десять минут на h2 в
	// харнесе пролетают быстрее — поэтому смотрим не на статус, а на порядок
	// открытых транспортов: сперва h2 с памяти, потом WireGuard.
	waitFor(t, "возврат на wg", func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		return len(h.made) >= 2 && h.made[0].step.Transport == "h2" && h.made[len(h.made)-1].step.Transport == "wg"
	})
	cancel()
	<-done
}

// Режим «только WireGuard»: когда все WG-ступени мертвы, движок уходит в
// кулдаун, а не на MASQUE.
func TestModeWGNeverFallsToH2(t *testing.T) {
	h := newHarness(t, baseDevice(), map[string]bool{"h2:443": true})
	cfg := h.config()
	cfg.Mode = "wg"
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan struct{})
	go func() { Run(ctx, cfg); close(done) }()
	waitFor(t, "кулдаун после полного прохода", func() bool {
		h.mu.Lock()
		defer h.mu.Unlock()
		for _, s := range h.sleeps {
			if s > time.Minute {
				return true
			}
		}
		return false
	})
	cancel()
	<-done
	h.mu.Lock()
	defer h.mu.Unlock()
	for _, m := range h.made {
		if m.step.Transport == "h2" {
			t.Fatalf("режим WireGuard открыл h2")
		}
	}
}
