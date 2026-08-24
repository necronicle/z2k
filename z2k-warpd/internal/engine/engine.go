// Package engine — главный цикл z2k-warpd: device.json → TUN → NAT →
// лестница транспортов → liveness → status.json. Всё, что можно подменить
// в тестах (часы, сон, транспорты, TUN, команды), приходит через Config.
package engine

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"time"

	"golang.zx2c4.com/wireguard/tun"

	"github.com/necronicle/z2k/z2k-warpd/internal/account"
	"github.com/necronicle/z2k/z2k-warpd/internal/health"
	"github.com/necronicle/z2k/z2k-warpd/internal/ladder"
	"github.com/necronicle/z2k/z2k-warpd/internal/nat"
	"github.com/necronicle/z2k/z2k-warpd/internal/status"
	"github.com/necronicle/z2k/z2k-warpd/internal/transport"
	"github.com/necronicle/z2k/z2k-warpd/internal/tundev"
	"github.com/necronicle/z2k/z2k-warpd/internal/tunshare"
)

const (
	// MTU — одно значение для обоих транспортов: смена транспорта без
	// пересоздания TUN. 1280 — потолок h2 (нет PMTU, движок режет по буферу).
	MTU         = 1280
	openTimeout = 15 * time.Second
	tick        = time.Second
	// tunOffset — запас перед пакетом, который просят транспорты (virtio-заголовок).
	tunOffset = 16
)

// TransportFactory строит транспорт под шаг лестницы.
type TransportFactory func(step account.Step, dev tun.Device, d *account.Device) (transport.Transport, error)

// Config — зависимости движка.
type Config struct {
	DevicePath string
	StatusPath string
	LockPath   string        // пусто = рядом со status.json
	ForceStep  *account.Step // --force-transport: лестница из одного шага
	Logf       func(string, ...any)

	Now          func() time.Time
	Sleep        func(ctx context.Context, d time.Duration) error
	NewTransport TransportFactory
	CreateTUN    func(name string, mtu int) (tun.Device, error)
	Run          tundev.Runner
	Probe        health.Prober
	SwitchTunnel func(ctx context.Context, d *account.Device, tunnel string) error
	// Proxy — VPS-релей для API, если напрямую заблокирован (как у register).
	Proxy string
	Tick  time.Duration
}

func (c *Config) defaults() {
	if c.Logf == nil {
		c.Logf = func(string, ...any) {}
	}
	if c.Now == nil {
		c.Now = time.Now
	}
	if c.Sleep == nil {
		c.Sleep = func(ctx context.Context, d time.Duration) error {
			t := time.NewTimer(d)
			defer t.Stop()
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-t.C:
				return nil
			}
		}
	}
	if c.CreateTUN == nil {
		c.CreateTUN = tundev.Create
	}
	if c.Run == nil {
		c.Run = tundev.Exec
	}
	if c.Probe == nil {
		c.Probe = health.TraceProbe(8 * time.Second)
	}
	if c.SwitchTunnel == nil {
		api := &account.Client{HTTP: &http.Client{Timeout: 25 * time.Second}}
		proxy := c.Proxy
		logf := c.Logf
		// Подмена ключа — это вызов API. На роутере, где API заблокирован
		// DPI, прямой PATCH не пройдёт, и без запасного пути h2-шаг умирал
		// ещё до транспорта — с тем же вердиктом no_endpoint, что и настоящий
		// полный блок. Тот же релей, что у регистрации.
		c.SwitchTunnel = func(ctx context.Context, d *account.Device, tunnel string) error {
			err := api.SwitchTunnel(ctx, d, tunnel)
			if err == nil || errors.Is(err, account.ErrRevoked) || proxy == "" {
				return err
			}
			logf("api: direct switch to %s failed (%v) — retrying via relay", tunnel, err)
			relay, perr := api.WithProxy(proxy)
			if perr != nil {
				return err
			}
			return relay.SwitchTunnel(ctx, d, tunnel)
		}
	}
	if c.Tick == 0 {
		c.Tick = tick
	}
}

// Engine — состояние одного запуска.
type Engine struct {
	cfg    Config
	d      *account.Device
	st     *status.Writer
	tunDev  *tunshare.Shared
	iface   string
	since   time.Time
	lastErr string // причина держится до первого успеха, а не до следующей записи
}

