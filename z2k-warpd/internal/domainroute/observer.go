package domainroute

import (
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

type Status struct {
	Active   bool   `json:"active"`
	Rules    int    `json:"rules"`
	Pairs    int    `json:"pairs"`
	Skipped  uint64 `json:"skipped"`
	Overflow uint64 `json:"overflow"`
	Error    string `json:"error,omitempty"`
	// Исключения: домены «никогда через WARP» и сколько их адресов в наборе.
	ExclRules int `json:"excl_rules"`
	ExclPairs int `json:"excl_pairs"`
	// Ответы по IPv6 на домены из списков, устройство которых не нашлось в
	// таблице соседей: маршрут в WARP для них не поставлен.
	Unmapped uint64 `json:"unmapped"`
}

type Options struct {
	DomainPath, SnapshotPath, StatusPath string
	PairSet                              PairSet
	// Исключения. Пустой ExcludePath — выключены; отсутствующий файл — пустой
	// список, а не ошибка: исключений у большинства нет.
	ExcludePath, ExcludeSnapshotPath string
	ExclSet                          ExclSet
}

var ErrObserverAlreadyRunning = errors.New("domain observer is already running")

type Observer struct {
	mu      sync.Mutex
	decoder *PacketDecoder
	cache   *Cache
	excl    *Cache
	local   map[netip.Addr]struct{}
	neigh   *neighbors
	// noV6 — ядро без IPv6: ответы AAAA не учим, IPv6-наборов нет.
	noV6      bool
	active    bool
	overflow  uint64
	unmapped  uint64
	lastError string
}

func NewObserver(r Rules) *Observer {
	none, _ := ParseRules([]byte("v1\n"))
	return &Observer{decoder: NewPacketDecoder(), cache: NewCache(r), excl: NewExclusionCache(none), local: make(map[netip.Addr]struct{}), neigh: newNeighbors()}
}

func (o *Observer) SetLocalAddresses(addresses []netip.Addr) []Change {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.local = make(map[netip.Addr]struct{}, len(addresses))
	for _, ip := range addresses {
		// Свои адреса роутера обоих семейств: имя, указывающее на сам роутер,
		// в туннель уводить нельзя.
		o.local[ip.WithZone("")] = struct{}{}
	}
	var changes []Change
	for k := range o.cache.pairs {
		if _, owned := o.local[k.dest]; owned {
			delete(o.cache.pairs, k)
			changes = append(changes, Change{Client: k.client, Dest: k.dest, Delete: true})
		}
	}
	return changes
}

func routerAddresses() []netip.Addr {
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return nil
	}
	result := make([]netip.Addr, 0, len(addrs))
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok {
			continue
		}
		if ip, ok := netip.AddrFromSlice(ipnet.IP); ok {
			result = append(result, ip.Unmap())
		}
	}
	return result
}

func (o *Observer) Process(packet []byte, now time.Time) []Change {
	include, _ := o.ProcessAll(packet, now)
	return include
}

// ProcessAll разбирает ответ DNS один раз и отдаёт изменения обоим наборам:
// маршрутизации в WARP и исключений.
func (o *Observer) ProcessAll(packet []byte, now time.Time) (include, exclude []Change) {
	o.mu.Lock()
	defer o.mu.Unlock()
	if len(packet) > maxDNSFrame+60 {
		o.overflow++
		return nil, nil
	}
	client, payload, transport := o.decoder.Push(packet, now)
	if !client.IsValid() || len(payload) == 0 {
		return nil, nil
	}
	name, answers, err := ParseReply(payload, transport)
	if err != nil {
		return nil, nil
	}
	filtered := answers[:0]
	for _, answer := range answers {
		if _, local := o.local[answer.IP]; !local && !(o.noV6 && answer.IP.Is6()) {
			filtered = append(filtered, answer)
		}
	}
	exclude = o.excl.Observe(client, name, filtered, now)
	if client.Is6() {
		// Наборы маршрутизации — на IPv4 устройства. Соседей спрашиваем только
		// ради домена из списков: остальные ответы DNS их не касаются.
		if !o.cache.rules.Match(name) {
			return nil, exclude
		}
		v4, ok := o.neigh.ipv4For(client, now)
		if !ok {
			o.unmapped++
			return nil, exclude
		}
		client = v4
	}
	return o.cache.Observe(client, name, filtered, now), exclude
}