// Run выполняет цикл до отмены ctx. Возвращает ошибку только для
// невосстановимых состояний (нет device.json, нет TUN).
func Run(ctx context.Context, cfg Config) error {
	cfg.defaults()
	// Замок ДО всего: пока он не наш, мы не трогаем ни TUN, ни status.json —
	// иначе обречённый второй экземпляр сносит состояние живого первого.
	lockPath := cfg.LockPath
	if lockPath == "" {
		lockPath = filepath.Join(filepath.Dir(cfg.StatusPath), "warpd.lock")
	}
	release, err := acquireLock(lockPath)
	if err != nil {
		return err
	}
	defer release()

	e := &Engine{cfg: cfg, st: &status.Writer{Path: cfg.StatusPath, MinInterval: time.Second}, since: cfg.Now()}
	defer e.st.Remove()

	d, err2 := account.Load(cfg.DevicePath)
	err = err2
	if err != nil {
		e.write(status.Status{LastError: status.ErrRegisterBlocked})
		e.st.Flush()
		return fmt.Errorf("device.json: %w", err)
	}
	e.d = d

	if err := e.bringUpTUN(); err != nil {
		e.write(status.Status{LastError: status.ErrTunFailed})
		e.st.Flush()
		return err
	}
	defer e.tearDownTUN()

	// Статус пишем СРАЗУ, ещё до первой ступени: обход лестницы занимает
	// десятки секунд, а до этой строки status.json не существовал вовсе — и
	// панель, диагностика и selfheal всё это время читали «движок не
	// запущен» вместо «поднимается» (поле r-79.4).
	e.write(status.Status{Ready: false, Iface: e.iface, Addr: d.AddrV4, HandshakeAge: -1})
	e.st.Flush()

	if err := nat.Ensure(nat.Runner(cfg.Run), e.iface); err != nil {
		cfg.Logf("nat: %v", err)
	}
	defer nat.Remove(nat.Runner(cfg.Run), e.iface)

	var lad *ladder.Ladder
	if cfg.ForceStep != nil {
		fs := *cfg.ForceStep
		if fs.Transport == "wg" && fs.Host == "" {
			fs.Host = d.Endpoint.V4
		}
		lad = ladder.NewFixed(fs)
	} else {
		lad = ladder.New(d.Endpoint, d.LastGood)
	}
	mon := &health.Monitor{Probe: cfg.Probe, Doubt: 30 * time.Second, Fails: 2}

	for ctx.Err() == nil {
		step := lad.Current()
		e.write(status.Status{Ready: false, Transport: step.Transport, Endpoint: ladder.Label(step),
			Iface: e.iface, Addr: d.AddrV4, HandshakeAge: -1, LadderStep: lad.Index()})
		tr, err := e.open(ctx, step, e.tunDev.Handle())
		if err != nil {
			cfg.Logf("ladder: %s failed: %v", ladder.Label(step), err)
			next, wait := lad.Next(cfg.Now())
			if wait > 0 {
				cfg.Logf("ladder: full pass failed, next try in %s", wait.Round(time.Second))
				e.lastErr = status.ErrNoEndpoint
				e.write(status.Status{LastError: status.ErrNoEndpoint, LadderStep: lad.Index()})
				if err := cfg.Sleep(ctx, wait); err != nil {
					return nil
				}
			}
			_ = next
			continue
		}
		e.lastErr = ""
		good := lad.Good()
		// Форсированный шаг — отладка, а не опыт: память лестницы не трогаем,
		// иначе один прогон с --force-transport h2 пинил бы роутер на h2.
		if cfg.ForceStep == nil {
			d.LastGood = &good
			if err := d.Save(cfg.DevicePath); err != nil {
				cfg.Logf("device.json: %v", err)
			}
		}
		e.since = cfg.Now()
		mon.Reset()
		cfg.Logf("ladder: %s ok (%s)", ladder.Label(step), tr.Endpoint())
		e.serve(ctx, tr, step, lad, mon)
		tr.Close()
		if ctx.Err() == nil {
			lad.Next(cfg.Now())
		}
	}
	return nil
}

// open строит и открывает транспорт шага, переключая ключ устройства,
// если у Cloudflare активен ключ другого типа.
func (e *Engine) open(ctx context.Context, step account.Step, dev tun.Device) (transport.Transport, error) {
	tr, err := e.openOnce(ctx, step, dev, false)
	if err == nil || !errors.Is(err, transport.ErrNotEnrolled) {
		return tr, err
	}
	// Ключ, записанный у нас, Cloudflare не знает: device.json говорит
	// «masque», а на сервере зарегистрирован другой ключ (прерванная смена
	// транспорта, гонка, откат). Обычный путь сюда не заглядывает — он
	// меняет ключ, только если ТИП не совпал, — и роутер оставался в
	// «access denied» навсегда (поле r-79.4). Перерегистрируем тот же ключ.
	e.cfg.Logf("api: ключ не зарегистрирован — перерегистрирую и пробую снова")
	return e.openOnce(ctx, step, dev, true)
}

// openOnce строит и открывает транспорт; force — сменить ключ даже если тип
// в device.json уже совпадает.
func (e *Engine) openOnce(ctx context.Context, step account.Step, dev tun.Device, force bool) (transport.Transport, error) {
	want := account.TunnelWG
	if step.Transport == "h2" {
		want = account.TunnelMasque
	}
	if force || e.d.Tunnel != want {
		if err := e.cfg.SwitchTunnel(ctx, e.d, want); err != nil {
			if errors.Is(err, account.ErrRevoked) {
				e.lastErr = status.ErrDeviceRevoked
				e.write(status.Status{LastError: status.ErrDeviceRevoked, Iface: e.iface})
			}
			return nil, fmt.Errorf("switch key to %s: %w", want, err)
		}
		if err := e.d.Save(e.cfg.DevicePath); err != nil {
			e.cfg.Logf("device.json: %v", err)
		}
	}
	tr, err := e.cfg.NewTransport(step, dev, e.d)
	if err != nil {
		return nil, err
	}
	octx, cancel := context.WithTimeout(ctx, openTimeout)
	defer cancel()
	if err := tr.Open(octx); err != nil {
		tr.Close()
		return nil, err
	}
	return tr, nil
}

// serve держит транспорт, пока монитор не скажет Dead или не отменят ctx.
// На h2 раз в ProbeUpEvery пробует вернуться на WG.
func (e *Engine) serve(ctx context.Context, tr transport.Transport, step account.Step, lad *ladder.Ladder, mon *health.Monitor) {
	lastUp := e.cfg.Now()
	for {
		now := e.cfg.Now()
		h := tr.Health()
		v := mon.Assess(ctx, h, now, e.iface)
		e.write(status.Status{
			Ready:        v != health.Dead,
			Transport:    step.Transport,
			Endpoint:     tr.Endpoint(),
			Iface:        e.iface,
			Addr:         e.d.AddrV4,
			HandshakeAge: h.HandshakeAge(now),
			Rx:           h.Rx,
			Tx:           h.Tx,
			LadderStep:   lad.Index(),
			Since:        e.since.Unix(),
		})
		if v == health.Dead {
			e.cfg.Logf("health: %s dead (%v)", ladder.Label(step), h.Err)
			return
		}
		if lad.OnH2() && e.cfg.ForceStep == nil && now.Sub(lastUp) >= ladder.ProbeUpEvery {
			lastUp = now
			if e.wgReachable(ctx) {
				e.cfg.Logf("ladder: WireGuard reachable again — leaving h2")
				lad.Top()
				return
			}
		}
		if err := e.cfg.Sleep(ctx, e.cfg.Tick); err != nil {
			return
		}
	}
}

// wgReachable пробует WG-handshake на пустом TUN. Ключ на время пробы
// переключается на WG и возвращается на MASQUE при провале.
func (e *Engine) wgReachable(ctx context.Context) bool {
	nt := newNullTun(MTU)
	defer nt.Close()
	tr, err := e.open(ctx, account.Step{Transport: "wg", Host: e.d.Endpoint.V4, Port: 2408}, nt)
	if err != nil {
		if e.d.Tunnel != account.TunnelMasque {
			if err := e.cfg.SwitchTunnel(ctx, e.d, account.TunnelMasque); err == nil {
				_ = e.d.Save(e.cfg.DevicePath)
			}
		}
		return false
	}
	tr.Close()
	return true
}

func (e *Engine) bringUpTUN() error {
	name := e.d.Iface
	if name == "" {
		name = tundev.PickName(func(n string) bool { return tundev.Exists(e.cfg.Run, n) })
	}
	dev, err := e.cfg.CreateTUN(name, MTU)
	if err != nil {
		return fmt.Errorf("tun %s: %w", name, err)
	}
	if err := tundev.Configure(e.cfg.Run, name, e.d.AddrV4, MTU); err != nil {
		dev.Close()
		return fmt.Errorf("tun %s: %w", name, err)
	}
	e.tunDev, e.iface = tunshare.New(dev, MTU, tunOffset), name
	if e.d.Iface != name {
		e.d.Iface = name
		if err := e.d.Save(e.cfg.DevicePath); err != nil {
			e.cfg.Logf("device.json: %v", err)
		}
	}
	e.cfg.Logf("tun: %s %s/32 mtu %d", name, e.d.AddrV4, MTU)
	return nil
}

func (e *Engine) tearDownTUN() {
	if e.tunDev == nil {
		return
	}
	tundev.Teardown(e.cfg.Run, e.iface)
	e.tunDev.Close()
	e.tunDev = nil
}

func (e *Engine) write(s status.Status) {
	s.PID = os.Getpid()
	if s.LastError == "" {
		s.LastError = e.lastErr
	}
	if s.Iface == "" {
		s.Iface = e.iface
	}
	if s.Since == 0 {
		s.Since = e.since.Unix()
	}
	_ = e.st.Write(s)
}