func (o *Observer) ReplaceExclusions(r Rules, now time.Time) []Change {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.excl.ReplaceRules(r, now)
}

func (o *Observer) ReplaceRules(r Rules, now time.Time) []Change {
	o.mu.Lock()
	defer o.mu.Unlock()
	return o.cache.ReplaceRules(r, now)
}

func (o *Observer) status() Status {
	o.mu.Lock()
	defer o.mu.Unlock()
	return Status{Active: o.active, Rules: o.cache.rules.Len(), Pairs: o.cache.Len(), Skipped: o.cache.Skipped(), Overflow: o.overflow, Error: o.lastError,
		ExclRules: o.excl.rules.Len(), ExclPairs: o.excl.Len(), Unmapped: o.unmapped}
}

func (o *Observer) setState(active bool, err error) {
	o.mu.Lock()
	defer o.mu.Unlock()
	o.active = active
	if err == nil {
		o.lastError = ""
	} else {
		o.lastError = err.Error()
	}
}

func writeStatus(path string, s Status) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	b, err := json.Marshal(s)
	if err != nil {
		return err
	}
	tmp := path + ".new"
	if err := os.WriteFile(tmp, b, 0600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func (o *Observer) Run(ctx context.Context, opts Options) error {
	if opts.DomainPath == "" || opts.SnapshotPath == "" || opts.StatusPath == "" {
		return errors.New("missing observer path")
	}
	if err := os.MkdirAll(filepath.Dir(opts.StatusPath), 0700); err != nil {
		return err
	}
	lock, err := os.OpenFile(filepath.Join(filepath.Dir(opts.StatusPath), "observer.lock"), os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return err
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return ErrObserverAlreadyRunning
	}
	defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	data, err := os.ReadFile(opts.DomainPath)
	if err != nil {
		o.setState(false, err)
		_ = writeStatus(opts.StatusPath, o.status())
		return err
	}
	rules, err := ParseRules(data)
	if err != nil {
		o.setState(false, err)
		_ = writeStatus(opts.StatusPath, o.status())
		return err
	}
	o.ReplaceRules(rules, time.Now())
	if _, err := os.Stat("/proc/net/if_inet6"); err != nil {
		o.mu.Lock()
		o.noV6 = true
		o.mu.Unlock()
		opts.ExclSet.NoV6 = true
	}
	if opts.PairSet.MACOf == nil {
		opts.PairSet.MACOf = func(client netip.Addr) (string, bool) { return o.neigh.macFor(client, time.Now()) }
	}
	excl := opts.ExcludePath != ""
	if excl {
		if r, err := readExclusions(opts.ExcludePath); err == nil {
			o.ReplaceExclusions(r, time.Now())
		} else {
			o.setState(false, err)
		}
	}
	o.SetLocalAddresses(routerAddresses())
	o.mu.Lock()
	err = o.cache.Load(opts.SnapshotPath, time.Now())
	if excl {
		// Битый снимок исключений не должен мешать ни маршрутизации, ни свежему
		// обучению: пустой кэш доучится по ответам DNS.
		_ = o.excl.Load(opts.ExcludeSnapshotPath, time.Now())
	}
	o.mu.Unlock()
	o.SetLocalAddresses(routerAddresses())
	o.mu.Lock()
	initial := o.cache.All(time.Now())
	initialExcl := o.excl.All(time.Now())
	o.mu.Unlock()
	if err != nil {
		// A corrupt tmpfs snapshot must not disable fresh DNS learning.
		o.setState(false, err)
	}
	var kernelMu sync.Mutex
	needReconcile := false
	// Устройства с проверенным правилом метки (см. PairSet.apply). Полный
	// проход — все пары кэша — проверяет каждое заново и заменяет память.
	marked := make(marks)
	apply := func(changes []Change) {
		kernelMu.Lock()
		defer kernelMu.Unlock()
		if err := opts.PairSet.apply(changes, time.Now(), marked); err != nil {
			needReconcile = true
			o.setState(false, err)
		}
	}
	applyAll := func(changes []Change) {
		kernelMu.Lock()
		defer kernelMu.Unlock()
		fresh := make(marks)
		if err := opts.PairSet.apply(changes, time.Now(), fresh); err != nil {
			needReconcile = true
			o.setState(false, err)
			marked = fresh
			return
		}
		marked = fresh
	}
	reconcile := func(changes []Change) {
		kernelMu.Lock()
		defer kernelMu.Unlock()
		fresh := make(marks)
		err := opts.PairSet.replaceAll(changes, time.Now(), fresh)
		marked = fresh
		if err != nil {
			needReconcile = true
			o.setState(false, err)
		} else {
			needReconcile = false
			o.setState(true, nil)
		}
	}
	reconcile(initial)
	exclPending := false
	applyExcl := func(changes []Change) {
		if !excl || len(changes) == 0 {
			return
		}
		kernelMu.Lock()
		defer kernelMu.Unlock()
		if err := opts.ExclSet.Apply(changes, time.Now()); err != nil {
			exclPending = true
			o.setState(false, err)
		}
	}
	reconcileExcl := func(changes []Change) {
		if !excl {
			return
		}
		kernelMu.Lock()
		defer kernelMu.Unlock()
		if err := opts.ExclSet.ReplaceAll(changes, time.Now()); err != nil {
			exclPending = true
			o.setState(false, err)
		} else {
			exclPending = false
		}
	}
	reconcileExcl(initialExcl)
	stop, err := receivePackets(ctx, func(packet []byte) {
		include, exclude := o.ProcessAll(packet, time.Now())
		apply(include)
		applyExcl(exclude)
	}, func(err error) { o.setState(false, err) })
	if err != nil {
		o.setState(false, err)
		_ = writeStatus(opts.StatusPath, o.status())
		return err
	}
	defer stop()
	kernelMu.Lock()
	pending := needReconcile
	kernelMu.Unlock()
	if !pending {
		o.setState(true, nil)
	}
	_ = writeStatus(opts.StatusPath, o.status())
	tick := time.NewTicker(5 * time.Second)
	defer tick.Stop()
	lastSave := time.Now()
	for {
		select {
		case <-ctx.Done():
			o.mu.Lock()
			err := o.cache.Save(opts.SnapshotPath)
			if excl {
				_ = o.excl.Save(opts.ExcludeSnapshotPath)
			}
			o.mu.Unlock()
			o.setState(false, err)
			_ = writeStatus(opts.StatusPath, o.status())
			return nil
		case now := <-tick.C:
			apply(o.SetLocalAddresses(routerAddresses()))
			if data, err := os.ReadFile(opts.DomainPath); err == nil {
				if next, err := ParseRules(data); err == nil {
					apply(o.ReplaceRules(next, now))
				} else {
					o.setState(false, err)
				}
			} else {
				o.setState(false, err)
			}
			if excl {
				if next, err := readExclusions(opts.ExcludePath); err == nil {
					applyExcl(o.ReplaceExclusions(next, now))
				} else {
					o.setState(false, err)
				}
			}
			o.mu.Lock()
			changes := o.cache.Expire(now)
			all := o.cache.All(now)
			exclChanges := o.excl.Expire(now)
			exclAll := o.excl.All(now)
			if now.Sub(lastSave) >= 15*time.Second {
				_ = o.cache.Save(opts.SnapshotPath)
				if excl {
					_ = o.excl.Save(opts.ExcludeSnapshotPath)
				}
				lastSave = now
			}
			o.mu.Unlock()
			apply(changes)
			applyExcl(exclChanges)
			kernelMu.Lock()
			exclRetry := exclPending
			kernelMu.Unlock()
			if exclRetry {
				reconcileExcl(exclAll)
			} else {
				applyExcl(exclAll)
			}
			kernelMu.Lock()
			pending := needReconcile
			kernelMu.Unlock()
			if pending {
				reconcile(all)
			} else {
				applyAll(all)
			}
			_ = writeStatus(opts.StatusPath, o.status())
		}
	}
}

// readExclusions — домены-исключения. Нет файла — нет исключений: так у
// большинства, и это не ошибка наблюдателя.
func readExclusions(path string) (Rules, error) {
	data, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		data, err = []byte("v1\n"), nil
	}
	if err != nil {
		return Rules{}, err
	}
	return ParseRules(data)
}
